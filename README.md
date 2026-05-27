This document describes a simple example to configure CI/CD with OCP and Jenkins.

1. First, provision OCPv4.21.11.   

2. create a new project/namespace.   
```
# oc login --token=*** --server=https://api.***.ibm.com:6443
The server uses a certificate signed by an unknown authority.
You can bypass the certificate check, but any data you send to the server could be intercepted by others.
Use insecure connections? (y/n): y

WARNING: Using insecure TLS client config. Setting this option is not supported!

Logged into "https://api.***.ibm.com:6443" as "kube:admin" using the token provided.

You have access to 73 projects, the list has been suppressed. You can list all projects with 'oc projects'

Using project "default".
# oc get clusterversion
NAME      VERSION   AVAILABLE   PROGRESSING   SINCE   STATUS
version   4.21.11   True        False         3m49s   Cluster version is 4.21.11
# oc new-project e30532
Now using project "e30532" on server "https://api.***.ibm.com:6443".

You can add applications to this project with the 'new-app' command. For example, try:

    oc new-app rails-postgresql-example

to build a new example application in Ruby. Or use kubectl to deploy a simple Kubernetes application:

    kubectl create deployment hello-node --image=registry.k8s.io/e2e-test-images/agnhost:2.43 -- /agnhost serve-hostname

# 
```
3. Install jenkins template (Ecosystem -> Software Catalog -> CI/CD -> Jenkins(Ephemeral)) with default options in the namespace you just created.   
```
# oc get all -n e30532
Warning: apps.openshift.io/v1 DeploymentConfig is deprecated in v4.14+, unavailable in v4.10000+
NAME                   READY   STATUS      RESTARTS   AGE
pod/jenkins-1-deploy   0/1     Completed   0          54s
pod/jenkins-1-wp4hp    1/1     Running     0          53s

NAME                              DESIRED   CURRENT   READY   AGE
replicationcontroller/jenkins-1   1         1         1       54s

NAME                   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)     AGE
service/jenkins        ClusterIP   172.30.87.234   <none>        80/TCP      55s
service/jenkins-jnlp   ClusterIP   172.30.69.73    <none>        50000/TCP   55s

NAME                                         REVISION   DESIRED   CURRENT   TRIGGERED BY
deploymentconfig.apps.openshift.io/jenkins   1          1         1         config,image(jenkins:2)

NAME                               HOST/PORT                                        PATH   SERVICES   PORT    TERMINATION     WILDCARD
route.route.openshift.io/jenkins   jenkins-e30532.apps.***.ibm.com          jenkins    <all>   edge/Redirect   None
# 
```

5. Because jenkins maven agent is no longer available in newer OCP, we need to create own maven agent.

5.1. externalize the OCP internal image registry.   
```
# oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge
config.imageregistry.operator.openshift.io/cluster patched
# oc get route -A | grep image
openshift-image-registry   default-route             default-route-openshift-image-registry.apps.***.ibm.com                     image-registry      <all>   reencrypt              None
#
```
5.2. register the image registry as insecure and login to the registry.   
```
# vi /etc/containers/registries.conf
# tail -n 3 /etc/containers/registries.conf
[[registry]]
location = "default-route-openshift-image-registry.apps.***.ibm.com"
insecure = true
# podman login -u kubeadmin -p $(oc whoami -t) https://default-route-openshift-image-registry.apps.***.ibm.com
Login Succeeded!
# 
```
5.3. augument the existing jenkins-agent-base with maven and use it as jenkins-agent-maven. It's important to add a label and an annotation so that jenkins can recognize it automatically.        
```
# oc get is -n openshift | grep jenkins-agent
jenkins-agent-base                                   default-route-openshift-image-registry.apps.***.ibm.com/openshift/jenkins-agent-base                                   latest,scheduled-upgrade,user-maintained-upgrade         36 minutes ago
# vi Containerfile 
# cat Containerfile 
FROM default-route-openshift-image-registry.apps.***.ibm.com/openshift/jenkins-agent-base:latest

USER root

RUN yum install -y maven git tar gzip && \
    yum clean all

USER 1001
#
# podman build -t jenkins-agent-maven .
# podman tag jenkins-agent-maven default-route-openshift-image-registry.apps.***.ibm.com/openshift/jenkins-agent-maven:latest
# podman push default-route-openshift-image-registry.apps.***.ibm.com/openshift/jenkins-agent-maven:latest
# oc label is/jenkins-agent-maven role=jenkins-agent -n openshift
imagestream.image.openshift.io/jenkins-agent-maven labeled
# oc annotate is/jenkins-agent-maven agent-label=maven -n openshift
imagestream.image.openshift.io/jenkins-agent-maven annotated
# 
```


6. create a pipeline.   
<img width="734" height="442" alt="image" src="https://github.com/user-attachments/assets/637dde6e-fead-441a-995a-30816ad0bdbd" />    

Because the github.com can't directly access the jenkins running in Fyre(behind F/W), we use SCM Polling instead of WebHook.     

<img width="602" height="276" alt="image" src="https://github.com/user-attachments/assets/28c026c9-04e7-4409-b58c-129ca3250794" />    

In this example, I use https://github.com/e30532/myjenkins.    

<img width="825" height="701" alt="image" src="https://github.com/user-attachments/assets/0b2fd943-111e-4357-b248-203819c4712f" />    

