#!/usr/bin/env bash

echo "Setting up SSH key..."
if [[ -z $SSH_KEY ]]
then
  echo "SSH Key is missing"
  exit 1
fi
mkdir /root/.ssh && echo "$SSH_KEY" > /root/.ssh/id_rsa && chmod 0600 /root/.ssh/id_rsa

if [[ -z $Action ]] || [[ -z $Cluster ]]
then
  echo "Action and Cluster must be set"
  exit 1
fi

if [[ "$Action" == "cluster_up" ]]
then
  if [[ ! -d ~/clusters/"$Cluster" ]]
  then
    echo "Cluster folder is missing"
    exit 2
  else
    cd ~/clusters/"$Cluster"
    if [[ ! -f ./cluster.yml ]]
    then
      echo "cluster.yml is missing"
      exit 3
    else
      rke up --config cluster.yml
    fi
  fi
fi
