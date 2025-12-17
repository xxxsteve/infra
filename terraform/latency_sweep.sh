#!/bin/bash
# Instances auto-run tests and upload results to S3

set -e

export AWS_PROFILE=default

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EC2_DIR="$SCRIPT_DIR/ec2"
SHARED_DIR="$SCRIPT_DIR/shared"

# Read defaults from terraform.tfvars (single source of truth)
TFVARS_FILE="$EC2_DIR/terraform.tfvars"

# Helper to read value from tfvars
read_tfvar() {
    grep "^$1" "$TFVARS_FILE" 2>/dev/null | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' "' || echo ""
}

# Terraform variables (from tfvars, can be overridden via env)
TARGET_REGION="${TARGET_REGION:-$(read_tfvar aws_region)}"
TARGET_AZ="${TARGET_AZ:-$(read_tfvar availability_zone)}"
INSTANCE_TYPE="${INSTANCE_TYPE:-$(read_tfvar instance_type)}"

# Script-only variables (not in Terraform)
POLL_INTERVAL="${POLL_INTERVAL:-30}"     # how often to check S3 for results
MAX_WAIT="${MAX_WAIT:-600}"              # max seconds to wait for results (5 min)
TARGET_LATENCY="${TARGET_LATENCY:-1}"    # Keep instances below this latency (ms)
NUM_INSTANCES="${NUM_INSTANCES:-5}"      # Number of instances to test

# Results directory (all results go here)
RESULTS_BASE="$SCRIPT_DIR/results"
RESULTS_DIR="$RESULTS_BASE/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"
RESULTS_FILE="$RESULTS_DIR/latency_results.csv"
LOG_FILE="$RESULTS_DIR/run.log"

# Log function: echo to terminal AND append to log file
log() {
    echo "$@" | tee -a "$LOG_FILE"
}

echo "region,az,instance,tcp_p99_ms,ping_p99_ms,trade_p99_ms,instance_ip,kept" > "$RESULTS_FILE"

