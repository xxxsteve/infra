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
MAX_WAIT="${MAX_WAIT:-600}"              # max seconds to wait for results
TARGET_LATENCY="${TARGET_LATENCY:-2.48}"  # Keep instances below this latency (ms)
NUM_INSTANCES="${NUM_INSTANCES:-1}"      # Number of instances to test

# Results directory (all results go here)
RESULTS_BASE="$SCRIPT_DIR/results"
RESULTS_DIR="$RESULTS_BASE/$(date +%Y%m%d_%H%M%S)"
SWEEP_ID="$(date +%Y%m%d_%H%M%S)"  # Unique ID for this sweep run
mkdir -p "$RESULTS_DIR"
RESULTS_FILE="$RESULTS_DIR/latency_results.csv"
LOG_FILE="$RESULTS_DIR/run.log"
TERRAFORM_LOG="$RESULTS_DIR/terraform.log"

# Log function: echo to terminal AND append to log file
log() {
    echo "$@" | tee -a "$LOG_FILE"
}

echo "region,az,instance,tcp_p99_ms,ping_p99_ms,trade_p99_ms,order_p99_ms,orderbook_p99_ms,tcp_p50_ms,order_p50_ms,orderbook_p50_ms,orderbook_mean_ms,combined_ms,instance_ip,kept" > "$RESULTS_FILE"

