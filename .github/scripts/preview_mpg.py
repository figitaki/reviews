#!/usr/bin/env python3
"""Provision a preview database on Fly Managed Postgres v2.

Only the database URL goes to stdout, for the workflow's secrets import.
Cleanup imports the same target guards and database API functions.
"""

import json
import os
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


def request(cluster, method="GET", suffix="", body=None):
    data = None if body is None else json.dumps(body).encode()
    req = Request(
        f"https://api.machines.dev/v1/postgres/{cluster}{suffix}",
        data=data, method=method,
        headers={"Authorization": "Bearer " + os.environ["FLY_API_TOKEN"],
                 "Content-Type": "application/json"},
    )
    try:
        with urlopen(req, timeout=60) as response:
            return json.load(response)
    except HTTPError as error:
        # Never echo API bodies: credential endpoints can contain secrets.
        raise RuntimeError(f"Fly MPG {method} failed (HTTP {error.code})") from None
    except (URLError, TimeoutError):
        raise RuntimeError(f"Fly MPG {method} connection failed") from None


def target():
    name = os.environ.get("PREVIEW_DB_NAME", "")
    app = os.environ.get("APP_NAME", "")
    cluster = os.environ.get("PREVIEW_MPG_CLUSTER_ID", "")
    if not re.fullmatch(r"reviews_pr_[0-9]+", name) or app != name.replace("_", "-"):
        raise ValueError("preview app and database names must match the PR number")
    if len(name) > 63 or not re.fullmatch(r"[a-z0-9]+", cluster):
        raise ValueError("invalid preview database name or MPG cluster ID")
    metadata = request(cluster)["data"]
    # Refuse accidental production selection, even with an otherwise valid ID.
    if not metadata["name"].startswith("reviews-preview-"):
        raise ValueError("MPG cluster name must start with reviews-preview-")
    if metadata["status"] != "ready":
        raise ValueError("preview MPG cluster is not ready")
    return cluster, name, metadata


def databases(cluster):
    return {db["name"] for db in request(cluster, suffix="/databases")["data"]}


def drop_database(cluster, name):
    if name in databases(cluster):
        request(cluster, "DELETE", "/databases/" + name)
    if name in databases(cluster):
        raise RuntimeError("preview database still exists after MPG deletion")
    print(f"Dropped {name} (or already absent).", flush=True)


def provision():
    cluster, name, metadata = target()
    if name not in databases(cluster):
        try:
            request(cluster, "POST", "/databases", {"name": name})
        except RuntimeError:
            # A create may have succeeded despite a lost response. Confirm its
            # effect instead of blindly repeating a side-effecting request.
            if name not in databases(cluster):
                raise
    if name not in databases(cluster):
        raise RuntimeError("preview database is missing after MPG creation")
    credentials = request(cluster, suffix="/users/fly-user/credentials")["data"]
    endpoint = metadata["endpoints"]["primary"]["pooler"]
    user = quote(credentials["username"], safe="")
    password = quote(credentials["password"], safe="")
    return f"postgresql://{user}:{password}@{endpoint['host']}:{endpoint['port']}/{name}"


if __name__ == "__main__":
    try:
        print(provision())
    except (ValueError, KeyError, OSError, RuntimeError) as error:
        detail = str(error) if isinstance(error, RuntimeError) else "check preview MPG configuration"
        print(f"::error::Preview MPG provisioning failed: {detail}.", file=sys.stderr)
        sys.exit(1)
