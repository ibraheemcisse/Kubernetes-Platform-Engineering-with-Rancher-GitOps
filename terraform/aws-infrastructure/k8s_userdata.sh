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