# Helper function to retry terraform destroy and cleanup workspace
cleanup_instance() {
    local workspace_name=$1
    local destroy_success=false
    
    for attempt in 1 2 3; do
        echo "  Destroy attempt $attempt/3..."
        if terraform destroy -auto-approve -no-color -compact-warnings >> "$TERRAFORM_LOG" 2>&1; then
            destroy_success=true
            break
        else
            [ $attempt -lt 3 ] && echo "  ⚠️  Destroy attempt $attempt failed, retrying in 10s..." && sleep 10
        fi
    done
    
    if [ "$destroy_success" = true ]; then
        echo "  ✓ Resources destroyed, cleaning up workspace..."
        terraform workspace select default
        terraform workspace delete "$workspace_name" 2>/dev/null || true
        echo "  ✓ Workspace $workspace_name deleted"
    else
        echo "  ❌ Destroy failed after 3 attempts. Workspace $workspace_name left intact."
        echo "  Run ./ec2/cleanup_orphaned_resources.sh to clean up manually."
    fi
    
    return $([ "$destroy_success" = true ] && echo 0 || echo 1)
}

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
    
    # Create workspace for this test (include sweep ID to avoid collision with kept instances)
    local workspace_name="${region}_${az//-/_}_inst${instance_num}_${SWEEP_ID}"
    terraform workspace new "$workspace_name" 2>/dev/null || terraform workspace select "$workspace_name"

    # Clean up old S3 result files to avoid false matches
    local s3_bucket_name="binance-latency-results-steven"
    echo "Cleaning up old S3 results for instance ${instance_num}"
    aws s3 rm "s3://$s3_bucket_name/results/" --recursive --exclude "*" --include "*_${region}_${az}_inst${instance_num}*" 2>/dev/null || true

    # Apply terraform
    echo "  Creating instance..."
    terraform apply -auto-approve -no-color -compact-warnings \
        -var "aws_region=$region" \
        -var "availability_zone=$az" \
        -var "instance_type=$INSTANCE_TYPE" \
        -var "instance_num=$instance_num" >> "$TERRAFORM_LOG" 2>&1
    
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to deploy in $region/$az"
        cleanup_instance "$workspace_name"
        return 1
    fi
    
    # Get instance info immediately after creation
    local instance_id instance_ip s3_bucket
    instance_id=$(terraform output -raw instance_id || echo "unknown")
    instance_ip=$(terraform output -raw instance_public_ip || echo "unknown")
    s3_bucket=$(terraform output -raw s3_bucket_name || echo "unknown")
    
    # Log EC2 info prominently for debugging
    local created_time=$(date '+%Y-%m-%d %H:%M:%S %Z')
    log ""
    log "╔══════════════════════════════════════════════════════════════════════════════╗"
    log "$(printf "║  %-75s ║" "EC2 INSTANCE CREATED #$instance_num")"
    log "╠══════════════════════════════════════════════════════════════════════════════╣"
    log "$(printf "║  %-75s ║" "Instance ID: $instance_id")"
    log "$(printf "║  %-75s ║" "Public IP:   $instance_ip")"
    log "$(printf "║  %-75s ║" "Region:      $region")"
    log "$(printf "║  %-75s ║" "AZ:          $az")"
    log "$(printf "║  %-75s ║" "S3 Bucket:   $s3_bucket")"
    log "$(printf "║  %-75s ║" "Created:     $created_time")"
    log "╚══════════════════════════════════════════════════════════════════════════════╝"
    log ""
    
    echo "Instance will auto-run test and upload results to S3..."
    echo "Waiting for results (checking S3 every ${POLL_INTERVAL}s)..."
    
    # Poll S3 for results (now looking for latency log)
    local waited=0
    local results_found=false
    
    while [ $waited -lt $MAX_WAIT ]; do
        # Check if orderbook latency JSON file exists in S3 (indicates test completion)
        local s3_results
        s3_results=$(aws s3 ls "s3://$s3_bucket/results/orderbook_latency_${region}_${az}_inst${instance_num}" --region "$region" 2>/dev/null | tail -1 || true)
        
        if [ -n "$s3_results" ]; then
            echo "✓ Results found in S3!"
            
            # Download latency log (contains tcp, ping, trade p99 metrics)
            local latency_log_file
            latency_log_file=$(aws s3 ls "s3://$s3_bucket/results/latency_${region}_${az}_inst${instance_num}.log" --region "$region" 2>/dev/null | tail -1 | awk '{print $4}' || true)
            local local_file="$RESULTS_DIR/${region}_${az}_inst${instance_num}_latency.log"
            if [ -n "$latency_log_file" ]; then
                aws s3 cp "s3://$s3_bucket/results/$latency_log_file" "$local_file" --region "$region"
                echo "  Latency log downloaded: $local_file"
            else
                echo "  Warning: Latency log not found in S3"
                # Create empty file so grep doesn't fail
                touch "$local_file"
            fi
            
            # Also download network analysis JSON if it exists
            local network_file
            network_file=$(aws s3 ls "s3://$s3_bucket/results/network_analysis_${region}_${az}_inst${instance_num}.json" --region "$region" 2>/dev/null | tail -1 | awk '{print $4}' || true)
            if [ -n "$network_file" ]; then
                local local_network_file="$RESULTS_DIR/${region}_${az}_inst${instance_num}_network.json"
                aws s3 cp "s3://$s3_bucket/results/$network_file" "$local_network_file" --region "$region"
                echo "  Network analysis downloaded: $local_network_file"
            fi
            
            # Download rs latency test results (both order and orderbook files)
            local order_p50="N/A" orderbook_p50="N/A" orderbook_mean="N/A" order_p99="N/A" orderbook_p99="N/A"
            
            # Download and parse order latency JSON
            local order_latency_file
            order_latency_file=$(aws s3 ls "s3://$s3_bucket/results/order_latency_${region}_${az}_inst${instance_num}" --region "$region" 2>/dev/null | tail -1 | awk '{print $4}' || true)
            if [ -n "$order_latency_file" ]; then
                local local_order_file="$RESULTS_DIR/${region}_${az}_inst${instance_num}_order_latency.json"
                aws s3 cp "s3://$s3_bucket/results/$order_latency_file" "$local_order_file" --region "$region"
                echo "  Order latency test downloaded: $local_order_file"
                # Parse p50 and p99 from JSON (nanoseconds -> milliseconds)
                local p50_ns p99_ns
                p50_ns=$(jq -r '.statistics_ns.median // empty' "$local_order_file" 2>/dev/null || echo "")
                p99_ns=$(jq -r '.statistics_ns.p99 // empty' "$local_order_file" 2>/dev/null || echo "")
                [ -n "$p50_ns" ] && order_p50=$(echo "scale=3; $p50_ns / 1000000" | bc)
                [ -n "$p99_ns" ] && order_p99=$(echo "scale=3; $p99_ns / 1000000" | bc)
            fi
            
            # Download and parse orderbook latency JSON
            local orderbook_latency_file
            orderbook_latency_file=$(aws s3 ls "s3://$s3_bucket/results/orderbook_latency_${region}_${az}_inst${instance_num}" --region "$region" 2>/dev/null | tail -1 | awk '{print $4}' || true)
            if [ -n "$orderbook_latency_file" ]; then
                local local_orderbook_file="$RESULTS_DIR/${region}_${az}_inst${instance_num}_orderbook_latency.json"
                aws s3 cp "s3://$s3_bucket/results/$orderbook_latency_file" "$local_orderbook_file" --region "$region"
                echo "  Orderbook latency test downloaded: $local_orderbook_file"
                # Parse p50, p99, and mean from JSON (nanoseconds -> milliseconds)
                local ob_p50_ns ob_p99_ns ob_mean_ns
                ob_p50_ns=$(jq -r '.statistics_ns.median // empty' "$local_orderbook_file" 2>/dev/null || echo "")
                ob_p99_ns=$(jq -r '.statistics_ns.p99 // empty' "$local_orderbook_file" 2>/dev/null || echo "")
                ob_mean_ns=$(jq -r '.statistics_ns.mean // empty' "$local_orderbook_file" 2>/dev/null || echo "")
                [ -n "$ob_p50_ns" ] && orderbook_p50=$(echo "scale=3; $ob_p50_ns / 1000000" | bc)
                [ -n "$ob_p99_ns" ] && orderbook_p99=$(echo "scale=3; $ob_p99_ns / 1000000" | bc)
                [ -n "$ob_mean_ns" ] && orderbook_mean=$(echo "scale=3; $ob_mean_ns / 1000000" | bc)
            fi
            
            # Parse P99 results from log (format: "  tcp_connect          : 0.123 ms")
            local tcp_p99 ping_p99 trade_p99 tcp_p50
            tcp_p99=$(grep "tcp_connect" "$local_file" | tail -1 | awk '{print $3}' || echo "N/A")
            tcp_p50=$(grep "^  P50:" "$local_file" | head -1 | awk '{print $2}' || echo "N/A")
            ping_p99=$(grep "ws_ping_pong" "$local_file" | tail -1 | awk '{print $3}' || echo "N/A")
            trade_p99=$(grep "trade_stream" "$local_file" | tail -1 | awk '{print $3}' || echo "N/A")
            
            # Calculate combined latency (0.5 * order_p50 + orderbook_mean)
            local combined_ms="N/A"
            if [ "$order_p50" != "N/A" ] && [ "$orderbook_mean" != "N/A" ]; then
                combined_ms=$(echo "scale=3; 0.5 * $order_p50 + $orderbook_mean" | bc)
            fi
            
            # Save to results file
            echo "$region,$az,$instance_num,$tcp_p99,$ping_p99,$trade_p99,$order_p99,$orderbook_p99,$tcp_p50,$order_p50,$orderbook_p50,$orderbook_mean,$combined_ms,$instance_ip,pending" >> "$RESULTS_FILE"

            echo "Results: Orderbook Mean=${orderbook_mean}ms, Order P50=${order_p50}ms, Combined=${combined_ms}ms"
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
        echo "$region,$az,$instance_num,TIMEOUT,TIMEOUT,TIMEOUT,TIMEOUT,TIMEOUT,TIMEOUT,TIMEOUT,TIMEOUT,TIMEOUT,TIMEOUT,N/A,destroyed" >> "$RESULTS_FILE"
        cleanup_instance "$workspace_name"
        return 1
    fi
    
    # Cleanup decision based on combined latency
    local should_destroy=true
    
    # Use combined latency (0.5 * order_p50 + orderbook_mean) for comparison
    local compare_latency="$combined_ms"
    local compare_label="Combined (0.5 * Order P50 + Orderbook Mean)"
    
    if [ "$results_found" = true ] && [ "$compare_latency" != "N/A" ]; then
        # Check if latency is below target
        echo "Comparing: ${compare_latency}ms (${compare_label}) vs target ${TARGET_LATENCY}ms"
        comparison_result=$(echo "$compare_latency < $TARGET_LATENCY" | bc -l)
        echo "Comparison result: $comparison_result (1=keep, 0=destroy)"
        if (( comparison_result )); then
            echo "🎯 EXCELLENT LATENCY: ${compare_label} ${compare_latency}ms < ${TARGET_LATENCY}ms - KEEPING INSTANCE #$instance_num!"
            echo "   Formula: 0.5 * ${order_p50}ms + ${orderbook_mean}ms = ${compare_latency}ms"
            echo "   Instance IP: $instance_ip"
            echo "   Workspace: $workspace_name"
            echo "   To destroy later: cd ec2 && terraform workspace select $workspace_name && terraform destroy"
            should_destroy=false
            
            # Send Telegram alert
            if [ -n "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
                echo "Sending Telegram notification..."
                local tg_msg="⚔ *ICON TRADING*\\n🎯 Low Latency Instance Found\\!\\n\\n${compare_label}: ${compare_latency}ms"
                tg_msg+="\\nOrderbook Mean: ${orderbook_mean}ms"
                tg_msg+="\\nOrder P50: ${order_p50}ms\\nRegion: ${region}\\nAZ: ${az}\\nIP: ${instance_ip}"
                curl -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
                    -H 'Content-type: application/json' \
                    --data "{\"chat_id\":${TELEGRAM_CHAT_ID},\"text\":\"${tg_msg}\",\"parse_mode\":\"Markdown\"}" \
                    -s > /dev/null || echo "Failed to send Telegram notification"
            fi
            
            # Update CSV to mark as kept
            sed -i "s/$region,$az,$instance_num,.*,pending$/$region,$az,$instance_num,$tcp_p99,$ping_p99,$trade_p99,$order_p99,$orderbook_p99,$tcp_p50,$order_p50,$orderbook_p50,$orderbook_mean,$combined_ms,$instance_ip,KEPT/" "$RESULTS_FILE"
        fi
    fi
    
    if [ "$should_destroy" = true ]; then
        echo "Destroying instance #$instance_num (${compare_label}: ${compare_latency}ms >= ${TARGET_LATENCY}ms)..."
        # Update CSV to mark as destroyed
        sed -i "s/$region,$az,$instance_num,.*,pending$/$region,$az,$instance_num,$tcp_p99,$ping_p99,$trade_p99,$order_p99,$orderbook_p99,$tcp_p50,$order_p50,$orderbook_p50,$orderbook_mean,$combined_ms,$instance_ip,destroyed/" "$RESULTS_FILE"
        cleanup_instance "$workspace_name"
    fi
    
    echo "Completed: $region / $az / Instance #$instance_num"
}

