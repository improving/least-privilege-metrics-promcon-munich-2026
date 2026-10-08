#!/usr/bin/env bash
# Rehearse the whole chain on a laptop, no cluster. Needs: prometheus, prom-label-proxy,
# kyverno CLI on PATH (or set *_BIN), python3 with gate/requirements.txt installed.
set -euo pipefail
cd "$(dirname "$0")/.."
PROM_BIN=${PROM_BIN:-prometheus}; PLP_BIN=${PLP_BIN:-prom-label-proxy}; KYVERNO_BIN=${KYVERNO_BIN:-kyverno}
mkdir -p /tmp/lpm && : > /tmp/lpm/query.log
CUSTOMERS=acme-corp,globex PORT=8001 python3 apps/fake_shop.py & 
CUSTOMERS=initech,umbrella,hooli PORT=8002 python3 apps/fake_shop.py &
python3 hack/fake_ksm.py &
$PROM_BIN --config.file=hack/prometheus.local.yml --storage.tsdb.path=/tmp/lpm/tsdb \
  --web.listen-address=:9090 >/tmp/lpm/prometheus.log 2>&1 &
$PLP_BIN -label namespace -header-name X-Tenant -upstream http://localhost:9090 \
  -insecure-listen-address :8080 -enable-label-apis -error-on-replace >/tmp/lpm/plp.log 2>&1 &
AUTH_MODE=static TENANTS_FILE=hack/tenants.local.yaml POLICY_DIR=policies \
  PROMETHEUS_URL=http://localhost:9090 UPSTREAM_URL=http://localhost:8080 KYVERNO_BIN=$KYVERNO_BIN \
  python3 -m uvicorn --app-dir gate app:app --port 8888 --log-level warning &
trap 'kill $(jobs -p) 2>/dev/null' EXIT
echo "gate on :8888, prometheus on :9090 (query log: /tmp/lpm/query.log). Ctrl-C to stop."
wait
