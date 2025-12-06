#!/usr/bin/env python3
"""
Binance WebSocket Latency Test
Measures tick-to-trade latency through WebSocket connections.
"""

import websocket
import json
import time
import threading
import statistics
from collections import deque

class BinanceWSLatencyTest:
    def __init__(self, symbol="btcusdt"):
        self.symbol = symbol.lower()
        self.latencies = deque(maxlen=1000)
        self.running = False
        self.message_count = 0
        
    def on_message(self, ws, message):
        recv_time = time.perf_counter_ns()
        data = json.loads(message)
        
        # Get event time from message
        if 'E' in data:
            event_time_ms = data['E']
            event_time_ns = event_time_ms * 1_000_000
            
            # Calculate latency (approximate - depends on clock sync)
            system_time_ns = time.time_ns()
            latency_ms = (system_time_ns - event_time_ns) / 1_000_000
            
            self.latencies.append(latency_ms)
            self.message_count += 1
            
            if self.message_count % 100 == 0:
                self.print_stats()
    
    def on_error(self, ws, error):
        print(f"Error: {error}")
    
    def on_close(self, ws, close_status_code, close_msg):
        print("WebSocket closed")
        self.running = False
    
    def on_open(self, ws):
        print(f"Connected to Binance WebSocket for {self.symbol}")
        self.running = True
    
    def print_stats(self):
        if len(self.latencies) < 10:
            return
        
        lats = list(self.latencies)
        print(f"\nMessages: {self.message_count}")
        print(f"  Min: {min(lats):.3f} ms")
        print(f"  Max: {max(lats):.3f} ms")
        print(f"  Avg: {statistics.mean(lats):.3f} ms")
        print(f"  Median: {statistics.median(lats):.3f} ms")
        if len(lats) > 1:
            print(f"  StdDev: {statistics.stdev(lats):.3f} ms")
    
    def run(self, duration=60):
        # Trade stream for tick data
        url = f"wss://stream.binance.com:9443/ws/{self.symbol}@trade"
        
        print(f"Connecting to: {url}")
        print(f"Will run for {duration} seconds...")
        
        ws = websocket.WebSocketApp(
            url,
            on_message=self.on_message,
            on_error=self.on_error,
            on_close=self.on_close,
            on_open=self.on_open
        )
        
        # Run in thread
        ws_thread = threading.Thread(target=ws.run_forever)
        ws_thread.start()
        
        # Wait for duration
        time.sleep(duration)
        
        # Close and wait
        ws.close()
        ws_thread.join(timeout=5)
        
        # Final stats
        print("\n" + "=" * 60)
        print("FINAL STATISTICS")
        print("=" * 60)
        self.print_stats()
        
        return list(self.latencies)

if __name__ == "__main__":
    import sys
    symbol = sys.argv[1] if len(sys.argv) > 1 else "btcusdt"
    duration = int(sys.argv[2]) if len(sys.argv) > 2 else 60
    
    test = BinanceWSLatencyTest(symbol)
    test.run(duration)