# Main execution
echo "Binance Latency Machine Hunt"
echo "=========================================="
echo "Target: $TARGET_REGION / $TARGET_AZ"
echo "Goal: Find machine with < ${TARGET_LATENCY}ms latency"
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

if ! command -v bc &> /dev/null; then
    echo "ERROR: bc not found (required for float comparison)"
    echo "Install: sudo apt install bc  # Ubuntu/Debian"
    echo "     or: brew install bc      # macOS"
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
terraform init -no-color -upgrade >> "$TERRAFORM_LOG" 2>&1
terraform apply -auto-approve -no-color -compact-warnings >> "$TERRAFORM_LOG" 2>&1

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
terraform init -no-color -upgrade >> "$TERRAFORM_LOG" 2>&1

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
echo "All tested instances (sorted by Combined latency):"
echo ""
sort -t',' -k13 -n "$RESULTS_FILE" | column -t -s','

# Show kept instances
echo ""
echo "=========================================="
kept_count=$(grep -c ",KEPT$" "$RESULTS_FILE" 2>/dev/null || echo "0")
kept_count=$(echo "$kept_count" | tr -d '\n\r' | head -1)
if [ "$kept_count" -gt 0 ]; then
    echo "🎯 KEPT INSTANCES (Combined < ${TARGET_LATENCY}ms):"
    echo ""
    grep ",KEPT$" "$RESULTS_FILE" | sort -t',' -k13 -n | column -t -s','
