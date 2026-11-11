#!/usr/bin/env python3
"""Destroy a preview app, then drop its database without running preview code."""

import os
import re
import subprocess
import sys
import tempfile
import time
from urllib.parse import parse_qsl, unquote, urlsplit


def cleanup():
    name = os.environ.get("PREVIEW_DB_NAME", "")
    app = os.environ.get("APP_NAME", "")
    org = os.environ.get("FLY_ORG", "")
    if not re.fullmatch(r"reviews_pr_[0-9]+", name) or app != name.replace("_", "-"):
        raise ValueError("preview app and database names must match the PR number")
    if not org:
        raise ValueError("FLY_ORG is required")

    managed = None
    if os.environ.get("PREVIEW_MPG_CLUSTER_ID"):
        import preview_mpg

        # Validate the cluster before destroying anything. v1 databases must
        # never be silently treated as already absent on the v2 API.
        managed = preview_mpg.target()

    print("Cleanup stage: list preview apps.", flush=True)
    apps = subprocess.run(
        ["flyctl", "apps", "list", "--org", org, "--quiet"],
        check=True, capture_output=True, text=True, timeout=60,
    )
    if app in apps.stdout.split():
        # Stop all app/release machines before dropping their database. A
        # failed destruction must not be mistaken for an absent application.
        print(f"Cleanup stage: destroy {app}.", flush=True)
        subprocess.run(
            ["flyctl", "apps", "destroy", app, "--yes"],
            check=True, capture_output=True, timeout=120,
        )
        print(f"Destroyed {app}.", flush=True)
    else:
        print(f"Preview app {app} is already absent.", flush=True)

    if managed:
        print(f"Cleanup stage: drop {name} through Managed Postgres.", flush=True)
        preview_mpg.drop_database(managed[0], name)
        return

    print("Cleanup stage: configure maintenance connection.", flush=True)
    url = urlsplit(os.environ.get("PREVIEW_DATABASE_URL", ""))
    if url.scheme not in ("postgres", "postgresql") or not url.hostname or not url.username:
        raise ValueError("PREVIEW_DATABASE_URL must be a Postgres URL")
    remote_port = url.port or 5432
    # Keep credentials out of argv and logs. Pin the maintenance database and
    # tunnel address even if the original URL contains routing query options.
    env = {key: value for key, value in os.environ.items() if not key.startswith("PG")}
    env.update(
        PGDATABASE="postgres", PGHOST=url.hostname, PGHOSTADDR="127.0.0.1", PGPORT="15432",
        PGUSER=unquote(url.username), PGPASSWORD=unquote(url.password or ""), PGCONNECT_TIMEOUT="5",
    )
    # Preserve TLS settings, including the original hostname for verify-full.
    for key, value in parse_qsl(url.query):
        if key in ("sslmode", "sslrootcert", "sslcert", "sslkey", "sslcrl", "sslcrldir",
                   "sslpassword", "channel_binding", "gssencmode"):
            env["PG" + key.upper()] = value

    # Fly's private network is not reachable directly from a hosted runner.
    # Proxy to the URL's endpoint, not to a preview app that may never have
    # started. This also works for old releases and already-deleted apps.
    # flyctl loads fly.toml from cwd, and its app overrides --org. Run outside
    # the checkout so production's fly.toml cannot select the proxy network.
    with tempfile.TemporaryDirectory() as directory:
        print("Cleanup stage: start database proxy.", flush=True)
        proxy = subprocess.Popen(
            ["flyctl", "proxy", f"15432:{remote_port}", url.hostname,
             "--org", org, "--bind-addr", "127.0.0.1"],
            cwd=directory,
            env={key: value for key, value in os.environ.items() if key != "FLY_APP"},
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            sql = f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE);'
            print(f"Cleanup stage: drop {name}.", flush=True)
            for _ in range(12):
                if proxy.poll() is not None:
                    raise RuntimeError("Fly database proxy exited before cleanup completed")
                result = subprocess.run(
                    ["psql", "-X", "--no-password", "--set", "ON_ERROR_STOP=1", "--command", sql],
                    env=env, capture_output=True, timeout=20,
                )
                if result.returncode == 0:
                    print(f"Dropped {name}.")
                    return
                if result.returncode != 2:
                    raise RuntimeError(f"drop failed (psql exit {result.returncode}; SQL/client error)")
                time.sleep(2)
            raise RuntimeError("drop failed (psql exit 2; connection or authentication failure)")
        finally:
            if proxy.poll() is None:
                proxy.terminate()
            try:
                proxy.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proxy.kill()
                proxy.wait()


if __name__ == "__main__":
    try:
        cleanup()
    except (ValueError, KeyError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        # Subprocess errors and connection strings can contain credentials.
        detail = "check the last cleanup stage and the manual cleanup runbook"
        if isinstance(error, RuntimeError):
            detail = str(error)
        elif isinstance(error, subprocess.CalledProcessError):
            detail = f"Fly command exit {error.returncode}; check the last cleanup stage"
        print(f"::error::Preview cleanup failed: {detail}.", file=sys.stderr)
        sys.exit(1)
