#!/usr/bin/env python3
"""
TODO TODO TODO: Double check the URLs
Binance WebSocket P99 Latency Test

Methods:
  tcp   - Raw TCP connect latency (baseline network RTT)
  ping  - WebSocket ping/pong round-trip (application-layer RTT)
  trade - Trade stream event time latency (requires NTP sync)

Usage:
    python ws_latency.py --method tcp --samples 500 --host fstream.binance.com
    python ws_latency.py --method ping --samples 200 --interval 250
    python ws_latency.py --method trade --duration 60

Rate Limits (Binance):
    - WebSocket ping/pong: max 5 per second (use --interval 200+)
"""

import argparse
import json
import socket
import threading
import time
from collections import deque
from dataclasses import dataclass, field

import numpy as np
import websocket

@dataclass(slots=True)
class LatencyStats:
    """Latency statistics container"""
    samples: list = field(default_factory=list)

    def add(self, latency_ms: float):
        self.samples.append(latency_ms)

    def compute(self) -> dict:
        if len(self.samples) < 2:
            return {"error": "Not enough samples"}

        arr = np.array(self.samples)
        return {
            "count": len(arr),
            "min": float(np.min(arr)),
            "max": float(np.max(arr)),
            "mean": float(np.mean(arr)),
            "median": float(np.median(arr)),
            "stdev": float(np.std(arr)),
            "p50": float(np.percentile(arr, 50)),
            "p90": float(np.percentile(arr, 90)),
            "p95": float(np.percentile(arr, 95)),
            "p99": float(np.percentile(arr, 99)),
            "p99_9": float(np.percentile(arr, 99.9)) if len(arr) >= 1000 else None,
        }
    
    def print_stats(self, title: str = "Latency Statistics"):
        stats = self.compute()
        if "error" in stats:
            print(f"Error: {stats['error']}")
            return
        
        print(f"\n{'='*60}")
        print(f"{title}")
        print(f"{'='*60}")
        print(f"  Samples:  {stats['count']}")
        print(f"  Min:      {stats['min']:.3f} ms")
        print(f"  Max:      {stats['max']:.3f} ms")
        print(f"  Mean:     {stats['mean']:.3f} ms")
        print(f"  Median:   {stats['median']:.3f} ms")
        print(f"  StdDev:   {stats['stdev']:.3f} ms")
        print(f"  P50:      {stats['p50']:.3f} ms")
        print(f"  P90:      {stats['p90']:.3f} ms")
        print(f"  P95:      {stats['p95']:.3f} ms")
        print(f"  P99:      {stats['p99']:.3f} ms")
        if stats['p99_9']:
            print(f"  P99.9:    {stats['p99_9']:.3f} ms")


