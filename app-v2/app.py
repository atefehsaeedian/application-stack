import os
import signal
import time
import json
import socket
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.request import urlopen

from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST


VERSION = os.getenv("APP_VERSION", "v2")
PORT = 8002
DEPENDENCY_URL = "http://127.0.0.1:9000"


def log_message(level, request_id, message):
    print(
        json.dumps({
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "level": level,
            "request_id": request_id,
            "message": message
        }),
        flush=True
    )


total_requests = Counter(
    "total_requests",
    "Total number of HTTP requests"
)

http_2xx = Counter(
    "http_2xx",
    "Total number of successful HTTP responses"
)

http_4xx = Counter(
    "http_4xx",
    "Total number of client error HTTP responses"
)

http_5xx = Counter(
    "http_5xx",
    "Total number of server error HTTP responses"
)

request_duration = Histogram(
    "request_duration",
    "HTTP request duration in seconds"
)


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

        if 200 <= status_code < 300:
            http_2xx.inc()

        elif 400 <= status_code < 500:
            http_4xx.inc()

        elif 500 <= status_code < 600:
            http_5xx.inc()

        duration = time.perf_counter() - self.request_start_time
        request_duration.observe(duration)

        log_message(
            "INFO" if status_code < 500 else "ERROR",
            self.request_id,
            f"{self.command} {self.path} -> {status_code}"
        )

    def do_GET(self):

        self.request_id = self.headers.get("X-Request-ID") or str(uuid.uuid4())

        if self.path == "/metrics":

            output = generate_latest()

            self.send_response(200)
            self.send_header("Content-Type", CONTENT_TYPE_LATEST)
            self.send_header("Content-Length", str(len(output)))
            self.end_headers()

            self.wfile.write(output)

            return

        self.request_start_time = time.perf_counter()

        total_requests.inc()

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

    print(
        f"Starting app {VERSION} on port {PORT}",
        flush=True
    )

    server = HTTPServer(
        ("0.0.0.0", PORT),
        Handler
    )

    server.serve_forever()