else
    echo "❌ No instances met the target latency of <${TARGET_LATENCY}ms"
fi

# Find best instance (by combined latency)
echo ""
echo "🏆 BEST MACHINE:"
best_line=$(sort -t',' -k13 -n "$RESULTS_FILE" | grep -v TIMEOUT | grep -v "region" | head -1)
echo "$best_line" | column -t -s','

best_tcp_p99=$(echo "$best_line" | cut -d',' -f4)
best_ping_p99=$(echo "$best_line" | cut -d',' -f5)
best_trade_p99=$(echo "$best_line" | cut -d',' -f6)
best_order_p99=$(echo "$best_line" | cut -d',' -f7)
best_orderbook_p99=$(echo "$best_line" | cut -d',' -f8)
best_tcp_p50=$(echo "$best_line" | cut -d',' -f9)
best_order_p50=$(echo "$best_line" | cut -d',' -f10)
best_orderbook_p50=$(echo "$best_line" | cut -d',' -f11)
best_orderbook_mean=$(echo "$best_line" | cut -d',' -f12)
best_combined=$(echo "$best_line" | cut -d',' -f13)
best_ip=$(echo "$best_line" | cut -d',' -f14)
best_status=$(echo "$best_line" | cut -d',' -f15)

echo ""
if [ "$best_status" = "KEPT" ]; then
    echo "✅ Best machine is running at: $best_ip"
    echo "   Combined: ${best_combined}ms (0.5 * ${best_order_p50}ms + ${best_orderbook_mean}ms)"