8. In the Docker file, there are two steps. In the first phase, the application is packaged as a war file. In the later phase, a liberty image is built with the new application.    
```
# cat Dockerfile 
FROM registry.access.redhat.com/ubi8/ubi-minimal AS build
USER root
RUN microdnf install -y \
    java-11-openjdk-headless \
    maven && \
    microdnf clean all
WORKDIR /app
COPY . .
RUN mvn install

FROM icr.io/appcafe/websphere-liberty:latest
MAINTAINER Yoshiki Yamada, e30532@jp.ibm.com
COPY --chown=1001:0  server.xml /config/server.xml
COPY --chown=1001:0 --from=build /app/target/*.war /config/dropins/myjenkins.war
# ARG VERBOSE=true
ENV WLP_LOGGING_CONSOLE_FORMAT=JSON
ENV WLP_LOGGING_CONSOLE_LOGLEVEL=info
ENV WLP_LOGGING_CONSOLE_SOURCE=message,trace,accessLog,ffdc,audit
RUN configure.sh
```

8. As you see in Jenkinsfile, it uses a buildconfig named myjenkins. So we need to create it at OCP side in the namespace.    
```
# cat Jenkinsfile 
library identifier: "pipeline-library@v1.5",
retriever: modernSCM(
  [
    $class: "GitSCMSource",
    remote: "https://github.com/redhat-cop/pipeline-library.git"
  ]
)

appName = "myjenkins"

pipeline {
    agent {
      label 'maven'
    }
    stages {

        stage('Build'){
          steps {
            sh "mvn clean install -q"
          }
        }

        stage("Docker Build") {
            steps {
                binaryBuild(projectName: "e30532", buildConfigName: appName, buildFromPath: ".")
            }
        }
    }
}
```

```
# cat <<'EOF' | oc apply -f -
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  labels:
    app.kubernetes.io/name: myjenkins
  name: myjenkins
spec:
  output:
    to:
      kind: ImageStreamTag
      name: myjenkins:latest
  source:
    type: Binary
    binary: {}
  strategy:
    type: Docker
    dockerStrategy:
      dockerfilePath: Dockerfile
EOF
buildconfig.build.openshift.io/myjenkins created
# oc get bc -n e30532
NAME        TYPE     FROM     LATEST
myjenkins   Docker   Binary   0
# oc create imagestream myjenkins
imagestream.image.openshift.io/myjenkins created
# oc get is -n e30532
NAME        IMAGE REPOSITORY                                                                          TAGS   UPDATED
myjenkins   default-route-openshift-image-registry.apps.***.ibm.com/e30532/myjenkins          
#
```

9. Let's build by clicking "Buld Now" button in the jenkins console.

<img width="461" height="339" alt="image" src="https://github.com/user-attachments/assets/8304623e-6715-4fc1-a5bd-b2f32ac5796a" />    

```
# oc get build
NAME          TYPE     FROM             STATUS    STARTED          DURATION
myjenkins-1   Docker   Binary@f26558b   Running   26 seconds ago   
# oc get pod
NAME                READY   STATUS      RESTARTS   AGE
jenkins-1-deploy    0/1     Completed   0          70m
jenkins-1-wp4hp     1/1     Running     0          70m
maven-k2fn5         1/1     Running     0          81s
myjenkins-1-build   1/1     Running     0          34s
:
Note: maven-k2fn5 is the pod of that we created as a jenkins agent (jenkins-agent-maven). 
:
# oc get pod
NAME                READY   STATUS      RESTARTS   AGE
jenkins-1-deploy    0/1     Completed   0          73m
jenkins-1-wp4hp     1/1     Running     0          73m
myjenkins-1-build   0/1     Completed   0          3m45s 
# oc logs -f myjenkins-1-build |tail -n 3
Defaulted container "docker-build" out of: docker-build, git-clone (init), manage-dockerfile (init)
Writing manifest to image destination
Successfully pushed image-registry.openshift-image-registry.svc:5000/e30532/myjenkins@sha256:d928571908519a3d9e9c539c262babe75b522b4a5d3a6c4ed4b1c4959fc03f64
Push successful
# 
```



10. Let's create an application using the image stream.   
```
# oc new-app myjenkins
# oc expose service/myjenkins
# oc get route | grep myjenkins
myjenkins   myjenkins-e30532.apps.***.ibm.com          myjenkins   9080-tcp                   None
# curl http://myjenkins-e30532.apps.***.ibm.com/myjenkins/SimpleServlet
** Served at: /myjenkins
#
```

11. By pushing the change to the github repository, 

```
# tree
.
├── argocd
│   └── myliberty.yaml
├── argocd2
│   └── myliberty.yaml
├── Dockerfile
├── Jenkinsfile
├── pom.xml
├── README.md
├── server.xml
└── src
    └── myjenkins
        └── SimpleServlet.java

4 directories, 8 files
# vi src/myjenkins/SimpleServlet.java
# git add .
# git commit -m "update SimpleServlet"
# git push
```

A new build is kicked.   
```
# oc get build
NAME          TYPE     FROM             STATUS     STARTED          DURATION
myjenkins-1   Docker   Binary@f26558b   Complete   14 minutes ago   2m46s
myjenkins-2   Docker   Binary@7830766   Running    8 seconds ago
```


Once the build is completed, a new image is published to the internal registry and the application pod is recreated with the new image.    
```
# oc get pod
NAME                         READY   STATUS      RESTARTS   AGE
jenkins-1-deploy             0/1     Completed   0          85m
jenkins-1-wp4hp              1/1     Running     0          85m
myjenkins-1-build            0/1     Completed   0          16m
myjenkins-2-build            0/1     Completed   0          2m24s
myjenkins-65f465c64f-p42xv   1/1     Running     0          14s
[root@v2-3068815 myjenkins]# curl http://myjenkins-e30532.apps.***.ibm.com/myjenkins/SimpleServlet
** UPDATE Served at: /myjenkins
# 
```


