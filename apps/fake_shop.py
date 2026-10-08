"""Tiny stdlib-only Prometheus exporter that pretends to be a tenant's shop.
checkout_revenue_total carries customer_id: exactly the kind of label that must
never leak across tenants."""
import os, random, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer

CUSTOMERS = os.getenv("CUSTOMERS", "cust-001,cust-002").split(",")
ROUTES = ["/", "/cart", "/checkout", "/api/items"]
lock = threading.Lock()
reqs = {(r, c): 0 for r in ROUTES for c in ("200", "500")}
revenue = {c: 0.0 for c in CUSTOMERS}

def tick():
    while True:
        with lock:
            for r in ROUTES:
                reqs[(r, "200")] += random.randint(5, 20)
                if random.random() < 0.1:
                    reqs[(r, "500")] += 1
            for c in CUSTOMERS:
                revenue[c] += round(random.uniform(10, 500), 2)
        time.sleep(1)

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        with lock:
            lines = ["# TYPE http_requests_total counter"]
            lines += [f'http_requests_total{{route="{r}",code="{c}"}} {v}' for (r, c), v in reqs.items()]
            lines += ["# TYPE checkout_revenue_total counter"]
            lines += [f'checkout_revenue_total{{customer_id="{c}"}} {v:.2f}' for c, v in revenue.items()]
        body = ("\n".join(lines) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass

threading.Thread(target=tick, daemon=True).start()
HTTPServer(("", int(os.getenv("PORT", "8000"))), H).serve_forever()
