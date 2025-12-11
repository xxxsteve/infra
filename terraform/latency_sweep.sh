#!/bin/bash
# Instances auto-run tests and upload results to S3

set -e

export AWS_PROFILE=default

# Configuration
# Read defaults from terraform.tfvars (single source of truth)
TFVARS_FILE="terraform.tfvars"

# Helper to read value from tfvars
read_tfvar() {
    grep "^$1" "$TFVARS_FILE" 2>/dev/null | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' "' || echo ""
}

# Terraform variables (from tfvars, can be overridden via env)
TARGET_REGION="${TARGET_REGION:-$(read_tfvar aws_region)}"
TARGET_AZ="${TARGET_AZ:-$(read_tfvar availability_zone)}"
INSTANCE_TYPE="${INSTANCE_TYPE:-$(read_tfvar instance_type)}"

# Script-only variables (not in Terraform)
TEST_DURATION="${TEST_DURATION:-120}"    # seconds to run latency test
POLL_INTERVAL="${POLL_INTERVAL:-30}"     # how often to check S3 for results
MAX_WAIT="${MAX_WAIT:-600}"              # max seconds to wait for results (10 min)
TARGET_LATENCY="${TARGET_LATENCY:-1}"    # Keep instances below this latency (ms)
NUM_INSTANCES="${NUM_INSTANCES:-2}"      # Number of instances to test

# Results directory (all results go here)
RESULTS_BASE="./results"
RESULTS_DIR="$RESULTS_BASE/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"
RESULTS_FILE="$RESULTS_DIR/latency_results.csv"
LOG_FILE="$RESULTS_DIR/run.log"

# Log function: echo to terminal AND append to log file
log() {
    echo "$@" | tee -a "$LOG_FILE"
}


# TODO: REMOVE THIS MONKEY PATCH after fixing IAM permissions
# Remove IAM resources from state before destroy (no delete permission)
# Terraform Resource	                       AWS Name
# aws_s3_bucket.results	                       binance-latency-results-{{project_name}}
# aws_iam_role.instance_role	               {{project_name}}-instance-role
# aws_iam_role_policy.s3_access	               {{project_name}}-s3-access
# aws_iam_instance_profile.instance_profile	   {{project_name}}-instance-profile
remove_iam_from_state() {
    terraform state rm aws_iam_role_policy.s3_access 2>/dev/null || true
    terraform state rm aws_iam_role.instance_role 2>/dev/null || true
    terraform state rm aws_iam_instance_profile.instance_profile 2>/dev/null || true
}

echo "region,az,instance,min_tcp_ms,avg_tcp_ms,p95_tcp_ms,min_http_ms,avg_http_ms,p95_http_ms,instance_ip,kept" > "$RESULTS_FILE"

