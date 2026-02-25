# GKE Standard Private Cluster Deployment Script

This repository contains scripts to automate the creation of a Google Kubernetes Engine (GKE) Standard private cluster. It is designed to provision a secure and production-ready cluster with a variety of features enabled by default.

There are two scripts available:
- `create-gke-cluster.sh`: Creates a zonal GKE cluster.
- `create-gke-regional-cluster.sh`: Creates a regional GKE cluster.

## Features

The scripts provision a GKE cluster with the following features:

*   **Private Cluster:** Worker nodes have no external IP addresses.
*   **Private Control Plane:** The Kubernetes API server is only accessible from authorized networks.
*   **Workload Identity:** For secure authentication of workloads to Google Cloud services.
*   **Shielded Nodes:** Provides verifiable integrity of your nodes.
*   **Custom VPC Networking:** Deploys the cluster into a pre-existing VPC and subnet.
*   **Dataplane V2:** For improved networking performance and security, with metrics and flow observability.
*   **Enhanced Monitoring:** In-depth monitoring for various Kubernetes resources.
*   **Managed Prometheus:** For scraping Prometheus-style metrics.
*   **Gateway API**: The script enables the `standard` channel of the Gateway API.

## Prerequisites

Before running the scripts, ensure you have the following:

*   `gcloud` CLI installed and authenticated (`gcloud auth login`).
*   A Google Cloud project with the required APIs enabled (the script will attempt to enable them).
*   A pre-existing VPC and subnet that match the configuration you will set.

## Configuration

All configuration for the scripts is handled through a `config.sh` file. This allows you to define all your settings in one place and keeps your specific configuration separate from the core script logic.

### Step 1: Create Your Configuration File

A template is provided to make configuration easy. Copy the example file to create your own personal configuration:

```bash
cp config.sh.example config.sh
```

**Important:** The `config.sh` file is included in `.gitignore`, so your local configuration will not be committed to your repository. This is done to protect sensitive information like your Project ID.

### Step 2: Edit `config.sh`

Open `config.sh` in a text editor. It contains all the variables needed to create your cluster. The file is heavily commented to explain what each variable does.

Key variables to customize include:
- `PROJECT_ID`
- `REGION` and `ZONE`
- `CLUSTER_NAME`
- `VPC_NETWORK` and `VPC_SUBNET`
- `MASTER_AUTHORIZED_NETWORKS` (to allow your IP to access the cluster)

The scripts will automatically load the variables from this file when you run them. If `config.sh` does not exist, the script will exit with an error.

## Usage

Once you have created and customized your `config.sh` file, you can run either of the creation scripts.

1.  **Make the script executable:**

    Use this script to create a Zonal Cluster
    ```bash
    chmod +x create-gke-cluster.sh
    ```

    Use this script to create a Regional Cluster
    ```bash
    chmod +x create-gke-regional-cluster.sh
    ```

2.  **Run the desired script:**

    *   **To create a zonal cluster:**
        ```bash
        ./create-gke-cluster.sh
        ```

    *   **To create a regional cluster:**
        ```bash
        ./create-gke-regional-cluster.sh
        ```

The script will then guide you through the rest of the process.

## Post-Creation

After the cluster is created, the script will:

1.  **Configure `kubectl`:** It will fetch the credentials for the new cluster so you can use `kubectl` to interact with it.
2.  **Verify the cluster:** It will run a series of checks to verify that the cluster is configured correctly, including checking node status, Dataplane V2, Workload Identity, and more.
3.  **Display access instructions:** It will print instructions on how to access the cluster's private control plane.
4.  **Display monitoring instructions:** It will provide information on the monitoring features and how to use them.

## Accessing the Cluster

Since this is a private cluster with an authorized network, you can access the Kubernetes API server in the following ways:

*   **From an authorized IP address:** If your current IP is in the `MASTER_AUTHORIZED_NETWORKS` list in your `config.sh`, you can use `kubectl` directly.
*   **Add your IP to the authorized network:** You can run a `gcloud` command to add your IP to the list.
*   **From Google Cloud Shell:** Cloud Shell is automatically authorized for clusters in the same project.
*   **From a bastion host:** You can set up a bastion host in the same VPC as the cluster.

The script will output detailed instructions on how to do this after the cluster is created.
