#!/bin/bash
# scripts/phase1-quick-deploy.sh
# IOC Labs Platform Demo - Phase 1 Quick Deployment Script

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT_NAME="ioc-platform-demo"
REGION="us-east-1"
SSH_KEY_NAME="ioc-platform-demo"

echo -e "${BLUE}=== IOC Labs Platform Demo - Phase 1 Deployment ===${NC}"
echo -e "${BLUE}This script will deploy the foundation infrastructure${NC}"
echo ""

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to print status
print_status() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command_exists terraform; then
    print_error "Terraform is not installed. Please install it first."
    exit 1
else
    print_status "Terraform is installed"
fi

if ! command_exists aws; then
    print_error "AWS CLI is not installed. Please install it first."
    exit 1
else
    print_status "AWS CLI is installed"
fi

if ! command_exists kubectl; then
    print_error "kubectl is not installed. Please install it first."
    exit 1
else
    print_status "kubectl is installed"
fi

if ! command_exists helm; then
    print_error "Helm is not installed. Please install it first."
    exit 1
else
    print_status "Helm is installed"
fi

# Check AWS credentials
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    print_error "AWS credentials not configured. Please run 'aws configure' first."
    exit 1
else
    print_status "AWS credentials are configured"
    AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
    echo -e "  Account: ${AWS_ACCOUNT}"
fi

echo ""

# Create project structure
echo -e "${YELLOW}Setting up project structure...${NC}"

if [ ! -d "$PROJECT_NAME" ]; then
    mkdir -p "$PROJECT_NAME"
    print_status "Created project directory: $PROJECT_NAME"
fi

cd "$PROJECT_NAME"

# Create directory structure
mkdir -p {terraform/aws-infrastructure/user-data,argocd-apps/{bootstrap,core-infrastructure},helm-charts/cluster-issuers/templates,scripts,docs}
print_status "Created directory structure"

# Generate SSH key if it doesn't exist
if [ ! -f ~/.ssh/${SSH_KEY_NAME} ]; then
    echo -e "${YELLOW}Generating SSH key...${NC}"
    ssh-keygen -t rsa -b 4096 -f ~/.ssh/${SSH_KEY_NAME} -N "" -C "IOC Platform Demo"
    chmod 400 ~/.ssh/${SSH_KEY_NAME}
    print_status "Generated SSH key: ~/.ssh/${SSH_KEY_NAME}"
else
    print_status "SSH key already exists: ~/.ssh/${SSH_KEY_NAME}"
fi

# Get public key content
PUBLIC_KEY_CONTENT=$(cat ~/.ssh/${SSH_KEY_NAME}.pub)

# Create terraform.tfvars if it doesn't exist
TFVARS_FILE="terraform/aws-infrastructure/terraform.tfvars"
if [ ! -f "$TFVARS_FILE" ]; then
    echo -e "${YELLOW}Creating terraform.tfvars...${NC}"
    
    # Prompt for required information
    echo ""
    echo "Please provide the following information:"
    read -p "Domain for Rancher (e.g., rancher.yourdomain.com): " RANCHER_HOSTNAME
    read -p "Your email for Let's Encrypt certificates: " LETSENCRYPT_EMAIL
    read -p "Project name [${PROJECT_NAME}]: " PROJECT_INPUT
    PROJECT_INPUT=${PROJECT_INPUT:-$PROJECT_NAME}
    
    cat > "$TFVARS_FILE" << EOF
# IOC Labs Platform Demo - Terraform Variables
# Generated on $(date)

# AWS Configuration
aws_region = "${REGION}"
environment = "demo"
project_name = "${PROJECT_INPUT}"

# Network Configuration
vpc_cidr = "10.0.0.0/16"
availability_zone_count = 3

# SSH Key
public_key = "${PUBLIC_KEY_CONTENT}"

# Instance Configuration
rancher_management_instance_type = "t3.large"
kubernetes_node_instance_type = "t3.large"
kubernetes_node_count = 1

# Storage Configuration
root_volume_size = 50
data_volume_size = 100

# Monitoring
enable_detailed_monitoring = true

# Rancher Configuration
rancher_version = "2.8.0"
rancher_hostname = "${RANCHER_HOSTNAME}"
cert_manager_version = "v1.13.0"

# Kubernetes Configuration
kubernetes_version = "v1.28.5+rke2r1"
cluster_name = "${PROJECT_INPUT}-cluster"
pod_cidr = "10.42.0.0/16"
service_cidr = "10.43.0.0/16"

# Additional Tags
additional_tags = {
  Department = "Platform Engineering"
  CostCenter = "Engineering"
  Owner = "IOC Labs"
  Email = "${LETSENCRYPT_EMAIL}"
}
EOF
    
    print_status "Created terraform.tfvars"
else
    print_status "terraform.tfvars already exists"
    source "$TFVARS_FILE"
fi

echo ""

# Ask for confirmation before deploying
echo -e "${YELLOW}Ready to deploy infrastructure with the following configuration:${NC}"
echo "  Project Name: ${PROJECT_INPUT:-$PROJECT_NAME}"
echo "  AWS Region: ${REGION}"
echo "  Rancher Hostname: ${RANCHER_HOSTNAME:-'Not specified'}"
echo "  Estimated Cost: ~$475/month"
echo ""
read -p "Do you want to continue with the deployment? (y/N): " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled."
    exit 0
fi

# Deploy infrastructure
echo -e "${YELLOW}Deploying infrastructure...${NC}"

cd terraform/aws-infrastructure

