"""
promql-gate: a policy-enforcing query proxy for Prometheus.

Every PromQL request is treated like a tool call in an agentic system:
  1. authenticate   -> who is asking? (Kubernetes TokenReview, or static tokens for local dev)
  2. parse          -> what are they asking for? (Prometheus' own parser via /api/v1/parse_query)
  3. decide         -> are they allowed? (Kyverno ValidatingPolicy, JSON mode)
  4. budget         -> can they afford it? (per-tenant, cost-weighted token bucket)
  5. forward        -> prom-label-proxy injects namespace="<tenant>" into every selector

Prometheus itself is never modified.
"""
import hashlib
import json
import logging
import os
import re
import subprocess
import tempfile
import time
from collections import OrderedDict
from pathlib import Path
from urllib.parse import urlencode

import httpx
import yaml
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response

PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://prometheus.monitoring.svc:9090")  # parse only
UPSTREAM_URL = os.getenv("UPSTREAM_URL", "http://prom-label-proxy.monitoring.svc:8080")  # data path
POLICY_DIR = os.getenv("POLICY_DIR", "/policies")
TENANTS_FILE = os.getenv("TENANTS_FILE", "/config/tenants.yaml")
KYVERNO_BIN = os.getenv("KYVERNO_BIN", "kyverno")
AUTH_MODE = os.getenv("AUTH_MODE", "tokenreview")  # tokenreview | static
TENANT_HEADER = os.getenv("TENANT_HEADER", "X-Tenant")
SCRAPE_INTERVAL = float(os.getenv("SCRAPE_INTERVAL_SECONDS", "15"))
DEFAULT_LOOKBACK = 300.0  # Prometheus' default lookback delta for instant selectors

logging.basicConfig(level=logging.INFO, format="%(asctime)s gate %(message)s")
log = logging.getLogger()
logging.getLogger("httpx").setLevel(logging.WARNING)
app = FastAPI(title="promql-gate")
http = httpx.AsyncClient(timeout=30)

# Only these read endpoints are proxied. Everything else (admin, federate, remote read,
# alerts, rules, status, targets...) is denied by default.
ALLOWED_ENDPOINTS = {
    "/api/v1/query", "/api/v1/query_range", "/api/v1/series",
    "/api/v1/labels",
}
LABEL_VALUES_RE = re.compile(r"^/api/v1/label/[^/]+/values$")


# --------------------------------------------------------------------------- config
def load_tenants() -> dict:
    with open(TENANTS_FILE) as f:
        return yaml.safe_load(f)["tenants"]


# --------------------------------------------------------------------------- 1. authn
async def authenticate(request: Request) -> tuple[str | None, str | None]:
    """Returns (tenant, subject). The tenant is derived from the verified identity,
    never from anything the client can set directly."""
    auth = request.headers.get("authorization", "")
    if not auth.lower().startswith("bearer "):
        return None, None
    token = auth.split(" ", 1)[1].strip()
    tenants = load_tenants()

    if AUTH_MODE == "static":
        for name, cfg in tenants.items():
            if token in cfg.get("static_tokens", []):
                return name, f"static:{name}"
        return None, None

    # In-cluster: ask the API server who owns this ServiceAccount token.
    sa_token = Path("/var/run/secrets/kubernetes.io/serviceaccount/token").read_text()
    review = {"apiVersion": "authentication.k8s.io/v1", "kind": "TokenReview",
              "spec": {"token": token}}
    async with httpx.AsyncClient(verify="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt") as k:
        r = await k.post("https://kubernetes.default.svc/apis/authentication.k8s.io/v1/tokenreviews",
                         json=review, headers={"Authorization": f"Bearer {sa_token}"})
    status = r.json().get("status", {})
    if not status.get("authenticated"):
        return None, None
    username = status["user"]["username"]  # system:serviceaccount:<ns>:<name>
    for name, cfg in tenants.items():
        if username in cfg.get("subjects", []):
            return name, username
    return None, username


