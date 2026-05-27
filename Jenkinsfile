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