class WSPingPongLatency:
    """
    WebSocket Ping/Pong Frame Latency.
    Measures true round-trip over established connection.
    Binance rate-limits to 5 pings/sec (200ms min interval).
    """
    
    def __init__(self, endpoint: str = "wss://ws-fapi.binance.com/ws-fapi/v1"):
        # old: "wss://stream.binance.com:9443/ws/btcusdt@trade"
        self.endpoint = endpoint
        self.stats = LatencyStats()
        self.pending_pings = deque()  # FIFO queue of send_time_ns
        self.ws = None
        self.sock = None
        self.running = False
        self.lock = threading.Lock()
        
    def on_open(self, ws):
        print(f"Connected to {self.endpoint}")
        self.sock = ws.sock
        self.running = True
        
    def on_message(self, ws, message):
        # don't care about messages for ping/pong test
        pass
    
    def on_pong(self, ws, data):
        recv_time = time.perf_counter_ns()
        
        with self.lock:
            # Match pong to oldest pending ping (FIFO)
            if self.pending_pings:
                send_time = self.pending_pings.popleft()
                latency_ms = (recv_time - send_time) / 1_000_000
                self.stats.add(latency_ms)
            # else: stray pong (shouldn't happen)
    
    def on_error(self, ws, error):
        print(f"Error: {error}")
    
    def on_close(self, ws, code, msg):
        print(f"Connection closed: {code} {msg}")
        self.running = False
        self.sock = None
    
    def send_ping(self):
        """Send a ping and record the time"""
        if self.sock and self.running:
            with self.lock:
                send_time = time.perf_counter_ns()
                self.sock.ping()
                self.pending_pings.append(send_time)
    
    def run(self, samples: int = 1000, interval_ms: int = 200):
        """
        Run ping/pong latency test
        
        Args:
            samples: Number of ping/pong round-trips to measure
            interval_ms: Interval between pings in milliseconds (min 200ms per Binance rate limit: 5/sec)
        """
        # Binance rate-limits pings to 5/second, enforce minimum 200ms interval
        interval_ms = max(interval_ms, 200)
        
        print(f"\nWSPingPong Latency Test")
        print(f"Endpoint: {self.endpoint}")
        print(f"Samples: {samples}, Interval: {interval_ms}ms")
        print(f"Note: Binance limits WS pings to 5/sec (200ms min interval)")
        est_time = (samples * interval_ms / 1000) + 5  # +5 for warmup
        print(f"Estimated time: ~{est_time:.0f}s")
        
        self.ws = websocket.WebSocketApp(
            self.endpoint,
            on_open=self.on_open,
            on_message=self.on_message,
            on_pong=self.on_pong,
            on_error=self.on_error,
            on_close=self.on_close
        )
        
        # Run WebSocket in background thread
        ws_thread = threading.Thread(target=self.ws.run_forever, kwargs={
            "ping_interval": 0,  # Disable automatic pings
            "ping_timeout": None
        })
        ws_thread.daemon = True
        ws_thread.start()
        
        # Wait for connection
        for _ in range(50):
            if self.running:
                break
            time.sleep(0.1)
        
        if not self.running:
            print("Failed to connect")
            return None
        
        # Warm-up: send a few pings at safe rate
        print("Warming up...")
        for _ in range(5):
            self.send_ping()
            time.sleep(0.25)  # 250ms = 4/sec, safely under limit
        
        # Wait for warmup pongs to arrive
        time.sleep(1.0)
        
        # Reset stats and counters after warmup
        with self.lock:
            self.stats = LatencyStats()
            self.pending_pings.clear()
        
        # Main measurement loop
        print(f"Collecting {samples} samples...")
        collected = 0
        last_print = 0
        while collected < samples and self.running:
            self.send_ping()
            time.sleep(interval_ms / 1000)
            with self.lock:
                collected = len(self.stats.samples)
            
            # Print progress every 50 samples or 10 seconds
            if collected >= last_print + 50:
                current = self.stats.compute()
                print(f"  {collected}/{samples} | P50: {current['p50']:.2f}ms | P99: {current['p99']:.2f}ms")
                last_print = collected
        
        # Wait for last pongs
        time.sleep(1.0)
        
        # Check for any lost pongs
        with self.lock:
            if self.pending_pings:
                print(f"Warning: {len(self.pending_pings)} pings never received pongs")
        
        self.ws.close()
        self.stats.print_stats("WS Ping/Pong Round-Trip Latency")
        return self.stats


