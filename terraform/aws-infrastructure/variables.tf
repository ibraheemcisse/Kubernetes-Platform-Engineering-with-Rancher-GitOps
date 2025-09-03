# terraform/aws-infrastructure/variables.tf

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "demo"
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "ioc-platform-demo"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zone_count" {
  description = "Number of availability zones to use"
  type        = number
  default     = 3
  
  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 6
    error_message = "Availability zone count must be between 2 and 6."
  }
}

variable "public_key" {
  description = "SSH public key for EC2 instances"
  type        = string
}

variable "rancher_management_instance_type" {
  description = "Instance type for Rancher management server"
  type        = string
  default     = "t3.large"
}

variable "kubernetes_node_instance_type" {
  description = "Instance type for Kubernetes nodes"
  type        = string
  default     = "t3.large"
}

variable "kubernetes_node_count" {
  description = "Number of Kubernetes nodes per availability zone"
  type        = number
  default     = 1
}

variable "enable_detailed_monitoring" {
  description = "Enable detailed CloudWatch monitoring for EC2 instances"
  type        = bool
  default     = true
}

variable "root_volume_size" {
  description = "Size of root volume in GB"
  type        = number
  default     = 50
}

variable "data_volume_size" {
  description = "Size of data volume in GB for Kubernetes nodes"
  type        = number
  default     = 100
}

# Rancher Configuration
variable "rancher_version" {
  description = "Rancher version to install"
  type        = string
  default     = "2.8.0"
}

variable "rancher_hostname" {
  description = "Hostname for Rancher server"
  type        = string
  default     = "rancher.ioc-labs.local"
}

variable "cert_manager_version" {
  description = "cert-manager version for Rancher"
  type        = string
  default     = "v1.13.0"
}

# Kubernetes Configuration
variable "kubernetes_version" {
  description = "Kubernetes version for the cluster"
  type        = string
  default     = "v1.28.5+rke2r1"
}

variable "cluster_name" {
  description = "Name for the Kubernetes cluster"
  type        = string
  default     = "ioc-platform-cluster"
}

# Networking
variable "pod_cidr" {
  description = "CIDR block for Kubernetes pods"
  type        = string
  default     = "10.42.0.0/16"
}

variable "service_cidr" {
  description = "CIDR block for Kubernetes services"
  type        = string
  default     = "10.43.0.0/16"
}

# Tags
variable "additional_tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# CloudFlare (for future phases)
variable "cloudflare_zone_id" {
  description = "CloudFlare zone ID for DNS management"
  type        = string
  default     = ""
}

variable "cloudflare_api_token" {
  description = "CloudFlare API token"
  type        = string
  sensitive   = true
  default     = ""
}
