import os
import signal
import time
import json
import socket
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.request import urlopen


VERSION = os.getenv("APP_VERSION", "v2")
PORT = 8002
DEPENDENCY_URL = "http://127.0.0.1:9000"


def application_timeout_handler(signum, frame):
    raise TimeoutError("Application timeout after 1 second")


class Handler(BaseHTTPRequestHandler):

    def send_json(self, status_code, data):
        body = json.dumps(data).encode()

        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()

        self.wfile.write(body)

    def do_GET(self):

        if self.path == "/":

            self.send_json(200, {
                "hostname": socket.gethostname(),
                "version": VERSION,
                "timestamp": time.time()
            })

        elif self.path == "/health":

            self.send_json(200, {
                "status": "healthy"
            })

        elif self.path == "/ready":

            try:
                with urlopen(DEPENDENCY_URL, timeout=2):
                    self.send_json(200, {
                        "status": "ready"
                    })

            except Exception:
                self.send_json(503, {
                    "status": "not ready"
                })

        elif self.path == "/error":

            self.send_json(500, {
                "error": "intentional application error"
            })

        elif self.path == "/slow":

            signal.signal(
                signal.SIGALRM,
                application_timeout_handler
            )

            signal.alarm(1)

            try:

                time.sleep(3)

                signal.alarm(0)

                self.send_json(200, {
                    "status": "slow",
                    "delay_seconds": 3
                })

            except TimeoutError as e:

                signal.alarm(0)

                self.send_json(504, {
                    "error": str(e)
                })

        elif self.path == "/version":

            self.send_json(200, {
                "version": VERSION
            })

        else:

            self.send_json(404, {
                "error": "not found"
            })


if __name__ == "__main__":

    print(f"Starting app {VERSION} on port {PORT}", flush=True)

    server = HTTPServer(("0.0.0.0", PORT), Handler)

    server.serve_forever()
