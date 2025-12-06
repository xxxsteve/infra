#!/bin/bash
# System tuning for low latency networking

echo "Applying low-latency network tuning..."

# Increase network buffers
sysctl -w net.core.rmem_max=26214400
sysctl -w net.core.wmem_max=26214400
sysctl -w net.core.rmem_default=1048576
sysctl -w net.core.wmem_default=1048576
sysctl -w net.ipv4.tcp_rmem="4096 1048576 26214400"
sysctl -w net.ipv4.tcp_wmem="4096 1048576 26214400"

# Reduce TCP latency
sysctl -w net.ipv4.tcp_low_latency=1
sysctl -w net.ipv4.tcp_fastopen=3
sysctl -w net.ipv4.tcp_slow_start_after_idle=0

# Increase connection tracking
sysctl -w net.netfilter.nf_conntrack_max=1048576 2>/dev/null || true

# Reduce ARP cache garbage collection
sysctl -w net.ipv4.neigh.default.gc_thresh1=1024
sysctl -w net.ipv4.neigh.default.gc_thresh2=4096
sysctl -w net.ipv4.neigh.default.gc_thresh3=8192

# Enable TCP BBR congestion control if available
if grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    sysctl -w net.core.default_qdisc=fq
    sysctl -w net.ipv4.tcp_congestion_control=bbr
    echo "BBR congestion control enabled"
fi

# Disable TCP timestamps for slightly less overhead
# sysctl -w net.ipv4.tcp_timestamps=0  # Uncomment if needed

echo "Network tuning applied!"

# Show current settings
echo ""
echo "Current network settings:"
sysctl net.core.rmem_max
sysctl net.core.wmem_max
sysctl net.ipv4.tcp_low_latency
sysctl net.ipv4.tcp_congestion_control 2>/dev/null || echo "tcp_congestion_control: not available"
