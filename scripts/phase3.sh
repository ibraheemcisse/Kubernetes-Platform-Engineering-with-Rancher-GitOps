#!/bin/bash

# Phase 3: Kubernetes Cluster Creation and Core Components Setup
# This script helps create the RKE2 cluster and install essential components

set -e

# Configuration
PROJECT_NAME="ioc-platform-demo"
CLUSTER_NAME="ioc-platform-cluster"
RANCHER_PUBLIC_IP="44.204.172.214"

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

# Check if running from correct directory
check_location() {
    if [ -f terraform/aws-infrastructure/rancher_public_ip.txt ]; then
        INFRA_PATH="terraform/aws-infrastructure"
        PROJECT_ROOT="."
    elif [ -f ../terraform/aws-infrastructure/rancher_public_ip.txt ]; then
        INFRA_PATH="../terraform/aws-infrastructure"
        PROJECT_ROOT=".."
    else
        error "Cannot find infrastructure files. Please run from project root or scripts/ directory."
        exit 1
    fi
}

# Step 1: Create RKE2 cluster through Rancher UI (guided)
create_cluster_guide() {
    log "Creating RKE2 cluster through Rancher UI"
    echo
    echo -e "${BLUE}=== STEP 1: CREATE KUBERNETES CLUSTER ===${NC}"
    echo "1. Go to Rancher UI: https://$RANCHER_PUBLIC_IP"
    echo "2. Click 'Create' button in the top right"
    echo "3. Select 'Amazon EC2' as the infrastructure provider"
    echo "4. Configure the cluster:"
    echo "   - Cluster Name: $CLUSTER_NAME"
    echo "   - Kubernetes Version: v1.28.5+rke2r1"
    echo "   - CNI Provider: Calico"
    echo
    echo "5. Configure Node Pool:"
    echo "   - Pool Name: controlplane"
    echo "   - Count: 1"
    echo "   - Roles: etcd, Control Plane, Worker"
    echo "   - Instance Type: t3.large"
    echo "   - Region: us-east-1"
    echo "   - VPC/Subnet: Use your existing private subnet"
    echo "   - Security Groups: Use your k8s security group"
    echo
    echo "6. Click 'Create' and wait for cluster to be ready (15-20 minutes)"
    echo
    read -p "Press Enter after the cluster is created and shows 'Active' status..."
}

# Step 2: Download kubeconfig
download_kubeconfig() {
    log "Downloading kubeconfig from Rancher"
    echo
    echo -e "${BLUE}=== STEP 2: DOWNLOAD KUBECONFIG ===${NC}"
    echo "1. In Rancher UI, click on your cluster name: $CLUSTER_NAME"
    echo "2. Click 'Download KubeConfig' button in the top right"
    echo "3. Save the file as 'kubeconfig' in your project root directory"
    echo
    read -p "Press Enter after downloading the kubeconfig file..."
    
    # Check if kubeconfig exists
    if [ -f $PROJECT_ROOT/kubeconfig ]; then
        export KUBECONFIG=$PROJECT_ROOT/kubeconfig
        log "Kubeconfig found and set"
        
        # Test connection
        if kubectl cluster-info &>/dev/null; then
            log "Successfully connected to cluster!"
            kubectl get nodes
        else
            warn "Could not connect to cluster. Please check kubeconfig file."
        fi
    else
        warn "Kubeconfig file not found. Please download it and place it in the project root."
        echo "Expected location: $PROJECT_ROOT/kubeconfig"
    fi
}

# Step 3: Install cert-manager
install_cert_manager() {
    log "Installing cert-manager"
    
    # Add cert-manager helm repository
    helm repo add jetstack https://charts.jetstack.io
    helm repo update
    
    # Install cert-manager
    helm install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --version v1.13.0 \
        --set installCRDs=true \
        --wait
    
    log "Cert-manager installed successfully"
    
    # Wait for cert-manager to be ready
    kubectl wait --for=condition=available deployment/cert-manager -n cert-manager --timeout=300s
    kubectl wait --for=condition=available deployment/cert-manager-cainjector -n cert-manager --timeout=300s
    kubectl wait --for=condition=available deployment/cert-manager-webhook -n cert-manager --timeout=300s
    
    log "Cert-manager is ready"
}

