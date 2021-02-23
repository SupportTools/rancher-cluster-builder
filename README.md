[![Build Status](https://drone.support.tools/api/badges/SupportTools/rancher-cluster-builder/status.svg)](https://drone.support.tools/SupportTools/rancher-cluster-builder)
[![Pulls](https://img.shields.io/docker/pulls/supporttools/rancher-cluster-builder.svg)](https://hub.docker.com/r/supporttools/rancher-cluster-builder)
[![Twitter](https://img.shields.io/twitter/follow/cube8021?style=social&logo=twitter)](https://twitter.com/cube8021)

Rancher-Clusters-Builder
========================

The rancher-clusters-builder is designed to manage RKE clusters (mainly Rancher local clusters) using a drone as the CICD pipeline, GitHub as the code repository, and Wasabisys's S3 storage for storing the artifacts from the build process.

## Required Drone secrets
- S3_ACCESSKEY
  This should be the plaintext access key for accessing the S3 bucket.
  Example: AKIAIOSFODNN7EXAMPLE

- S3_SECRETKEY
  This should be the plaintext secret key for accessing the S3 bucket.
  Example: wJalrXUtnFEMI/K7MDENG/bPxRfiCEXAMPLEKEY

- S3_BUCKET
  This should be the S3 bucket name for storing the artifacts (cluster.rkestate, kube_config_cluster.yml, tls.crt, tls.key)
  Example: rancher-clusters

- S3_ENDPOINT
  This should be the S3 API endpoint. This is optional is using AWS S3.
  Example: https://s3.us-central-1.wasabisys.com

- S3_REGION
  This should be the region for the S3 bucket.
  Example: us-east-1

- ssh_key
  This should be the plaintext SSH private key for accessing the RKE nodes.
  Example: `-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1r......\n-----END OPENSSH PRIVATE KEY-----`

## Adding a cluster
Before starting, we'll assume that the Servers in this cluster have been built and have docker installed. To add a cluster to the pipeline, you must create a folder in `clusters`; this folder name will be the cluster's name. So please try not to use any control characters or spaces in the name. Inside that folder, we'll need to create the cluster.yml using the template file provided in `clusters/template.` To protect for storing passwords in git; we use the file `creds` (An example can be found in `s3-template/creds`) to find and replace the values. Note, the creds file should be stored in S3 in the folder `clusters/ClusterName/creds.` Once the files have been created and committed to the repository. The drone build runs a basic test on the main build script, `run.sh`. Then to build the cluster, we'll promote the drone build using the following options.

- Action: Promote
- Environment: (This can be anything but it must be something)
- Parameters:
  - Action=cluster_up
  - Cluster=ClusterNameHere

Once this build is started, the tool will verify the required files are in the right place. It will then handle the process of building the RKE cluster using the command `rke up`. Once the cluster has been created, the files `cluster.rkestate` and `kube_config_cluster.yml` will be synced up to S3 as needed for the next time we do a `rke up.`

## Upgrading k8s on a cluster
We will need to edit the value for `kubernetes_version` in the cluster.yml for the cluster we would like to update. The supported Kubernetes versions can be found at [here](https://raw.githubusercontent.com/rancher/kontainer-driver-metadata/dev-v2.5/data/data.json)

Once the changes have been committed to the repository, we'll promote the drone build using the following options.

- Action: Promote
- Environment: (This can be anything but it must be something)
- Parameters:
  - Action=cluster_up
  - Cluster=ClusterNameHere

## Installing/Upgrading Rancher on an RKE cluster
We'll assume that the RKE cluster is being managed by this tool. To install/upgrade Rancher on a cluster, we'll need to create the file `rancher-values.yaml` in the cluster folder that we want to deploy to. All the install flags can be found [here](https://rancher.com/docs/rancher/v2.x/en/installation/install-rancher-on-k8s/) Note: If you're going to bring your certificate, you'll need to upload the certificate and key to the S3 bucket under the cluster folder with the file names tls.crt and tls.key.

Once the changes have been committed to the repository, we'll promote the drone build using the following options.

- Action: Promote
- Environment: (This can be anything but it must be something)
- Parameters:
  - Action=rancher_up
  - Cluster=ClusterNameHere

## Applying a rolling reboot to a cluster
To do a safe rolling reboot of an RKE cluster, we'll cordon and drain the node. Then reboot the server and wait for the node to return. Once the node has returned, we'll uncordon it and run an RKE up to verify the cluster is healthy. Once all that is done, we'll move on to the next node in the cluster. Note: This process has many periods of sleep sections and is designed to be as safe as possible.
