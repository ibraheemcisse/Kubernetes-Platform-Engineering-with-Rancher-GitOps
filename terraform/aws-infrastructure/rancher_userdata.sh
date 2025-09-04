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
