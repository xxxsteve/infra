#!/bin/bash
set -e
exec > >(tee /home/ubuntu/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

# Configure SSH to listen on port 21112
echo "Port 21112" >> /etc/ssh/sshd_config.d/custom.conf
systemctl restart ssh

# Install minimal packages
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 python3-pip jq mtr traceroute

# Install Python packages
pip3 install --break-system-packages requests websocket-client awscli

# Create test directory
mkdir -p /home/ubuntu/latency_tests
cd /home/ubuntu/latency_tests

# Download scripts from S3
echo "Downloading scripts from S3..."
aws s3 cp "s3://${s3_bucket}/scripts/binance_latency.py" /home/ubuntu/latency_tests/binance_latency.py --region ${region}
aws s3 cp "s3://${s3_bucket}/scripts/ws_latency.py" /home/ubuntu/latency_tests/ws_latency.py --region ${region}
aws s3 cp "s3://${s3_bucket}/scripts/tune_system.sh" /home/ubuntu/latency_tests/tune_system.sh --region ${region}

chmod +x /home/ubuntu/latency_tests/*.py /home/ubuntu/latency_tests/*.sh
chown -R ubuntu:ubuntu /home/ubuntu/latency_tests

echo "Scripts downloaded. Running latency test..."

sleep 10

# Run test with endpoints
su - ubuntu -c 'cd /home/ubuntu/latency_tests && BINANCE_ENDPOINTS='"'"'${binance_endpoints}'"'"' python3 binance_latency.py' > /home/ubuntu/latency_tests/latency_test.log 2>&1

# Upload results
RESULTS_FILE=$(ls -t /home/ubuntu/latency_tests/results_*.json 2>/dev/null | head -1)
if [ -n "$RESULTS_FILE" ]; then
    FILENAME="results_${region}_${availability_zone}_$(date +%s).json"
    aws s3 cp "$RESULTS_FILE" "s3://${s3_bucket}/$FILENAME" --region ${region} && echo "Results uploaded to S3"
else
    aws s3 cp /home/ubuntu/latency_tests/latency_test.log "s3://${s3_bucket}/error_${region}_${availability_zone}_$(date +%s).log" --region ${region}
fi
echo "Done!"
