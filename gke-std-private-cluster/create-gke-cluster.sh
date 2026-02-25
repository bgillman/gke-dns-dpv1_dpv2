#!/bin/bash

################################################################################
# GKE Private Standard Cluster Deployment Script
# 
# This script creates a GKE Standard cluster with:
# - Private worker nodes
# - Private control plane with authorized networks
# - Workload Identity enabled
# - Shielded nodes
# - Custom VPC networking
# - Dataplane V2 with metrics and flow observability
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
    echo "  VPC Network:        vpc-02-us-central"
    echo "  VPC Subnet:         vpc-02-subnet-04"
    echo "  Pod CIDR:           $POD_CIDR"
    echo "  Service CIDR:       $SERVICE_CIDR"
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
    echo "  Master Auth Net:    ✓ Enabled ($MASTER_AUTHORIZED_NETWORKS)"
    echo "  Workload Identity:  ✓ Enabled"
    echo "  Shielded Nodes:     ✓ Enabled"
    echo "  Dataplane V2:       ✓ Enabled (with metrics & flow observability)"
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
        --zone="$ZONE" \
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
        --cluster-ipv4-cidr="$POD_CIDR" \
        --no-enable-intra-node-visibility \
        --default-max-pods-per-node="$MAX_PODS_PER_NODE" \
        \
        `# Private Cluster Configuration` \
        --enable-private-nodes \
        --enable-master-authorized-networks \
        --master-authorized-networks="$MASTER_AUTHORIZED_NETWORKS" \
        --no-enable-google-cloud-access \
        \
        `# DNS and IP Access` \
        --enable-dns-access \
        --enable-ip-access \
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
        `# Dataplane V2` \
        --enable-dataplane-v2 \
        --enable-dataplane-v2-metrics \
        --enable-dataplane-v2-flow-observability \
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
        --zone="$ZONE" \
        --project="$PROJECT_ID"
    
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
        --zone="$ZONE" \
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
    kubectl get nodes -o wide 2>/dev/null || log_warning "Could not reach cluster (check if your IP is in master-authorized-networks)"
    
    # Verify Dataplane V2
    log_info "Verifying Dataplane V2..."
    DATAPLANE=$(gcloud container clusters describe "$CLUSTER_NAME" \
        --zone="$ZONE" \
        --project="$PROJECT_ID" \
        --format="value(networkConfig.datapathProvider)")
    
    if [ "$DATAPLANE" == "ADVANCED_DATAPATH" ]; then
        log_success "Dataplane V2 is enabled"
    else
        log_warning "Dataplane V2 status: $DATAPLANE"
    fi
    
    # Verify Workload Identity
    log_info "Verifying Workload Identity..."
    WI_POOL=$(gcloud container clusters describe "$CLUSTER_NAME" \
        --zone="$ZONE" \
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
        --zone="$ZONE" \
        --project="$PROJECT_ID" \
        --format="value(privateClusterConfig.enablePrivateNodes)")
    
    if [ "$PRIVATE_NODES" == "True" ]; then
        log_success "Private nodes are enabled"
    else
        log_warning "Private nodes status: $PRIVATE_NODES"
    fi
    
    # Verify Master Authorized Networks
    log_info "Verifying Master Authorized Networks..."
    gcloud container clusters describe "$CLUSTER_NAME" \
        --zone="$ZONE" \
        --project="$PROJECT_ID" \
        --format="table(masterAuthorizedNetworksConfig.cidrBlocks[].cidrBlock)"
    
    # Verify Managed Prometheus
    log_info "Verifying Managed Prometheus..."
    PROMETHEUS=$(gcloud container clusters describe "$CLUSTER_NAME" \
        --zone="$ZONE" \
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
    echo "✓ This cluster has PRIVATE NODES with MASTER AUTHORIZED NETWORKS"
    echo ""
    echo "Master Authorized Networks: $MASTER_AUTHORIZED_NETWORKS"
    echo ""
    echo "Access Methods:"
    echo ""
    echo "1. From Authorized IP ($MASTER_AUTHORIZED_NETWORKS):"
    echo "   kubectl get nodes"
    echo ""
    echo "2. Add Your Current IP to Authorized Networks:"
    echo "   MY_IP=\$(curl -s ifconfig.me)"
    echo "   gcloud container clusters update $CLUSTER_NAME \\"
    echo "     --zone=$ZONE \\"
    echo "     --enable-master-authorized-networks \\"
    echo "     --master-authorized-networks=$MASTER_AUTHORIZED_NETWORKS,\${MY_IP}/32"
    echo ""
    echo "3. Cloud Shell (if in same project):"
    echo "   gcloud cloud-shell ssh"
    echo "   gcloud container clusters get-credentials $CLUSTER_NAME --zone=$ZONE"
    echo "   kubectl get nodes"
    echo ""
    echo "4. Remove Master Authorized Networks (not recommended):"
    echo "   gcloud container clusters update $CLUSTER_NAME \\"
    echo "     --zone=$ZONE \\"
    echo "     --no-enable-master-authorized-networks"
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
    echo "Managed Prometheus: ✓ Enabled"
    echo "Dataplane V2 Flow Observability: ✓ Enabled"
    echo ""
    echo "View in Cloud Console:"
    echo "  https://console.cloud.google.com/kubernetes/clusters/details/$ZONE/$CLUSTER_NAME/observability?project=$PROJECT_ID"
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
    log_info "Starting GKE Private Cluster Deployment"
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
    echo "  View cluster:  gcloud container clusters describe $CLUSTER_NAME --zone=$ZONE"
    echo "  Get nodes:     kubectl get nodes"
    echo "  View pods:     kubectl get pods --all-namespaces"
    echo ""
}

# Run main function
main "$@"