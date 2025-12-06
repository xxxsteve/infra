aws_region = "ap-northeast-1"
availability_zone = "ap-northeast-1c"
instance_type = "c7gn.medium"

# Your existing EC2 key pair name
key_pair_name = "your-key-pair-name"

# Storage configuration
root_volume_size       = 30
root_volume_type       = "gp3"
root_volume_iops       = 3000
root_volume_throughput = 125

# ENA Express for lower latency (requires c7gn or similar)
enable_ena_express     = true
enable_ena_express_udp = true

# Project name for tagging
project_name = "binance"

# VPC configuration
vpc_cidr    = "10.0.0.0/16"
subnet_cidr = "10.0.1.0/24"

# Leave empty to use latest Ubuntu 24.04 ARM
ami_id = ""
