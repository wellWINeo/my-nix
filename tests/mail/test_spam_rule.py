"""After `make setup-dummy-secrets`, run with Stalwart 0.15 on PATH:
python3 -m unittest discover -s tests/mail -v
"""

import base64
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
from urllib.request import Request, urlopen
from zipfile import ZipFile


def classify(port, sender, envelope_sender):
    payload = {
        "message": f"From: Sender <{sender}>\r\nTo: user@test.invalid\r\n"
                   "Subject: Hello\r\n\r\nHello.\r\n",
        "remoteIp": "127.0.0.1",
        "ehloDomain": "test.invalid",
        "envFrom": envelope_sender,
        "envFromFlags": 0,
        "envRcptTo": ["user@test.invalid"],
    }
    auth = base64.b64encode(b"admin:test-only").decode()
    request = Request(
        f"http://127.0.0.1:{port}/api/spam-filter/classify",
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Basic {auth}", "Content-Type": "application/json"},
    )
    with urlopen(request, timeout=15) as response:
        return json.load(response)["data"]["disposition"]


class StalwartSpamRuleTest(unittest.TestCase):
    def test_numbered_acyl_from_address_is_classified_as_spam(self):
        repo = Path(__file__).resolve().parents[2]
        settings = json.loads(subprocess.check_output([
            "nix", "eval", "--json",
            "path:.#nixosConfigurations.mokosh.config.services.stalwart.settings",
            "--apply", 's: s.spam-filter or {}',
        ], cwd=repo))
        with tempfile.TemporaryDirectory() as tmp:
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            with ZipFile(Path(tmp) / "webadmin.zip", "w") as bundle:
                bundle.writestr("index.html", "")
            config = Path(tmp) / "config.toml"
            config.write_text(f'''
server.hostname = "mail.test.invalid"
server.listener.http.bind = "127.0.0.1:{port}"
server.listener.http.protocol = "http"
authentication.fallback-admin.user = "admin"
authentication.fallback-admin.secret = "test-only"
store.db.type = "rocksdb"
store.db.path = {json.dumps(str(Path(tmp) / "db"))}
storage.data = "db"
storage.blob = "db"
storage.lookup = "db"
storage.fts = "db"
storage.directory = "internal"
directory.internal.type = "internal"
directory.internal.store = "db"
webadmin.resource = "file://{tmp}/webadmin.zip"
version.spam-filter = "0.0.0"
spam-filter.pyzor.enable = false
resolver.type = "custom"
resolver.custom = ["udp://127.0.0.1:{port}"]
resolver.timeout = "100ms"
resolver.attempts = 1
tracer.stdout.type = "stdout"
tracer.stdout.level = "error"
''')
            with config.open("a") as f:
                for rule, fields in settings.get("rule", {}).items():
                    for key, value in fields.items():
                        f.write(f"spam-filter.rule.{rule}.{key} = {json.dumps(value)}\n")
                for tag, score in settings.get("list", {}).get("scores", {}).items():
                    f.write(f"spam-filter.list.scores.{tag} = {json.dumps(score)}\n")

            with subprocess.Popen(
                ["stalwart", "--config", str(config)], cwd=tmp, env={**os.environ, "TMPDIR": tmp}
            ) as server:
                try:
                    for _ in range(100):
                        try:
                            with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                                break
                        except (ConnectionRefusedError, TimeoutError):
                            if server.poll() is not None:
                                self.fail(f"Stalwart exited with status {server.returncode}")
                            time.sleep(0.05)
                    else:
                        self.fail("Stalwart did not open its HTTP listener")

                    for sender, envelope_sender, verdict in [
                        ("info@s2.acyl.ru", "bounce@test.invalid", "spam"),
                        ("INFO@S42.ACYL.RU", "bounce@test.invalid", "spam"),
                        ("info@s2.acyl.ru.example", "bounce@test.invalid", "ham"),
                        ("billing@s2.acyl.ru", "info@s2.acyl.ru", "ham"),
                    ]:
                        with self.subTest(sender=sender):
                            result = classify(port, sender, envelope_sender)
                            self.assertEqual(result["action"], "allow")
                            self.assertIn(f"X-Spam-Score: {verdict},", result["value"])
                finally:
                    server.kill()
