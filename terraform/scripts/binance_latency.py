#!/usr/bin/env python3
"""
Binance Latency Test Script
Tests latency to various Binance endpoints using multiple methods.

# how to set environment variables:
export BINANCE_ENDPOINTS='{"test_api": "192.168.1.1"}'
export DISABLE_SSL=1  # disable SSL

"""

import socket
import time
import statistics
import subprocess
import json
import sys
import os
import requests

# Binance endpoints - will be overridden by environment variable if set
ENDPOINTS = {
    "spot_api": "api.binance.com",
    "futures_api": "fapi.binance.com",
    "coin_futures": "dapi.binance.com",
    "spot_ws": "stream.binance.com",
    "futures_ws": "fstream.binance.com"
}

# SSL configuration - can be overridden by environment variable
# export DISABLE_SSL=1  (any value) to disable SSL
USE_SSL = "DISABLE_SSL" not in os.environ
DEFAULT_PORT = 443 if USE_SSL else 80

def tcp_ping(host, port=443, count=10):
    """Measure TCP connection latency"""
    latencies = []
    
    for _ in range(count):
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(5)
            
            start = time.perf_counter_ns()
            sock.connect((host, port))
            end = time.perf_counter_ns()
            
            latency_ms = (end - start) / 1_000_000
            latencies.append(latency_ms)
            sock.close()
            time.sleep(0.1)
        except Exception as e:
            print(f"Error connecting to {host}: {e}")
    
    return latencies

def http_ping(host, count=10):
    """Measure HTTP request latency"""
    latencies = []
    
    protocol = "https" if USE_SSL else "http"
    
    # Use /api/v3/ping for spot API, /fapi/v1/ping for futures
    if host == "fapi.binance.com":
        url = f"{protocol}://fapi.binance.com/fapi/v1/ping"
    elif host == "dapi.binance.com":
        url = f"{protocol}://dapi.binance.com/dapi/v1/ping"
    elif host == "api.binance.com":
        url = f"{protocol}://api.binance.com/api/v3/ping"
    else:
        url = f"{protocol}://{host}"
    
    session = requests.Session()
    
    for _ in range(count):
        try:
            start = time.perf_counter_ns()
            resp = session.get(url, timeout=5)
            end = time.perf_counter_ns()
            
            latency_ms = (end - start) / 1_000_000
            latencies.append(latency_ms)
            time.sleep(0.1)
        except Exception as e:
            print(f"Error HTTP ping to {host}: {e}")
    
    session.close()
    return latencies

def dns_lookup(host):
    """Get DNS resolution info"""
    try:
        result = socket.getaddrinfo(host, DEFAULT_PORT, socket.AF_INET)
        ips = list(set([r[4][0] for r in result]))
        return ips
    except Exception as e:
        return [f"Error: {e}"]

def run_traceroute(host):
    """Run traceroute to endpoint"""
    try:
        result = subprocess.run(
            ["traceroute", "-n", "-q", "1", "-w", "2", host],
            capture_output=True,
            text=True,
            timeout=30
        )
        return result.stdout
    except Exception as e:
        return f"Error: {e}"

def run_mtr(host):
    """Run MTR for detailed path analysis"""
    try:
        result = subprocess.run(
            ["mtr", "-r", "-c", "10", "-n", host],
            capture_output=True,
            text=True,
            timeout=60
        )
        return result.stdout
    except Exception as e:
        return f"Error: {e}"

def analyze_latencies(latencies):
    """Calculate statistics for latency measurements"""
    if not latencies:
        return None
    
    return {
        "min": round(min(latencies), 3),
        "max": round(max(latencies), 3),
        "avg": round(statistics.mean(latencies), 3),
        "median": round(statistics.median(latencies), 3),
        "stdev": round(statistics.stdev(latencies), 3) if len(latencies) > 1 else 0,
        "p95": round(sorted(latencies)[int(len(latencies) * 0.95)], 3),
        "p99": round(sorted(latencies)[int(len(latencies) * 0.99)], 3) if len(latencies) >= 100 else round(sorted(latencies)[-1], 3),
        "count": len(latencies),
    }

def main():
    # Load endpoints from environment variable if set
    global ENDPOINTS
    if os.environ.get("BINANCE_ENDPOINTS"):
        ENDPOINTS = json.loads(os.environ["BINANCE_ENDPOINTS"])
    
    print("=" * 60)
    print("Binance Latency Test")
    print("=" * 60)
    print(f"\nTest started at: {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}")
    
    results = {}
    
    for name, host in ENDPOINTS.items():
        print(f"\n{'='*60}")
        print(f"Testing: {name} ({host})")
        print("=" * 60)
        
        # DNS lookup
        print("\nDNS Resolution:")
        ips = dns_lookup(host)
        for ip in ips:
            print(f"  {ip}")
        
        # TCP ping
        print(f"\nTCP Ping (port {DEFAULT_PORT}):")
        tcp_latencies = tcp_ping(host, DEFAULT_PORT, 20)
        tcp_stats = analyze_latencies(tcp_latencies)
        if tcp_stats:
            print(f"  Min: {tcp_stats['min']:.3f} ms")
            print(f"  Max: {tcp_stats['max']:.3f} ms")
            print(f"  Avg: {tcp_stats['avg']:.3f} ms")
            print(f"  Median: {tcp_stats['median']:.3f} ms")
            print(f"  StdDev: {tcp_stats['stdev']:.3f} ms")
            print(f"  P95: {tcp_stats['p95']:.3f} ms")
        
        # HTTP ping (for API endpoints)
        if "api" in name or "futures" in name:
            print("\nHTTP Ping (API endpoint):")
            http_latencies = http_ping(host, 20)
            http_stats = analyze_latencies(http_latencies)
            if http_stats:
                print(f"  Min: {http_stats['min']:.3f} ms")
                print(f"  Max: {http_stats['max']:.3f} ms")
                print(f"  Avg: {http_stats['avg']:.3f} ms")
                print(f"  Median: {http_stats['median']:.3f} ms")
                print(f"  StdDev: {http_stats['stdev']:.3f} ms")
                print(f"  P95: {http_stats['p95']:.3f} ms")
        else:
            http_stats = None
        
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
            "tcp": tcp_stats,
            "http": http_stats,
            "traceroute": traceroute_output,
            "mtr": mtr_output,
        }
    
    # Save results to JSON
    output_file = f"/home/ubuntu/latency_tests/results_{int(time.time())}.json"
    with open(output_file, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\n\nResults saved to: {output_file}")
    
    # Summary
    print("\n" + "=" * 60)
    print("SUMMARY - TCP Latency (Avg)")
    print("=" * 60)
    for name, data in sorted(results.items(), key=lambda x: x[1]["tcp"]["avg"] if x[1]["tcp"] else 9999):
        if data["tcp"]:
            print(f"  {name}: {data['tcp']['avg']:.3f} ms")

if __name__ == "__main__":
    main()
