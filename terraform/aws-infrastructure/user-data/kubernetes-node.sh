#!/bin/bash
# terraform/aws-infrastructure/user-data/kubernetes-node.sh

set -e

# Variables from Terraform
RANCHER_SERVER_URL="${rancher_server_url}"
CLUSTER_NAME="${cluster_name}"
KUBERNETES_VERSION="${kubernetes_version}"

# Log all output
exec > >(tee /var/log/k8s-node-setup.log) 2>&1

echo "=== Starting Kubernetes Node Setup ==="
echo "Rancher Server URL: $RANCHER_SERVER_URL"
echo "Cluster Name: $CLUSTER_NAME"
echo "Kubernetes Version: $KUBERNETES_VERSION"

# Update system
echo "=== Updating system packages ==="
yum update -y

# Install required packages
echo "=== Installing required packages ==="
yum install -y \
    curl \
    wget \
    jq \
    git \
    unzip \
    htop \
    iotop \
    net-tools \
    bind-utils \
    lvm2 \
    device-mapper-persistent-data

# Setup additional disk for container storage
echo "=== Setting up additional storage ==="
if [ -b /dev/xvdf ]; then
    echo "Setting up /dev/xvdf for container storage"
    
    # Create physical volume
    pvcreate /dev/xvdf
    
    # Create volume group
    vgcreate docker-vg /dev/xvdf
    
    # Create logical volume for Docker
    lvcreate -l 80%VG -n docker-lv docker-vg
    
    # Create logical volume for Longhorn (Phase 2)
    lvcreate -l 20%VG -n longhorn-lv docker-vg
    
    # Format the Docker volume
    mkfs.xfs /dev/docker-vg/docker-lv
    
    # Create mount point
    mkdir -p /var/lib/docker
    
    # Add to fstab
    echo '/dev/docker-vg/docker-lv /var/lib/docker xfs defaults 0 0' >> /etc/fstab
    
    # Mount the volume
    mount /var/lib/docker
    
    echo "Storage setup complete"
else
    echo "Additional disk /dev/xvdf not found, using root disk"
fi

# Install Docker
echo "=== Installing Docker ==="
yum install -y docker
systemctl start docker
systemctl enable docker
usermod -aG docker ec2-user

# Configure Docker daemon
echo "=== Configuring Docker daemon ==="
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.override_kernel_check=true"
  ],
  "exec-opts": ["native.cgroupdriver=systemd"],
  "live-restore": true,
  "max-concurrent-downloads": 3,
  "max-concurrent-uploads": 5
}
EOF

systemctl restart docker

# Install kubectl
echo "=== Installing kubectl ==="
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/

# Install Helm (for future use)
echo "=== Installing Helm ==="
curl https://get.helm.sh/helm-v3.13.0-linux-amd64.tar.gz | tar -xzO linux-amd64/helm > /usr/local/bin/helm
chmod +x /usr/local/bin/helm

# Install RKE2 Agent
echo "=== Installing RKE2 Agent ==="
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" INSTALL_RKE2_CHANNEL=latest sh -

# Create RKE2 config directory
mkdir -p /etc/rancher/rke2

# Get instance metadata
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)

echo "=== Instance Information ==="
echo "Instance ID: $INSTANCE_ID"
echo "Private IP: $PRIVATE_IP"
echo "Public IP: $PUBLIC_IP"
echo "Availability Zone: $AZ"

# Wait for Rancher server to be available
echo "=== Waiting for Rancher server to be available ==="
for i in {1..60}; do
    if curl -k --connect-timeout 5 --max-time 10 "$RANCHER_SERVER_URL/ping" >/dev/null 2>&1; then
        echo "Rancher server is available!"
        break
    fi
    echo "Waiting for Rancher server... ($i/60)"
    sleep 30
done

# Note: In a production setup, you would get the cluster registration token from Rancher
# For this demo, we'll create a placeholder configuration that will be updated later
cat > /etc/rancher/rke2/config.yaml << EOF
# RKE2 Agent Configuration
server: https://rancher-management-server:9345
token: REPLACE_WITH_ACTUAL_TOKEN
node-ip: $PRIVATE_IP
node-external-ip: $PUBLIC_IP
node-name: $INSTANCE_ID
node-label:
  - "node-role.kubernetes.io/worker=true"
  - "topology.kubernetes.io/zone=$AZ"
  - "node.longhorn.io/create-default-disk=true"
kubelet-arg:
  - "cloud-provider=external"
  - "provider-id=aws:///$AZ/$INSTANCE_ID"
EOF

# Create a script to get the actual cluster token
cat > /usr/local/bin/get-cluster-token.sh << 'EOF'
#!/bin/bash
# This script will be used to retrieve the actual cluster registration token
# from Rancher server once it's available

RANCHER_SERVER_URL="$1"
TOKEN_FILE="/etc/rancher/rke2/token"

if [ -z "$RANCHER_SERVER_URL" ]; then
    echo "Usage: $0 <rancher_server_url>"
    exit 1
fi

# Wait for Rancher to be fully ready
echo "Waiting for Rancher server to be ready..."
while ! curl -k --connect-timeout 5 --max-time 10 "$RANCHER_SERVER_URL/v3" >/dev/null 2>&1; do
    sleep 10
done

