#!/bin/bash

# AWS Infrastructure Setup Script for IOC Platform Demo
# This script creates the same infrastructure as the Terraform configuration

set -e  # Exit on any error

# Configuration Variables
PROJECT_NAME="ioc-platform-demo"
ENVIRONMENT="demo"
AWS_REGION="us-east-1"
VPC_CIDR="10.0.0.0/16"
KEY_NAME="${PROJECT_NAME}-key"
RANCHER_INSTANCE_TYPE="t3.large"
K8S_INSTANCE_TYPE="t3.large"
K8S_NODE_COUNT=1
ROOT_VOLUME_SIZE=50
DATA_VOLUME_SIZE=100

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if AWS CLI is installed and configured
check_prerequisites() {
    log "Checking prerequisites..."
    
    if ! command -v aws &> /dev/null; then
        error "AWS CLI is not installed. Please install it first."
        exit 1
    fi
    
    if ! aws sts get-caller-identity &> /dev/null; then
        error "AWS CLI is not configured. Please run 'aws configure' first."
        exit 1
    fi
    
    # Check if SSH key exists
    if [ ! -f ~/.ssh/id_rsa.pub ]; then
        error "SSH public key not found at ~/.ssh/id_rsa.pub"
        echo "Please generate one with: ssh-keygen -t rsa -b 4096"
        exit 1
    fi
    
    log "Prerequisites check passed!"
}

# Create VPC
create_vpc() {
    log "Creating VPC..."
    
    VPC_ID=$(aws ec2 create-vpc \
        --cidr-block $VPC_CIDR \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT_NAME}-vpc},{Key=Environment,Value=$ENVIRONMENT},{Key=Department,Value=Platform Engineering},{Key=CostCenter,Value=Engineering},{Key=Owner,Value=IOC Labs}]" \
        --query 'Vpc.VpcId' \
        --output text \
        --region $AWS_REGION)
    
    log "VPC created: $VPC_ID"
    
    # Enable DNS hostnames
    aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames --region $AWS_REGION
    aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support --region $AWS_REGION
    
    echo $VPC_ID > vpc_id.txt
}

# Create Internet Gateway
create_internet_gateway() {
    log "Creating Internet Gateway..."
    
    IGW_ID=$(aws ec2 create-internet-gateway \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-igw},{Key=Environment,Value=$ENVIRONMENT}]" \
        --query 'InternetGateway.InternetGatewayId' \
        --output text \
        --region $AWS_REGION)
    
    # Attach to VPC
    aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region $AWS_REGION
    
    log "Internet Gateway created and attached: $IGW_ID"
    echo $IGW_ID > igw_id.txt
}

# Create subnets
create_subnets() {
    log "Creating subnets..."
    
    # Get availability zones
    AZS=($(aws ec2 describe-availability-zones --query 'AvailabilityZones[0:3].ZoneName' --output text --region $AWS_REGION))
    
    # Create public subnets
    PUBLIC_SUBNETS=()
    for i in {0..2}; do
        SUBNET_CIDR="10.0.$((i+10)).0/24"
        SUBNET_ID=$(aws ec2 create-subnet \
            --vpc-id $VPC_ID \
            --cidr-block $SUBNET_CIDR \
            --availability-zone ${AZS[$i]} \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-public-subnet-$((i+1))},{Key=Type,Value=Public},{Key=Environment,Value=$ENVIRONMENT}]" \
            --query 'Subnet.SubnetId' \
            --output text \
            --region $AWS_REGION)
        
        # Enable auto-assign public IP
        aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID --map-public-ip-on-launch --region $AWS_REGION
        
        PUBLIC_SUBNETS+=($SUBNET_ID)
        log "Public subnet created: $SUBNET_ID in ${AZS[$i]}"
    done
    
    # Create private subnets
    PRIVATE_SUBNETS=()
    for i in {0..2}; do
        SUBNET_CIDR="10.0.$i.0/24"
        SUBNET_ID=$(aws ec2 create-subnet \
            --vpc-id $VPC_ID \
            --cidr-block $SUBNET_CIDR \
            --availability-zone ${AZS[$i]} \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-subnet-$((i+1))},{Key=Type,Value=Private},{Key=Environment,Value=$ENVIRONMENT}]" \
            --query 'Subnet.SubnetId' \
            --output text \
            --region $AWS_REGION)
        
        PRIVATE_SUBNETS+=($SUBNET_ID)
        log "Private subnet created: $SUBNET_ID in ${AZS[$i]}"
    done
    
    echo "${PUBLIC_SUBNETS[@]}" > public_subnets.txt
    echo "${PRIVATE_SUBNETS[@]}" > private_subnets.txt
}

