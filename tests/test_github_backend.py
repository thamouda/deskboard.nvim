"""GitHub adapter fixtures. No credentials or network calls."""
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from urllib.parse import parse_qs, urlsplit

spec = importlib.util.spec_from_file_location("github_sync", Path(__file__).parents[1] / "scripts/github-sync.py")
backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend)


def issue(number=1, **changes):
    return {"number": number, "title": "Work \n title", "state": "open", "user": {"login": "colleague"},
            "repository_url": "https://api.github.com/repos/team/repo", "assignees": [{"login": "me"}],
            "labels": [{"name": "bug"}], **changes}


def search(items, **changes):
    return {"items": items, "total_count": len(items), "incomplete_results": False, **changes}


def thread_data(nodes, next_page=False, cursor=None):
    return {"data": {"repository": {"pullRequest": {"reviewThreads": {
        "nodes": nodes, "pageInfo": {"hasNextPage": next_page, "endCursor": cursor}}}}}}


class GitHubTests(unittest.TestCase):
    def client(self, respond):
        calls = []
        def runner(args, **kwargs):
            calls.append(args)
            self.assertEqual(args[:6], ["gh", "api", "--hostname", "github.com", "--method", "POST" if args[6] == "graphql" else "GET"])
            self.assertEqual(kwargs["timeout"], 12)
            self.assertTrue(kwargs["capture_output"] and kwargs["text"])
            value = respond(args[6], args)
            return value if isinstance(value, subprocess.CompletedProcess) else subprocess.CompletedProcess(args, 0, json.dumps(value), "")
        return backend.GitHub("team/repo", runner), calls

    def test_assigned_issues_use_gh_only_and_filter_prs_closed_and_other_repos(self):
        items = [issue(), issue(2, pull_request={}), issue(3, assignees=[]), issue(4, state="closed"),
                 issue(5, repository_url="https://api.github.com/repos/other/repo")]
        def respond(path, _):
            if path == "user":
                return {"login": "me"}
            query = parse_qs(urlsplit(path).query)["q"][0]
            self.assertEqual(query, "repo:team/repo is:open is:issue assignee:me")
            return search(items)
        client, calls = self.client(respond)
        value, error = client.queue("issues")
        self.assertIsNone(error)
        self.assertEqual([row["iid"] for row in value["rows"]], [1])
        self.assertEqual(value["rows"][0]["title"], "Work   title")
        self.assertEqual(value["rows"][0]["web_url"], "https://github.com/team/repo/issues/1")
        self.assertEqual(value["rows"][0]["labels"], "bug")
        self.assertEqual(len(calls), 2)

    def test_complete_pagination_and_confirmed_empty_queue(self):
        def respond(path, _):
            if path == "user":
                return {"login": "me"}
            page = parse_qs(urlsplit(path).query)["page"][0]
            return search([issue(n) for n in range(1, 101)] if page == "1" else [issue(101)], total_count=101)
        client, _ = self.client(respond)
        value, error = client.queue("issues")
        self.assertIsNone(error)
        self.assertEqual(len(value["rows"]), 101)
        client.request = lambda path: ({"login": "me"}, None) if path == "user" else (search([]), None)
        value, error = client.queue("issues")
        self.assertIsNone(error)
        self.assertEqual(value["rows"], [])

    def test_partial_invalid_or_search_capped_results_never_replace_cache(self):
        variants = [search([], incomplete_results=True), search([], total_count=1001), search([], total_count=3),
                    search([issue(number="1")]), search([issue(assignees=None)]), {"items": []}]
        for result in variants:
            client, _ = self.client(lambda path, _: {"login": "me"} if path == "user" else result)
            value, error = client.queue("issues")
            self.assertIsNone(value)
            self.assertTrue(error)
        def respond(path, _):
            if path == "user":
                return {"login": "me"}
            if parse_qs(urlsplit(path).query)["page"] == ["1"]:
                return search([issue(n) for n in range(1, 101)], total_count=101)
            return subprocess.CompletedProcess([], 1, "SECRET", "unauthorized SECRET")
        client, _ = self.client(respond)
        value, error = client.queue("issues")
        self.assertIsNone(value)
        self.assertNotIn("SECRET", error)

    def test_review_requests_use_pr_metadata_and_read_only_thread_query(self):
        def respond(path, args):
            if path == "user":
                return {"login": "me"}
            if path.startswith("search/"):
                self.assertIn("review-requested:me -author:me", parse_qs(urlsplit(path).query)["q"][0])
                return search([issue(pull_request={}), issue(2, pull_request={}, user={"login": "me"})])
            if path.endswith("/pulls/1"):
                return {"number": 1, "state": "open", "requested_reviewers": [{"login": "me"}],
                        "base": {"ref": "main"}, "head": {"sha": "a" * 40}, "commits": 3}
            if path.endswith("/reviews?per_page=100&page=1"):
                return [{"id": 1, "state": "APPROVED", "user": {"login": "me"}},
                        {"id": 2, "state": "APPROVED", "user": {"login": "other"}}]
            if path.endswith("/status"):
                return {"total_count": 0, "state": "pending"}
            if "/check-runs?" in path:
                return {"total_count": 1, "check_runs": [{"status": "completed", "conclusion": "success"}]}
            if path == "graphql":
                self.assertFalse(any("mutation" in arg for arg in args))
                return thread_data([{"isResolved": False, "comments": {"nodes": [{"author": {"login": "me"}}]}},
                                    {"isResolved": True, "comments": {"nodes": [{"author": {"login": "other"}}]}}])
            self.fail(path)
        client, _ = self.client(respond)
        value, error = client.queue("reviews")
        self.assertIsNone(error)
        self.assertEqual(len(value["rows"]), 1)
        row = value["rows"][0]
        self.assertEqual((row["commits"], row["ci"], row["target_branch"]), (3, "success", "main"))
        self.assertEqual((row["approved"], row["my_approved"], row["other_approvals"]), (2, True, 1))
        self.assertEqual(row["threads"], {"resolved": 1, "total": 2})
        self.assertEqual(row["my_threads"], {"resolved": 0, "total": 1})
        self.assertEqual(value["warnings"], [])

    def test_review_metadata_failures_stay_unknown_not_all_clear(self):
        def respond(path, _):
            if path == "user":
                return {"login": "me"}
            if path.startswith("search/"):
                return search([issue(pull_request={})])
            return subprocess.CompletedProcess([], 1, "SECRET", "SECRET")
        client, _ = self.client(respond)
        value, error = client.queue("reviews")
        self.assertIsNone(error)
        row = value["rows"][0]
        for field in ("ci", "commits", "approved", "my_approved", "other_approvals", "threads", "my_threads"):
            self.assertIsNone(row[field])
        self.assertTrue(value["warnings"])
        self.assertNotIn("SECRET", str(value))

    def test_disappeared_review_requests_are_removed_after_detail_verification(self):
        client, _ = self.client(lambda path, _: {"login": "me"} if path == "user" else search([issue(pull_request={})])
                                if path.startswith("search/") else {"number": 1, "state": "open", "base": {"ref": "main"}, "requested_reviewers": []})
        value, error = client.queue("reviews")
        self.assertIsNone(error)
        self.assertEqual(value["rows"], [])

    def test_approvals_count_distinct_latest_decisions_not_comments_or_duplicate_votes(self):
        reviews = [{"id": 1, "user": {"login": "me"}, "state": "APPROVED"},
                   {"id": 2, "user": {"login": "me"}, "state": "COMMENTED"},
                   {"id": 3, "user": {"login": "other"}, "state": "APPROVED"},
                   {"id": 4, "user": {"login": "other"}, "state": "CHANGES_REQUESTED"},
                   {"id": 5, "user": {"login": "other"}, "state": "APPROVED"}]
        client, _ = self.client(lambda *_: reviews)
        self.assertEqual(client.approvals(1, "me"), (2, True, 1))
        reviews.append({"id": 6, "user": {"login": "me"}, "state": "DISMISSED"})
        self.assertEqual(client.approvals(1, "me"), (1, False, 1))
        reviews.append({"id": 7, "state": "APPROVED"})
        self.assertEqual(client.approvals(1, "me"), (None, None, None))

    def test_ci_distinguishes_absent_checks_from_pending_failures_and_unknowns(self):
        for status, checks, expected in [
            ({"total_count": 0, "state": "pending"}, {"total_count": 0, "check_runs": []}, "none"),
            ({"total_count": 1, "state": "pending"}, {"total_count": 0, "check_runs": []}, "pending"),
            ({"total_count": 1, "state": "success"}, {"total_count": 1, "check_runs": [{"status": "completed", "conclusion": "failure"}]}, "failed"),
            ({"total_count": 0}, {"total_count": 101, "check_runs": []}, None),
        ]:
            client, _ = self.client(lambda path, _: status if path.endswith("/status") else checks)
            self.assertEqual(client.ci("a" * 40), expected)

    def test_thread_pagination_and_unknown_ownership_are_conservative(self):
        calls = 0
        def respond(*_):
            nonlocal calls
            calls += 1
            return thread_data([{"isResolved": True, "comments": {"nodes": [{"author": None}]}}], calls == 1, "cursor")
        client, _ = self.client(respond)
        self.assertEqual(client.threads(1, "me"), ({"resolved": 2, "total": 2}, None))
        client, _ = self.client(lambda *_: thread_data([], True, "repeated"))
        self.assertEqual(client.threads(1, "me"), (None, None))

    def test_timeouts_missing_cli_and_malformed_auth_never_expose_raw_errors(self):
        for error in (subprocess.TimeoutExpired("gh", 12), FileNotFoundError("SECRET")):
            client = backend.GitHub("team/repo", lambda *a, **k: (_ for _ in ()).throw(error))
            data, message = client.queue("issues")
            self.assertIsNone(data)
            self.assertNotIn("SECRET", message)
        for repo in ("../repo", "owner/..", "https://github.com/owner/repo", "owner/repo;echo SECRET"):
            with self.assertRaises(ValueError):
                backend.GitHub(repo)


if __name__ == "__main__":
    unittest.main()