class TradeStreamLatency:
    """
    Trade Stream Event Time Latency.
    Measures exchange event time vs local receive time.
    !!! Requires NTP sync - check with: chronyc tracking
    """
    
    def __init__(self, symbol: str = "btcusdt", 
                 endpoint: str = "wss://fstream.binance.com/ws"):
        self.symbol = symbol.lower()
        self.endpoint = endpoint
        self.stats = LatencyStats()
        self.running = False
        self.message_count = 0
        self.warmup = True
        
    def on_message(self, ws, message):
        recv_time_ns = time.time_ns()  # Use wall clock for event time comparison
        
        try:
            data = json.loads(message)
        except:
            return
        
        # Skip warmup messages
        if self.warmup:
            return
        
        # Get event time (E) from message - in milliseconds
        if 'E' in data:
            event_time_ms = data['E']
            event_time_ns = event_time_ms * 1_000_000
            
            # Latency = local receive time - exchange event time
            latency_ms = (recv_time_ns - event_time_ns) / 1_000_000
            
            # Sanity check: negative latency means clock skew
            if latency_ms < -100:
                if self.message_count == 0:
                    print(f"Warning: Large negative latency ({latency_ms:.1f}ms) - check NTP sync")
            
            self.stats.add(latency_ms)
            self.message_count += 1
            
            if self.message_count % 500 == 0:
                current_stats = self.stats.compute()
                print(f"  {self.message_count} msgs | "
                      f"P50: {current_stats['p50']:.2f}ms | "
                      f"P99: {current_stats['p99']:.2f}ms")
    
    def on_open(self, ws):
        print(f"Connected, subscribing to {self.symbol}@aggTrade...")
        
        # Subscribe to aggregate trade stream (less noisy than @trade)
        subscribe_msg = {
            "method": "SUBSCRIBE",
            "params": [f"{self.symbol}@aggTrade"],
            "id": 1
        }
        ws.send(json.dumps(subscribe_msg))
        self.running = True
    
    def on_error(self, ws, error):
        print(f"Error: {error}")
    
    def on_close(self, ws, code, msg):
        print(f"Closed: {code}")
        self.running = False
    
    def run(self, duration_sec: int = 60, warmup_sec: int = 5):
        """
        Run trade stream latency test
        
        Args:
            duration_sec: How long to collect samples
            warmup_sec: Warmup period to skip
        """
        print(f"\nTrade Stream Latency Test")
        print(f"Symbol: {self.symbol}")
        print(f"Duration: {duration_sec}s (+ {warmup_sec}s warmup)")
        print(f"\nNote: Requires NTP sync. Check with: chronyc tracking")
        
        ws = websocket.WebSocketApp(
            self.endpoint,
            on_open=self.on_open,
            on_message=self.on_message,
            on_error=self.on_error,
            on_close=self.on_close
        )
        
        ws_thread = threading.Thread(target=ws.run_forever)
        ws_thread.daemon = True
        ws_thread.start()
        
        # Wait for connection
        for _ in range(50):
            if self.running:
                break
            time.sleep(0.1)
        
        if not self.running:
            print("Failed to connect")
            return None
        
        # Warmup period
        print(f"Warming up for {warmup_sec}s...")
        time.sleep(warmup_sec)
        self.warmup = False
        self.stats = LatencyStats()
        
        # Collection period
        print(f"Collecting for {duration_sec}s...")
        time.sleep(duration_sec)
        
        ws.close()
        ws_thread.join(timeout=2)
        
        self.stats.print_stats("Trade Stream Event Latency (requires NTP sync)")
        return self.stats


class TCPConnectLatency:
    """
    Raw TCP Connection Latency (SYN-ACK round-trip).
    Baseline network latency without TLS/WS overhead.
    """
    
    def __init__(self, host: str = "fstream.binance.com", port: int = 443):
        self.host = host
        self.port = port
        self.stats = LatencyStats()
    
    def run(self, samples: int = 1000, interval_ms: int = 50):
        """
        Run TCP connect latency test
        """
        print(f"\nTCP Connect Latency Test")
        print(f"Host: {self.host}:{self.port}")
        print(f"Samples: {samples}")
        
        # Resolve DNS once
        try:
            ip = socket.gethostbyname(self.host)
            print(f"Resolved IP: {ip}")
        except Exception as e:
            print(f"DNS resolution failed: {e}")
            return None
        
        # Warmup
        print("Warming up...")
        for _ in range(10):
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(5)
                sock.connect((ip, self.port))
                sock.close()
            except:
                pass
            time.sleep(0.05)
        
        # Main loop
        print(f"Collecting {samples} samples...")
        for i in range(samples):
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(5)
                
                start = time.perf_counter_ns()
                sock.connect((ip, self.port))
                end = time.perf_counter_ns()
                
                latency_ms = (end - start) / 1_000_000
                self.stats.add(latency_ms)
                sock.close()
                
            except Exception as e:
                print(f"Connection {i} failed: {e}")
            
            if (i + 1) % 100 == 0:
                print(f"  Progress: {i + 1}/{samples}")
            
            time.sleep(interval_ms / 1000)
        
        self.stats.print_stats("TCP Connect Latency (SYN-ACK round-trip)")
        return self.stats


