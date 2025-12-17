terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# S3 bucket for latency test results
resource "aws_s3_bucket" "results" {
  bucket        = "binance-latency-results-${var.project_name}"
  force_destroy = true

  tags = {
    Name    = "${var.project_name}-results"
    Project = var.project_name
  }
}

# Block public access
resource "aws_s3_bucket_public_access_block" "results" {
  bucket = aws_s3_bucket.results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM role for EC2 instances
resource "aws_iam_role" "instance_role" {
  name = "${var.project_name}-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = {
    Name    = "${var.project_name}-instance-role"
    Project = var.project_name
  }
}

# Policy to allow S3 read/write access
resource "aws_iam_role_policy" "s3_access" {
  name = "${var.project_name}-s3-access"
  role = aws_iam_role.instance_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:PutObjectAcl"
      ]
      Resource = "${aws_s3_bucket.results.arn}/*"
    }]
  })
}

# Instance profile
resource "aws_iam_instance_profile" "instance_profile" {
  name = "${var.project_name}-instance-profile"
  role = aws_iam_role.instance_role.name

  tags = {
    Name    = "${var.project_name}-instance-profile"
    Project = var.project_name
  }
}

# Upload test scripts to S3
resource "aws_s3_object" "network_analysis_script" {
  bucket = aws_s3_bucket.results.id
  key    = "scripts/network_analysis.py"
  source = "${path.module}/../scripts/network_analysis.py"
  etag   = filemd5("${path.module}/../scripts/network_analysis.py")
}

resource "aws_s3_object" "ws_latency_script" {
  bucket = aws_s3_bucket.results.id
  key    = "scripts/ws_latency.py"
  source = "${path.module}/../scripts/ws_latency.py"
  etag   = filemd5("${path.module}/../scripts/ws_latency.py")
}

resource "aws_s3_object" "tune_system_script" {
  bucket = aws_s3_bucket.results.id
  key    = "scripts/tune_system.sh"
  source = "${path.module}/../scripts/tune_system.sh"
  etag   = filemd5("${path.module}/../scripts/tune_system.sh")
}

# Outputs
output "s3_bucket_name" {
  description = "S3 bucket name for results"
  value       = aws_s3_bucket.results.id
}

output "s3_bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.results.arn
}

output "instance_profile_name" {
  description = "IAM instance profile name for EC2"
  value       = aws_iam_instance_profile.instance_profile.name
}

output "instance_role_arn" {
  description = "IAM role ARN"
  value       = aws_iam_role.instance_role.arn
}