# Step 4: Install NGINX Ingress Controller
install_nginx_ingress() {
    log "Installing NGINX Ingress Controller"
    
    # Add ingress-nginx helm repository
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo update
    
    # Install NGINX Ingress Controller
    helm install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
        --set controller.service.type=LoadBalancer \
        --wait
    
    log "NGINX Ingress Controller installed successfully"
    
    # Wait for ingress controller to get external IP
    log "Waiting for LoadBalancer to get external IP..."
    sleep 30
    
    INGRESS_IP=$(kubectl get service ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    if [ -n "$INGRESS_IP" ]; then
        log "Ingress Controller available at: $INGRESS_IP"
        echo "$INGRESS_IP" > $PROJECT_ROOT/ingress_hostname.txt
    else
        warn "Ingress IP not yet available. It may take a few minutes."
    fi
}

# Step 5: Apply cluster issuers for cert-manager
apply_cluster_issuers() {
    log "Applying certificate cluster issuers"
    
    # Create cluster issuers directory if it doesn't exist
    mkdir -p $PROJECT_ROOT/helm-charts/cluster-issuers/templates
    
    # Apply Let's Encrypt staging issuer
    cat > $PROJECT_ROOT/temp-letsencrypt-staging.yaml << 'EOF'
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

    # Apply Let's Encrypt production issuer
    cat > $PROJECT_ROOT/temp-letsencrypt-prod.yaml << 'EOF'
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

    kubectl apply -f $PROJECT_ROOT/temp-letsencrypt-staging.yaml
    kubectl apply -f $PROJECT_ROOT/temp-letsencrypt-prod.yaml
    
    # Clean up temp files
    rm -f $PROJECT_ROOT/temp-letsencrypt-staging.yaml $PROJECT_ROOT/temp-letsencrypt-prod.yaml
    
    log "Certificate issuers applied successfully"
}

# Step 6: Install ArgoCD
install_argocd() {
    log "Installing ArgoCD"
    
    # Create ArgoCD namespace
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    
    # Add ArgoCD helm repository
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
    
    # Install ArgoCD
    helm install argocd argo/argo-cd \
        --namespace argocd \
        --set server.service.type=LoadBalancer \
        --set server.config."application\.instanceLabelKey"="argocd.argoproj.io/instance" \
        --set configs.params."server\.insecure"=true \
        --wait
    
    log "ArgoCD installed successfully"
    
    # Wait for ArgoCD to be ready
    kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s
    
    # Get ArgoCD admin password
    ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    echo "ArgoCD admin password: $ARGOCD_PASSWORD" > $PROJECT_ROOT/argocd_password.txt
    
    # Get ArgoCD LoadBalancer hostname
    sleep 30
    ARGOCD_URL=$(kubectl get service argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    
    log "ArgoCD installed successfully!"
    log "URL: http://$ARGOCD_URL"
    log "Username: admin"
    log "Password: $ARGOCD_PASSWORD"
    
    echo "$ARGOCD_URL" > $PROJECT_ROOT/argocd_url.txt
}

# Step 7: Install Longhorn storage
install_longhorn() {
    log "Installing Longhorn distributed storage"
    
    # Add Longhorn helm repository
    helm repo add longhorn https://charts.longhorn.io
    helm repo update
    
    # Install Longhorn
    helm install longhorn longhorn/longhorn \
        --namespace longhorn-system \
        --create-namespace \
        --set defaultSettings.defaultDataPath="/opt/longhorn" \
        --wait
    
    log "Longhorn installed successfully"
    
    # Set Longhorn as default storage class
    kubectl patch storageclass longhorn -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    
    log "Longhorn set as default storage class"
}

# Step 8: Create sample application
create_sample_app() {
    log "Creating sample application"
    
    mkdir -p $PROJECT_ROOT/argocd-apps/sample-app
    
    cat > $PROJECT_ROOT/argocd-apps/sample-app/app.yaml << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sample-nginx
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF

    kubectl apply -f $PROJECT_ROOT/argocd-apps/sample-app/app.yaml
    
    log "Sample application created in ArgoCD"
}

# Display summary
display_summary() {
    log "Phase 3 completed successfully!"
    echo
    echo -e "${BLUE}=== PLATFORM SUMMARY ===${NC}"
    echo "✅ Kubernetes cluster: $CLUSTER_NAME (Active)"
    echo "✅ Cert-manager: Installed"
    echo "✅ NGINX Ingress: Installed"
    echo "✅ ArgoCD: Installed"
    echo "✅ Longhorn Storage: Installed"
    echo "✅ Sample Application: Deployed"
    echo
    echo -e "${BLUE}=== ACCESS INFORMATION ===${NC}"
    if [ -f $PROJECT_ROOT/argocd_url.txt ]; then
        ARGOCD_URL=$(cat $PROJECT_ROOT/argocd_url.txt)
        ARGOCD_PASSWORD=$(cat $PROJECT_ROOT/argocd_password.txt 2>/dev/null || echo "Check argocd_password.txt")
        echo "🔗 ArgoCD: http://$ARGOCD_URL"
        echo "   Username: admin"
        echo "   Password: $ARGOCD_PASSWORD"
    fi
    
    if [ -f $PROJECT_ROOT/ingress_hostname.txt ]; then
        INGRESS_URL=$(cat $PROJECT_ROOT/ingress_hostname.txt)
        echo "🔗 Ingress Controller: $INGRESS_URL"
    fi
    
    echo "🔗 Rancher: https://$RANCHER_PUBLIC_IP"
    echo
    echo -e "${BLUE}=== USEFUL COMMANDS ===${NC}"
    echo "# Check cluster status"
    echo "kubectl get nodes"
    echo
    echo "# Check all pods"
    echo "kubectl get pods --all-namespaces"
    echo
    echo "# Access ArgoCD CLI"
    echo "argocd login $ARGOCD_URL --username admin --password $ARGOCD_PASSWORD --insecure"
    echo
    echo -e "${BLUE}=== NEXT STEPS ===${NC}"
    echo "1. Access ArgoCD and explore the sample application"
    echo "2. Set up monitoring stack (Prometheus/Grafana)"
    echo "3. Configure DNS records for your applications"
    echo "4. Deploy your own applications using GitOps"
    echo "5. Set up backup and disaster recovery"
}

# Main execution
main() {
    echo -e "${BLUE}=== IOC Platform Demo - Phase 3: Cluster Setup ===${NC}"
    echo "This script will help you create the Kubernetes cluster and install core components"
    echo
    
    check_location
    
    echo "What would you like to do?"
    echo "1. Full setup (recommended for first time)"
    echo "2. Install individual components"
    echo "3. Skip to summary (if everything is already installed)"
    
    read -p "Choose option (1-3): " choice
    
    case $choice in
        1)
            create_cluster_guide
            download_kubeconfig
            install_cert_manager
            install_nginx_ingress
            apply_cluster_issuers
            install_argocd
            install_longhorn
            create_sample_app
            display_summary
            ;;
        2)
            echo "Individual component installation:"
            echo "a) Download kubeconfig"
            echo "b) Install cert-manager"
            echo "c) Install NGINX Ingress"
            echo "d) Install ArgoCD"
            echo "e) Install Longhorn"
            read -p "Choose component: " component
            
            case $component in
                a) download_kubeconfig ;;
                b) install_cert_manager ;;
                c) install_nginx_ingress ;;
                d) install_argocd ;;
                e) install_longhorn ;;
                *) error "Invalid choice" ;;
            esac
            ;;
        3)
            display_summary
            ;;
        *)
            error "Invalid choice"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
