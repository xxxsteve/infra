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

# Download all scripts from S3
echo "Downloading all scripts from S3..."
aws s3 sync "s3://${s3_bucket}/scripts/" /home/ubuntu/latency_tests/ --region ${region}

# Set permissions
chmod +x /home/ubuntu/latency_tests/*.py /home/ubuntu/latency_tests/*.sh /home/ubuntu/latency_tests/rs
chown -R ubuntu:ubuntu /home/ubuntu/latency_tests

echo "✓ All scripts downloaded from S3"

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
    FILENAME="results/network_analysis_${region}_${availability_zone}_inst${instance_num}.json"
    aws s3 cp "$RESULTS_FILE" "s3://${s3_bucket}/$FILENAME" --region ${region} && echo "Network analysis uploaded to S3"
    else
    aws s3 cp /home/ubuntu/latency_tests/network_analysis.log "s3://${s3_bucket}/results/error_network_${region}_${availability_zone}_inst${instance_num}.log" --region ${region}
fi

# Run full latency test suite (TCP, WS Ping/Pong, Trade Stream)
echo "Running full latency test suite..."
su - ubuntu -c 'cd /home/ubuntu/latency_tests && python3 ws_latency.py --method full --samples 1000 --host fstream.binance.com > /home/ubuntu/latency_tests/latency.log 2>&1'

# Upload log
aws s3 cp /home/ubuntu/latency_tests/latency.log "s3://${s3_bucket}/results/latency_${region}_${availability_zone}_inst${instance_num}.log" --region ${region}

# Run rs binary for WS API latency test ####################
echo "Running rs latency test..."
RS_OUTPUT="/home/ubuntu/latency_tests"
su - ubuntu -c "cd /home/ubuntu/latency_tests && ./rs latency_test BTCUSDT $RS_OUTPUT"

# Upload rs latency results (both order and orderbook files)
ORDER_FILE="$RS_OUTPUT/order_latency_test.json"
ORDERBOOK_FILE="$RS_OUTPUT/orderbook_latency_test.json"

if [ -f "$ORDER_FILE" ]; then
    aws s3 cp "$ORDER_FILE" "s3://${s3_bucket}/results/order_latency_${region}_${availability_zone}_inst${instance_num}.json" --region ${region}
    echo "RS order latency results uploaded to S3"
else
    echo "ERROR: RS order latency test failed - no output JSON"
    exit 1
fi

if [ -f "$ORDERBOOK_FILE" ]; then
    aws s3 cp "$ORDERBOOK_FILE" "s3://${s3_bucket}/results/orderbook_latency_${region}_${availability_zone}_inst${instance_num}.json" --region ${region}
    echo "RS orderbook latency results uploaded to S3"
else
    echo "ERROR: RS orderbook latency test failed - no output JSON"
    exit 1
fi
############################################################

echo "Done! All tests completed and results uploaded"