# Function to test a single instance
test_instance() {
    local region=$1
    local az=$2
    local instance_num=$3
    
    echo ""
    echo "=========================================="
    echo "Testing: $region / $az / Instance #$instance_num"
    echo "=========================================="
    
    cd "$EC2_DIR"
    
    # Create workspace for this test
    local workspace_name="${region}_${az//-/_}_inst${instance_num}"
    terraform workspace new "$workspace_name" 2>/dev/null || terraform workspace select "$workspace_name"

    # Clean up old S3 result files to avoid false matches
    local s3_bucket_name="binance-latency-results-steven"
    local s3_prefix="results/latency_${region}_${az}_inst${instance_num}_"
    echo "Cleaning up old S3 results with prefix: $s3_prefix"
    aws s3 rm "s3://$s3_bucket_name/" --recursive --exclude "*" --include "${s3_prefix}*" 2>/dev/null || true

    # Apply terraform
    terraform apply -auto-approve \
        -var "aws_region=$region" \
        -var "availability_zone=$az" \
        -var "instance_type=$INSTANCE_TYPE" \
        -var "instance_num=$instance_num"
    
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to deploy in $region/$az"
        terraform destroy -auto-approve 2>/dev/null || true
        return 1
    fi
    
    # Get instance info immediately after creation
    local instance_id instance_ip s3_bucket
    instance_id=$(terraform output -raw instance_id || echo "unknown")
    instance_ip=$(terraform output -raw instance_public_ip || echo "unknown")
    s3_bucket=$(terraform output -raw s3_bucket_name || echo "unknown")
    
    # Log EC2 info prominently for debugging
    log ""
    log "╔════════════════════════════════════════════════════════════╗"
    log "║  EC2 INSTANCE CREATED                                      ║"
    log "╠════════════════════════════════════════════════════════════╣"
    log "║  Instance ID: $instance_id"
    log "║  Public IP:   $instance_ip"
    log "║  Region:      $region"
    log "║  AZ:          $az"
    log "║  S3 Bucket:   $s3_bucket"
    log "╚════════════════════════════════════════════════════════════╝"
    log ""
    
    echo "Instance will auto-run test and upload results to S3..."
    echo "Waiting for results (checking S3 every ${POLL_INTERVAL}s)..."
    
    # Poll S3 for results (now looking for latency log)
    local waited=0
    local results_found=false
    
    while [ $waited -lt $MAX_WAIT ]; do
        # Check if latency log file exists in S3
        local s3_results
        s3_results=$(aws s3 ls "s3://$s3_bucket/results/latency_${region}_${az}_inst${instance_num}_" --region "$region" 2>/dev/null | tail -1 || true)
        
        if [ -n "$s3_results" ]; then
            echo "✓ Results found in S3!"
            
            # Extract filename from ls output
            local s3_filename
            s3_filename=$(echo "$s3_results" | awk '{print $4}')
            
            # Download results log
            local local_file="$RESULTS_DIR/${region}_${az}_inst${instance_num}_latency.log"
            aws s3 cp "s3://$s3_bucket/results/$s3_filename" "$local_file" --region "$region"
            
            # Parse P99 results from log (format: "  tcp_connect          : 0.123 ms")
            local tcp_p99 ping_p99 trade_p99
            tcp_p99=$(grep "tcp_connect" "$local_file" | tail -1 | awk '{print $3}' || echo "N/A")
            ping_p99=$(grep "ws_ping_pong" "$local_file" | tail -1 | awk '{print $3}' || echo "N/A")
            trade_p99=$(grep "trade_stream" "$local_file" | tail -1 | awk '{print $3}' || echo "N/A")
            
            # Save to results file
            local instance_ip
            instance_ip=$(terraform output -raw instance_public_ip 2>/dev/null || echo 'N/A')
            echo "$region,$az,$instance_num,$tcp_p99,$ping_p99,$trade_p99,$instance_ip,pending" >> "$RESULTS_FILE"
            
            echo "Results: TCP P99=${tcp_p99}ms, WS Ping P99=${ping_p99}ms, Trade P99=${trade_p99}ms"
            results_found=true
            break
        fi
        
        # Show progress
        echo "  Still waiting... (${waited}s elapsed)"
        sleep "$POLL_INTERVAL"
        waited=$((waited + POLL_INTERVAL))
    done
    
    if [ "$results_found" = false ]; then
        echo "⚠ Timeout: No results received after ${MAX_WAIT}s"
        echo "Check instance logs or S3 bucket for errors"
        echo "$region,$az,$instance_num,TIMEOUT,TIMEOUT,TIMEOUT,N/A,destroyed" >> "$RESULTS_FILE"
        terraform destroy -auto-approve
        return 1
    fi
    
    # Cleanup decision based on TCP Connect P99 latency from ws_latency.py
    local should_destroy=true
    local instance_ip
    instance_ip=$(terraform output -raw instance_public_ip 2>/dev/null || echo 'N/A')
    
    if [ "$results_found" = true ] && [ "$tcp_p99" != "N/A" ]; then
        # Check if TCP P99 latency is below target
        if (( $(echo "$tcp_p99 < $TARGET_LATENCY" | bc -l) )); then
            echo "🎯 EXCELLENT LATENCY: TCP P99 ${tcp_p99}ms < ${TARGET_LATENCY}ms - KEEPING INSTANCE #$instance_num!"
            echo "   Instance IP: $instance_ip"
            echo "   Workspace: $workspace_name"
            echo "   To destroy later: cd ec2 && terraform workspace select $workspace_name && terraform destroy"
            should_destroy=false
            # Update CSV to mark as kept
            sed -i "s/$region,$az,$instance_num,.*,pending$/$region,$az,$instance_num,$tcp_p99,$ping_p99,$trade_p99,$instance_ip,KEPT/" "$RESULTS_FILE"
        fi
    fi
    
    if [ "$should_destroy" = true ]; then
        echo "Destroying instance #$instance_num (TCP Connect P99: ${tcp_p99}ms >= ${TARGET_LATENCY}ms)..."
        # Update CSV to mark as destroyed
        sed -i "s/$region,$az,$instance_num,.*,pending$/$region,$az,$instance_num,$tcp_p99,$ping_p99,$trade_p99,$instance_ip,destroyed/" "$RESULTS_FILE"
        terraform destroy -auto-approve
    fi
    
    echo "Completed: $region / $az / Instance #$instance_num"
}

