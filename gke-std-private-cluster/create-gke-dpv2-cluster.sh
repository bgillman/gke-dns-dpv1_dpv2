#!/bin/bash

################################################################################
# GKE Private Standard Cluster Deployment Script
#
# This script creates a GKE Standard cluster with:
# - Private worker nodes
# - Fully private control plane — NO public IP, NO IP endpoint
# - DNS-based endpoint as the sole external access method
# - Workload Identity enabled
# - Shielded nodes
# - Custom VPC networking
# - Dataplane V2 (eBPF-based CNI with metrics and flow observability)
# - Cloud DNS as the cluster DNS provider (replaces kube-dns)
# - Enhanced monitoring (including Storage, Pod, Deployment, etc.)
################################################################################

set -e  # Exit on error
set -u  # Exit on undefined variable

################################################################################
# CONFIGURATION VARIABLES
################################################################################

# CONFIGURATION
# ------------------------------------------------------------------------------
# The script sources variables from the `config.sh` file.
# If the file doesn't exist, it exits with an error.

if [ -f "config.sh" ]; then
    # shellcheck source=config.sh
    source "config.sh"
else
    echo "ERROR: Configuration file 'config.sh' not found."
    echo "Please copy 'config.sh.example' to 'config.sh' and customize it."
    exit 1
fi

################################################################################
# COLOR OUTPUT
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

################################################################################
# PREREQUISITES CHECK
################################################################################

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check if gcloud is installed
    if ! command -v gcloud &> /dev/null; then
        log_error "gcloud CLI is not installed. Please install it first."
        exit 1
    fi

    # Check if logged in
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" &> /dev/null; then
        log_error "Not authenticated with gcloud. Please run: gcloud auth login"
        exit 1
    fi

    # Check project is set
    if [ -z "$PROJECT_ID" ]; then
        log_error "PROJECT_ID is not set. Please set it or configure: gcloud config set project PROJECT_ID"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

################################################################################
# ENABLE REQUIRED APIS
################################################################################

enable_apis() {
    log_info "Enabling required Google Cloud APIs..."

    gcloud services enable \
        container.googleapis.com \
        compute.googleapis.com \
        cloudresourcemanager.googleapis.com \
        monitoring.googleapis.com \
        logging.googleapis.com \
        gkehub.googleapis.com \
        dns.googleapis.com \
        --project="$PROJECT_ID"

    log_success "Required APIs enabled"
}

################################################################################
# DISPLAY CONFIGURATION
################################################################################

