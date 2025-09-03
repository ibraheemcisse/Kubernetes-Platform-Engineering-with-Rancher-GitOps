# terraform/aws-infrastructure/outputs.tf

# VPC Outputs
output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "Availability zones used"
  value       = data.aws_availability_zones.available.names
}

# Security Group Outputs
output "rancher_management_security_group_id" {
  description = "ID of the Rancher management security group"
  value       = aws_security_group.rancher_management.id
}

output "kubernetes_nodes_security_group_id" {
  description = "ID of the Kubernetes nodes security group"
  value       = aws_security_group.kubernetes_nodes.id
}

# Rancher Management Server Outputs
output "rancher_management_instance_id" {
  description = "Instance ID of the Rancher management server"
  value       = aws_instance.rancher_management.id
}

output "rancher_management_private_ip" {
  description = "Private IP address of the Rancher management server"
  value       = aws_instance.rancher_management.private_ip
}

output "rancher_management_public_ip" {
  description = "Public IP address of the Rancher management server"
  value       = aws_eip.rancher_management.public_ip
}

output "rancher_url" {
  description = "URL to access Rancher UI"
  value       = "https://${var.rancher_hostname}"
}

# Kubernetes Cluster Outputs
output "kubernetes_api_lb_dns" {
  description = "DNS name of the Kubernetes API load balancer"
  value       = aws_lb.kubernetes_api.dns_name
}

output "kubernetes_api_lb_zone_id" {
  description = "Zone ID of the Kubernetes API load balancer"
  value       = aws_lb.kubernetes_api.zone_id
}

output "autoscaling_group_name" {
  description = "Name of the Kubernetes nodes auto scaling group"
  value       = aws_autoscaling_group.kubernetes_nodes.name
}

output "autoscaling_group_arn" {
  description = "ARN of the Kubernetes nodes auto scaling group"
  value       = aws_autoscaling_group.kubernetes_nodes.arn
}

# IAM Outputs
output "rancher_node_role_arn" {
  description = "ARN of the IAM role for Rancher nodes"
  value       = aws_iam_role.rancher_node_role.arn
}

output "rancher_node_instance_profile_name" {
  description = "Name of the IAM instance profile for Rancher nodes"
  value       = aws_iam_instance_profile.rancher_node_profile.name
}

# SSH Key Pair Output
output "key_pair_name" {
  description = "Name of the AWS key pair"
  value       = aws_key_pair.main.key_name
}

# Certificate Output
output "kubernetes_api_certificate_arn" {
  description = "ARN of the ACM certificate for Kubernetes API"
  value       = aws_acm_certificate.kubernetes_api.arn
}

# Connection Information
output "ssh_connection_commands" {
  description = "SSH commands to connect to instances"
  value = {
    rancher_management = "ssh -i ~/.ssh/${aws_key_pair.main.key_name}.pem ec2-user@${aws_eip.rancher_management.public_ip}"
  }
}

output "cluster_information" {
  description = "Important cluster information"
  value = {
    rancher_ui_url              = "https://${var.rancher_hostname}"
    rancher_management_ip       = aws_eip.rancher_management.public_ip
    kubernetes_api_endpoint     = aws_lb.kubernetes_api.dns_name
    cluster_name               = var.cluster_name
    vpc_cidr                   = var.vpc_cidr
    pod_cidr                   = var.pod_cidr
    service_cidr               = var.service_cidr
    availability_zones         = data.aws_availability_zones.available.names
    node_count_per_az          = var.kubernetes_node_count
    total_initial_nodes        = var.availability_zone_count * var.kubernetes_node_count
  }
}

# Quick Start Commands
output "quick_start_commands" {
  description = "Quick start commands for cluster access"
  value = {
    ssh_to_rancher         = "ssh -i ~/.ssh/${aws_key_pair.main.key_name}.pem ec2-user@${aws_eip.rancher_management.public_ip}"
    view_rancher_password  = "ssh -i ~/.ssh/${aws_key_pair.main.key_name}.pem ec2-user@${aws_eip.rancher_management.public_ip} 'cat ~/rancher-password.txt'"
    view_cluster_info      = "ssh -i ~/.ssh/${aws_key_pair.main.key_name}.pem ec2-user@${aws_eip.rancher_management.public_ip} 'cat ~/cluster-info.txt'"
    kubectl_get_nodes      = "ssh -i ~/.ssh/${aws_key_pair.main.key_name}.pem ec2-user@${aws_eip.rancher_management.public_ip} 'kubectl get nodes'"
  }
}

# DNS Configuration (for manual setup or future automation)
output "dns_records_needed" {
  description = "DNS records that need to be created"
  value = {
    rancher_hostname = {
      name    = var.rancher_hostname
      type    = "A"
      value   = aws_eip.rancher_management.public_ip
      comment = "Rancher Management UI"
    }
    kubernetes_api = {
      name    = "k8s-api.${replace(var.rancher_hostname, "rancher.", "")}"
      type    = "CNAME"
      value   = aws_lb.kubernetes_api.dns_name
      comment = "Kubernetes API Load Balancer"
    }
  }
}

# Phase 2 Preparation Outputs
output "phase2_preparation" {
  description = "Information needed for Phase 2 implementation"
  value = {
    vpc_id                    = aws_vpc.main.id
    private_subnet_ids        = aws_subnet.private[*].id
    kubernetes_security_group = aws_security_group.kubernetes_nodes.id
    rancher_management_ip     = aws_eip.rancher_management.public_ip
    cluster_name              = var.cluster_name
    iam_role_arn              = aws_iam_role.rancher_node_role.arn
  }
}
