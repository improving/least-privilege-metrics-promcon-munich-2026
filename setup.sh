#!/usr/bin/env bash
# Builds the whole demo on a fresh kind cluster (~3-4 min).
set -euo pipefail
cd "$(dirname "$0")"
for b in kind kubectl helm docker jq; do
  command -v "$b" >/dev/null || { echo "missing prerequisite: $b"; exit 1; }
done

step(){ printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }

step "kind cluster"
kind get clusters | grep -qx promcon || kind create cluster --config kind/kind-config.yaml

step "namespaces + Prometheus"
kubectl apply -f k8s/00-namespaces.yaml
kubectl apply -f k8s/10-prometheus.yaml

step "kube-state-metrics (the source of kube_secret_info)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
  -n monitoring --wait

step "tenant apps (team-a, team-b)"
render(){ sed -e "s/\${TENANT}/$1/g" -e "s/\${CUSTOMERS}/$2/g" -e "s/\${SECRET_NAME}/$3/g" \
  k8s/20-tenant-apps.yaml.tmpl; }
for t in team-a team-b; do
  kubectl -n "$t" create configmap fake-shop-code --from-file=apps/fake_shop.py \
    --dry-run=client -o yaml | kubectl apply -f -
done
render team-a "acme-corp,globex"         stripe-live-key  | kubectl apply -f -
render team-b "initech,umbrella,hooli"   db-root-password | kubectl apply -f -

step "promql-gate image"
docker build -t promql-gate:dev gate/
kind load docker-image promql-gate:dev --name promcon

step "policies + gate + prom-label-proxy"
kubectl -n promql-gate create configmap gate-policies --from-file=policies/ \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f k8s/30-gate.yaml

step "waiting for everything"
for d in monitoring/prometheus promql-gate/promql-gate promql-gate/prom-label-proxy \
         team-a/fake-shop team-b/fake-shop; do
  kubectl -n "${d%/*}" rollout status deploy/"${d#*/}" --timeout=180s
done
kubectl -n team-a wait pod/toolbox --for=condition=Ready --timeout=120s
kubectl -n team-b wait pod/toolbox --for=condition=Ready --timeout=120s

echo; echo "Ready. Give Prometheus ~30s to scrape, then run: ./demo.sh"
