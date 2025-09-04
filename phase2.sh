#!/bin/bash

# Phase 2: Rancher Setup and Configuration Script
# This script configures Rancher and sets up the initial Kubernetes cluster

set -e

# Configuration
PROJECT_NAME="ioc-platform-demo"
AWS_REGION="us-east-1"
CLUSTER_NAME="ioc-platform-cluster"
RANCHER_HOSTNAME="rancher.ioc-labs.local"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log "Checking Phase 2 prerequisites..."
    
    # Check if infrastructure files exist
    if [ ! -f terraform/aws-infrastructure/rancher_public_ip.txt ]; then
        error "Rancher public IP not found. Please complete Phase 1 first."
        exit 1
    fi
    
    # Read infrastructure details
    RANCHER_PUBLIC_IP=$(cat terraform/aws-infrastructure/rancher_public_ip.txt)
    RANCHER_INSTANCE_ID=$(cat terraform/aws-infrastructure/rancher_instance_id.txt)
    K8S_INSTANCE_IDS=($(cat terraform/aws-infrastructure/k8s_instance_ids.txt))
    VPC_ID=$(cat terraform/aws-infrastructure/vpc_id.txt)
    
    log "Rancher Public IP: $RANCHER_PUBLIC_IP"
    log "Rancher Instance ID: $RANCHER_INSTANCE_ID"
    log "Kubernetes Nodes: ${#K8S_INSTANCE_IDS[@]} instances"
    
    # Check if Rancher is accessible
    log "Checking Rancher accessibility..."
    if ! curl -k -s --connect-timeout 10 https://$RANCHER_PUBLIC_IP >/dev/null; then
        warn "Rancher is not yet accessible. This is normal if it just started."
        echo "Please wait 5-10 minutes for Rancher to fully initialize, then run this script again."
        exit 1
    fi
    
    log "Prerequisites check passed!"
}

# Wait for Rancher to be ready
wait_for_rancher() {
    log "Waiting for Rancher to be fully ready..."
    
    local max_attempts=60
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if curl -k -s https://$RANCHER_PUBLIC_IP/ping | grep -q "pong"; then
            log "Rancher is ready!"
            return 0
        fi
        
        echo -n "."
        sleep 10
        ((attempt++))
    done
    
    error "Rancher failed to become ready after 10 minutes"
    exit 1
}

# Get Rancher bootstrap password
get_rancher_password() {
    log "Retrieving Rancher bootstrap password..."
    
    # SSH to Rancher instance and get bootstrap password
    BOOTSTRAP_PASSWORD=$(ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no ubuntu@$RANCHER_PUBLIC_IP \
        "sudo docker logs \$(sudo docker ps | grep rancher/rancher | awk '{print \$1}') 2>&1 | grep 'Bootstrap Password:' | tail -1 | awk '{print \$3}'" 2>/dev/null)
    
    if [ -z "$BOOTSTRAP_PASSWORD" ]; then
        error "Failed to retrieve bootstrap password"
        echo "Please manually retrieve it by running:"
        echo "ssh -i ~/.ssh/id_rsa ubuntu@$RANCHER_PUBLIC_IP"
        echo "sudo docker logs \$(sudo docker ps | grep rancher/rancher | awk '{print \$1}') 2>&1 | grep 'Bootstrap Password:'"
        exit 1
    fi
    
    log "Bootstrap password retrieved"
    echo "BOOTSTRAP_PASSWORD: $BOOTSTRAP_PASSWORD" > rancher_bootstrap_password.txt
}

# Configure Rancher (manual steps guide)
configure_rancher() {
    log "Rancher configuration steps:"
    echo
    echo -e "${BLUE}=== MANUAL RANCHER SETUP REQUIRED ===${NC}"
    echo "1. Open your browser and go to: https://$RANCHER_PUBLIC_IP"
    echo "2. Accept the self-signed certificate warning"
    echo "3. Enter the bootstrap password: $BOOTSTRAP_PASSWORD"
    echo "4. Set a new admin password (save it securely!)"
    echo "5. Set Server URL to: https://$RANCHER_PUBLIC_IP"
    echo "6. Complete the initial setup wizard"
    echo
    read -p "Press Enter after completing the Rancher setup..."
}

