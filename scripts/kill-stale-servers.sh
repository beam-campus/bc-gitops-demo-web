#!/bin/bash
# Kill stale Phoenix/BEAM servers holding ports 4000 or 8080

echo "Finding processes on ports 4000 and 8080..."

# Find PIDs holding these ports
for port in 4000 8080; do
    pids=$(ss -tlnp 2>/dev/null | grep ":$port" | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | sort -u)
    if [ -n "$pids" ]; then
        echo "Port $port held by PIDs: $pids"
        for pid in $pids; do
            echo "Killing PID $pid..."
            kill -9 "$pid" 2>/dev/null || sudo kill -9 "$pid"
        done
    else
        echo "Port $port is free"
    fi
done

# Also kill any remaining BEAM processes running phx.server as root
echo ""
echo "Checking for root-owned Phoenix servers..."
sudo pkill -9 -f "mix phx.server" 2>/dev/null && echo "Killed root Phoenix servers" || echo "No root Phoenix servers found"

echo ""
echo "Current port status:"
ss -tlnp | grep -E ':(4000|8080|8082)' || echo "All ports free!"
