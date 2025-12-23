aws_region = "ap-northeast-1"
availability_zone = "ap-northeast-1c"
# instance_type = "t2.micro"
# instance_type = "c7i.metal-48xl"
instance_type = "c7gn.16xlarge"
# architecture = "x86_64"
architecture = "arm64"

# Your existing EC2 key pair name
key_pair_name = "aws-steven-2026"

# Storage configuration
root_volume_size       = 32
root_volume_type       = "gp3"
root_volume_iops       = 3000
root_volume_throughput = 125

# ENA Express
enable_ena_express     = true
enable_ena_express_udp = true

# Project name for tagging
project_name = "steven"

# VPC configuration
vpc_cidr    = "10.0.0.0/16"
subnet_cidr = "10.0.1.0/24"

# Leave empty to use Ubuntu 24.04
ami_id = ""



# Tier 1:
# 1. c7i.metal - Latest gen Intel, all physical cores, best x86_64 single-thread performance
# 2. c7gn.metal - Graviton3E with up to 200 Gbps network, lowest AWS network latency
# 3. c6in.metal - 200 Gbps network bandwidth, excellent for market data
# 4. c6gn.metal - Graviton2 with 100 Gbps network
# Tier 2:
# 5. c7i.48xlarge - Nearly same as metal, slightly more overhead
# 6. metal-48xl - More memory than compute-optimized, still excellent
# 7. r7iz.metal-32xl - Highest single-core boost (3.9 GHz all-core)
# 8. c6in.32xlarge - 200 Gbps network, 128 vCPUs
# Tie3 3:
# 9. c7i.24xlarge - Half of c7i.48xlarge, still very fast
# 10. c7gn.16xlarge - Good Graviton3E performance at lower cost
