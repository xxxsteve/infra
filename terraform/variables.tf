variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
}

variable "availability_zone" {
  description = "Specific availability zone within the region"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type - c7gn for network optimized"
  type        = string
}

variable "key_pair_name" {
  description = "Name of existing EC2 key pair for SSH access"
  type        = string
}

variable "root_volume_size" {
  description = "Size of root EBS volume in GB"
  type        = number
  default     = 30
}

variable "root_volume_type" {
  description = "Type of root EBS volume"
  type        = string
  default     = "gp3"
}

variable "root_volume_iops" {
  description = "IOPS for root volume (gp3)"
  type        = number
  default     = 3000
}

variable "root_volume_throughput" {
  description = "Throughput for root volume in MB/s (gp3)"
  type        = number
  default     = 125
}

variable "enable_ena_express" {
  description = "Enable ENA Express for lower latency"
  type        = bool
  default     = true
}

variable "enable_ena_express_udp" {
  description = "Enable ENA Express UDP support"
  type        = bool
  default     = true
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "project_name" {
  description = "Project name for resource tagging"
  type        = string
  default     = "binance-latency-test"
}

variable "ami_id" {
  description = "AMI ID to use. If empty, will use latest Ubuntu 24.04 ARM"
  type        = string
  default     = ""
}

variable "binance_endpoints" {
  description = "Binance API endpoints to test"
  type        = map(string)
  default = {
    spot_api       = "api.binance.com"
    spot_ws        = "stream.binance.com"
    futures_api    = "fapi.binance.com"
    futures_ws     = "fstream.binance.com"
    coin_futures   = "dapi.binance.com"
  }
}
