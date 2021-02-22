#!/bin/bash

CWD=`pwd`

setup-ssh() {
  echo "Setting up SSH key..."
  if [[ -z $SSH_KEY ]]
  then
    echo "SSH Key is missing"
    exit 1
  fi
  mkdir /root/.ssh && echo "$SSH_KEY" > /root/.ssh/id_rsa && chmod 0600 /root/.ssh/id_rsa
}

verify-files() {
  Cluster=$1
  if [[ ! -d "$CWD"/clusters/"$Cluster" ]]
  then
    echo "Cluster folder is missing"
    exit 2
  fi

  if [[ ! -f "$CWD"/clusters/cluster.yml ]]
  then
    echo "cluster.yml is missing"
    exit 3
  fi
}

pull-files-from-s3() {
  Cluster=$1
  aws s3 sync --exclude="cluster.yml" s3://"$S3_BUCKET"/clusters/"$Cluster"/ "$CWD"/clusters/"$Cluster"/
}

push-files-to-s3() {
  Cluster=$1
  aws s3 sync "$CWD"/clusters/"$Cluster"/ s3://"$S3_BUCKET"/clusters/"$Cluster"/
}

rolling_reboot() {
  Cluster=$1
  cd "$CWD"/clusters/"$Cluster"
  export KUBECONFIG=./kube_config_cluster.yml
  for node in `kubectl get nodes -o name | awk -F'/' '{print $2}'`
  do
    echo "Node: $node"
    status=`kubectl get nodes "$node" | tail -n1 | awk '{print $2}'`
    echo "Checking if node is ready..."
    if [[ "$status" == "Ready" ]]
    then
      echo "Cordoning node..."
      kubectl cordon "$node"
      kubectl drain "$node" --ignore-daemonsets --delete-local-data --force --grace-period=900
      echo "Sleeping..."
      sleep 360
      echo "Updating..."
      ssh root@"$node" 'apt update -y && apt upgrade -y'
      echo "Rebooting..."
      ssh root@"$node" 'reboot'
      echo "Sleeping..."
      sleep 360
      echo "Waiting for ping..."
      while ! ping -c 1 $node
      do
        echo "Waiting..."
        sleep 1
      done
      echo "Waiting for SSH..."
      while ! ssh root@"$node" "uptime"
      do
        echo "Waiting..."
        sleep 1
      done
      echo "Waiting for docker..."
      while ! ssh root@"$node" "docker ps"
      do
        echo "Waiting..."
        sleep 1
      done
      echo "Sleeping..."
      sleep 360
      echo "Waiting for node ready..."
      while ! kubectl get nodes "$node" | tail -n1 | awk '{print $2}' | grep "Ready"
      do
        echo "Waiting..."
        sleep 1
      done
      echo "Sleeping..."
      sleep 360
      echo "Uncordoning node..."
      kubectl uncordon "$node"
      echo "Sleeping..."
      sleep 360
      rke up
    else
       echo "Uncordoning node..."
       kubectl uncordon "$node"
    fi
  done
}

cluster_up() {
  Cluster=$1
  pull-files-from-s3 $Cluster
  cd "$CWD"/clusters/"$Cluster"
  rke up --config cluster.yml
  push-files-to-s3 $Cluster
}

cluster_new() {
  Cluster=$1
  cd "$CWD"/clusters/"$Cluster"
  rke up --config cluster.yml
  push-files-to-s3 $Cluster
}

#### Starting Main

setup-ssh
if [[ -z $Action ]] || [[ -z $Cluster ]]
then
  echo "Action and Cluster must be set"
  exit 0
fi
verify-files

if [[ "$Action" == "cluster_up" ]]
then
  cluster_up
elif [[ "$Action" == "cluster_new" ]]
then
  cluster_new
elif [[ "$Action" == "rolling_reboot" ]]
then
  rolling_reboot
else
  echo "Unknown Action"
  exit 254
fi
