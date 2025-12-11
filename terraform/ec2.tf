terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# region
provider "aws" {
  region = var.aws_region
}

# image
data "aws_ami" "ubuntu" {
  most_recent = true  # Get the newest matching AMI
  owners      = ["099720109477"]  # Canonical

  filter {
    name   = "name"
    # TODO values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    # TODO values = ["arm64"]
    values = ["x86_64"]
  }
}

# Network Interface with ENA Express (uses VPC resources from vpc.tf)
resource "aws_network_interface" "main" {
  subnet_id       = aws_subnet.public.id
  security_groups = [aws_security_group.binance.id]

  tags = {
    Name    = "${var.project_name}-eni"
    Project = var.project_name
  }
}

# EC2 Instance
resource "aws_instance" "latency_test" {
  # If var.ami_id is provided, use it; otherwise use the auto-discovered Ubuntu AMI
  ami               = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu.id
  instance_type     = var.instance_type
  key_name          = var.key_pair_name
  availability_zone = var.availability_zone
  iam_instance_profile = aws_iam_instance_profile.instance_profile.name  # Permissions for S3

  network_interface {
    network_interface_id = aws_network_interface.main.id
    device_index         = 0
  }

  # Root disk configuration
  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = var.root_volume_type      # gp3 = fast SSD
    iops                  = var.root_volume_type == "gp3" ? var.root_volume_iops : null
    throughput            = var.root_volume_type == "gp3" ? var.root_volume_throughput : null
    delete_on_termination = true
    encrypted             = true
  }

  # Instance metadata service settings (security)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # Require IMDSv2 (more secure)
    http_put_response_hop_limit = 2
  }

  # user_data = startup script that runs when instance first boots
  # templatefile() reads user_data.sh and substitutes variables
  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    binance_endpoints = jsonencode(var.binance_endpoints)
    s3_bucket         = aws_s3_bucket.results.id
    region            = var.aws_region
    availability_zone = var.availability_zone
  }))

  tags = {
    Name    = "${var.project_name}-instance"
    Project = var.project_name
    Purpose = "Binance latency testing"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Enable ENA Express on the network interface after instance creation
resource "null_resource" "enable_ena_express" {
  count = var.enable_ena_express ? 1 : 0  # Only create if enable_ena_express = true

  depends_on = [aws_instance.latency_test]  # Wait for instance to exist first

  # local-exec runs a command on YOUR machine (not the EC2 instance)
  provisioner "local-exec" {
    command = <<-EOT
      aws ec2 modify-network-interface-attribute \
        --network-interface-id ${aws_network_interface.main.id} \
        --ena-srd-specification "EnaSrdEnabled=true,EnaSrdUdpSpecification={EnaSrdUdpEnabled=${var.enable_ena_express_udp}}" \
        --region ${var.aws_region}
    EOT
  }
}

# Elastic IP for stable public IP
resource "aws_eip" "main" {
  domain = "vpc"

  tags = {
    Name    = "${var.project_name}-eip"
    Project = var.project_name
  }
}

resource "aws_eip_association" "main" {
  network_interface_id = aws_network_interface.main.id
  allocation_id        = aws_eip.main.id
}

# Outputs
output "instance_public_ip" {
  description = "Public IP address of the instance"
  value       = aws_eip.main.public_ip
}

output "instance_id" {
  description = "Instance ID"
  value       = aws_instance.latency_test.id
}

output "s3_bucket_name" {
  description = "S3 bucket for results"
  value       = aws_s3_bucket.results.id
}

output "region" {
  description = "AWS region"
  value       = var.aws_region
}

output "availability_zone" {
  description = "Availability zone"
  value       = var.availability_zone
}