def save_results(stats: LatencyStats, filename: str):
    """Save results to JSON file"""
    data = {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime()),
        "statistics": stats.compute(),
        "raw_samples": stats.samples,
    }
    with open(filename, "w") as f:
        json.dump(data, f, indent=2)
    print(f"\nResults saved to: {filename}")


def run_full_stack(host: str, samples: int = 200):
    """Run all latency tests and print comparison summary."""
    print("\n" + "=" * 60)
    print("FULL STACK LATENCY TEST")
    print("=" * 60)
    print(f"Host: {host}")

    results = {}

    # 1. TCP Connect
    tcp_test = TCPConnectLatency(host, 443)
    tcp_stats = tcp_test.run(samples=samples, interval_ms=20)
    if tcp_stats:
        results["tcp_connect"] = tcp_stats.compute()

    # 2. WS Ping/Pong (use bare /ws endpoint, not a stream, to avoid message queue delays)
    ping_test = WSPingPongLatency(f"wss://{host}/ws")
    ping_stats = ping_test.run(samples=min(samples, 100), interval_ms=250)
    if ping_stats:
        results["ws_ping_pong"] = ping_stats.compute()

    # 3. Trade Stream (!!! event time)
    trade_test = TradeStreamLatency("btcusdt", f"wss://{host}/ws")
    trade_stats = trade_test.run(duration_sec=30, warmup_sec=3)
    if trade_stats:
        results["trade_stream"] = trade_stats.compute()

    # Summary
    print("\n" + "=" * 60)
    print("SUMMARY - P99 LATENCIES")
    print("=" * 60)
    for name, stats in results.items():
        if "p99" in stats:
            print(f"  {name:20s}: {stats['p99']:.3f} ms")

    return results


def main():
    parser = argparse.ArgumentParser(description="Binance WebSocket P99 Latency Test")
    parser.add_argument("--method", choices=["tcp", "ping", "trade", "full"], default="tcp",
                        help="tcp: raw TCP connect, ping: WS ping/pong, trade: event time, full: all methods")
    parser.add_argument("--samples", type=int, default=500,
                        help="Number of samples (tcp/ping)")
    parser.add_argument("--duration", type=int, default=60,
                        help="Duration in seconds (trade)")
    parser.add_argument("--interval", type=int, default=250,
                        help="Interval between samples in ms (min 200 for ping)")
    parser.add_argument("--symbol", default="btcusdt", help="Trading symbol")
    parser.add_argument("--host", default="fstream.binance.com",
                        help="Binance host (fstream/stream/dstream)")
    parser.add_argument("--output", help="Save results to JSON file")

    args = parser.parse_args()

    print("=" * 60)
    print("Binance P99 Latency Test")
    print("=" * 60)
    print(f"Time: {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}")
    print(f"Method: {args.method}, Host: {args.host}")

    stats = None

    if args.method == "tcp":
        test = TCPConnectLatency(args.host, 443)
        stats = test.run(samples=args.samples, interval_ms=20)
    elif args.method == "ping":
        endpoint = f"wss://{args.host}/ws"
        test = WSPingPongLatency(endpoint)
        stats = test.run(samples=args.samples, interval_ms=args.interval)
    elif args.method == "trade":
        endpoint = f"wss://{args.host}/ws"
        test = TradeStreamLatency(args.symbol, endpoint)
        stats = test.run(duration_sec=args.duration, warmup_sec=5)
    elif args.method == "full":
        run_full_stack(args.host, samples=args.samples)

    if stats and args.output:
        save_results(stats, args.output)


if __name__ == "__main__":
    main()