# Function to test a single instance
test_instance() {
    local region=$1
    local az=$2
    local instance_num=$3
    
    echo ""
    echo "=========================================="
    echo "Testing: $region / $az / Instance #$instance_num"
    echo "=========================================="
    
    # Create workspace for this test
    local workspace_name="${region}_${az//-/_}_inst${instance_num}"
    terraform workspace new "$workspace_name" 2>/dev/null || terraform workspace select "$workspace_name"
    
    # Apply terraform
    terraform apply -auto-approve \
        -var "aws_region=$region" \
        -var "availability_zone=$az" \
        -var "instance_type=$INSTANCE_TYPE"
    
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to deploy in $region/$az"
        remove_iam_from_state
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
    
    # Poll S3 for results
    local waited=0
    local results_found=false
    
    while [ $waited -lt $MAX_WAIT ]; do
        # Check if results file exists in S3
        local s3_results
        s3_results=$(aws s3 ls "s3://$s3_bucket/results_${region}_${az}_" --region "$region" 2>/dev/null | tail -1 || true)
        
        if [ -n "$s3_results" ]; then
            echo "✓ Results found in S3!"
            
            # Extract filename from ls output
            local s3_filename
            s3_filename=$(echo "$s3_results" | awk '{print $4}')
            
            # Download results
            local local_file="$RESULTS_DIR/${region}_${az}_results.json"
            aws s3 cp "s3://$s3_bucket/$s3_filename" "$local_file" --region "$region"
            
            # Parse results
            local min_tcp avg_tcp p95_tcp min_http avg_http p95_http
            min_tcp=$(jq -r '.spot_api.tcp.min // "N/A"' "$local_file")
            avg_tcp=$(jq -r '.spot_api.tcp.avg // "N/A"' "$local_file")
            p95_tcp=$(jq -r '.spot_api.tcp.p95 // "N/A"' "$local_file")
            min_http=$(jq -r '.spot_api.http.min // "N/A"' "$local_file")
            avg_http=$(jq -r '.spot_api.http.avg // "N/A"' "$local_file")
            p95_http=$(jq -r '.spot_api.http.p95 // "N/A"' "$local_file")
            
            # Save to results file
            local instance_ip
            instance_ip=$(terraform output -raw instance_public_ip 2>/dev/null || echo 'N/A')
            echo "$region,$az,$instance_num,$min_tcp,$avg_tcp,$p95_tcp,$min_http,$avg_http,$p95_http,$instance_ip,pending" >> "$RESULTS_FILE"
            
            echo "Results: TCP avg=${avg_tcp}ms, HTTP avg=${avg_http}ms"
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
        echo "$region,$az,$instance_num,TIMEOUT,TIMEOUT,TIMEOUT,TIMEOUT,TIMEOUT,TIMEOUT,N/A,destroyed" >> "$RESULTS_FILE"
        remove_iam_from_state
        terraform destroy -auto-approve
        return 1
    fi
    
    # Cleanup decision based on latency
    local should_destroy=true
    local instance_ip
    instance_ip=$(terraform output -raw instance_public_ip 2>/dev/null || echo 'N/A')
    
    if [ "$results_found" = true ] && [ "$avg_tcp" != "N/A" ]; then
        # Check if average TCP latency is below target
        if (( $(echo "$avg_tcp < $TARGET_LATENCY" | bc -l) )); then
            echo "🎯 EXCELLENT LATENCY: ${avg_tcp}ms < ${TARGET_LATENCY}ms - KEEPING INSTANCE #$instance_num!"
            echo "   Instance IP: $instance_ip"
            echo "   Workspace: $workspace_name"
            echo "   To destroy later: terraform workspace select $workspace_name && terraform destroy"
            should_destroy=false
            # Update CSV to mark as kept
            sed -i "s/$region,$az,$instance_num,.*,pending$/$region,$az,$instance_num,$min_tcp,$avg_tcp,$p95_tcp,$min_http,$avg_http,$p95_http,$instance_ip,KEPT/" "$RESULTS_FILE"
        fi
    fi
    
    if [ "$should_destroy" = true ]; then
        echo "Destroying instance #$instance_num (latency: ${avg_tcp}ms >= ${TARGET_LATENCY}ms)..."
        # Update CSV to mark as destroyed
        sed -i "s/$region,$az,$instance_num,.*,pending$/$region,$az,$instance_num,$min_tcp,$avg_tcp,$p95_tcp,$min_http,$avg_http,$p95_http,$instance_ip,destroyed/" "$RESULTS_FILE"
        remove_iam_from_state
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

# Initialize terraform
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
echo "All tested instances (sorted by avg TCP latency):"
echo ""
sort -t',' -k5 -n "$RESULTS_FILE" | column -t -s','

# Show kept instances
echo ""
echo "=========================================="
kept_count=$(grep -c ",KEPT$" "$RESULTS_FILE" || echo "0")
if [ "$kept_count" -gt 0 ]; then
    echo "🎯 KEPT INSTANCES (latency < ${TARGET_LATENCY}ms):"
    echo ""
    grep ",KEPT$" "$RESULTS_FILE" | sort -t',' -k5 -n | column -t -s','
    echo ""
    echo "To destroy a kept instance:"
    echo "  terraform workspace select <workspace_name>"
    echo "  terraform destroy"
else
    echo "❌ No instances met the target latency of <${TARGET_LATENCY}ms"
    echo ""
    echo "Best result was:"
    sort -t',' -k5 -n "$RESULTS_FILE" | grep -v "region" | head -1 | column -t -s','
    echo ""
    echo "Consider:"
    echo "  - Increasing NUM_INSTANCES (current: $NUM_INSTANCES)"
    echo "  - Relaxing TARGET_LATENCY (current: ${TARGET_LATENCY}ms)"
    echo "  - Running at a different time of day"
fi

# Find best instance
echo ""
echo "🏆 BEST MACHINE:"
best_line=$(sort -t',' -k5 -n "$RESULTS_FILE" | grep -v TIMEOUT | grep -v "region" | head -1)
echo "$best_line" | column -t -s','

best_latency=$(echo "$best_line" | cut -d',' -f5)
best_ip=$(echo "$best_line" | cut -d',' -f10)
best_status=$(echo "$best_line" | cut -d',' -f11)

echo ""
if [ "$best_status" = "KEPT" ]; then
    echo "✅ Best machine is running at: $best_ip"
    echo "   Latency: ${best_latency}ms"
else
    echo "Best latency achieved: ${best_latency}ms (instance was destroyed)"
fi
