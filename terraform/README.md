# Binance Latency Testing
Find an AWS EC2 instance with the lowest latency to Binance exchange servers.

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
- **Default region**: `ap-northeast-1` (Account related)
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
- `./results/<timestamp>/latency_results.csv`
- `./results/<timestamp>/` directory (includes JSON files)

---

## S3 Auto-Reporting

**1. Instance Boots** 
- AWS runs `user_data.sh` automatically

**2. Script Installs Everything**
```bash
# Install Python, tools, create test scripts
# This all happens in user_data.sh
```

**3. Script Runs Tests Automatically**
```bash
# At the end of user_data.sh:
# Network path analysis (DNS, traceroute, MTR)
python3 network_analysis.py

# Full latency test suite (TCP, WS Ping/Pong, Trade Stream)
python3 ws_latency.py --method full --samples 1000 --host fstream.binance.com
```

**4. Results Upload to S3**
```bash
aws s3 cp latency.log s3://bucket-name/latency_<region>_<az>_<timestamp>.log
```

**5. Script Polls S3**
```bash
# Every 30 seconds:
aws s3 ls s3://bucket-name/latency_*
# When file appears → download and parse P99 latencies
```

**6. Parse and Destroy**
- Extract latency numbers
- Destroy high-latency instances
- Keep the winner


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

## Files Structure

| File | Description |
|------|-------------|
| `ec2/` | EC2 instance terraform (VPC, subnet, security groups) |
| `shared/` | Shared resources (S3 bucket, IAM roles) |
| `scripts/network_analysis.py` | Network path analytics (DNS, traceroute, MTR) |
| `scripts/ws_latency.py` | P99 latency testing (TCP, WS ping/pong, trade stream) |
| `scripts/tune_system.sh` | System tuning for low latency |
| `latency_sweep.sh` | Automated latency testing orchestration |
| `results/` | Test results (CSV and logs) |