"""Black-box cleanup tests: real local Postgres, a local-only Fly stand-in.

Run with python3 -m unittest discover -s .github/scripts -p 'test_*.py'.
POSTGRES_HOST/PORT/USER/PASSWORD select a disposable server with CREATEDB.
No Fly credentials or network access are used.
"""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.parse import quote


FLY_STUB = r'''#!/usr/bin/env python3
import os, select, socket, socketserver, sys
from pathlib import Path
mode = os.environ.get("TEST_FLY_MODE", "absent")
state = Path(os.environ["TEST_APP_STATE"])
if sys.argv[1:3] == ["apps", "list"]:
    if mode == "list-fails":
        sys.exit(1)
    if state.exists():
        print(os.environ["APP_NAME"])
elif sys.argv[1:3] == ["apps", "destroy"]:
    if mode == "destroy-fails":
        sys.exit(1)
    state.unlink()
elif sys.argv[1] == "proxy":
    # Real flyctl loads cwd/fly.toml, whose app overrides --org. Simulate an
    # inaccessible production network if cleanup accidentally inherits it.
    if Path("fly.toml").exists() or os.environ.get("FLY_APP"):
        sys.exit(3)
    if mode == "proxy-fails":
        print(os.environ["PREVIEW_DATABASE_URL"], file=sys.stderr)
        sys.exit(1)
    class Forward(socketserver.BaseRequestHandler):
        def handle(self):
            with socket.create_connection((os.environ["POSTGRES_HOST"], int(os.environ["POSTGRES_PORT"]))) as db:
                while True:
                    for source in select.select([self.request, db], [], [])[0]:
                        data = source.recv(65536)
                        if not data:
                            return
                        (db if source is self.request else self.request).sendall(data)
    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True
    with Server(("127.0.0.1", 15432), Forward) as server:
        server.serve_forever()
else:
    sys.exit(2)
'''


class CleanupPreviewTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        stub = root / "flyctl"
        stub.write_text(FLY_STUB)
        stub.chmod(0o755)
        self.state = root / "app-exists"
        self.name = f"reviews_pr_98{os.getpid()}"
        self.other = self.name + "1"
        self.env = dict(os.environ)
        for key, default in (("HOST", "127.0.0.1"), ("PORT", "5432"), ("USER", "postgres")):
            self.env.setdefault("POSTGRES_" + key, default)
        self.env.update(
            PATH=f"{root}:{os.environ['PATH']}",
            APP_NAME=self.name.replace("_", "-"), PREVIEW_DB_NAME=self.name,
            FLY_ORG="local-test-only", TEST_APP_STATE=str(self.state),
            PGHOST=self.env["POSTGRES_HOST"], PGPORT=self.env["POSTGRES_PORT"],
            PGUSER=self.env["POSTGRES_USER"], PGPASSWORD=self.env.get("POSTGRES_PASSWORD", ""),
            PGDATABASE="postgres",
        )
        user = quote(self.env["PGUSER"], safe="")
        password = quote(self.env["PGPASSWORD"], safe="")
        self.env["PREVIEW_DATABASE_URL"] = (
            f"postgres://{user}:{password}@preview.internal:5432/{self.other}?sslmode=disable"
        )
        for name in (self.name, self.other):
            self.sql(f'CREATE DATABASE "{name}"')
            self.addCleanup(self.sql, f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')

    def sql(self, sql):
        return subprocess.run(
            ["psql", "-XAt", "--no-password", "--set", "ON_ERROR_STOP=1", "--command", sql],
            env=self.env, check=True, capture_output=True, text=True,
        ).stdout.strip()

    def exists(self, name):
        return self.sql(f"SELECT count(*) FROM pg_database WHERE datname = '{name}'") == "1"

    def cleanup(self, timeout=60, **overrides):
        return subprocess.run(
            [sys.executable, str(Path(__file__).with_name("cleanup_preview.py"))],
            env=dict(self.env, **overrides), capture_output=True, text=True, timeout=timeout,
        )

    def test_absent_app_and_repeated_cleanup_drop_only_the_target(self):
        for _ in range(2):
            result = self.cleanup(FLY_APP="must-not-select-production")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(self.exists(self.name))
            self.assertTrue(self.exists(self.other))

    def test_existing_app_is_removed_and_url_cannot_override_drop_target(self):
        self.state.touch()
        client = subprocess.Popen(
            ["psql", "-X", "--no-password", "--command", "SELECT pg_sleep(60)"],
            env=dict(self.env, PGDATABASE=self.name),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.addCleanup(client.wait, timeout=5)
        self.addCleanup(client.terminate)
        for _ in range(100):
            if self.sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname = '{self.name}' AND state = 'active'") == "1":
                break
            time.sleep(0.05)
        else:
            self.fail("target connection did not become active")
        url = self.env["PREVIEW_DATABASE_URL"] + f"&dbname={self.other}&hostaddr=192.0.2.1&port=1"
        result = self.cleanup(PREVIEW_DATABASE_URL=url)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.exists(self.name))
        self.assertTrue(self.exists(self.other))
        self.assertNotEqual(client.wait(timeout=5), 0)

    def test_database_failure_still_destroys_app_and_fails_visibly(self):
        self.state.touch()
        result = self.cleanup(TEST_FLY_MODE="proxy-fails")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.state.exists())
        self.assertTrue(self.exists(self.name))
        self.assertNotIn(self.env["PREVIEW_DATABASE_URL"], result.stdout + result.stderr)

    def test_sql_errors_fail_promptly_without_echoing_client_output(self):
        with tempfile.TemporaryDirectory() as directory:
            client = Path(directory) / "psql"
            client.write_text("#!/bin/sh\necho 'sensitive-connection-detail' >&2\nexit 1\n")
            client.chmod(0o755)
            result = self.cleanup(timeout=5, PATH=f"{directory}:{self.env['PATH']}")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("psql exit 1", result.stderr)
        self.assertNotIn("sensitive-connection-detail", result.stdout + result.stderr)
        self.assertTrue(self.exists(self.name))

    def test_app_discovery_or_destruction_failure_does_not_drop_database(self):
        self.state.touch()
        for mode in ("list-fails", "destroy-fails"):
            result = self.cleanup(TEST_FLY_MODE=mode)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(self.state.exists())
            self.assertTrue(self.exists(self.name))

    def test_invalid_target_is_rejected_before_app_or_database_changes(self):
        self.state.touch()
        for name in (self.name + "\n", self.name + '; DROP DATABASE x', self.other):
            result = self.cleanup(PREVIEW_DB_NAME=name)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(self.state.exists())
            self.assertTrue(self.exists(self.name))
            self.assertTrue(self.exists(self.other))
