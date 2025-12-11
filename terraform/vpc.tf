resource "aws_vpc" "binance" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "binance-vpc"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.binance.id
  availability_zone       = var.availability_zone
  cidr_block              = var.subnet_cidr
  map_public_ip_on_launch = true  # crucial for low-jitter direct connectivity

  tags = {
    Name = "binance-public-subnet-${var.availability_zone}"
  }
}

# Check with Aleck: is it possible to get around without IGW
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.binance.id

  tags = {
    Name = "binance-igw"
  }
}

# Route Table (NOTE: cleanest possible routing, no NAT)
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.binance.id

  tags = {
    Name = "binance-public-rt"
  }
}

resource "aws_route" "default_route" {
  route_table_id         = aws_route_table.public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_security_group" "binance" {
  name        = "binance-sg"
  description = "Low-latency SG for Binance trading nodes"
  vpc_id      = aws_vpc.binance.id

  ingress {
    description = "SSH access"
    from_port   = 21112
    to_port     = 21112
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # TODO Harden this
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "binance-sg"
  }
}

# OUTPUTS
output "vpc_id" {
  value = aws_vpc.binance.id
}

output "subnet_id" {
  value = aws_subnet.public.id
}

output "security_group_id" {
  value = aws_security_group.binance.id
}