# --------------------------------------------------------------------------- 2. parse
def parse_duration(v: str | None, default: float = 0.0) -> float:
    if v is None or v == "":
        return default
    try:
        return float(v)
    except ValueError:
        pass
    units = {"ms": 0.001, "s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800, "y": 31536000}
    total = 0.0
    for num, unit in re.findall(r"(\d+(?:\.\d+)?)(ms|s|m|h|d|w|y)", v):
        total += float(num) * units[unit]
    return total


def parse_time(v: str | None) -> float:
    if not v:
        return time.time()
    try:
        return float(v)
    except ValueError:
        from datetime import datetime
        return datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp()


async def parse_promql(expr: str) -> dict:
    r = await http.get(f"{PROMETHEUS_URL}/api/v1/parse_query", params={"query": expr})
    body = r.json()
    if body.get("status") != "success":
        raise ValueError(body.get("error", "parse error"))
    return body["data"]


def analyse(ast: dict) -> dict:
    """Walk Prometheus' JSON AST and extract what the policy needs to reason about."""
    out = {"selectors": [], "functions": set(), "subqueries": 0, "maxLookbackSeconds": 0.0,
           "samplesPerEval": 0.0}

    def walk(node, multiplier: float):
        if isinstance(node, list):
            for n in node:
                walk(n, multiplier)
            return
        if not isinstance(node, dict):
            return
        t = node.get("type")
        if t in ("vectorSelector", "matrixSelector"):
            lookback = node.get("range", 0) / 1000 if t == "matrixSelector" else DEFAULT_LOOKBACK
            lookback += node.get("offset", 0) / 1000
            out["maxLookbackSeconds"] = max(out["maxLookbackSeconds"], lookback)
            # rough samples touched per evaluation of this selector
            out["samplesPerEval"] += multiplier * (lookback / SCRAPE_INTERVAL + 1)
            matchers = [{"name": m["name"], "type": m["type"], "value": m["value"]}
                        for m in node.get("matchers", [])]
            name_eq = [m["value"] for m in matchers if m["name"] == "__name__" and m["type"] == "="]
            out["selectors"].append({"metric": name_eq[0] if name_eq else "",
                                     "matchers": [m for m in matchers if m["name"] != "__name__"],
                                     "nameMatchers": [m for m in matchers if m["name"] == "__name__"]})
        if t == "subquery":
            out["subqueries"] += 1
            rng, step = node.get("range", 0) / 1000, (node.get("step") or 0) / 1000 or 60
            out["maxLookbackSeconds"] = max(out["maxLookbackSeconds"], rng)
            walk(node.get("expr"), multiplier * (rng / step + 1))
            return
        if t == "call":
            out["functions"].add(node["func"]["name"])
        for k, v in node.items():
            if isinstance(v, (dict, list)):
                walk(v, multiplier)

    walk(ast, 1.0)
    out["functions"] = sorted(out["functions"])
    return out


async def build_request_doc(path: str, params: dict, tenant: str, subject: str) -> dict:
    """The JSON document Kyverno evaluates. Every field is always present, so policies
    never have to null-check."""
    exprs = [params["query"]] if "query" in params else params.get("match[]", [])
    if isinstance(exprs, str):
        exprs = [exprs]

    doc = {"kind": "PromQLQuery", "endpoint": path, "tenant": tenant, "subject": subject,
           "query": " | ".join(exprs), "metrics": [], "selectors": [], "functions": [],
           "hasUnnamedSelector": False, "subqueries": 0, "maxLookbackSeconds": 0,
           "windowSeconds": 0, "stepSeconds": 0, "estimatedSamples": 0}

    samples_per_eval = 0.0
    for e in exprs:
        a = analyse(await parse_promql(e))
        doc["selectors"] += a["selectors"]
        doc["functions"] = sorted(set(doc["functions"]) | set(a["functions"]))
        doc["subqueries"] += a["subqueries"]
        doc["maxLookbackSeconds"] = max(doc["maxLookbackSeconds"], int(a["maxLookbackSeconds"]))
        samples_per_eval += a["samplesPerEval"]

    doc["metrics"] = sorted({s["metric"] for s in doc["selectors"] if s["metric"]})
    doc["hasUnnamedSelector"] = any(not s["metric"] for s in doc["selectors"])

    evals = 1
    if path.endswith("query_range"):
        start, end = parse_time(params.get("start")), parse_time(params.get("end"))
        step = parse_duration(params.get("step"), 15)
        doc["windowSeconds"], doc["stepSeconds"] = int(end - start), int(step)
        evals = int((end - start) / max(step, 1)) + 1
    elif path == "/api/v1/series":
        start, end = parse_time(params.get("start") or "0"), parse_time(params.get("end"))
        doc["windowSeconds"] = int(end - start)
    doc["estimatedSamples"] = int(samples_per_eval * evals)
    return doc


# --------------------------------------------------------------------------- 3. decide
_cache: OrderedDict[str, list] = OrderedDict()


def policy_files() -> list[str]:
    # Top level only: ConfigMap volumes also contain hidden ..<timestamp>/ copies,
    # which would make Kyverno load every policy twice.
    return [str(p) for p in sorted(Path(POLICY_DIR).glob("*.yaml"))]


def policy_fingerprint() -> str:
    h = hashlib.sha256()
    for p in policy_files():
        h.update(p.encode() + Path(p).read_bytes())
    return h.hexdigest()


def decide(doc: dict) -> list[dict]:
    """Run every Kyverno policy against the request. Returns the list of violations."""
    key_doc = {k: v for k, v in doc.items() if k != "subject"}
    key = policy_fingerprint() + hashlib.sha256(json.dumps(key_doc, sort_keys=True).encode()).hexdigest()
    if key in _cache:
        _cache.move_to_end(key)
        return _cache[key]

    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(doc, f)
        payload = f.name
    try:
        proc = subprocess.run([KYVERNO_BIN, "apply", *policy_files(), "--json", payload,
                               "-p", "--output-format", "json"],
                              capture_output=True, text=True, timeout=10)
    finally:
        os.unlink(payload)
    try:
        report = json.loads(proc.stdout)
    except json.JSONDecodeError:
        # fail closed: if the policy engine can't answer, nobody gets data
        return [{"policy": "kyverno", "message": f"policy engine error: {proc.stderr.strip()[:300]}"}]

    violations = [{"policy": r["policy"], "message": r.get("message", "")}
                  for r in report.get("results", []) if r.get("result") in ("fail", "error")]
    _cache[key] = violations
    if len(_cache) > 2048:
        _cache.popitem(last=False)
    return violations


# --------------------------------------------------------------------------- 4. budget
class Bucket:
    def __init__(self, capacity: float):
        self.capacity, self.tokens, self.ts = capacity, capacity, time.monotonic()

    def take(self, cost: float) -> tuple[bool, float]:
        now = time.monotonic()
        rate = self.capacity / 60.0  # refill the full budget once a minute
        self.tokens = min(self.capacity, self.tokens + (now - self.ts) * rate)
        self.ts = now
        if cost <= self.tokens:
            self.tokens -= cost
            return True, 0.0
        return False, (cost - self.tokens) / rate


_buckets: dict[str, Bucket] = {}


def charge(tenant: str, cost: int) -> tuple[bool, float, float]:
    budget = float(load_tenants()[tenant].get("samples_per_minute", 1e6))
    b = _buckets.get(tenant)
    if b is None or b.capacity != budget:
        b = _buckets[tenant] = Bucket(budget)
    ok, retry = b.take(min(cost, budget))  # a single query can at most drain the bucket
    return ok, retry, b.tokens


# --------------------------------------------------------------------------- 5. forward
def deny(status: int, reason: str, tenant: str | None, doc: dict | None = None, **extra):
    log.info("DENY  tenant=%s status=%s reason=%s query=%r", tenant, status,
             reason, (doc or {}).get("query"))
    body = {"status": "error", "errorType": "forbidden" if status == 403 else "gate",
            "error": reason, "gate": {"tenant": tenant, **extra}}
    headers = {"X-PromQL-Gate": "denied"}
    if status == 429:
        headers["Retry-After"] = str(int(extra.get("retryAfterSeconds", 1)) + 1)
    return JSONResponse(body, status_code=status, headers=headers)


@app.get("/healthz")
async def healthz():
    return {"ok": True}


@app.api_route("/{full_path:path}", methods=["GET", "POST"])
async def gate(full_path: str, request: Request):
    path = "/" + full_path
    tenant, subject = await authenticate(request)
    if tenant is None:
        return deny(401, f"unauthenticated or unmapped subject ({subject or 'no token'})", None)

    if path not in ALLOWED_ENDPOINTS and not LABEL_VALUES_RE.match(path):
        return deny(403, f"endpoint {path} is not exposed to tenants", tenant)

    # Merge GET params and POST form (Grafana uses POST). Repeated keys are only legal for
    # match[]: anything else could let the gate approve one query while Prometheus runs
    # another (parameter-pollution / parser-differential attack).
    items = list(request.query_params.multi_items())
    if request.method == "POST":
        await request.body()  # cache the body before form parsing consumes the stream
        items += list((await request.form()).multi_items())
    params: dict = {}
    for k, v in items:
        if k == "match[]":
            params.setdefault(k, []).append(v)
        elif k in params:
            return deny(400, f"duplicate parameter '{k}' rejected", tenant)
        else:
            params[k] = v

    try:
        doc = await build_request_doc(path, params, tenant, subject)
    except ValueError as e:
        return deny(400, f"invalid PromQL: {e}", tenant)

    violations = decide(doc)
    if violations:
        return deny(403, "; ".join(f"[{v['policy']}] {v['message']}" for v in violations),
                    tenant, doc, violations=violations)

    ok, retry, left = charge(tenant, doc["estimatedSamples"])
    if not ok:
        return deny(429, f"tenant {tenant} is over its query budget "
                         f"(this query ~{doc['estimatedSamples']:,} samples)",
                    tenant, doc, retryAfterSeconds=round(retry, 1))

    # Forward. Strip anything the client could use to impersonate another tenant,
    # then set the tenant header from the *verified* identity.
    fwd_headers = {k: v for k, v in request.headers.items()
                   if k.lower() in ("accept", "accept-encoding", "user-agent")}
    fwd_headers[TENANT_HEADER] = tenant
    # Forward exactly the parameters that were validated, nothing else.
    fwd = [(k, x) for k, v in params.items() for x in (v if isinstance(v, list) else [v])]
    if request.method == "POST":
        fwd_headers["Content-Type"] = "application/x-www-form-urlencoded"
        upstream = await http.post(f"{UPSTREAM_URL}{path}", content=urlencode(fwd), headers=fwd_headers)
    else:
        upstream = await http.get(f"{UPSTREAM_URL}{path}", params=fwd, headers=fwd_headers)
    log.info("ALLOW tenant=%s cost=%s budget_left=%d query=%r", tenant,
             doc["estimatedSamples"], left, doc["query"])
    return Response(upstream.content, status_code=upstream.status_code,
                    media_type=upstream.headers.get("content-type"),
                    headers={"X-PromQL-Gate": "allowed", "X-PromQL-Tenant": tenant,
                             "X-PromQL-Cost": str(doc["estimatedSamples"])})
