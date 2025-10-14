#!/bin/bash
# Commands to run on media server (192.168.1.100) to check Organizr status

echo "=== Checking Docker Containers ==="
docker ps | grep -i organizr

echo "=== Checking Running Processes ==="
ps aux | grep -i organizr

echo "=== Checking Port 9000 ==="
netstat -tlnp | grep 9000

echo "=== Checking Docker Compose ==="
docker-compose ps 2>/dev/null || echo "Docker Compose not found"

echo "=== Checking if anything is listening on port 9000 ==="
lsof -i :9000 2>/dev/null || echo "Nothing listening on port 9000"

echo "=== Testing local connection ==="
curl -I http://localhost:9000 2>/dev/null || echo "Port 9000 not responding"

echo "=== Checking Docker images ==="
docker images | grep -i organizr
