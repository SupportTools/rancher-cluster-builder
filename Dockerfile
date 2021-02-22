FROM ubuntu:latest
MAINTAINER Matthew Mattox <mmattox@support.tools>

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -yq --no-install-recommends \
    apt-utils \
    curl \
    python3-pip \
    awscli \
    openssh-client \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

## Install kubectl
RUN curl -kLO "https://storage.googleapis.com/kubernetes-release/release/$(curl -ks https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl" && \
chmod u+x kubectl && \
mv kubectl /usr/local/bin/kubectl

## Install RKE
RUN curl -kLO "https://github.com/rancher/rke/releases/download/v1.2.4/rke_linux-amd64" && \
chmod u+x rke_linux-amd64 && \
mv rke_linux-amd64 /usr/local/bin/rke

## Install Helm3
RUN curl -kLO "https://get.helm.sh/helm-v3.5.0-linux-amd64.tar.gz" && \
tar -zvxf helm-* && \
cd linux-amd64 && \
chmod u+x helm && \
mv helm /usr/local/bin/helm
