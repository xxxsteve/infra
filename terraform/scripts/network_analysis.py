#!/usr/bin/env python3
"""
TODO TODO TODO Consolidate URLs
Binance Network Path Analytics
Provides network routing analysis (DNS, traceroute, MTR) for Binance endpoints.

For latency testing, use ws_latency.py instead.

# how to set environment variables:
export BINANCE_ENDPOINTS='{"test_api": "192.168.1.1"}'
"""

import socket
import subprocess
import json
import time
import os

# Binance endpoints - will be overridden by environment variable if set
ENDPOINTS = {
    "spot_api": "api.binance.com",
    "futures_api": "fapi.binance.com",
    "coin_futures": "dapi.binance.com",
    "spot_ws": "stream.binance.com",
    "futures_ws": "fstream.binance.com"
}

def dns_lookup(host, port=443):
    """Get DNS resolution info"""
    try:
        result = socket.getaddrinfo(host, port, socket.AF_INET)
        ips = list(set([r[4][0] for r in result]))
        return ips
    except Exception as e:
        return [f"Error: {e}"]

def run_traceroute(host):
    """Run traceroute to endpoint"""
    try:
        result = subprocess.run(
            ["traceroute", "-n", "-q", "1", "-w", "1", host],
            capture_output=True,
            text=True,
            timeout=20
        )
        return result.stdout
    except Exception as e:
        return f"Error: {e}"

def run_mtr(host):
    """Run MTR for detailed path analysis"""
    try:
        result = subprocess.run(
            ["mtr", "-r", "-c", "5", "-n", host],
            capture_output=True,
            text=True,
            timeout=30
        )
        return result.stdout
    except Exception as e:
        return f"Error: {e}"

def main():
    # Load endpoints from environment variable if set
    global ENDPOINTS
    if os.environ.get("BINANCE_ENDPOINTS"):
        ENDPOINTS = json.loads(os.environ["BINANCE_ENDPOINTS"])
    
    print("=" * 60)
    print("Binance Network Path Analytics")
    print("=" * 60)
    print(f"\nAnalysis started at: {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}")
    print("Note: For latency testing, use ws_latency.py\n")
    
    results = {}
    
    for name, host in ENDPOINTS.items():
        print(f"\n{'='*60}")
        print(f"Analyzing: {name} ({host})")
        print("=" * 60)
        
        # DNS lookup
        print("\nDNS Resolution:")
        ips = dns_lookup(host)
        for ip in ips:
            print(f"  {ip}")
        
        # Traceroute
        print("\nTraceroute:")
        traceroute_output = run_traceroute(host)
        print(traceroute_output)
        
        # MTR (detailed path analysis)
        print("\nMTR (detailed path analysis):")
        mtr_output = run_mtr(host)
        print(mtr_output)
        
        results[name] = {
            "host": host,
            "ips": ips,
            "traceroute": traceroute_output,
            "mtr": mtr_output,
        }
    
    # Save results to JSON
    output_file = f"/home/ubuntu/latency_tests/network_analysis_{int(time.time())}.json"
    with open(output_file, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\n\nResults saved to: {output_file}")

if __name__ == "__main__":
    main()