else
    echo "Best Combined latency achieved: ${best_combined}ms (instance was destroyed)"
fi

# Send Telegram summary
if [ -n "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
    echo ""
    echo "Sending Telegram summary..."
    
    # Build mobile-friendly message with proper newlines
    msg="🔍 *Latency Sweep Complete*\n\n"
    msg+="📊 *Results Summary*\n"
    msg+="• Tested: ${NUM_INSTANCES} instances\n"
    msg+="• Region: ${TARGET_REGION}\n"
    msg+="• AZ: ${TARGET_AZ}\n"
    msg+="• Type: ${INSTANCE_TYPE}\n\n"
    
    if [ "$kept_count" -gt 0 ]; then
        msg+="✅ *Kept: ${kept_count} instance(s)*\n"
        msg+="(Combined < ${TARGET_LATENCY}ms)\n\n"
        
        # List kept instances
        msg+="🖥 *Running Instances:*\n"
        while IFS=',' read -r region az inst tcp ping trade order_p99 orderbook_p99 tcp_p50 order_p50 orderbook_p50 orderbook_mean combined ip status; do
            if [ "$status" = "KEPT" ]; then
                msg+="• \`${ip}\`\n"
                msg+="  Combined: ${combined}ms\n"
            fi
        done < <(grep ",KEPT$" "$RESULTS_FILE")
    else
        msg+="❌ *No instances kept*\n"
        msg+="(None met <${TARGET_LATENCY}ms target)\n"
    fi
    
    msg+="\n─────────────────────\n"
    msg+="🏆 *Best Result*\n"
    msg+="Combined: \`${best_combined}ms\`\n"
    msg+="Orderbook Mean: ${best_orderbook_mean}ms\\n"
    msg+="Order P50: ${best_order_p50}ms\\n"
    if [ "$best_status" = "KEPT" ]; then
        msg+="IP: \`${best_ip}\`\n"
        msg+="Status: Running ✅"
    else
        msg+="Status: Destroyed 🗑"
    fi
    
    curl -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -H 'Content-type: application/json' \
        --data "{\"chat_id\":${TELEGRAM_CHAT_ID},\"text\":\"${msg}\",\"parse_mode\":\"Markdown\"}" \
        -s > /dev/null || echo "⚠ Failed to send Telegram summary"
fi
