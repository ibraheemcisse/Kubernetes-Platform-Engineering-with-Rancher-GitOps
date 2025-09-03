# terraform/aws-infrastructure/instances.tf

# Launch Template for Rancher Management Server
resource "aws_launch_template" "rancher_management" {
  name_prefix   = "${var.project_name}-rancher-mgmt"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.rancher_management_instance_type
  key_name      = aws_key_pair.main.key_name
  
  vpc_security_group_ids = [aws_security_group.rancher_management.id]
  
  iam_instance_profile {
    name = aws_iam_instance_profile.rancher_node_profile.name
  }
  
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.root_volume_size
      volume_type          = "gp3"
      encrypted            = true
      delete_on_termination = true
    }
  }
  
  monitoring {
    enabled = var.enable_detailed_monitoring
  }
  
  user_data = base64encode(templatefile("${path.module}/user-data/rancher-management.sh", {
    rancher_hostname = var.rancher_hostname
    rancher_version  = var.rancher_version
    cert_manager_version = var.cert_manager_version
  }))
  
  tag_specifications {
    resource_type = "instance"
    tags = merge(
      {
        Name = "${var.project_name}-rancher-management"
        Role = "rancher-management"
      },
      var.additional_tags
    )
  }
  
  tag_specifications {
    resource_type = "volume"
    tags = merge(
      {
        Name = "${var.project_name}-rancher-management-volume"
      },
      var.additional_tags
    )
  }
  
  tags = {
    Name = "${var.project_name}-rancher-management-template"
  }
}

# Launch Template for Kubernetes Nodes
resource "aws_launch_template" "kubernetes_nodes" {
  name_prefix   = "${var.project_name}-k8s-nodes"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.kubernetes_node_instance_type
  key_name      = aws_key_pair.main.key_name
  
  vpc_security_group_ids = [aws_security_group.kubernetes_nodes.id]
  
  iam_instance_profile {
    name = aws_iam_instance_profile.rancher_node_profile.name
  }
  
  # Root volume
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.root_volume_size
      volume_type          = "gp3"
      encrypted            = true
      delete_on_termination = true
    }
  }
  
  # Data volume for container storage
  block_device_mappings {
    device_name = "/dev/xvdf"
    ebs {
      volume_size           = var.data_volume_size
      volume_type          = "gp3"
      encrypted            = true
      delete_on_termination = true
    }
  }
  
  monitoring {
    enabled = var.enable_detailed_monitoring
  }
  
  user_data = base64encode(templatefile("${path.module}/user-data/kubernetes-node.sh", {
    rancher_server_url = "https://${var.rancher_hostname}"
    cluster_name       = var.cluster_name
    kubernetes_version = var.kubernetes_version
  }))
  
  tag_specifications {
    resource_type = "instance"
    tags = merge(
      {
        Name = "${var.project_name}-k8s-node"
        Role = "kubernetes-node"
        "kubernetes.io/cluster/${var.cluster_name}" = "owned"
      },
      var.additional_tags
    )
  }
  
  tag_specifications {
    resource_type = "volume"
    tags = merge(
      {
        Name = "${var.project_name}-k8s-node-volume"
      },
      var.additional_tags
    )
  }
  
  tags = {
    Name = "${var.project_name}-k8s-nodes-template"
  }
}

# Rancher Management Server Instance
resource "aws_instance" "rancher_management" {
  launch_template {
    id      = aws_launch_template.rancher_management.id
    version = "$Latest"
  }
  
  subnet_id = aws_subnet.public[0].id
  
  # Associate Elastic IP
  associate_public_ip_address = true
  
  tags = {
    Name = "${var.project_name}-rancher-management"
    Role = "rancher-management"
  }
}

# Elastic IP for Rancher Management Server
resource "aws_eip" "rancher_management" {
  instance = aws_instance.rancher_management.id
  domain   = "vpc"
  
  tags = {
    Name = "${var.project_name}-rancher-management-eip"
  }
  
  depends_on = [aws_internet_gateway.main]
}

# Auto Scaling Group for Kubernetes Nodes
resource "aws_autoscaling_group" "kubernetes_nodes" {
  name                = "${var.project_name}-k8s-nodes-asg"
  vpc_zone_identifier = aws_subnet.private[*].id
  target_group_arns   = []
  health_check_type   = "EC2"
  health_check_grace_period = 300
  
  min_size         = var.availability_zone_count * var.kubernetes_node_count
  max_size         = var.availability_zone_count * var.kubernetes_node_count * 3
  desired_capacity = var.availability_zone_count * var.kubernetes_node_count
  
  launch_template {
    id      = aws_launch_template.kubernetes_nodes.id
    version = "$Latest"
  }
  
  # Instance distribution
  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.kubernetes_nodes.id
        version           = "$Latest"
      }
      
      override {
        instance_type = var.kubernetes_node_instance_type
      }
    }
    
    instances_distribution {
      on_demand_base_capacity                  = 1
      on_demand_percentage_above_base_capacity = 50
      spot_allocation_strategy                 = "capacity-optimized"
    }
  }
  
  tag {
    key                 = "Name"
    value               = "${var.project_name}-k8s-node"
    propagate_at_launch = true
  }
  
  tag {
    key                 = "kubernetes.io/cluster/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = true
  }
  
  tag {
    key                 = "Role"
    value               = "kubernetes-node"
    propagate_at_launch = true
  }
  
  # Enable instance refresh
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup       = 300
    }
  }
  
  lifecycle {
    create_before_destroy = true
  }
}

# Application Load Balancer for Kubernetes API
resource "aws_lb" "kubernetes_api" {
  name               = "${var.project_name}-k8s-api-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.kubernetes_api_alb.id]
  subnets            = aws_subnet.public[*].id
  
  enable_deletion_protection = false
  
  tags = {
    Name = "${var.project_name}-k8s-api-alb"
  }
}

# Security Group for ALB
resource "aws_security_group" "kubernetes_api_alb" {
  name_prefix = "${var.project_name}-k8s-api-alb"
  vpc_id      = aws_vpc.main.id
  description = "Security group for Kubernetes API ALB"
  
  # HTTPS
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  # HTTP (for redirect)
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  # All outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "${var.project_name}-k8s-api-alb-sg"
  }
}

# Target Group for Kubernetes API
resource "aws_lb_target_group" "kubernetes_api" {
  name     = "${var.project_name}-k8s-api-tg"
  port     = 6443
  protocol = "HTTPS"
  vpc_id   = aws_vpc.main.id
  
  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = "/livez"
    port                = "traffic-port"
    protocol            = "HTTPS"
    timeout             = 5
    unhealthy_threshold = 2
  }
  
  tags = {
    Name = "${var.project_name}-k8s-api-tg"
  }
}

# ALB Listener
resource "aws_lb_listener" "kubernetes_api" {
  load_balancer_arn = aws_lb.kubernetes_api.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS-1-2-2017-01"
  certificate_arn   = aws_acm_certificate.kubernetes_api.arn
  
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kubernetes_api.arn
  }
}

# Self-signed certificate for initial setup
resource "aws_acm_certificate" "kubernetes_api" {
  domain_name       = var.rancher_hostname
  validation_method = "DNS"
  
  lifecycle {
    create_before_destroy = true
  }
  
  tags = {
    Name = "${var.project_name}-k8s-api-cert"
  }
}