echo "Rancher server is ready. Token retrieval would be implemented here."
# In production, you would use Rancher API to get cluster registration token
# For now, we'll use a placeholder
EOF

chmod +x /usr/local/bin/get-cluster-token.sh

# Install AWS CLI
echo "=== Installing AWS CLI ==="
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip

# Setup system optimizations for Kubernetes
echo "=== Applying Kubernetes optimizations ==="

# Disable swap
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Configure sysctl for Kubernetes
cat > /etc/sysctl.d/99-kubernetes.conf << EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
vm.overcommit_memory = 1
kernel.panic = 10
kernel.panic_on_oops = 1
EOF

sysctl --system

# Setup kernel modules
cat > /etc/modules-load.d/kubernetes.conf << EOF
br_netfilter
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF

modprobe br_netfilter
modprobe ip_vs
modprobe ip_vs_rr
modprobe ip_vs_wrr
modprobe ip_vs_sh
modprobe nf_conntrack

# Setup systemd service for node registration
cat > /etc/systemd/system/k8s-node-register.service << EOF
[Unit]
Description=Kubernetes Node Registration
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/node-register.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Create node registration script
cat > /usr/local/bin/node-register.sh << EOF
#!/bin/bash
# This script handles the node registration process

echo "\$(date): Starting node registration process" >> /var/log/node-registration.log

# Get the actual cluster registration token and update config
# This would typically involve calling the Rancher API
echo "Node registration process started. Manual cluster joining required." >> /var/log/node-registration.log

# For Phase 1, we'll prepare the node but not auto-join
# The cluster joining will be done manually or via Rancher UI
echo "Node prepared for cluster joining. Use Rancher UI to add this node to cluster." >> /var/log/node-registration.log
EOF

chmod +x /usr/local/bin/node-register.sh
systemctl enable k8s-node-register.service

# Setup node monitoring
cat > /etc/systemd/system/node-monitor.service << EOF
[Unit]
Description=Kubernetes Node Monitor
After=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/node-monitor.sh
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF

cat > /usr/local/bin/node-monitor.sh << 'EOF'
#!/bin/bash
export PATH=$PATH:/var/lib/rancher/rke2/bin

while true; do
    echo "$(date): Node status check" >> /var/log/node-status.log
    
    # Check system resources
    echo "Memory Usage: $(free -m | awk 'NR==2{printf "%.2f%%", $3*100/$2 }')" >> /var/log/node-status.log
    echo "Disk Usage: $(df -h / | awk 'NR==2{print $5}')" >> /var/log/node-status.log
    echo "Load Average: $(uptime | awk -F'load average:' '{print $2}')" >> /var/log/node-status.log
    
    # Check Docker status
    if systemctl is-active --quiet docker; then
        echo "Docker: Running" >> /var/log/node-status.log
    else
        echo "Docker: NOT Running" >> /var/log/node-status.log
    fi
    
    # Check if RKE2 agent is running
    if systemctl is-active --quiet rke2-agent; then
        echo "RKE2 Agent: Running" >> /var/log/node-status.log
        # If joined to cluster, show node status
        if command -v kubectl >/dev/null 2>&1 && [ -f /etc/rancher/rke2/rke2.yaml ]; then
            export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
            kubectl get nodes --no-headers 2>/dev/null | grep $(hostname) >> /var/log/node-status.log || true
        fi
    else
        echo "RKE2 Agent: NOT Running (normal for Phase 1)" >> /var/log/node-status.log
    fi
    
    echo "---" >> /var/log/node-status.log
    sleep 300
done
EOF

chmod +x /usr/local/bin/node-monitor.sh
systemctl enable node-monitor.service
systemctl start node-monitor.service

# Create information file for debugging
cat > /home/ec2-user/node-info.txt << EOF
=== IOC Platform Demo - Kubernetes Node ===

Node Information:
- Instance ID: $INSTANCE_ID
- Private IP: $PRIVATE_IP
- Public IP: $PUBLIC_IP
- Availability Zone: $AZ

Status:
- Docker: $(systemctl is-active docker)
- Node prepared for cluster joining

Next Steps:
1. Access Rancher UI at: $RANCHER_SERVER_URL
2. Create or select target Kubernetes cluster
3. Get cluster registration token
4. Run cluster join command on this node

Logs:
- Setup Log: /var/log/k8s-node-setup.log
- Node Status: /var/log/node-status.log
- Registration: /var/log/node-registration.log

Useful Commands:
- docker ps
- systemctl status docker
- systemctl status rke2-agent
- tail -f /var/log/node-status.log

EOF

chown ec2-user:ec2-user /home/ec2-user/node-info.txt

# Setup log rotation
cat > /etc/logrotate.d/kubernetes-node << EOF
/var/log/k8s-node-setup.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
}

/var/log/node-status.log {
    daily
    rotate 30
    compress
    missingok
    notifempty
}

/var/log/node-registration.log {
    daily
    rotate 30
    compress
    missingok
    notifempty
}
EOF

echo "=== Kubernetes Node Setup Complete ==="
echo "Node prepared for cluster joining"
echo "Node information saved to: /home/ec2-user/node-info.txt"
echo "Access Rancher UI to add this node to a cluster"

# Signal completion
touch /tmp/k8s-node-setup-complete
