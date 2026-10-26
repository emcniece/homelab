#!/usr/bin/env bash
# Unit-tests the Prometheus alert rules in prometheus-rules.yaml with promtool
# (same image as the cluster's Prometheus). Usage: infra/monitoring/tests/run.sh
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
import sys, yaml
cm = yaml.safe_load(open("../prometheus-rules.yaml"))
for name, body in cm["data"].items():
    open(f"{sys.argv[1]}/{name}", "w").write(body)
PY
cp ./*.test.yml "$work"/
image=$(grep -o 'prom/prometheus:[^" ]*' ../prometheus-deployment.yaml | head -1)
for t in "$work"/*.test.yml; do
  docker run --rm --entrypoint promtool -v "$work":/cfg -w /cfg "$image" test rules "$(basename "$t")"
done
