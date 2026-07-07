# IAM Role for Monitoring Instances
resource "aws_iam_role" "monitoring_role" {
  name = "monitoring-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Policy to allow Prometheus EC2 Service Discovery
resource "aws_iam_policy" "prometheus_discovery" {
  name        = "prometheus-ec2-discovery-policy"
  description = "Allows Prometheus to discover EC2 instances via API"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeTags",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# Attach policy to IAM Role
resource "aws_iam_role_policy_attachment" "discovery_attachment" {
  role       = aws_iam_role.monitoring_role.name
  policy_arn = aws_iam_policy.prometheus_discovery.arn
}

# Attach SSM Policy (standard helper policy for EC2 management)
resource "aws_iam_role_policy_attachment" "ssm_attachment" {
  role       = aws_iam_role.monitoring_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}



# Instance Profile
resource "aws_iam_instance_profile" "monitoring_profile" {
  name = "monitoring-instance-profile"
  role = aws_iam_role.monitoring_role.name
}

# Fetch latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Launch Template for ASG
resource "aws_launch_template" "monitoring" {
  name_prefix   = "monitoring-template-"
  image_id      = data.aws_ami.amazon_linux_2023.id
  instance_type = var.monitoring_instance_type
  key_name      = var.key_name

  iam_instance_profile {
    arn = aws_iam_instance_profile.monitoring_profile.arn
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.private_instances.id]
  }

  # User Data Script for bootstrapping (installs Ansible, runs playbook locally)
  user_data = base64encode(<<-EOF
              #!/bin/bash
              # Install Git and Ansible-core
              dnf install -y git ansible-core

              # Bootstrap via Ansible Local/Pull
              mkdir -p /opt/bootstrap
              
              # Clone git repo (this repository will be set via variables in Jenkins/Terraform)
              git clone -b ${var.git_repo_branch} ${var.git_repo_url} /opt/bootstrap
              
              # Execute Ansible locally
              cd /opt/bootstrap/ansible
              ansible-playbook -i "localhost," playbooks/monitoring.yml --connection=local --extra-vars "aws_default_region=${var.aws_region}"
              EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "monitoring-server"
      Role = "Monitoring"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Auto Scaling Group (ASG)
resource "aws_autoscaling_group" "monitoring_asg" {
  name_prefix         = "monitoring-asg-"
  desired_capacity    = 2
  max_size            = 4
  min_size            = 2
  vpc_zone_identifier = aws_subnet.private[*].id
  target_group_arns   = [
    aws_lb_target_group.grafana.arn
  ]
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.monitoring.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
    triggers = ["tag"]
  }

  tag {
    key                 = "Name"
    value               = "monitoring-server"
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "Monitoring"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