# Create NAT Gateway
create_nat_gateway() {
    log "Creating NAT Gateway..."
    
    # Allocate Elastic IP
    EIP_ALLOC_ID=$(aws ec2 allocate-address \
        --domain vpc \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PROJECT_NAME}-nat-eip},{Key=Environment,Value=$ENVIRONMENT}]" \
        --query 'AllocationId' \
        --output text \
        --region $AWS_REGION)
    
    # Create NAT Gateway in first public subnet
    NAT_GW_ID=$(aws ec2 create-nat-gateway \
        --subnet-id ${PUBLIC_SUBNETS[0]} \
        --allocation-id $EIP_ALLOC_ID \
        --query 'NatGateway.NatGatewayId' \
        --output text \
        --region $AWS_REGION)
    
    log "NAT Gateway created: $NAT_GW_ID"
    
    # Wait for NAT Gateway to be available
    log "Waiting for NAT Gateway to be available..."
    aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_GW_ID --region $AWS_REGION
    
    # Add tags to NAT Gateway after creation
    aws ec2 create-tags \
        --resources $NAT_GW_ID \
        --tags "Key=Name,Value=${PROJECT_NAME}-nat-gw" "Key=Environment,Value=$ENVIRONMENT" \
        --region $AWS_REGION
    
    echo $NAT_GW_ID > nat_gw_id.txt
}

# Create route tables
create_route_tables() {
    log "Creating route tables..."
    
    # Public route table
    PUBLIC_RT_ID=$(aws ec2 create-route-table \
        --vpc-id $VPC_ID \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-public-rt},{Key=Type,Value=Public},{Key=Environment,Value=$ENVIRONMENT}]" \
        --query 'RouteTable.RouteTableId' \
        --output text \
        --region $AWS_REGION)
    
    # Add route to Internet Gateway
    aws ec2 create-route --route-table-id $PUBLIC_RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID --region $AWS_REGION
    
    # Associate public subnets
    for subnet in "${PUBLIC_SUBNETS[@]}"; do
        aws ec2 associate-route-table --route-table-id $PUBLIC_RT_ID --subnet-id $subnet --region $AWS_REGION
    done
    
    log "Public route table created and associated: $PUBLIC_RT_ID"
    
    # Private route table
    PRIVATE_RT_ID=$(aws ec2 create-route-table \
        --vpc-id $VPC_ID \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-rt},{Key=Type,Value=Private},{Key=Environment,Value=$ENVIRONMENT}]" \
        --query 'RouteTable.RouteTableId' \
        --output text \
        --region $AWS_REGION)
    
    # Add route to NAT Gateway
    aws ec2 create-route --route-table-id $PRIVATE_RT_ID --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_GW_ID --region $AWS_REGION
    
    # Associate private subnets
    for subnet in "${PRIVATE_SUBNETS[@]}"; do
        aws ec2 associate-route-table --route-table-id $PRIVATE_RT_ID --subnet-id $subnet --region $AWS_REGION
    done
    
    log "Private route table created and associated: $PRIVATE_RT_ID"
}