# Initialize Terraform
echo -e "${BLUE}Initializing Terraform...${NC}"
terraform init

# Plan deployment
echo -e "${BLUE}Planning deployment...${NC}"
if ! terraform plan -var-file="terraform.tfvars" -out=tfplan; then
    print_error "Terraform plan failed"
    exit 1
fi

print_status "Terraform plan completed successfully"

# Apply deployment
echo -e "${BLUE}Applying deployment... (This will take 10-15 minutes)${NC}"
if ! terraform apply tfplan; then
    print_error "Terraform apply failed"
    exit 1
fi

print_status "Infrastructure deployment completed!"

# Get outputs
RANCHER_IP=$(terraform output -raw rancher_management_public_ip)
RANCHER_URL="https://${RANCHER_HOSTNAME:-$RANCHER_IP}"

echo ""
echo -e "${GREEN}=== Deployment Completed Successfully! ===${NC}"
echo -e "${BLUE}Rancher Management Server:${NC} ${RANCHER_IP}"
echo -e "${BLUE}Rancher URL:${NC} ${RANCHER_URL}"
echo ""

# Wait for Rancher to be ready
echo -e "${YELLOW}Waiting for Rancher to be ready... (This may take 5-10 minutes)${NC}"

# Function to check if Rancher is ready
check_rancher_ready() {
    ssh -i ~/.ssh/${SSH_KEY_NAME} -o StrictHostKeyChecking=no -o ConnectTimeout=10 ec2-user@${RANCHER_IP} \
        'test -f /tmp/rancher-setup-complete' 2>/dev/null
}

# Wait for Rancher setup to complete
TIMEOUT=1800  # 30 minutes timeout
ELAPSED=0
INTERVAL=30

while [ $ELAPSED -lt $TIMEOUT ]; do
    if check_rancher_ready; then
        print_status "Rancher setup completed!"
        break
    fi
    
    echo -e "  Waiting... (${ELAPSED}s elapsed)"
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    print_warning "Rancher setup is taking longer than expected"
    echo "You can check the status manually:"
    echo "  ssh -i ~/.ssh/${SSH_KEY_NAME} ec2-user@${RANCHER_IP} 'sudo tail -f /var/log/rancher-setup.log'"
else
    # Get Rancher password
    echo -e "${YELLOW}Getting Rancher bootstrap password...${NC}"
    RANCHER_PASSWORD=$(ssh -i ~/.ssh/${SSH_KEY_NAME} -o StrictHostKeyChecking=no ec2-user@${RANCHER_IP} 'cat ~/rancher-password.txt' 2>/dev/null)
    
    if [ -n "$RANCHER_PASSWORD" ]; then
        print_status "Retrieved Rancher password"
    else
        print_warning "Could not retrieve Rancher password automatically"
        RANCHER_PASSWORD="Check ~/rancher-password.txt on the server"
    fi
fi

cd ../../

# Create summary file
SUMMARY_FILE="deployment-summary.txt"
cat > "$SUMMARY_FILE" << EOF
IOC Labs Platform Demo - Phase 1 Deployment Summary
===================================================

Deployment Date: $(date)
Project Name: ${PROJECT_INPUT:-$PROJECT_NAME}

Infrastructure Details:
- AWS Region: ${REGION}
- VPC CIDR: 10.0.0.0/16
- Availability Zones: 3

Access Information:
- Rancher Management IP: ${RANCHER_IP}
- Rancher URL: ${RANCHER_URL}
- SSH Command: ssh -i ~/.ssh/${SSH_KEY_NAME} ec2-user@${RANCHER_IP}

Rancher Login:
- Username: admin
- Password: ${RANCHER_PASSWORD}

Next Steps:
1. Access Rancher UI at: ${RANCHER_URL}
2. Configure DNS (if using custom domain): ${RANCHER_HOSTNAME:-'N/A'} -> ${RANCHER_IP}
3. Deploy ArgoCD and core applications
4. Proceed to Phase 2 for storage and database setup

Useful Commands:
- SSH to Rancher: ssh -i ~/.ssh/${SSH_KEY_NAME} ec2-user@${RANCHER_IP}
- View cluster info: ssh -i ~/.ssh/${SSH_KEY_NAME} ec2-user@${RANCHER_IP} 'cat ~/cluster-info.txt'
- Check cluster status: ssh -i ~/.ssh/${SSH_KEY_NAME} ec2-user@${RANCHER_IP} 'kubectl get nodes'

Estimated Monthly Cost: ~$475 USD

EOF

print_status "Created deployment summary: $SUMMARY_FILE"

echo ""
echo -e "${GREEN}=== Phase 1 Deployment Complete! 🎉 ===${NC}"
echo ""
echo -e "${BLUE}Quick Access:${NC}"
echo "  Rancher UI: ${RANCHER_URL}"
echo "  SSH: ssh -i ~/.ssh/${SSH_KEY_NAME} ec2-user@${RANCHER_IP}"
echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo "  1. Access Rancher UI and complete initial setup"
echo "  2. Configure DNS if using custom domain"
echo "  3. Deploy ArgoCD using the provided configurations"
echo "  4. Prepare for Phase 2 deployment"
echo ""
echo -e "${YELLOW}Important:${NC} Save the deployment summary file: $SUMMARY_FILE"

# Optional: Open Rancher URL if on desktop
if command_exists xdg-open; then
    read -p "Open Rancher UI in browser? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        xdg-open "${RANCHER_URL}"
    fi
elif command_exists open; then
    read -p "Open Rancher UI in browser? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        open "${RANCHER_URL}"
    fi
fi
