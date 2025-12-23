#!/bin/bash
# System tuning for low latency networking

echo "Applying low-latency network tuning..."

# ==========================================
# Network Buffer Optimization
# ==========================================
# Increase network buffers
sysctl -w net.core.rmem_max=26214400
sysctl -w net.core.wmem_max=26214400
sysctl -w net.core.rmem_default=1048576
sysctl -w net.core.wmem_default=1048576
sysctl -w net.ipv4.tcp_rmem="4096 1048576 26214400"
sysctl -w net.ipv4.tcp_wmem="4096 1048576 26214400"

# Increase netdev backlog for high packet rates
sysctl -w net.core.netdev_max_backlog=50000
sysctl -w net.core.netdev_budget=600
sysctl -w net.core.netdev_budget_usecs=8000

# ==========================================
# TCP Optimizations
# ==========================================
# Reduce TCP latency
sysctl -w net.ipv4.tcp_low_latency=1
sysctl -w net.ipv4.tcp_fastopen=3
sysctl -w net.ipv4.tcp_slow_start_after_idle=0

# Disable TCP timestamps (reduces 12 bytes per packet, ~5-10% faster)
sysctl -w net.ipv4.tcp_timestamps=0

# Disable TCP SACK (Selective ACK) - less processing
sysctl -w net.ipv4.tcp_sack=0
sysctl -w net.ipv4.tcp_dsack=0
sysctl -w net.ipv4.tcp_fack=0

# Reduce TCP retransmit timeout
sysctl -w net.ipv4.tcp_retries2=5

# Enable TCP window scaling
sysctl -w net.ipv4.tcp_window_scaling=1

# ==========================================
# Connection Tracking & ARP
# ==========================================
# Increase connection tracking
sysctl -w net.netfilter.nf_conntrack_max=1048576 2>/dev/null || true

# Reduce ARP cache garbage collection
sysctl -w net.ipv4.neigh.default.gc_thresh1=1024
sysctl -w net.ipv4.neigh.default.gc_thresh2=4096
sysctl -w net.ipv4.neigh.default.gc_thresh3=8192

# ==========================================
# Congestion Control
# ==========================================
# Enable TCP BBR congestion control if available
if grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    sysctl -w net.core.default_qdisc=fq
    sysctl -w net.ipv4.tcp_congestion_control=bbr
    echo "BBR congestion control enabled"
fi

# ==========================================
# CPU & IRQ Optimizations
# ==========================================
# Disable CPU frequency scaling (force max frequency)
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    echo "Setting CPU governor to performance..."
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$cpu" 2>/dev/null || true
    done
fi

# Disable Intel C-states (prevent CPU sleep for consistent latency)
if [ -f /sys/devices/system/cpu/cpu0/cpuidle/state1/disable ]; then
    echo "Disabling CPU C-states..."
    for state in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do
        echo 1 > "$state" 2>/dev/null || true
    done
fi

# Enable RPS (Receive Packet Steering) on all network interfaces
echo "Configuring RPS/RFS..."
for iface in /sys/class/net/eth* /sys/class/net/ens*; do
    if [ -d "$iface" ]; then
        iface_name=$(basename "$iface")
        # Get number of CPUs
        num_cpus=$(nproc)
        # Calculate RPS mask (all CPUs)
        rps_mask=$(printf '%x' $((2**num_cpus - 1)))
        
        for queue in "$iface"/queues/rx-*/rps_cpus; do
            echo "$rps_mask" > "$queue" 2>/dev/null || true
        done
        echo "RPS enabled on $iface_name with mask $rps_mask"
    fi
done

# Configure RFS (Receive Flow Steering)
sysctl -w net.core.rps_sock_flow_entries=32768
for iface in /sys/class/net/eth*/queues/rx-*/rps_flow_cnt; do
    echo 2048 > "$iface" 2>/dev/null || true
done

echo "Network tuning applied!"

# ==========================================
# Display Current Settings
# ==========================================
echo ""
echo "Current network settings:"
sysctl net.core.rmem_max
sysctl net.core.wmem_max
sysctl net.ipv4.tcp_low_latency
sysctl net.ipv4.tcp_timestamps
sysctl net.ipv4.tcp_congestion_control 2>/dev/null || echo "tcp_congestion_control: not available"
sysctl net.core.netdev_max_backlog

echo ""
echo "CPU governor:"
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "Not available"