# Create security groups
create_security_groups() {
    log "Creating security groups..."
    
    # Rancher security group
    RANCHER_SG_ID=$(aws ec2 create-security-group \
        --group-name "${PROJECT_NAME}-rancher-sg" \
        --description "Security group for Rancher management server" \
        --vpc-id $VPC_ID \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT_NAME}-rancher-sg},{Key=Environment,Value=$ENVIRONMENT}]" \
        --query 'GroupId' \
        --output text \
        --region $AWS_REGION)
    
    # Add rules to Rancher security group
    aws ec2 authorize-security-group-ingress --group-id $RANCHER_SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $AWS_REGION
    aws ec2 authorize-security-group-ingress --group-id $RANCHER_SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $AWS_REGION
    aws ec2 authorize-security-group-ingress --group-id $RANCHER_SG_ID --protocol tcp --port 443 --cidr 0.0.0.0/0 --region $AWS_REGION
    
    log "Rancher security group created: $RANCHER_SG_ID"
    
    # Kubernetes nodes security group
    K8S_SG_ID=$(aws ec2 create-security-group \
        --group-name "${PROJECT_NAME}-k8s-nodes-sg" \
        --description "Security group for Kubernetes nodes" \
        --vpc-id $VPC_ID \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT_NAME}-k8s-nodes-sg},{Key=Environment,Value=$ENVIRONMENT}]" \
        --query 'GroupId' \
        --output text \
        --region $AWS_REGION)
    
    # Add rules to K8s security group
    aws ec2 authorize-security-group-ingress --group-id $K8S_SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $AWS_REGION
    aws ec2 authorize-security-group-ingress --group-id $K8S_SG_ID --protocol tcp --port 6443 --cidr $VPC_CIDR --region $AWS_REGION
    aws ec2 authorize-security-group-ingress --group-id $K8S_SG_ID --protocol tcp --port 10250 --cidr $VPC_CIDR --region $AWS_REGION
    aws ec2 authorize-security-group-ingress --group-id $K8S_SG_ID --protocol tcp --port 30000-32767 --cidr $VPC_CIDR --region $AWS_REGION
    
    log "Kubernetes security group created: $K8S_SG_ID"
    
    echo $RANCHER_SG_ID > rancher_sg_id.txt
    echo $K8S_SG_ID > k8s_sg_id.txt
}

# Create key pair
create_key_pair() {
    log "Creating key pair..."
    
    # Import existing public key
    aws ec2 import-key-pair \
        --key-name $KEY_NAME \
        --public-key-material fileb://~/.ssh/id_rsa.pub \
        --tag-specifications "ResourceType=key-pair,Tags=[{Key=Name,Value=$KEY_NAME},{Key=Environment,Value=$ENVIRONMENT}]" \
        --region $AWS_REGION
    
    log "Key pair imported: $KEY_NAME"
}