# Main execution
echo "Binance Latency Machine Hunt"
echo "=========================================="
echo "Target: $TARGET_REGION / $TARGET_AZ"
echo "Goal: Find machine with <${TARGET_LATENCY}ms latency"
echo "Testing: $NUM_INSTANCES instances"
echo "Instance type: $INSTANCE_TYPE"
echo "Poll interval: $POLL_INTERVAL seconds"
echo ""

# Check prerequisites
if ! command -v terraform &> /dev/null; then
    echo "ERROR: terraform not found"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "ERROR: jq not found"
    exit 1
fi

if ! command -v aws &> /dev/null; then
    echo "ERROR: aws cli not found"
    exit 1
fi

# Verify AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo "ERROR: AWS credentials not configured"
    echo "Run: aws configure"
    exit 1
fi

# ==========================================
# STEP 1: Initialize and apply shared resources (S3 + IAM)
# ==========================================
echo ""
echo "=========================================="
echo "Setting up shared resources (S3 + IAM)..."
echo "=========================================="
cd "$SHARED_DIR"
terraform init
terraform apply -auto-approve

# Get S3 bucket name for reference
S3_BUCKET=$(terraform output -raw s3_bucket_name)
echo "✓ Shared resources ready. S3 bucket: $S3_BUCKET"

echo "Clearing previous results from S3..."
aws s3 rm "s3://$S3_BUCKET/results/" --recursive 2>/dev/null || true
echo "✓ S3 results folder cleared"

# ==========================================
# STEP 2: Initialize EC2 terraform
# ==========================================
echo ""
echo "=========================================="
echo "Initializing EC2 terraform..."
echo "=========================================="
cd "$EC2_DIR"
terraform init

# Test multiple instances in target zone
echo ""
echo "Launching $NUM_INSTANCES instances in $TARGET_AZ to find the best machine..."
echo ""

for i in $(seq 1 $NUM_INSTANCES); do
    if ! test_instance "$TARGET_REGION" "$TARGET_AZ" "$i"; then
        echo "Warning: Test failed for instance #$i, continuing..."
    fi
done

# Print summary
echo ""
echo "=========================================="
echo "MACHINE HUNT COMPLETE"
echo "=========================================="
echo ""
echo "Results saved to: $RESULTS_FILE"
echo "Downloaded JSON files in: $RESULTS_DIR"
echo ""
echo "All tested instances (sorted by TCP Connect P99 latency):"
echo ""
sort -t',' -k4 -n "$RESULTS_FILE" | column -t -s','

# Show kept instances
echo ""
echo "=========================================="
kept_count=$(grep -c ",KEPT$" "$RESULTS_FILE" || echo "0")
if [ "$kept_count" -gt 0 ]; then
    echo "🎯 KEPT INSTANCES (TCP Connect P99 < ${TARGET_LATENCY}ms):"
    echo ""
    grep ",KEPT$" "$RESULTS_FILE" | sort -t',' -k4 -n | column -t -s','
else
    echo "❌ No instances met the target latency of <${TARGET_LATENCY}ms"
    echo ""
    echo "Best result was:"
    sort -t',' -k4 -n "$RESULTS_FILE" | grep -v "region" | head -1 | column -t -s','
    echo ""
fi

# Find best instance
echo ""
echo "🏆 BEST MACHINE:"
best_line=$(sort -t',' -k4 -n "$RESULTS_FILE" | grep -v TIMEOUT | grep -v "region" | head -1)
echo "$best_line" | column -t -s','

best_tcp_p99=$(echo "$best_line" | cut -d',' -f4)
best_ping_p99=$(echo "$best_line" | cut -d',' -f5)
best_ip=$(echo "$best_line" | cut -d',' -f7)
best_status=$(echo "$best_line" | cut -d',' -f8)

echo ""
if [ "$best_status" = "KEPT" ]; then
    echo "✅ Best machine is running at: $best_ip"
    echo "   TCP Connect P99: ${best_tcp_p99}ms"
    echo "   WS Ping/Pong P99: ${best_ping_p99}ms (reference)"
else
    echo "Best TCP Connect P99 latency achieved: ${best_tcp_p99}ms (instance was destroyed)"
fi
