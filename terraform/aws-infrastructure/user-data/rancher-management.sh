#!/bin/bash
# terraform/aws-infrastructure/user-data/rancher-management.sh

set -e

# Variables from Terraform
RANCHER_HOSTNAME="${rancher_hostname}"
RANCHER_VERSION="${rancher_version}"
CERT_MANAGER_VERSION="${cert_manager_version}"

# Log all output
exec > >(tee /var/log/rancher-setup.log) 2>&1

echo "=== Starting Rancher Management Server Setup ==="
echo "Hostname: $RANCHER_HOSTNAME"
echo "Rancher Version: $RANCHER_VERSION"
echo "Cert Manager Version: $CERT_MANAGER_VERSION"

# Update system
echo "=== Updating system packages ==="
yum update -y

# Install required packages
echo "=== Installing required packages ==="
yum install -y \
    docker \
    curl \
    wget \
    jq \
    git \
    unzip \
    htop \
    iotop \
    net-tools \
    bind-utils

# Start and enable Docker
echo "=== Starting Docker service ==="
systemctl start docker
systemctl enable docker
usermod -aG docker ec2-user

# Install Docker Compose
echo "=== Installing Docker Compose ==="
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Install kubectl
echo "=== Installing kubectl ==="
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/

# Install Helm
echo "=== Installing Helm ==="
curl https://get.helm.sh/helm-v3.13.0-linux-amd64.tar.gz | tar -xzO linux-amd64/helm > /usr/local/bin/helm
chmod +x /usr/local/bin/helm

# Setup Docker daemon configuration
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
  ]
}
EOF

systemctl restart docker

# Install RKE2 (Rancher Kubernetes Engine 2)
echo "=== Installing RKE2 ==="
curl -sfL https://get.rke2.io | INSTALL_RKE2_CHANNEL=latest sh -

# Create RKE2 config directory
mkdir -p /etc/rancher/rke2

