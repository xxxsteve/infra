aws_region = "ap-northeast-1"
availability_zone = "ap-northeast-1c"
instance_type = "t2.micro"
# instance_type = "c7gn.medium"

# Your existing EC2 key pair name
key_pair_name = "aws-steven-2026"

# Storage configuration
root_volume_size       = 8
root_volume_type       = "gp3"
root_volume_iops       = 3000
root_volume_throughput = 125

# ENA Express
enable_ena_express     = false
enable_ena_express_udp = false

# Project name for tagging
project_name = "steven"

# VPC configuration
vpc_cidr    = "10.0.0.0/16"
subnet_cidr = "10.0.1.0/24"

# Leave empty to use Ubuntu 24.04
ami_id = ""
