# terraform/aws-infrastructure/terraform.tfvars.example
# Copy this file to terraform.tfvars and update with your values

# AWS Configuration
aws_region = "us-east-1"
environment = "demo"
project_name = "ioc-platform-demo"

# Network Configuration
vpc_cidr = "10.0.0.0/16"
availability_zone_count = 3

# SSH Key - Generate with: ssh-keygen -t rsa -b 4096 -f ~/.ssh/ioc-platform-demo
# Then paste the contents of ~/.ssh/ioc-platform-demo.pub here
public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC... your-public-key-here"

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
rancher_hostname = "rancher.ioc-labs.local"  # Update with your actual domain
cert_manager_version = "v1.13.0"

# Kubernetes Configuration
kubernetes_version = "v1.28.5+rke2r1"
cluster_name = "ioc-platform-cluster"
pod_cidr = "10.42.0.0/16"
service_cidr = "10.43.0.0/16"

# CloudFlare (for future phases)
cloudflare_zone_id = ""
cloudflare_api_token = ""

# Additional Tags
additional_tags = {
  Department = "Platform Engineering"
  CostCenter = "Engineering"
  Owner = "IOC Labs"
}
