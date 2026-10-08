#!/usr/bin/env bash
# Least-Privilege Metrics: live demo driver.
#   ./demo.sh            run all scenes against the kind cluster (press Enter to advance)
#   ./demo.sh 3          start from scene 3
#   LOCAL=1 ./demo.sh    rehearse against hack/local-run.sh (no cluster; scene 6 skipped)
#   NOPAUSE=1 ./demo.sh  no keypresses (dry run / recording)
#   ./demo.sh reset      restore pre-demo state; run before every rehearsal and before going on stage
set -uo pipefail
cd "$(dirname "$0")"
START=${1:-0}
LOCAL=${LOCAL:-0}
GATE=http://localhost:8888
# private per-run scratch dir: never collides with another user or an earlier sudo run
WORK=$(mktemp -d "${TMPDIR:-/tmp}/lpm-demo.XXXXXX"); OUT=$WORK/out
cleanup(){ [ -n "${PF:-}" ] && kill "$PF" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# ------------------------------------------------------------------ presentation helpers
C_CMD='\033[1;36m'; C_SCENE='\033[1;33m'; C_OK='\033[1;32m'; C_BAD='\033[1;31m'; C_DIM='\033[2m'; C_0='\033[0m'
pause(){ [ "${NOPAUSE:-0}" = 1 ] || read -rs; }
scene(){ printf "\n${C_SCENE}━━━ Scene %s: %s ━━━${C_0}\n" "$1" "$2"; pause; }
say(){ printf "${C_DIM}# %s${C_0}\n" "$*"; }
pe(){ printf "${C_CMD}\$ %s${C_0}" "$*"; pause; echo; eval "$@"; }

# Pretty-print a Prometheus API response: results on success, the reason on denial.
show(){
  local code=${1:-000} file=$2 colour=$C_OK
  [ "$code" -ge 400 ] 2>/dev/null || [ "$code" = 000 ] && colour=$C_BAD
  printf "${colour}HTTP %s${C_0}\n" "$code"
  if [ "$code" = 000 ]; then echo "(no response: is the gate port-forward up? kubectl -n promql-gate get pods)"; return; fi
  jq -C 'if .status == "success" then
           (.data | if type == "object" then [.result[] | {metric} + (if .value then {value: .value[1]} else {points: (.values | length)} end)] else . end)
         else {error} end' "$file" 2>/dev/null || cat "$file"
}

# ------------------------------------------------------------------ environment plumbing
token(){
  if [ "$LOCAL" = 1 ]; then echo "token-$1"; else
    local v="TOKEN_${1//-/_}"; echo "${!v}"; fi
}
if [ "$LOCAL" = 1 ] && [ "$START" = reset ]; then
  echo "LOCAL mode: restart hack/local-run.sh to reset budgets; policies are restored automatically after scene 7."; exit 0
fi
if [ "$LOCAL" != 1 ]; then
  if ! kubectl get ns promql-gate >/dev/null 2>&1; then
    echo "kubectl can't reach the promcon cluster as $(whoami) (context: $(kubectl config current-context 2>/dev/null || echo none))."
    echo "If the cluster was created with sudo, run once:"
    echo "  sudo kind export kubeconfig --name promcon --kubeconfig \$HOME/.kube/config"
    echo "  sudo chown \$USER:\$USER \$HOME/.kube/config"
    exit 1
  fi
  if [ "$START" = reset ]; then
    ok(){ printf "${C_OK}✔${C_0} %s\n" "$*"; }
    fail(){ printf "${C_BAD}✘ %s${C_0}\n" "$*"; exit 1; }
    kubectl -n promql-gate create configmap gate-policies --from-file=policies/ \
      --dry-run=client -o yaml > "$WORK/cm.yaml" && kubectl apply -f "$WORK/cm.yaml" >/dev/null \
      && ok "policies ConfigMap restored from ./policies" || fail "could not apply the policies ConfigMap"
    kubectl delete -f k8s/40-networkpolicies.yaml --ignore-not-found >/dev/null && ok "NetworkPolicies removed"
    # A fresh gate pod mounts the current ConfigMap immediately (no kubelet sync wait)
    # and starts with empty rate-limit buckets and an empty decision cache.
    kubectl -n promql-gate rollout restart deploy/promql-gate >/dev/null
    kubectl -n promql-gate rollout status deploy/promql-gate --timeout=120s >/dev/null \
      && ok "gate restarted (rate-limit budgets refilled, decision cache cleared)" || fail "gate did not become ready"
    for f in policies/*.yaml; do
      kubectl -n promql-gate exec deploy/promql-gate -- cat "/policies/$(basename "$f")" 2>/dev/null \
        | diff -q - "$f" >/dev/null || fail "gate pod has a stale $(basename "$f")"
    done; ok "gate pod sees the original policies"
    for _ in $(seq 1 10); do
      c=$(kubectl -n team-a exec toolbox -- curl -s -m 3 -o /dev/null -w '%{http_code}' \
           http://prometheus.monitoring.svc:9090/-/ready 2>/dev/null)
      [ "$c" = 200 ] && break; sleep 2
    done
    [ "$c" = 200 ] && ok "Prometheus reachable directly from team-a (scene 0 will leak)" \
                   || fail "team-a still can't reach Prometheus directly (code ${c:-none})"
    n=$(kubectl -n team-a exec toolbox -- curl -s -m 5 -G http://prometheus.monitoring.svc:9090/api/v1/query \
         --data-urlencode 'query=count(kube_secret_info{namespace=~"team-.*"})' 2>/dev/null \
         | jq -r '.data.result[0].value[1] // 0')
    [ "${n:-0}" -ge 2 ] 2>/dev/null && ok "kube_secret_info shows both tenants' secrets" \
                                 || printf "${C_BAD}!${C_0} kube_secret_info has no tenant secrets yet (check kube-state-metrics)\n"
    printf "\nReady for a clean run.\n"
    exit 0
  fi
  TOKEN_team_a=$(kubectl -n team-a create token metrics-reader --duration=2h)
  TOKEN_team_b=$(kubectl -n team-b create token metrics-reader --duration=2h)
  kubectl -n promql-gate port-forward svc/promql-gate 8888:8080 >/dev/null 2>&1 &
  PF=$!
  sleep 2
fi

# q <tenant> <promql>                    instant query through the gate
q(){ local c; c=$(curl -s -o $OUT -w '%{http_code}' -H "Authorization: Bearer $(token "$1")" \
       "$GATE/api/v1/query" --data-urlencode "query=$2"); show "$c" $OUT; }
# qr <tenant> <promql> <window_seconds> <step>   range query through the gate
qr(){ local now c; now=$(date +%s)
      c=$(curl -s -o $OUT -w '%{http_code}' -H "Authorization: Bearer $(token "$1")" \
       "$GATE/api/v1/query_range" --data-urlencode "query=$2" \
       -d start=$((now - $3)) -d end="$now" -d step="$4"); show "$c" $OUT; }
# what Prometheus actually executed (after the gate + prom-label-proxy)
ran(){ if [ "$LOCAL" = 1 ]; then tail -n1 /tmp/lpm/query.log; else
         kubectl -n monitoring exec deploy/prometheus -- tail -n1 /prometheus/query.log; fi \
       | jq -r '"Prometheus executed:  " + .params.query'; }
# query Prometheus directly from inside team-a's namespace, skipping the gate
direct(){ local c
  if [ "$LOCAL" = 1 ]; then
    c=$(curl -s -m 5 -o $OUT -w '%{http_code}' -G localhost:9090/api/v1/query --data-urlencode "query=$1")
  else
    c=$(kubectl -n team-a exec toolbox -- curl -s -m 5 -o /tmp/out -w '%{http_code}' -G \
         http://prometheus.monitoring.svc:9090/api/v1/query --data-urlencode "query=$1" 2>/dev/null)
    kubectl -n team-a exec toolbox -- cat /tmp/out > "$OUT" 2>/dev/null
  fi
  [ "$c" = "000" ] && { printf "${C_BAD}connection timed out (dropped by NetworkPolicy)${C_0}\n"; return; }
  show "$c" $OUT; }
apply_policies(){
  if [ "$LOCAL" = 1 ]; then cp "$1"/*.yaml policies/; return; fi
  kubectl -n promql-gate create configmap gate-policies --from-file="$1" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  printf "waiting for kubelet to sync the ConfigMap into the gate pod "
  for _ in $(seq 1 60); do
    kubectl -n promql-gate exec deploy/promql-gate -- cat /policies/03-tenant-metric-allowlist.yaml \
      | diff -q - "$1/03-tenant-metric-allowlist.yaml" >/dev/null && break
    printf "."; sleep 2
  done; echo
}

# ================================================================== scenes
if [ "$START" -le 0 ]; then
scene 0 "The problem: PromQL has no authorization model"
say "I'm in team-a's namespace. Prometheus is one Service away."
pe direct "'checkout_revenue_total'"
say "team-b's customers and revenue. And the secret *names* of every tenant:"
pe direct "'kube_secret_info{namespace=~\"team-.*\"}'"
fi

if [ "$START" -le 1 ]; then
scene 1 "Every query is a request: authenticate, parse, decide, rewrite"
say "No identity, no data."
pe "curl -s $GATE/api/v1/query --data-urlencode 'query=up' | jq -C .error"
say "team-a authenticates with its own ServiceAccount token and asks a broad question..."
pe q team-a "'sum by (namespace, customer_id) (checkout_revenue_total)'"
say "...and only gets its own namespace back. Here is what Prometheus actually ran:"
pe ran
fi

if [ "$START" -le 2 ]; then
scene 2 "Tenant isolation: blocked with a reason, not silently emptied"
pe q team-a "'checkout_revenue_total{namespace=\"team-b\"}'"
pe q team-a "'checkout_revenue_total{namespace=~\"team-.*\"}'"
say "Enumeration: dump every series, then look for something interesting"
pe q team-a "'{__name__=~\".+\"}'"
say "Sensitive metrics: denied even for your *own* namespace"
pe q team-a "'kube_secret_info'"
fi

if [ "$START" -le 3 ]; then
scene 3 "Least privilege: team-b is a restricted tier"
pe q team-b "'sum by (route) (rate(http_requests_total[5m]))'"
pe q team-b "'checkout_revenue_total'"
say "A 7-day dashboard panel from a tier that gets 1 hour"
pe qr team-b "'rate(http_requests_total[5m])'" 604800 60
say "Subqueries multiply cost; this tier gets none"
pe q team-b "'max_over_time(rate(http_requests_total[1m])[10m:15s])'"
fi

if [ "$START" -le 4 ]; then
scene 4 "Cost-aware rate limiting: protecting the shared TSDB"
say "Each request is priced by estimated samples touched. team-b's budget: 60k samples/min."
pe 'for i in $(seq 1 7); do curl -s -o /dev/null -w "%{http_code} cost=%header{x-promql-cost}\n" -H "Authorization: Bearer $(token team-b)" $GATE/api/v1/query_range --data-urlencode "query=sum by (route)(rate(http_requests_total[15m]))" -d start=$(( $(date +%s) - 3600 )) -d end=$(date +%s) -d step=15; done'
say "The response tells a well-behaved client when to come back:"
pe 'curl -s -D - -o $OUT -H "Authorization: Bearer $(token team-b)" $GATE/api/v1/query_range --data-urlencode "query=sum by (route)(rate(http_requests_total[15m]))" -d start=$(( $(date +%s) - 3600 )) -d end=$(date +%s) -d step=15 | grep -i -E "^HTTP|retry-after"; jq -C .error $OUT'
say "team-a is unaffected: budgets are per tenant"
pe q team-a "'sum(up)'"
fi

if [ "$START" -le 5 ]; then
scene 5 "Attacking the gate itself"
say "Spoof the tenant header that prom-label-proxy trusts:"
pe "curl -s -H \"Authorization: Bearer \$(token team-a)\" -H 'X-Tenant: team-b' $GATE/api/v1/query --data-urlencode 'query=count by (namespace) (http_requests_total)' | jq -C '.data.result'"
say "Parameter pollution: get 'up' approved, make Prometheus run something else:"
pe "curl -s -H \"Authorization: Bearer \$(token team-a)\" '$GATE/api/v1/query?query=up' --data-urlencode 'query=kube_secret_info' | jq -C .error"
say "Admin and federation endpoints are not on the allowlist:"
pe "curl -s -H \"Authorization: Bearer \$(token team-a)\" -X POST $GATE/api/v1/admin/tsdb/snapshot | jq -C .error"
pe "curl -s -H \"Authorization: Bearer \$(token team-a)\" -G $GATE/federate --data-urlencode 'match[]={job=~\".+\"}' | jq -C .error"
fi

if [ "$START" -le 6 ] && [ "$LOCAL" != 1 ]; then
scene 6 "A gate you can walk around is not a gate"
say "Everything so far is meaningless if team-a can still do this:"
pe direct "'checkout_revenue_total'"
pe kubectl apply -f k8s/40-networkpolicies.yaml
pe direct "'checkout_revenue_total'"
say "The gate path still works:"
pe q team-a "'sum(checkout_revenue_total)'"
fi

if [ "$START" -le 7 ]; then
scene 7 "Policy as code: change access without touching Prometheus"
say "team-b's finance team needs revenue. One line in a Kyverno policy:"
rm -rf $WORK/policies $WORK/policies-orig && mkdir -p $WORK/policies $WORK/policies-orig
cp policies/*.yaml $WORK/policies/ && cp policies/*.yaml $WORK/policies-orig/
sed -i.bak 's/"team-b": \["up", "http_requests_total"\]/"team-b": ["up", "http_requests_total", "checkout_"]/' \
  $WORK/policies/03-tenant-metric-allowlist.yaml && rm -f $WORK/policies/*.bak
pe "diff policies/03-tenant-metric-allowlist.yaml $WORK/policies/03-tenant-metric-allowlist.yaml"
pe apply_policies $WORK/policies
pe q team-b "'sum by (customer_id) (checkout_revenue_total)'"
pe ran
say "Still only team-b's customers: entitlement and isolation are separate controls."
fi

printf "\n${C_SCENE}━━━ fin ━━━${C_0}\n"
if [ "$LOCAL" = 1 ]; then
  [ -d $WORK/policies-orig ] && cp $WORK/policies-orig/*.yaml policies/ && say "policies restored"
else
  say "reset for another run:  ./demo.sh reset"
fi