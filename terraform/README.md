# Binance Latency Testing

Find an AWS EC2 instance with the lowest latency to Binance exchange servers.

---

## Table of Contents
- [Quick Start](#quick-start)
- [How It Works (S3 Auto-Reporting)](#how-it-works-s3-auto-reporting)
- [Configuration Options](#configuration-options)
- [Troubleshooting](#troubleshooting)
- [Advanced Usage](#advanced-usage)
- [Files Structure](#files-structure)

---

## Quick Start

### Prerequisites
- AWS account with credentials configured
- Terraform installed (>= 1.0)
- AWS CLI installed
- `jq` installed

### Step 1: Configure AWS CLI

Tell AWS CLI who you are:

```bash
aws configure
```

When prompted, enter:
- **AWS Access Key ID**: Get from AWS Console → IAM → Users → Your User → Security Credentials
- **AWS Secret Access Key**: You get this when creating the access key
- **Default region**: `ap-northeast-1` (Tokyo)
- **Default output format**: `json`

**Test it works:**
```bash
aws sts get-caller-identity
```

### Step 2: Initialize Terraform

```bash
cd ~/terraform
terraform init
```

### Step 3: Run the Latency Sweep

```bash
./latency_sweep.sh
```

**What happens:**
1. Creates servers in designated AZ
2. Server runs latency test on boot
3. Each server runs latency test and uploads results to S3
4. Script polls S3 for results
5. Destroys high-latency servers
6. Keeps the server with lowest latency

### Step 4: Check Results

Results saved to:
- `latency_results_<timestamp>.csv`
- `./results_<timestamp>/` directory

---

## S3 Auto-Reporting

**1. Instance Boots** 
- AWS runs `user_data.sh` automatically
- No manual intervention needed

**2. Script Installs Everything**
```bash
# Install Python, tools, create test scripts
# This all happens in user_data.sh
```

**3. Script Runs Test Automatically**
```bash
# At the end of user_data.sh:
su - ubuntu -c 'python3 binance_latency.py'
```

**4. Results Upload to S3**
```bash
aws s3 cp results.json s3://bucket-name/results_<region>_<az>_<timestamp>.json
```

**5. Your Script Polls S3**
```bash
# Every 30 seconds:
aws s3 ls s3://bucket-name/results_*
# When file appears → download it!
```

**6. Parse and Destroy**
- Extract latency numbers
- Destroy high-latency instances
- Keep the winner

### Key Components

**1. IAM Role (s3_backend.tf)**
- Gives instances permission to write to S3
- No access keys needed!

**2. user_data.sh**
- Installs dependencies
- Runs latency test automatically
- Uploads results to S3

**3. Sweep Script (latency_sweep.sh)**
- Launches instances sequentially
- Polls S3 for results
- No SSH involved!

### Architecture Flow

```
┌─────────────────┐
│  Your PC        │
│  (terraform)    │
└────────┬────────┘
         │
         │ 1. terraform apply
         ↓
┌─────────────────────┐
│   EC2 Instance      │
│  ┌──────────────┐   │
│  │ user_data.sh │   │  2. Runs automatically on boot
│  │  - installs  │   │
│  │  - tests     │───┼──→ 3. Uploads results to S3
│  │  - uploads   │   │
│  └──────────────┘   │
└─────────────────────┘
                      │
                      ↓
                ┌──────────┐
                │    S3    │
                │  Bucket  │
                └─────┬────┘
                      │
        4. Polls      │
        every 30s     │
        ↓             │
┌─────────────────┐   │
│  Your PC        │←──┘
│  - downloads    │  5. Gets results
│  - parses       │
│  - keeps winner │
│  - destroys rest│
└─────────────────┘
```

---

## Configuration Options

### ENA Express

ENA Express provides:
- ~2x lower tail latency (P99)
- Consistent microsecond-level latency
- UDP support for WebSocket connections

Automatically enabled on c7gn instances.

### Network Tuning

Run `tune_system.sh` on the instance to apply:
- Increased socket buffers (26MB)
- TCP low latency mode
- TCP BBR congestion control
- Disabled slow start after idle
- Optimized ARP cache

---

## Troubleshooting

**"UnauthorizedOperation" error**  
→ Your AWS credentials don't have permission. Add `EC2FullAccess` and `S3FullAccess` policies to your IAM user.

**"Timeout: No results received"**  
→ Check S3 bucket for error logs. The instance may have failed to run the test.

**Results show "N/A"**  
→ The test failed. Check the error log in S3: `error_<region>_<az>_*.log`

### Cleanup

**IMPORTANT:** To avoid charges, destroy resources when done:

```bash
terraform destroy

# Check for remaining workspaces
terraform workspace list
terraform workspace select <name>
terraform destroy
```

---

## Advanced Usage

### Quick Test (Single Instance)

If you just want to test ONE instance quickly:

```bash
terraform apply
# Get the S3 bucket name
S3_BUCKET=$(terraform output -raw s3_bucket_name)
# Wait 3-5 minutes for the test to complete
aws s3 ls s3://$S3_BUCKET/
# Download the results
aws s3 cp s3://$S3_BUCKET/results_*.json ./
# View results
cat results_*.json | jq
```

### Manual SSH Access

1. Create key pair:
```bash
aws ec2 create-key-pair \
  --key-name binance-latency-key \
  --region ap-northeast-1 \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/binance-latency-key.pem
chmod 400 ~/.ssh/binance-latency-key.pem
```

2. Add to `terraform.tfvars`:
```
key_pair_name = "binance-latency-key"
```

3. Connect:
```bash
ssh -i ~/.ssh/binance-latency-key.pem ubuntu@<public-ip>
```

### Scripts on Instance

```bash
cd /home/ubuntu/latency_tests
python3 binance_latency.py          # Latency test
python3 ws_latency.py btcusdt 300   # WebSocket test (5 min)
sudo ./tune_system.sh               # Apply network tuning
```

---

## Files Structure

| File | Description |
|------|-------------|
| `main.tf` | Core infrastructure (VPC, subnet, EC2, security groups, outputs) |
| `s3_backend.tf` | S3 bucket and IAM roles for auto-reporting |
| `variables.tf` | Input variable definitions |
| `user_data.sh` | Instance initialization script (runs on boot) |
| `terraform.tfvars` | Your custom variable values |
| `latency_sweep.sh` | Automated latency testing script |
| `README.md` | This guide |
