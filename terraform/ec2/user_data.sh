#!/bin/bash
set -e
exec > >(tee /home/ubuntu/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

# Configure SSH to listen on port 21112
echo "Port 21112" >> /etc/ssh/sshd_config.d/custom.conf
systemctl daemon-reload
systemctl restart ssh.socket ssh

# Install minimal packages
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 python3-pip jq mtr traceroute chrony

# Configure and start chrony for accurate NTP sync
systemctl enable chrony
systemctl start chrony
sleep 3
chronyc makestep  # Force immediate sync
echo "NTP sync status:"
chronyc tracking | head -5

# Install Python packages
pip3 install --break-system-packages websocket-client numpy awscli

# Create test directory
mkdir -p /home/ubuntu/latency_tests
cd /home/ubuntu/latency_tests

# Download scripts from S3
echo "Downloading scripts from S3..."
aws s3 cp "s3://${s3_bucket}/scripts/network_analysis.py" /home/ubuntu/latency_tests/network_analysis.py --region ${region}
aws s3 cp "s3://${s3_bucket}/scripts/ws_latency.py" /home/ubuntu/latency_tests/ws_latency.py --region ${region}
aws s3 cp "s3://${s3_bucket}/scripts/tune_system.sh" /home/ubuntu/latency_tests/tune_system.sh --region ${region}

chmod +x /home/ubuntu/latency_tests/*.py /home/ubuntu/latency_tests/*.sh
chown -R ubuntu:ubuntu /home/ubuntu/latency_tests

echo "Scripts downloaded. Running network path analytics and latency testing..."

# Apply system tuning for low latency
echo "Applying system tuning..."
bash /home/ubuntu/latency_tests/tune_system.sh

sleep 10

# Run network path analysis (DNS, traceroute, MTR)
su - ubuntu -c 'cd /home/ubuntu/latency_tests && BINANCE_ENDPOINTS='"'"'${binance_endpoints}'"'"' python3 network_analysis.py' > /home/ubuntu/latency_tests/network_analysis.log 2>&1

# Upload network analysis results
RESULTS_FILE=$(ls -t /home/ubuntu/latency_tests/network_analysis_*.json 2>/dev/null | head -1)
if [ -n "$RESULTS_FILE" ]; then
    FILENAME="results/network_analysis_${region}_${availability_zone}_inst${instance_num}_$(date +%s).json"
    aws s3 cp "$RESULTS_FILE" "s3://${s3_bucket}/$FILENAME" --region ${region} && echo "Network analysis uploaded to S3"
    else
    aws s3 cp /home/ubuntu/latency_tests/network_analysis.log "s3://${s3_bucket}/results/error_network_${region}_${availability_zone}_inst${instance_num}_$(date +%s).log" --region ${region}
fi

# Run full latency test suite (TCP, WS Ping/Pong, Trade Stream)
echo "Running full latency test suite..."
su - ubuntu -c 'cd /home/ubuntu/latency_tests && python3 ws_latency.py --method full --samples 1000 --host fstream.binance.com > /home/ubuntu/latency_tests/latency.log 2>&1'

# Upload log
aws s3 cp /home/ubuntu/latency_tests/latency.log "s3://${s3_bucket}/results/latency_${region}_${availability_zone}_inst${instance_num}_$(date +%s).log" --region ${region}

echo "Done! All tests completed and results uploaded"