# Create RKE2 configuration
cat > /etc/rancher/rke2/config.yaml << EOF
# RKE2 Configuration for Rancher Management Server
token: $(openssl rand -hex 32)
tls-san:
  - $RANCHER_HOSTNAME
  - $(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
  - $(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
cluster-cidr: 10.42.0.0/16
service-cidr: 10.43.0.0/16
cluster-dns: 10.43.0.10
cluster-domain: cluster.local
write-kubeconfig-mode: "0644"
node-label:
  - "node-role.kubernetes.io/master=true"
  - "rancher.io/management=true"
disable:
  - rke2-ingress-nginx
EOF

# Start and enable RKE2 server
echo "=== Starting RKE2 server ==="
systemctl enable rke2-server.service
systemctl start rke2-server.service

# Wait for RKE2 to be ready
echo "=== Waiting for RKE2 to be ready ==="
while ! systemctl is-active --quiet rke2-server; do
    echo "Waiting for RKE2 server to start..."
    sleep 10
done

# Setup kubectl config for root
mkdir -p /root/.kube
cp /etc/rancher/rke2/rke2.yaml /root/.kube/config
chmod 600 /root/.kube/config

# Setup kubectl config for ec2-user
mkdir -p /home/ec2-user/.kube
cp /etc/rancher/rke2/rke2.yaml /home/ec2-user/.kube/config
chown ec2-user:ec2-user /home/ec2-user/.kube/config
chmod 600 /home/ec2-user/.kube/config

# Add RKE2 binaries to PATH
echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin' >> /etc/environment
echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' >> /etc/environment

# Add to current session
export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# Wait for cluster to be fully ready
echo "=== Waiting for Kubernetes cluster to be ready ==="
for i in {1..30}; do
    if kubectl get nodes --no-headers 2>/dev/null | grep -q Ready; then
        echo "Kubernetes cluster is ready!"
        break
    fi
    echo "Waiting for cluster to be ready... ($i/30)"
    sleep 10
done

# Install cert-manager
echo "=== Installing cert-manager ==="
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.crds.yaml

helm repo add jetstack https://charts.jetstack.io
helm repo update

kubectl create namespace cert-manager || true

helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --version $CERT_MANAGER_VERSION \
    --set installCRDs=true \
    --wait

# Wait for cert-manager to be ready
echo "=== Waiting for cert-manager to be ready ==="
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager -n cert-manager
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-cainjector -n cert-manager
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-webhook -n cert-manager

# Install Rancher
echo "=== Installing Rancher ==="
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update

kubectl create namespace cattle-system || true

# Generate bootstrap password
RANCHER_PASSWORD=$(openssl rand -base64 32)
echo "Rancher Bootstrap Password: $RANCHER_PASSWORD" > /home/ec2-user/rancher-password.txt
chown ec2-user:ec2-user /home/ec2-user/rancher-password.txt

# Install Rancher with generated certificate
helm upgrade --install rancher rancher-latest/rancher \
    --namespace cattle-system \
    --set hostname=$RANCHER_HOSTNAME \
    --set bootstrapPassword=$RANCHER_PASSWORD \
    --set ingress.tls.source=rancher \
    --set replicas=1 \
    --version $RANCHER_VERSION \
    --wait

# Wait for Rancher to be ready
echo "=== Waiting for Rancher to be ready ==="
kubectl wait --for=condition=available --timeout=600s deployment/rancher -n cattle-system

# Create a simple ingress controller (nginx)
echo "=== Installing NGINX Ingress Controller ==="
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.service.type=LoadBalancer \
    --wait

# Wait for ingress controller to get external IP
echo "=== Waiting for Load Balancer IP ==="
for i in {1..30}; do
    LB_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$LB_IP" ]; then
        echo "Load Balancer Hostname: $LB_IP"
        echo "$LB_IP" > /home/ec2-user/loadbalancer-hostname.txt
        chown ec2-user:ec2-user /home/ec2-user/loadbalancer-hostname.txt
        break
    fi
    echo "Waiting for Load Balancer to be assigned... ($i/30)"
    sleep 10
done

# Create cluster registration token for future worker nodes
echo "=== Creating cluster registration token ==="
kubectl create namespace cattle-global-data || true

# Save cluster information
echo "=== Saving cluster information ==="
cat > /home/ec2-user/cluster-info.txt << EOF
=== IOC Platform Demo - Rancher Management Server ===

Rancher UI: https://$RANCHER_HOSTNAME
Bootstrap Password: $RANCHER_PASSWORD

Kubernetes Cluster Info:
- Cluster Name: Local (Rancher Management Cluster)
- Kubernetes Version: $(kubectl version --short 2>/dev/null | grep Server | cut -d' ' -f3)
- Nodes: $(kubectl get nodes --no-headers | wc -l)

Load Balancer Hostname: $LB_IP

Useful Commands:
- kubectl get nodes
- kubectl get pods -A
- helm list -A

Configuration Files:
- Kubeconfig: /etc/rancher/rke2/rke2.yaml
- RKE2 Config: /etc/rancher/rke2/config.yaml
- Rancher Password: /home/ec2-user/rancher-password.txt

EOF

chown ec2-user:ec2-user /home/ec2-user/cluster-info.txt

# Setup systemd service for cluster monitoring
cat > /etc/systemd/system/cluster-monitor.service << EOF
[Unit]
Description=Kubernetes Cluster Monitor
After=rke2-server.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/cluster-monitor.sh
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

# Create cluster monitor script
cat > /usr/local/bin/cluster-monitor.sh << 'EOF'
#!/bin/bash
export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

while true; do
    # Log cluster status every 5 minutes
    echo "$(date): Cluster Status Check" >> /var/log/cluster-status.log
    kubectl get nodes --no-headers >> /var/log/cluster-status.log 2>&1
    kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded >> /var/log/cluster-status.log 2>&1 || true
    sleep 300
done
EOF

chmod +x /usr/local/bin/cluster-monitor.sh
systemctl enable cluster-monitor.service
systemctl start cluster-monitor.service

# Install AWS CLI
echo "=== Installing AWS CLI ==="
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip

# Setup log rotation
cat > /etc/logrotate.d/rancher-setup << EOF
/var/log/rancher-setup.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
}

/var/log/cluster-status.log {
    daily
    rotate 30
    compress
    missingok
    notifempty
}
EOF

echo "=== Rancher Management Server Setup Complete ==="
echo "Access Rancher UI at: https://$RANCHER_HOSTNAME"
echo "Bootstrap password saved to: /home/ec2-user/rancher-password.txt"
echo "Cluster information saved to: /home/ec2-user/cluster-info.txt"

# Signal completion
touch /tmp/rancher-setup-complete