# Get latest Ubuntu AMI
get_ubuntu_ami() {
    log "Getting latest Ubuntu 22.04 AMI..."
    
    UBUNTU_AMI_ID=$(aws ec2 describe-images \
        --owners 099720109477 \
        --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" "Name=state,Values=available" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text \
        --region $AWS_REGION)
    
    log "Ubuntu AMI ID: $UBUNTU_AMI_ID"
    echo $UBUNTU_AMI_ID > ubuntu_ami_id.txt
}

# Create Rancher instance
create_rancher_instance() {
    log "Creating Rancher management instance..."
    
    # Create user data script for Rancher installation
    cat > rancher_userdata.sh << 'EOF'
#!/bin/bash
apt-get update
apt-get install -y docker.io
systemctl start docker
systemctl enable docker
usermod -aG docker ubuntu

# Format and mount additional volume
mkfs.ext4 /dev/nvme1n1
mkdir -p /opt/rancher-data
mount /dev/nvme1n1 /opt/rancher-data
echo '/dev/nvme1n1 /opt/rancher-data ext4 defaults 0 2' >> /etc/fstab
chown -R ubuntu:ubuntu /opt/rancher-data

# Install Rancher
docker run -d --restart=unless-stopped \
  -p 80:80 -p 443:443 \
  -v /opt/rancher-data:/var/lib/rancher \
  --privileged \
  rancher/rancher:v2.8.0

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/
EOF

    RANCHER_INSTANCE_ID=$(aws ec2 run-instances \
        --image-id $UBUNTU_AMI_ID \
        --instance-type $RANCHER_INSTANCE_TYPE \
        --key-name $KEY_NAME \
        --security-group-ids $RANCHER_SG_ID \
        --subnet-id ${PUBLIC_SUBNETS[0]} \
        --monitoring Enabled=true \
        --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$ROOT_VOLUME_SIZE,\"VolumeType\":\"gp3\"}},{\"DeviceName\":\"/dev/sdf\",\"Ebs\":{\"VolumeSize\":$DATA_VOLUME_SIZE,\"VolumeType\":\"gp3\"}}]" \
        --user-data file://rancher_userdata.sh \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-rancher},{Key=Environment,Value=$ENVIRONMENT},{Key=Department,Value=Platform Engineering},{Key=CostCenter,Value=Engineering},{Key=Owner,Value=IOC Labs}]" \
        --query 'Instances[0].InstanceId' \
        --output text \
        --region $AWS_REGION)
    
    log "Rancher instance created: $RANCHER_INSTANCE_ID"
    echo $RANCHER_INSTANCE_ID > rancher_instance_id.txt
    
    # Wait for instance to be running
    log "Waiting for Rancher instance to be running..."
    aws ec2 wait instance-running --instance-ids $RANCHER_INSTANCE_ID --region $AWS_REGION
    
    # Get public IP
    RANCHER_PUBLIC_IP=$(aws ec2 describe-instances \
        --instance-ids $RANCHER_INSTANCE_ID \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text \
        --region $AWS_REGION)
    
    log "Rancher instance is running. Public IP: $RANCHER_PUBLIC_IP"
    echo $RANCHER_PUBLIC_IP > rancher_public_ip.txt
}

# Create Kubernetes nodes
create_k8s_nodes() {
    log "Creating Kubernetes node instances..."
    
    # Create user data script for K8s nodes
    cat > k8s_userdata.sh << 'EOF'
#!/bin/bash
apt-get update
apt-get install -y curl

# Format and mount additional volume
mkfs.ext4 /dev/nvme1n1
mkdir -p /opt/kubernetes-data
mount /dev/nvme1n1 /opt/kubernetes-data
echo '/dev/nvme1n1 /opt/kubernetes-data ext4 defaults 0 2' >> /etc/fstab
chown -R ubuntu:ubuntu /opt/kubernetes-data

# Prepare for RKE2 installation
curl -sfL https://get.rke2.io | sh -
mkdir -p /etc/rancher/rke2
EOF

    K8S_INSTANCE_IDS=()
    for i in $(seq 1 $K8S_NODE_COUNT); do
        INSTANCE_ID=$(aws ec2 run-instances \
            --image-id $UBUNTU_AMI_ID \
            --instance-type $K8S_INSTANCE_TYPE \
            --key-name $KEY_NAME \
            --security-group-ids $K8S_SG_ID \
            --subnet-id ${PRIVATE_SUBNETS[$((i-1))]} \
            --monitoring Enabled=true \
            --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$ROOT_VOLUME_SIZE,\"VolumeType\":\"gp3\"}},{\"DeviceName\":\"/dev/sdf\",\"Ebs\":{\"VolumeSize\":$DATA_VOLUME_SIZE,\"VolumeType\":\"gp3\"}}]" \
            --user-data file://k8s_userdata.sh \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-k8s-node-$i},{Key=Environment,Value=$ENVIRONMENT},{Key=Department,Value=Platform Engineering},{Key=CostCenter,Value=Engineering},{Key=Owner,Value=IOC Labs},{Key=Cluster,Value=ioc-platform-cluster}]" \
            --query 'Instances[0].InstanceId' \
            --output text \
            --region $AWS_REGION)
        
        K8S_INSTANCE_IDS+=($INSTANCE_ID)
        log "Kubernetes node $i created: $INSTANCE_ID"
    done
    
    echo "${K8S_INSTANCE_IDS[@]}" > k8s_instance_ids.txt
    
    # Wait for all instances to be running
    log "Waiting for Kubernetes nodes to be running..."
    for instance_id in "${K8S_INSTANCE_IDS[@]}"; do
        aws ec2 wait instance-running --instance-ids $instance_id --region $AWS_REGION
    done
    
    log "All Kubernetes nodes are running"
}

# Display summary
display_summary() {
    log "Infrastructure deployment completed!"
    echo
    echo -e "${BLUE}=== INFRASTRUCTURE SUMMARY ===${NC}"
    echo "Project: $PROJECT_NAME"
    echo "Environment: $ENVIRONMENT"
    echo "Region: $AWS_REGION"
    echo "VPC ID: $VPC_ID"
    echo "Rancher Instance ID: $RANCHER_INSTANCE_ID"
    echo "Rancher Public IP: $RANCHER_PUBLIC_IP"
    echo "Kubernetes Node Count: $K8S_NODE_COUNT"
    echo
    echo -e "${BLUE}=== NEXT STEPS ===${NC}"
    echo "1. Wait 5-10 minutes for Rancher to fully start"
    echo "2. Access Rancher at: https://$RANCHER_PUBLIC_IP"
    echo "3. SSH to Rancher: ssh -i ~/.ssh/id_rsa ubuntu@$RANCHER_PUBLIC_IP"
    echo "4. Configure Rancher and add Kubernetes nodes"
    echo
    echo -e "${BLUE}=== CLEANUP ===${NC}"
    echo "To clean up resources, run: ./cleanup.sh"
    
    # Create cleanup script
    cat > cleanup.sh << EOF
#!/bin/bash
echo "Cleaning up AWS resources..."

# Read resource IDs
VPC_ID=\$(cat vpc_id.txt 2>/dev/null)
RANCHER_INSTANCE_ID=\$(cat rancher_instance_id.txt 2>/dev/null)
K8S_INSTANCE_IDS=\$(cat k8s_instance_ids.txt 2>/dev/null)
NAT_GW_ID=\$(cat nat_gw_id.txt 2>/dev/null)

# Terminate instances
if [ ! -z "\$RANCHER_INSTANCE_ID" ]; then
    aws ec2 terminate-instances --instance-ids \$RANCHER_INSTANCE_ID --region $AWS_REGION
fi

if [ ! -z "\$K8S_INSTANCE_IDS" ]; then
    aws ec2 terminate-instances --instance-ids \$K8S_INSTANCE_IDS --region $AWS_REGION
fi

# Wait for instances to terminate
echo "Waiting for instances to terminate..."
sleep 60

# Delete NAT Gateway
if [ ! -z "\$NAT_GW_ID" ]; then
    aws ec2 delete-nat-gateway --nat-gateway-id \$NAT_GW_ID --region $AWS_REGION
    sleep 30
fi

# Release Elastic IP
EIP_ALLOC_ID=\$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=${PROJECT_NAME}-nat-eip" --query 'Addresses[0].AllocationId' --output text --region $AWS_REGION)
if [ "\$EIP_ALLOC_ID" != "None" ]; then
    aws ec2 release-address --allocation-id \$EIP_ALLOC_ID --region $AWS_REGION
fi

# Delete key pair
aws ec2 delete-key-pair --key-name $KEY_NAME --region $AWS_REGION

# Delete VPC (this will delete associated resources)
if [ ! -z "\$VPC_ID" ]; then
    aws ec2 delete-vpc --vpc-id \$VPC_ID --region $AWS_REGION
fi

# Clean up files
rm -f *.txt rancher_userdata.sh k8s_userdata.sh

echo "Cleanup completed!"
EOF
    
    chmod +x cleanup.sh
}

# Main execution
main() {
    echo -e "${BLUE}=== IOC Platform Demo Infrastructure Setup ===${NC}"
    echo "This script will create AWS infrastructure for Rancher and Kubernetes"
    echo
    
    check_prerequisites
    
    # Check if we have complete infrastructure
    if [ -f vpc_id.txt ] && [ -f public_subnets.txt ] && [ -f private_subnets.txt ] && [ -f nat_gw_id.txt ] && [ -f rancher_sg_id.txt ] && [ -f k8s_sg_id.txt ]; then
        PUBLIC_SUBNETS=($(cat public_subnets.txt))
        PRIVATE_SUBNETS=($(cat private_subnets.txt))
        VPC_ID=$(cat vpc_id.txt)
        IGW_ID=$(cat igw_id.txt)
        NAT_GW_ID=$(cat nat_gw_id.txt)
        RANCHER_SG_ID=$(cat rancher_sg_id.txt)
        K8S_SG_ID=$(cat k8s_sg_id.txt)
        
        log "Using existing complete VPC infrastructure..."
    else
        warn "Incomplete or missing infrastructure files detected. Creating fresh infrastructure..."
        # Clean up any partial files
        rm -f *.txt
        
        create_vpc
        create_internet_gateway
        create_subnets
        create_nat_gateway
        create_route_tables
        create_security_groups
    fi
    
    create_key_pair
    get_ubuntu_ami
    create_rancher_instance
    create_k8s_nodes
    
    display_summary
}

# Run main function
main "$@"
