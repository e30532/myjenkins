FROM registry.access.redhat.com/ubi8/ubi-minimal AS build
USER root
RUN microdnf install -y \
    java-11-openjdk-headless \
    maven && \
    microdnf clean all
WORKDIR /app
COPY . .
RUN mvn install

FROM icr.io/appcafe/websphere-liberty:25.0.0.12-kernel-java8-openj9-ubi-minimal
ARG VERBOSE=true
MAINTAINER Yoshiki Yamada, e30532@jp.ibm.com
COPY --chown=1001:0  server.xml /config/server.xml
COPY --chown=1001:0 --from=build /app/target/*.war /config/dropins/myjenkins.war
ARG FEATURE_REPO_URL=http://9.60.239.24/WLP/wlp-featureRepo-25.0.0.12.zip
ENV WLP_LOGGING_CONSOLE_FORMAT=JSON
ENV WLP_LOGGING_CONSOLE_LOGLEVEL=info
ENV WLP_LOGGING_CONSOLE_SOURCE=message,trace,accessLog,ffdc,audit
RUN configure.sh
