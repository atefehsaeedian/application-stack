import json
import os
import subprocess
import sys
import time
import unittest
from urllib.request import urlopen


class ApplicationTest(unittest.TestCase):

    def run_app_test(self, app_dir, port, expected_version):
        env = os.environ.copy()
        env["APP_VERSION"] = expected_version

        process = subprocess.Popen(
            [sys.executable, "app.py"],
            cwd=app_dir,
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
        )

        try:
            base_url = f"http://127.0.0.1:{port}"

            for _ in range(20):
                try:
                    with urlopen(f"{base_url}/health", timeout=1) as response:
                        if response.status == 200:
                            break
                except Exception:
                    time.sleep(0.5)
            else:
                self.fail(f"{app_dir} did not become healthy")

            with urlopen(f"{base_url}/health", timeout=2) as response:
                data = json.load(response)

            self.assertEqual(response.status, 200)
            self.assertEqual(data["status"], "healthy")

            with urlopen(f"{base_url}/version", timeout=2) as response:
                data = json.load(response)

            self.assertEqual(response.status, 200)
            self.assertEqual(data["version"], expected_version)

        finally:
            process.terminate()

            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

    def test_app_v1(self):
        self.run_app_test(
            "app-v1",
            8001,
            "v1",
        )

    def test_app_v2(self):
        self.run_app_test(
            "app-v2",
            8002,
            "v2",
        )


if __name__ == "__main__":
    unittest.main()