display_configuration() {
    log_info "Cluster Configuration:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Project ID:           $PROJECT_ID"
    echo "Cluster Name:         $CLUSTER_NAME"
    echo "Region:               $REGION"
    echo "Zone:                 $ZONE"
    echo "Cluster Version:      $CLUSTER_VERSION"
    echo "Release Channel:      $RELEASE_CHANNEL"
    echo ""
    echo "Network Configuration:"
    echo "  VPC Network:        $VPC_NETWORK_NAME"
    echo "  VPC Subnet:         $VPC_SUBNET_NAME"
    echo "  Pod Range:          $POD_RANGE_NAME ($POD_CIDR)"
    echo "  Services Range:     $SERVICES_RANGE_NAME ($SERVICE_CIDR)"
    echo ""
    echo "Node Configuration:"
    echo "  Machine Type:       $MACHINE_TYPE"
    echo "  Number of Nodes:    $NUM_NODES"
    echo "  Disk Type:          $DISK_TYPE"
    echo "  Disk Size:          ${DISK_SIZE}GB"
    echo "  Max Pods/Node:      $MAX_PODS_PER_NODE"
    echo ""
    echo "Security Features:"
    echo "  Private Nodes:      ✓ Enabled"
    echo "  Control Plane IP:   ✗ Disabled (no public or IP-based endpoint)"
    echo "  DNS Endpoint:       ✓ Enabled (sole access method)"
    echo "  Workload Identity:  ✓ Enabled"
    echo "  Shielded Nodes:     ✓ Enabled"
    echo "  Dataplane V2:       ✓ Enabled (eBPF CNI)"
    echo "  DPv2 Metrics:       ✓ Enabled"
    echo "  DPv2 Flow Obs:      ✓ Enabled"
    echo "  Cluster DNS:        Cloud DNS (VPC scope, domain: $CLUSTER_DNS_DOMAIN)"
    echo ""
    echo "Monitoring & Logging:"
    echo "  Logging:            SYSTEM, WORKLOAD"
    echo "  Monitoring:         SYSTEM, STORAGE, POD, DEPLOYMENT, STATEFULSET,"
    echo "                      DAEMONSET, HPA, JOBSET, CADVISOR, KUBELET, DCGM"
    echo "  Managed Prometheus: ✓ Enabled"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

################################################################################
# CREATE GKE CLUSTER
################################################################################

create_cluster() {
    log_info "Creating GKE cluster '$CLUSTER_NAME'..."
    log_warning "This may take 10-15 minutes..."

    gcloud beta container clusters create "$CLUSTER_NAME" \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --node-locations="$ZONE" \
        --cluster-version="$CLUSTER_VERSION" \
        --release-channel="$RELEASE_CHANNEL" \
        \
        `# Authentication` \
        --no-enable-basic-auth \
        \
        `# Network Configuration` \
        --network="$VPC_NETWORK" \
        --subnetwork="$VPC_SUBNET" \
        --enable-ip-alias \
        --cluster-secondary-range-name="$POD_RANGE_NAME" \
        --services-secondary-range-name="$SERVICES_RANGE_NAME" \
        --no-enable-intra-node-visibility \
        --default-max-pods-per-node="$MAX_PODS_PER_NODE" \
        \
        `# Private Cluster Configuration` \
        --enable-private-nodes \
        \
        `# Endpoint Access — DNS only, IP endpoint fully disabled` \
        --enable-dns-access \
        --no-enable-ip-access \
        \
        `# Security Features` \
        --workload-pool="${PROJECT_ID}.svc.id.goog" \
        --enable-shielded-nodes \
        --shielded-integrity-monitoring \
        --no-shielded-secure-boot \
        --security-posture=standard \
        --workload-vulnerability-scanning=disabled \
        --binauthz-evaluation-mode=DISABLED \
        \
        `# Dataplane V2 (eBPF-based CNI)` \
        --enable-dataplane-v2 \
        --enable-dataplane-v2-metrics \
        --enable-dataplane-v2-flow-observability \
        \
        `# Cluster DNS — Cloud DNS replaces kube-dns` \
        --cluster-dns=clouddns \
        --cluster-dns-scope=vpc \
        --cluster-dns-domain="$CLUSTER_DNS_DOMAIN" \
        \
        `# Node Pool Configuration` \
        --num-nodes="$NUM_NODES" \
        --machine-type="$MACHINE_TYPE" \
        --disk-type="$DISK_TYPE" \
        --disk-size="$DISK_SIZE" \
        --image-type="$IMAGE_TYPE" \
        --metadata=disable-legacy-endpoints=true \
        \
        `# Maintenance and Updates` \
        --enable-autorepair \
        --enable-autoupgrade \
        --max-surge-upgrade="$MAX_SURGE_UPGRADE" \
        --max-unavailable-upgrade="$MAX_UNAVAILABLE_UPGRADE" \
        \
        `# Monitoring and Logging` \
        --logging=SYSTEM,WORKLOAD \
        --monitoring=SYSTEM,STORAGE,POD,DEPLOYMENT,STATEFULSET,DAEMONSET,HPA,JOBSET,CADVISOR,KUBELET,DCGM \
        --enable-managed-prometheus \
        \
        `# Addons` \
        --addons=HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver \
        --gateway-api=standard \
        \
        `# Fleet` \
        --fleet-project="$PROJECT_ID" \
        \
        `# Tags and Labels` \
        --tags="gke-cluster,private-cluster" \
        --labels="environment=lab-test,managed-by=script"

    if [ $? -eq 0 ]; then
        log_success "Cluster '$CLUSTER_NAME' created successfully!"
    else
        log_error "Failed to create cluster"
        exit 1
    fi
}

################################################################################
# CONFIGURE KUBECTL
################################################################################

configure_kubectl() {
    log_info "Configuring kubectl credentials..."

    gcloud container clusters get-credentials "$CLUSTER_NAME" \
        --region="$REGION" \
        --project="$PROJECT_ID" \
        --dns-endpoint

    log_success "kubectl configured for cluster '$CLUSTER_NAME'"
}

################################################################################
# VERIFY CLUSTER
################################################################################

verify_cluster() {
    log_info "Verifying cluster configuration..."

    # Get cluster info
    log_info "Cluster Details:"
    gcloud container clusters describe "$CLUSTER_NAME" \
        --region="$REGION" \
        --project="$PROJECT_ID" \
        --format="table(
            name,
            location,
            currentMasterVersion,
            currentNodeCount,
            status
        )"

    # Check nodes
    log_info "Checking node status..."
    kubectl get nodes -o wide 2>/dev/null || log_warning "Could not reach cluster via DNS endpoint (ensure you are running from within Google Cloud or via a VPN/Interconnect into the VPC)"

    # Verify Dataplane V2
    log_info "Verifying Dataplane V2..."
    DATAPLANE=$(gcloud container clusters describe "$CLUSTER_NAME" \
        --region="$REGION" \
        --project="$PROJECT_ID" \
        --format="value(networkConfig.datapathProvider)")

    if [ "$DATAPLANE" == "ADVANCED_DATAPATH" ]; then
        log_success "Dataplane V2 (ADVANCED_DATAPATH) is enabled"
    else
        log_warning "Dataplane provider status: $DATAPLANE (expected ADVANCED_DATAPATH)"
    fi

    # Verify control plane has NO public IP endpoint
    log_info "Verifying control plane endpoint configuration..."
    IP_ACCESS=$(gcloud container clusters describe "$CLUSTER_NAME" \
        --region="$REGION" \
        --project="$PROJECT_ID" \
        --format="value(controlPlaneEndpointsConfig.ipEndpointsConfig.enabled)")

    if [ "$IP_ACCESS" == "False" ] || [ -z "$IP_ACCESS" ]; then
        log_success "IP endpoint is disabled — control plane has no public IP"
    else
        log_error "IP endpoint is ENABLED — control plane may have a public IP. Review cluster configuration."
    fi

    # Verify DNS endpoint is enabled
    log_info "Verifying DNS-based endpoint..."
    DNS_ACCESS=$(gcloud container clusters describe "$CLUSTER_NAME" \
        --region="$REGION" \
        --project="$PROJECT_ID" \
        --format="value(controlPlaneEndpointsConfig.dnsEndpointConfig.enabled)")

    if [ "$DNS_ACCESS" == "True" ]; then
        DNS_ENDPOINT=$(gcloud container clusters describe "$CLUSTER_NAME" \
            --region="$REGION" \
            --project="$PROJECT_ID" \
            --format="value(controlPlaneEndpointsConfig.dnsEndpointConfig.endpoint)")
        log_success "DNS endpoint is enabled: $DNS_ENDPOINT"
    else
        log_warning "DNS endpoint status: $DNS_ACCESS"
    fi

    # Verify Cloud DNS
    log_info "Verifying Cloud DNS configuration..."
    CLUSTER_DNS=$(gcloud container clusters describe "$CLUSTER_NAME" \
        --region="$REGION" \
        --project="$PROJECT_ID" \
        --format="value(networkConfig.dnsConfig.clusterDns)")

    DNS_SCOPE=$(gcloud container clusters describe "$CLUSTER_NAME" \
        --region="$REGION" \
        --project="$PROJECT_ID" \
        --format="value(networkConfig.dnsConfig.clusterDnsScope)")

    DNS_DOMAIN=$(gcloud container clusters describe "$CLUSTER_NAME" \
        --region="$REGION" \
        --project="$PROJECT_ID" \
        --format="value(networkConfig.dnsConfig.clusterDnsDomain)")

    if [ "$CLUSTER_DNS" == "CLOUD_DNS" ]; then
        log_success "Cluster DNS provider: Cloud DNS (scope: $DNS_SCOPE, domain: $DNS_DOMAIN)"
    else
        log_warning "Cluster DNS provider: $CLUSTER_DNS (expected CLOUD_DNS)"
    fi

    # Verify Workload Identity
    log_info "Verifying Workload Identity..."
    WI_POOL=$(gcloud container clusters describe "$CLUSTER_NAME" \
        --region="$REGION" \
        --project="$PROJECT_ID" \
        --format="value(workloadIdentityConfig.workloadPool)")

    if [ -n "$WI_POOL" ]; then
        log_success "Workload Identity enabled: $WI_POOL"
    else
        log_error "Workload Identity not detected"
    fi

    # Verify Private Nodes
    log_info "Verifying Private Nodes configuration..."
    PRIVATE_NODES=$(gcloud container clusters describe "$CLUSTER_NAME" \
        --region="$REGION" \
        --project="$PROJECT_ID" \
        --format="value(privateClusterConfig.enablePrivateNodes)")

    if [ "$PRIVATE_NODES" == "True" ]; then
        log_success "Private nodes are enabled"
    else
        log_warning "Private nodes status: $PRIVATE_NODES"
    fi

    # Verify Managed Prometheus
    log_info "Verifying Managed Prometheus..."
    PROMETHEUS=$(gcloud container clusters describe "$CLUSTER_NAME" \
        --region="$REGION" \
        --project="$PROJECT_ID" \
        --format="value(monitoringConfig.managedPrometheusConfig.enabled)")

    if [ "$PROMETHEUS" == "True" ]; then
        log_success "Managed Prometheus is enabled"
    else
        log_warning "Managed Prometheus status: $PROMETHEUS"
    fi

    log_success "Cluster verification complete!"
}