# Create RKE2 cluster configuration
create_cluster_config() {
    log "Creating RKE2 cluster configuration..."
    
    # Create rancher-bootstrap directory if it doesn't exist
    mkdir -p terraform/rancher-bootstrap
    
    # Create cluster configuration
    cat > terraform/rancher-bootstrap/cluster-config.yaml << EOF
apiVersion: provisioning.cattle.io/v1
kind: Cluster
metadata:
  name: $CLUSTER_NAME
  namespace: fleet-default
spec:
  kubernetesVersion: v1.28.5+rke2r1
  rkeConfig:
    chartValues:
      rke2-calico: {}
    etcd:
      snapshotRetention: 5
      snapshotScheduleCron: "0 */5 * * *"
    machineGlobalConfig:
      cni: calico
      disable-kube-proxy: false
      etcd-expose-metrics: false
    machinePools:
    - name: pool1
      quantity: 1
      unhealthyNodeTimeout: "3m"
      machineConfigRef:
        apiVersion: rke-machine-config.cattle.io/v1
        kind: Amazonec2Config
        name: $CLUSTER_NAME-pool1
      labels:
        node-role.kubernetes.io/control-plane: "true"
        node-role.kubernetes.io/etcd: "true"
        node-role.kubernetes.io/worker: "true"
    registries: {}
    upgradeStrategy:
      controlPlaneConcurrency: "1"
      controlPlaneDrainOptions:
        enabled: false
        force: false
        gracePeriod: -1
        ignoreDaemonSets: true
        timeout: 120
      workerConcurrency: "1"
      workerDrainOptions:
        enabled: false
        force: false
        gracePeriod: -1
        ignoreDaemonSets: true
        timeout: 120
---
apiVersion: rke-machine-config.cattle.io/v1
kind: Amazonec2Config
metadata:
  name: $CLUSTER_NAME-pool1
  namespace: fleet-default
spec:
  ami: ""  # Will auto-select latest Ubuntu
  instanceType: t3.large
  region: $AWS_REGION
  vpcId: $VPC_ID
  zone: a
  subnetId: $(cat $INFRA_PATH/private_subnets.txt | awk '{print $1}')
  securityGroup: 
  - $(cat $INFRA_PATH/k8s_sg_id.txt)
  sshUser: ubuntu
  volumeType: gp3
  rootSize: 50
  userData: |
    #!/bin/bash
    apt-get update
    apt-get install -y curl
EOF

    log "Cluster configuration created at terraform/rancher-bootstrap/cluster-config.yaml"
}

# Install kubectl and helm locally if not present
install_tools() {
    log "Checking for required tools..."
    
    # Install kubectl if not present
    if ! command -v kubectl &> /dev/null; then
        log "Installing kubectl..."
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/
    fi
    
    # Install helm if not present
    if ! command -v helm &> /dev/null; then
        log "Installing helm..."
        curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi
    
    log "Tools installation complete"
}

# Create ArgoCD bootstrap configuration
create_argocd_bootstrap() {
    log "Creating ArgoCD bootstrap configuration..."
    
    # Ensure bootstrap directory exists
    mkdir -p argocd-apps/bootstrap
    
    # Create ArgoCD installation manifest
    cat > argocd-apps/bootstrap/argocd-install.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://argoproj.github.io/argo-helm
    targetRevision: 5.51.6
    chart: argo-cd
    helm:
      values: |
        server:
          service:
            type: LoadBalancer
          config:
            application.instanceLabelKey: argocd.argoproj.io/instance
          ingress:
            enabled: true
            ingressClassName: nginx
            hosts:
            - argocd.ioc-labs.local
            tls:
            - secretName: argocd-server-tls
              hosts:
              - argocd.ioc-labs.local
        configs:
          params:
            server.insecure: true
        global:
          image:
            tag: v2.9.3
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF

    log "ArgoCD bootstrap configuration created"
}

# Create cert-manager configuration
create_cert_manager_config() {
    log "Creating cert-manager configuration..."
    
    mkdir -p helm-charts/cluster-issuers/templates
    
    cat > helm-charts/cluster-issuers/Chart.yaml << EOF
apiVersion: v2
name: cluster-issuers
description: Certificate issuers for the platform
type: application
version: 0.1.0
appVersion: "1.0"
EOF

    cat > helm-charts/cluster-issuers/templates/letsencrypt-staging.yaml << 'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: admin@ioc-labs.local
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

    cat > helm-charts/cluster-issuers/templates/letsencrypt-prod.yaml << 'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@ioc-labs.local
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

    log "Cert-manager configuration created"
}

