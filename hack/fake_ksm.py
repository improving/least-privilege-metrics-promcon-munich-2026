"""Local stand-in for kube-state-metrics: exposes kube_secret_info for both tenants."""
from http.server import BaseHTTPRequestHandler, HTTPServer
BODY = b'''# TYPE kube_secret_info gauge
kube_secret_info{namespace="team-a",secret="stripe-live-key"} 1
kube_secret_info{namespace="team-b",secret="db-root-password"} 1
'''
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "text/plain; version=0.0.4"); self.end_headers(); self.wfile.write(BODY)
    def log_message(self, *a): pass
HTTPServer(("", 8003), H).serve_forever()