################################################################################
# DISPLAY ACCESS INSTRUCTIONS
################################################################################

display_access_instructions() {
    log_info "Cluster Access Instructions:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "✓ FULLY PRIVATE CLUSTER — control plane has NO public IP"
    echo "✓ Access is via GKE DNS-based endpoint ONLY"
    echo ""
    echo "The DNS endpoint routes through Google's private network."
    echo "kubectl traffic does not traverse the public internet."
    echo ""
    echo "Access Requirements:"
    echo "  • Must be running from within Google Cloud (GCE VM, Cloud Shell,"
    echo "    GKE pod, Cloud Run, etc.) in the same project/VPC, OR"
    echo "  • Connected via Cloud VPN or Cloud Interconnect into the VPC"
    echo ""
    echo "Retrieve credentials (DNS endpoint):"
    echo "  gcloud container clusters get-credentials $CLUSTER_NAME \\"
    echo "    --region=$REGION \\"
    echo "    --project=$PROJECT_ID \\"
    echo "    --dns-endpoint"
    echo ""
    echo "Verify connectivity:"
    echo "  kubectl get nodes"
    echo "  kubectl cluster-info"
    echo ""
    echo "Get the DNS endpoint address:"
    echo "  gcloud container clusters describe $CLUSTER_NAME \\"
    echo "    --region=$REGION \\"
    echo "    --project=$PROJECT_ID \\"
    echo "    --format='value(controlPlaneEndpointsConfig.dnsEndpointConfig.endpoint)'"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

################################################################################
# DISPLAY MONITORING INSTRUCTIONS
################################################################################

display_monitoring_instructions() {
    log_info "Monitoring & Observability:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Enhanced Monitoring Enabled:"
    echo "  • System metrics (nodes, cluster)"
    echo "  • Storage metrics (PV, PVC)"
    echo "  • Pod metrics (CPU, memory, network)"
    echo "  • Deployment, StatefulSet, DaemonSet metrics"
    echo "  • HPA (Horizontal Pod Autoscaler) metrics"
    echo "  • Kubelet & cAdvisor metrics"
    echo "  • DCGM (GPU) metrics"
    echo ""
    echo "Managed Prometheus:       ✓ Enabled"
    echo "Dataplane V2:             ✓ Enabled (eBPF CNI)"
    echo "DPv2 Metrics:             ✓ Enabled"
    echo "DPv2 Flow Observability:  ✓ Enabled"
    echo "Cluster DNS:              Cloud DNS (cluster scope)"
    echo ""
    echo "View in Cloud Console:"
    echo "  https://console.cloud.google.com/kubernetes/clusters/details/$REGION/$CLUSTER_NAME/observability?project=$PROJECT_ID"
    echo ""
    echo "Query with kubectl:"
    echo "  kubectl top nodes"
    echo "  kubectl top pods --all-namespaces"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

################################################################################
# MAIN EXECUTION
################################################################################

main() {
    echo ""
    log_info "Starting GKE Private Cluster Deployment (Dataplane V2 + Cloud DNS)"
    echo ""

    # Run checks and setup
    check_prerequisites
    enable_apis

    # Display configuration
    display_configuration

    # Confirm before proceeding
    echo ""
    read -p "Do you want to proceed with cluster creation? (yes/no): " -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]es$ ]]; then
        log_warning "Cluster creation cancelled by user"
        exit 0
    fi

    # Create cluster
    create_cluster

    # Post-creation setup
    configure_kubectl
    verify_cluster

    # Display instructions
    echo ""
    display_access_instructions
    echo ""
    display_monitoring_instructions

    echo ""
    log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "GKE Private Cluster Deployment Complete!"
    log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Show quick commands
    log_info "Quick Commands:"
    echo "  View cluster:  gcloud container clusters describe $CLUSTER_NAME --region=$REGION --project=$PROJECT_ID"
    echo "  Get nodes:     kubectl get nodes"
    echo "  View pods:     kubectl get pods --all-namespaces"
    echo ""
}

# Run main function
main "$@"
