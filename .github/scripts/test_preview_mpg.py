"""Provider contract checks; real Fly lifecycle verification is separate."""

import os
import unittest
from unittest.mock import patch
from urllib.parse import unquote, urlsplit

import preview_mpg


class PreviewMpgTest(unittest.TestCase):
    def setUp(self):
        self.names = {"reviews_pr_42", "fly-db"}
        self.metadata = {
            "name": "reviews-preview-test", "status": "ready",
            "endpoints": {"primary": {"pooler": {"host": "preview.internal", "port": 5433}}},
        }
        self.env = patch.dict(os.environ, {
            "PREVIEW_DB_NAME": "reviews_pr_43", "APP_NAME": "reviews-pr-43",
            "PREVIEW_MPG_CLUSTER_ID": "testcluster", "FLY_API_TOKEN": "not-a-real-token",
        })
        self.env.start()
        self.addCleanup(self.env.stop)
        self.api = patch.object(preview_mpg, "request", side_effect=self.request)
        self.api.start()
        self.addCleanup(self.api.stop)

    def request(self, cluster, method="GET", suffix="", body=None):
        if not suffix:
            return {"data": self.metadata}
        if suffix == "/users/fly-user/credentials":
            return {"data": {"username": "fly-user", "password": "p@ss:w/rd%+?#"}}
        if method == "POST":
            self.names.add(body["name"])
            return {"data": body}
        if method == "DELETE":
            self.names.remove(suffix.removeprefix("/databases/"))
            return {"data": {}}
        return {"data": [{"name": name} for name in self.names]}

    def test_provision_is_idempotent_and_encodes_the_provider_credentials(self):
        first = preview_mpg.provision()
        self.assertEqual(preview_mpg.provision(), first)
        url = urlsplit(first)
        self.assertEqual((url.hostname, url.port, url.path),
                         ("preview.internal", 5433, "/reviews_pr_43"))
        self.assertEqual(unquote(url.password), "p@ss:w/rd%+?#")
        self.assertEqual(self.names, {"reviews_pr_42", "reviews_pr_43", "fly-db"})

    def test_repeated_cleanup_preserves_other_databases(self):
        preview_mpg.provision()
        cluster, name, _ = preview_mpg.target()
        for _ in range(2):
            preview_mpg.drop_database(cluster, name)
        self.assertEqual(self.names, {"reviews_pr_42", "fly-db"})

    def test_invalid_targets_cannot_create_or_delete_databases(self):
        for name in ("fly-db", "reviews_pr_43\n", "reviews_pr_43/../../", "reviews_pr_44"):
            with self.subTest(name=name), patch.dict(os.environ, PREVIEW_DB_NAME=name):
                with self.assertRaises(ValueError):
                    preview_mpg.provision()
                self.assertEqual(self.names, {"reviews_pr_42", "fly-db"})
        self.metadata["name"] = "production"
        with self.assertRaises(ValueError):
            preview_mpg.target()

    def test_lost_create_response_is_reconciled_without_repeating_creation(self):
        def uncertain(cluster, method="GET", suffix="", body=None):
            result = self.request(cluster, method, suffix, body)
            if method == "POST":
                raise RuntimeError("lost response")
            return result
        with patch.object(preview_mpg, "request", side_effect=uncertain):
            self.assertEqual(urlsplit(preview_mpg.provision()).path, "/reviews_pr_43")

    def test_drop_failure_is_not_mistaken_for_an_absent_database(self):
        preview_mpg.provision()
        def denied(cluster, method="GET", suffix="", body=None):
            if method == "DELETE":
                raise RuntimeError("Fly MPG DELETE failed (HTTP 403)")
            return self.request(cluster, method, suffix, body)
        with patch.object(preview_mpg, "request", side_effect=denied):
            with self.assertRaisesRegex(RuntimeError, "HTTP 403"):
                preview_mpg.drop_database("testcluster", "reviews_pr_43")
        self.assertIn("reviews_pr_43", self.names)


if __name__ == "__main__":
    unittest.main()
