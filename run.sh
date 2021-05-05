#!/bin/bash
CWD=`pwd`
timestamp() {
  date "+%Y-%m-%d %H:%M:%S"
}
techo() {
  echo "$(timestamp): $*"
}
decho() {
  if [[ ! -z $DEBUG ]]
  then
    techo "$*"
  fi
}
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
  if [[ "$DEBUG" == "true" ]]
  then
    ls -lh $CWD"/clusters/"$Cluster
  fi
  if [[ ! -d "$CWD"/clusters/"$Cluster" ]] && [[ ! "$Cluster" == "all" ]]
  then
    echo "Cluster folder is missing"
    exit 2
  fi
  if [[ ! -f "$CWD"/clusters/"$Cluster"/cluster.yml ]] && [[ ! "$Cluster" == "all" ]]
  then
    echo "cluster.yml is missing"
    exit 3
  fi
}
pull-files-from-s3() {
  aws s3 sync --exclude="cluster.yml" --endpoint-url="$S3_ENDPOINT" s3://"$S3_BUCKET"/clusters/"$Cluster"/ "$CWD"/clusters/"$Cluster"/
}
push-files-to-s3() {
  aws s3 sync --endpoint-url="$S3_ENDPOINT" "$CWD"/clusters/"$Cluster"/ s3://"$S3_BUCKET"/clusters/"$Cluster"/
}
update-creds-in-cluster-yml() {
  cd "$CWD"/clusters/"$Cluster"
  if [[ -f ./creds ]]
  then
    techo "Found creds file, updating cluster.yml"
    while read line;
    do
      find=`echo $line | awk -F '=' '{print $1}'`
      replace=`echo $line | awk -F '=' '{print $2}'`
      techo "Find and replacing value for $find"
      cat cluster.yml | sed "s|${find}|${replace}|g" > cluster.tmp
      if [[ -z cluster.tmp ]]
      then
        echo "Problem"
        exit 5
      fi
      mv cluster.tmp cluster.yml
    done < ./creds
    techo "Updated creds in cluster.yml"
  else
    techo "No creds file, skipping"
  fi
}
rolling_reboot() {
  pull-files-from-s3
  cd "$CWD"/clusters/"$Cluster"
  export KUBECONFIG=./kube_config_cluster.yml
  for node in `kubectl get nodes -o name | awk -F'/' '{print $2}'`
  do
    echo "Node: $node"
    ipaddress=`kubectl get node $node -o jsonpath='{.metadata.annotations.rke\.cattle\.io/external-ip}'`
    if [[ -z $ipaddress ]]
    then
      ipaddress=`kubectl get node $node -o jsonpath='{.metadata.annotations.rke\.cattle\.io/internal-ip}'`
    fi
    echo "IpAddress: $ipaddress"
    status=`kubectl get nodes "$node" | tail -n1 | awk '{print $2}'`
    echo "Checking if node is ready..."
    if [[ "$status" == "Ready" ]]
    then
      echo "Cordoning node..."
      kubectl cordon "$node"
      ## Skipping drain to speed up rolling reboot
      #kubectl drain "$node" --ignore-daemonsets --delete-local-data --force --grace-period=60
      echo "Updating..."
      ssh -q -o StrictHostKeyChecking=no -o GlobalKnownHostsFile=/dev/null -o UserKnownHostsFile=/dev/null root@"$ipaddress" 'apt update -y && apt upgrade -y; reboot'
      echo "Rebooting..."
      sleep 30
      echo "Waiting for ping..."
      while ! ping -c 1 $ipaddress
      do
        echo "Waiting..."
        sleep 1
      done
      echo "Waiting for docker..."
      while ! ssh -q -o StrictHostKeyChecking=no -o GlobalKnownHostsFile=/dev/null -o UserKnownHostsFile=/dev/null root@"$ipaddress" "docker ps"
      do
        echo "Waiting..."
        sleep 1
      done
      echo "Waiting for node ready..."
      while ! kubectl get nodes "$node" | tail -n1 | awk '{print $2}' | grep "Ready"
      do
        echo "Waiting..."
        sleep 1
      done
      echo "Uncordoning node..."
      kubectl uncordon "$node"
      rke up
    else
       echo "Uncordoning node..."
       kubectl uncordon "$node"
    fi
  done
  push-files-to-s3
}
etcd_snapshot() {
  if [[ ! -z "$1" ]]
  then
    SnapshotName=$1
  else
    SnapshotName="builder-"`date "+%Y-%m-%d-%H-%M-%S"`
  fi
  pull-files-from-s3 $Cluster
  cd "$CWD"/clusters/"$Cluster"
  update-creds-in-cluster-yml
  techo "Taking etcd snapshot"
  techo "Snapshot Name: $SnapshotName"
  rke etcd snapshot-save --name "$SnapshotName" --config cluster.yml
}
cluster_up() {
  pull-files-from-s3 $Cluster
  cd "$CWD"/clusters/"$Cluster"
  update-creds-in-cluster-yml
  if [[ "$DEBUG" == "true" ]]
  then
    rke up --debug --config cluster.yml
  else
    rke up --config cluster.yml
  fi
  push-files-to-s3 $Cluster
}
cluster_delete() {
  pull-files-from-s3 $Cluster
  cd "$CWD"/clusters/"$Cluster"
  if [[ "$DEBUG" == "true" ]]
  then
    rke remove --debug --config cluster.yml
  else
    rke remove --config cluster.yml
  fi
  push-files-to-s3 $Cluster
}
install_cert-manager() {
  kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v1.0.4/cert-manager.crds.yaml
  kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
  helm repo add jetstack https://charts.jetstack.io
  helm repo update
  helm upgrade --install \
  cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version v1.0.4
}
rancher_up() {
  cd "$CWD"/clusters/"$Cluster"
  techo "Checking for rancher-values.yaml"
  if [[ ! -f rancher-values.yaml ]]
  then
    techo "Missing rancher-values.yaml, canceling to Rancher Upgrade/Install"
    exit 8
  fi
  update-creds-in-cluster-yml
  techo "Taking per upgrade/install snapshot"
  SnapshotName="rancher-preupgrade-"`date "+%Y-%m-%d-%H-%M-%S"`
  etcd_snapshot $SnapshotName
  RC=$?
  if [ $RC -ne 0 ]
  then
    techo "etcd snapshot failed, canceling to Rancher Upgrade/Install"
    exit 6
  else
    techo "etcd snapshot was successful, processing to Rancher Upgrade/Install"
  fi
  techo "Verifing cluster access"
  export KUBECONFIG=kube_config_cluster.yml
  kubectl get nodes -o wide
  RC=$?
  if [ $RC -ne 0 ]
  then
    techo "Access failed, canceling to Rancher Upgrade/Install"
    exit 7
  fi
  techo "Creating cattle-system namespace"
  kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f -
  techo "Setting up certs"
  if cat ./rancher-values.yaml | grep -A 3 'ingress' | grep 'source: secret'
  then
    techo "Certificates from Files"
    if [[ -f tls.crt ]] && [[ -f tls.key ]]
    then
      techo "Adding tls.crt and tls.key from s3"
      kubectl -n cattle-system create secret tls tls-rancher-ingress --cert=tls.crt --key=tls.key --dry-run=client -o yaml | kubectl apply -f -
    else
      techo "Missing tls.crt and tls.key, canceling to Rancher Upgrade/Install"
      exit 9
    fi
  elif cat ./rancher-values.yaml | grep -A 3 'ingress' | grep 'source: letsEncrypt'
  then
    techo "Let’s Encrypt configured, installing cert-manager"
    install_cert-manager
  else
    techo "Rancher Generated Certificates (Default) configured, installing cert-manager"
    install_cert-manager
  fi
  techo "Adding Rancher helm repos"
  RancherChart=`cat ./rancher-values.yaml | grep 'rancher_chart:' | awk '{print $2}'`
  RancherChartUrlEnd=`echo $RancherChart | awk -F '-' '{print $2}'`
  if [[ -z $RancherChart ]]
  then
    RancherChart="rancher-latest"
    RancherChartUrlEnd="latest"
  fi
  helm repo add "$RancherChart" https://releases.rancher.com/server-charts/"$RancherChartUrlEnd"
  techo "Fetching charts"
  helm fetch "$RancherChart"/rancher
  techo "Deploying Rancher"
  RancherVerison=`cat ./rancher-values.yaml | grep 'rancher_verison:' | awk '{print $2}'`
  if [[ -z $RancherVerison ]]
  then
    techo "Installing/Upgrading Rancher to latest"
    helm upgrade --install rancher "$RancherChart" --namespace cattle-system -f values.yaml
  else
    techo "Installing/Upgrading Rancher to $RancherVerison"
    helm upgrade --install rancher "$RancherChart" --namespace cattle-system -f values.yaml --version "$RancherVerison"
  fi
  techo "Waiting for Rancher to be rolled out"
  kubectl -n cattle-system rollout status deploy/rancher -w
  techo "Taking post upgrade/install snapshot"
  SnapshotName="rancher-postupgrade-"`date "+%Y-%m-%d-%H-%M-%S"`
  etcd_snapshot $SnapshotName
  RC=$?
  if [ $RC -ne 0 ]
  then
    techo "etcd snapshot failed"
    exit 10
  else
    techo "etcd snapshot was successful"
  fi
}

#### Starting Main
if [[ -z $Action ]]
then
  echo "Action must be set"
  exit 0
fi
setup-ssh
verify-files

if [[ "$Action" == "cluster_up" ]]
then
  if [[ "$Cluster" == "all" ]]
  then
    for Cluster in `ls ./clusters`
    do
      if [[ ! "$Cluster" == "template" ]]
      then
        techo "Cluster: $Cluster"
        cluster_up
      else
        techo "Skipping template"
      fi
    done
  else
    cluster_up
  fi
elif [[ "$Action" == "cluster_delete" ]]
then
  cluster_delete
elif [[ "$Action" == "rolling_reboot" ]]
then
  rolling_reboot
elif [[ "$Action" == "rancher_up" ]]
then
  rancher_up
else
  techo "Action: $Action"
  techo "Unknown Action"
  exit 254
fi