# Create monitoring stack configuration
create_monitoring_config() {
    log "Creating monitoring stack configuration..."
    
    mkdir -p helm-charts/monitoring-stack/templates
    
    cat > helm-charts/monitoring-stack/Chart.yaml << EOF
apiVersion: v2
name: monitoring-stack
description: Prometheus, Grafana, and AlertManager stack
type: application
version: 0.1.0
appVersion: "1.0"
dependencies:
  - name: kube-prometheus-stack
    version: "55.5.0"
    repository: https://prometheus-community.github.io/helm-charts
EOF

    cat > helm-charts/monitoring-stack/values.yaml << 'EOF'
kube-prometheus-stack:
  prometheus:
    prometheusSpec:
      storageSpec:
        volumeClaimTemplate:
          spec:
            storageClassName: longhorn
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: 50Gi
  grafana:
    persistence:
      enabled: true
      storageClassName: longhorn
      size: 10Gi
    adminPassword: admin123  # Change this in production
    service:
      type: LoadBalancer
  alertmanager:
    alertmanagerSpec:
      storage:
        volumeClaimTemplate:
          spec:
            storageClassName: longhorn
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: 10Gi
EOF

    log "Monitoring stack configuration created"
}

# Display next steps
display_next_steps() {
    log "Phase 2 setup completed!"
    echo
    echo -e "${BLUE}=== SUMMARY ===${NC}"
    echo "✅ Rancher is accessible at: https://$RANCHER_PUBLIC_IP"
    echo "✅ Bootstrap password: $BOOTSTRAP_PASSWORD"
    echo "✅ Cluster configuration created"
    echo "✅ ArgoCD bootstrap configuration ready"
    echo "✅ Cert-manager configuration ready"
    echo "✅ Monitoring stack configuration ready"
    echo
    echo -e "${BLUE}=== NEXT STEPS (Phase 3) ===${NC}"
    echo "1. Complete Rancher manual setup if not done already"
    echo "2. Create the RKE2 cluster through Rancher UI or apply cluster-config.yaml"
    echo "3. Download kubeconfig from Rancher"
    echo "4. Install cert-manager: helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --version v1.13.0 --set installCRDs=true"
    echo "5. Install ArgoCD: kubectl apply -f argocd-apps/bootstrap/argocd-install.yaml"
    echo "6. Run Phase 3 script to deploy the platform applications"
    echo
    echo -e "${BLUE}=== IMPORTANT FILES ===${NC}"
    echo "- Bootstrap password: rancher_bootstrap_password.txt"
    echo "- Cluster config: terraform/rancher-bootstrap/cluster-config.yaml"
    echo "- ArgoCD config: argocd-apps/bootstrap/argocd-install.yaml"
    
    # Create Phase 3 script placeholder
    cat > scripts/phase3.sh << 'PHASE3'
#!/bin/bash
# Phase 3: Platform Applications Deployment
# This will be the next script to run after cluster is ready

echo "Phase 3: Platform Applications Deployment"
echo "This script will deploy:"
echo "- ArgoCD"
echo "- Cert-manager"
echo "- Ingress Controller"
echo "- Monitoring Stack"
echo "- Longhorn Storage"
echo ""
echo "Make sure you have:"
echo "1. Completed Rancher setup"
echo "2. Created the Kubernetes cluster"
echo "3. Downloaded and configured kubectl with the cluster kubeconfig"
echo ""
read -p "Are you ready to proceed? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Exiting. Run this script when ready."
    exit 0
fi

echo "Phase 3 implementation coming next..."
PHASE3
    
    chmod +x scripts/phase3.sh
    echo "- Phase 3 script: scripts/phase3.sh (placeholder created)"
}

# Main execution
main() {
    echo -e "${BLUE}=== IOC Platform Demo - Phase 2: Rancher Setup ===${NC}"
    echo "This script will configure Rancher and prepare the platform components"
    echo
    
    check_prerequisites
    wait_for_rancher
    get_rancher_password
    configure_rancher
    create_cluster_config
    install_tools
    create_argocd_bootstrap
    create_cert_manager_config
    create_monitoring_config
    display_next_steps
}

# Run main function
main "$@"
