"""Run: python3 -m unittest discover -s tests -p 'test_sprint_sync_backend.py'. No network."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("sprint_sync", Path(__file__).resolve().parents[1] / "scripts/sprint-sync.py")
backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend)


def review_metadata(path):
    """Default confirmed empty review metadata; never masks list/commit queries."""
    if path.endswith("/approvals"):
        return {"approved_by": [], "approvals_left": 1}
    if "/discussions?" in path:
        return []
    if "/merge_requests/" in path and path.rsplit("/", 1)[-1].isdigit():
        return {"iid": int(path.rsplit("/", 1)[-1]), "head_pipeline": None}
    return NotImplemented


class FakeClient:
    def __init__(self, jira=False, gitlab=True):
        self.jira_ok, self.gitlab_ok = jira, gitlab
        self.rows = [(False, "TEST-42", "To review", "Task")]
        self.issue = {"timetracking": {"remainingEstimate": "1d"}}

    def jira_tickets(self, cached):
        return (self.rows, None) if self.jira_ok else (None, "Jira authentication failed (HTTP 401)")

    def jira_issue(self, key):
        return self.issue, None

    def sprint(self):
        return "SPRINT|Sprint 26|2026-11-09 09:00:00|2026-11-30 09:00:00"

    def mr(self, key, old):
        if self.gitlab_ok:
            return {"mr": "🔀 !516 [OK]", "threads": "✅ 1/1"}, None
        return None, "GitLab request timed out"


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "notes.md"
        self.original = ("SPRINT|Sprint 25|start|end\nMy focus\n- [ ] Personal todo\n"
                         "synced 15:23\n- [ ] TEST-42|👀 To review|🧩 Task|2d↓|🔀 !516 [FAIL]|🔴 2/15\n")
        self.path.write_text(self.original)

    def client(self, responses):
        calls = []
        def runner(args, **opts):
            calls.append((args, opts))
            value = responses(args)
            if isinstance(value, subprocess.CompletedProcess):
                return value
            return subprocess.CompletedProcess(args, 0, json.dumps(value), "")
        with patch.dict(os.environ, {"GITLAB_TOKEN": "test-credential"}, clear=True):
            client = backend.Client("gitlab.example.invalid", "team/repo", "http://proxy.invalid:3128", runner)
        return client, calls

    def test_jira_401_still_refreshes_gitlab_and_preserves_jira_and_notes(self):
        report = backend.sync(self.path, FakeClient(), workers=1)
        self.assertTrue(report["ok"])
        self.assertEqual(report["sources"], {"jira": False, "gitlab": True})
        output = self.path.read_text()
        self.assertIn("TEST-42|👀 To review|🧩 Task|2d↓|🔀 !516 [OK]|✅ 1/1", output)
        self.assertIn("My focus\n- [ ] Personal todo", output)
        self.assertIn("SPRINT|Sprint 25|start|end", output)
        self.assertEqual(report["warnings"], ["Jira authentication failed (HTTP 401)"])

    def test_total_failure_never_rewrites_or_discards_cached_snapshot(self):
        before = self.path.stat().st_mtime_ns
        report = backend.sync(self.path, FakeClient(gitlab=False))
        self.assertFalse(report["ok"])
        self.assertEqual(self.path.read_text(), self.original)
        self.assertEqual(self.path.stat().st_mtime_ns, before)

    def test_successful_jira_retains_mr_fields_when_gitlab_fails(self):
        report = backend.sync(self.path, FakeClient(jira=True, gitlab=False))
        self.assertTrue(report["ok"])
        self.assertEqual(report["sources"], {"jira": True, "gitlab": False})
        output = self.path.read_text()
        self.assertIn("|1d↓|🔀 !516 [FAIL]|🔴 2/15", output)
        self.assertIn("SPRINT|Sprint 26", output)

    def test_confirmed_empty_jira_sprint_clears_only_script_owned_tickets(self):
        client = FakeClient(jira=True)
        client.rows = []
        report = backend.sync(self.path, client)
        self.assertTrue(report["ok"])
        self.assertNotIn("TEST-42", self.path.read_text())
        self.assertIn("- [ ] Personal todo", self.path.read_text())

    def test_atomic_write_keeps_permissions_and_concurrent_personal_note_edits(self):
        client = FakeClient()
        mr = client.mr
        def edit_notes(key, old):
            self.path.write_text(self.path.read_text() + "New personal note during refresh\n")
            return mr(key, old)
        client.mr = edit_notes
        self.path.chmod(0o600)
        backend.sync(self.path, client, workers=1)
        self.assertIn("New personal note during refresh", self.path.read_text())
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])

    def test_ci_uses_mr_head_pipeline_matching_gitlab_widget_not_pipeline_list(self):
        def respond(args):
            path = args[-1]
            if "/discussions?" in path:
                return []
            if "/pipelines" in path:
                self.fail("Must not use an arbitrary historical pipeline list")
            return {"iid": 516, "head_pipeline": {"id": 48142, "status": "success", "source": "merge_request_event"}}
        client, calls = self.client(respond)
        value, error = client.mr("TEST-42", ["TEST-42", "review", "Task", "1d", "!516 [FAIL]", "🔴 2/15"])
        self.assertIsNone(error)
        self.assertEqual(value["mr"], "🔀 !516 [OK]")
        self.assertEqual(value["threads"], "✅")
        self.assertEqual(calls[0][0][:6], ["glab", "api", "--hostname", "gitlab.example.invalid", "-X", "GET"])
        self.assertIn("projects/team%2Frepo/merge_requests/516", calls[0][0][-1])
        self.assertEqual(calls[0][1]["env"]["GITLAB_TOKEN"], "test-credential")
        self.assertEqual(calls[0][1]["env"]["https_proxy"], "http://proxy.invalid:3128")

    def test_unknown_discussions_keep_previous_count_instead_of_false_all_clear(self):
        def respond(args):
            if "/discussions?" in args[-1]:
                return subprocess.CompletedProcess(args, 1, "", "unauthorized")
            return {"iid": 516, "head_pipeline": {"status": "success"}}
        client, _ = self.client(respond)
        value, _ = client.mr("TEST-42", ["TEST-42", "review", "Task", "1d", "!516", "🔴 2/15"])
        self.assertEqual(value["threads"], "🔴 2/15")

    def test_jira_me_cached_login_is_not_treated_as_successful_authentication(self):
        def respond(args):
            if args[1] == "me":
                return subprocess.CompletedProcess(args, 0, "test-user\n", "")
            if args[1] == "sprint":
                return subprocess.CompletedProcess(args, 1, "", "No result found")
            return subprocess.CompletedProcess(args, 1, "", "Login Required: HTTP 401 secret-content")
        client, _ = self.client(respond)
        value, error = client.jira_tickets({"TEST-42": (False, [])})
        self.assertIsNone(value)
        self.assertEqual(error, "Jira authentication failed (HTTP 401)")
        self.assertNotIn("secret-content", error)

    def test_authenticated_sprint_rows_use_supported_columns_and_do_not_need_a_probe(self):
        def respond(args):
            if args[1] == "me":
                return subprocess.CompletedProcess(args, 0, "test-user\n", "")
            if args[1] == "sprint":
                self.assertEqual(args[-1], "key,status,type,created")
                return subprocess.CompletedProcess(args, 0, "TEST-42|To review|Task|2026-01-01\n", "")
            self.fail("Successful sprint query should not require an auth probe")
        client, _ = self.client(respond)
        rows, error = client.jira_tickets({})
        self.assertIsNone(error)
        self.assertEqual(rows, [(False, "TEST-42", "To review", "Task")])

    def test_empty_sprint_requires_successful_issue_probe_before_removing_cached_tickets(self):
        def respond(args):
            if args[1] == "me":
                return subprocess.CompletedProcess(args, 0, "test-user\n", "")
            if args[1] == "sprint":
                return subprocess.CompletedProcess(args, 1, "", "No result found")
            return {"key": "TEST-42", "fields": {"status": {"name": "Done"}}}
        client, _ = self.client(respond)
        rows, error = client.jira_tickets({"TEST-42": (False, [])})
        self.assertIsNone(error)
        self.assertEqual(rows, [])

    def test_inherited_token_never_invokes_or_gets_overwritten_by_pass(self):
        calls = []
        def runner(args, **kwargs):
            calls.append(args)
            raise AssertionError("Credential helper should not be called")
        with patch.dict(os.environ, {"GITLAB_TOKEN": "existing-credential"}, clear=True):
            client = backend.Client("host", "project", None, runner)
        self.assertFalse(calls)
        self.assertEqual(client.env["GITLAB_TOKEN"], "existing-credential")

    def test_shared_readiness_contract(self):
        contract = json.loads((Path(__file__).parent / "fixtures/sprint-review-state.json").read_text())
        for case in contract["readiness"]:
            with self.subTest(case["name"]):
                detail = {**contract["base"], **case["mr"]}
                self.assertEqual(backend.merge_readiness(detail, case["approvals"]), case["expected"])

    def test_shared_approval_count_contract(self):
        contract = json.loads((Path(__file__).parent / "fixtures/sprint-review-state.json").read_text())
        for case in contract["approval_counts"]:
            with self.subTest(case["name"]):
                self.assertEqual(backend.approved_count(case["data"]), case["expected"])

    def test_new_snapshot_columns_append_without_shifting_original_fields(self):
        client = FakeClient()
        original = client.mr
        def mr(key, old):
            value, error = original(key, old)
            value.update(approved="2", ready="yes", merged="–")
            return value, error
        client.mr = mr
        backend.sync(self.path, client, workers=1)
        cols = backend.read_reminder(self.path)[0]["TEST-42"][1]
        self.assertEqual(len(cols), 9)
        self.assertEqual(cols[4:6], ["🔀 !516 [OK]", "✅ 1/1"])
        self.assertEqual(cols[6:], ["2", "yes", "–"])

    def test_real_mr_fields_populate_votes_and_readiness(self):
        def respond(args):
            if args[-1].endswith("/approvals"):
                return {"approved_by": [{"user": {"id": 7}}], "approvals_left": 0, "approved": True}
            if "/discussions?" in args[-1]:
                return []
            return {"iid": 516, "state": "opened", "detailed_merge_status": "mergeable",
                    "target_branch": "release/6.0", "head_pipeline": {"status": "success"}}
        client, _ = self.client(respond)
        value, error = client.mr("TEST-42", ["TEST-42", "review", "Task", "1d", "!516", "✅"])
        self.assertIsNone(error)
        self.assertEqual((value["approved"], value["ready"], value["merged"]), ("1", "yes", "–"))

    def test_merged_target_is_actual_branch_not_assumed_main(self):
        def respond(args):
            if args[-1].endswith("/approvals"):
                return {"approved_by": [], "approvals_left": 0}
            if "/discussions?" in args[-1]:
                return []
            return {"iid": 516, "state": "merged", "target_branch": "feature/TEST-1824_relations",
                    "detailed_merge_status": "not_open"}
        client, _ = self.client(respond)
        value, _ = client.mr("TEST-42", ["TEST-42", "review", "Task", "1d", "!516", "✅"])
        self.assertEqual(value["ready"], "merged")
        self.assertEqual(value["merged"], "feature/TEST-1824_relations")

    def test_unavailable_approvals_keep_cached_count_but_never_cached_ready_yes(self):
        def respond(args):
            if args[-1].endswith("/approvals"):
                return subprocess.CompletedProcess(args, 1, "", "403 Forbidden")
            if "/discussions?" in args[-1]:
                return []
            return {"iid": 516, "state": "opened", "detailed_merge_status": "mergeable"}
        client, _ = self.client(respond)
        value, _ = client.mr("TEST-42", ["TEST-42", "review", "Task", "1d", "!516", "✅", "2", "yes", "–"])
        self.assertEqual(value["approved"], "~2")
        self.assertEqual(value["ready"], "unknown")

    def test_failed_mr_fetch_preserves_merge_history_and_invalidates_readiness(self):
        self.path.write_text(self.original.rstrip() + "|2|yes|release/6.0\n")
        backend.sync(self.path, FakeClient(jira=True, gitlab=False))
        cols = backend.read_reminder(self.path)[0]["TEST-42"][1]
        self.assertEqual(cols[6:], ["~2", "unknown", "release/6.0"])

    def test_no_associated_mr_does_not_invent_merge_state(self):
        client, _ = self.client(lambda _: [])
        value, error = client.mr("TEST-42", [])
        self.assertIsNone(error)
        self.assertEqual((value["approved"], value["ready"], value["merged"]), ("–", "–", "–"))

    def test_review_queue_only_includes_open_assigned_non_authored_mrs(self):
        def mr(iid, author=8, reviewer=7, state="opened"):
            return {"iid": iid, "title": "TEST-42 Review\nrequest", "state": state,
                    "author": {"id": author, "username": "colleague"}, "reviewers": [{"id": reviewer}],
                    "draft": iid == 1, "source_branch": "feature/test", "target_branch": "main"}
        def respond(args):
            path = args[-1]
            self.assertNotEqual(args[0], "jira")
            if path == "user":
                return {"id": 7, "username": "me"}
            if "/commits?" in path:
                return [{"id": "commit-one"}, {"id": "commit-two"}, {"id": "commit-three"}]
            extra = review_metadata(path)
            if extra is not NotImplemented:
                return extra
            self.assertIn("reviewer_id=7", path)
            self.assertIn("scope=all&state=opened", path)
            return [mr(1), mr(2, author=7), mr(3, reviewer=9), mr(4, state="merged"), mr(1)]
        client, calls = self.client(respond)
        report, error = client.reviews()
        self.assertIsNone(error)
        self.assertEqual(len(report["rows"]), 1)
        row = report["rows"][0]
        self.assertEqual((row["iid"], row["title"], row["project"]), (1, "TEST-42 Review request", "team/repo"))
        self.assertEqual((row["ticket"], row["commits"], row["target_branch"]), ("TEST-42", 3, "main"))
        self.assertTrue(row["draft"])
        self.assertEqual(row["web_url"], "https://gitlab.example.invalid/team/repo/-/merge_requests/1")
        self.assertEqual(len(calls), 6)
        self.assertEqual((row["ci"], row["approved"], row["threads"], row["my_threads"]),
                         ("none", 0, {"resolved": 0, "total": 0}, {"resolved": 0, "total": 0}))

    def test_review_queue_fetches_all_api_pages_without_duplicates(self):
        def row(iid):
            return {"iid": iid, "state": "opened", "title": "Review", "author": {"id": 8}, "reviewers": [{"id": 7}]}
        def respond(args):
            if args[-1] == "user":
                return {"id": 7, "username": "me"}
            if "/commits?" in args[-1]:
                return []
            extra = review_metadata(args[-1])
            if extra is not NotImplemented:
                return extra
            if "page=1&" in args[-1]:
                return [row(i) for i in range(1, 101)]
            self.assertIn("page=2&", args[-1])
            return [row(100), row(101)]
        client, _ = self.client(respond)
        report, error = client.reviews()
        self.assertIsNone(error)
        self.assertEqual([r["iid"] for r in report["rows"]], list(range(1, 102)))

    def test_review_failure_on_later_page_does_not_return_partial_success(self):
        def respond(args):
            if args[-1] == "user":
                return {"id": 7, "username": "me"}
            if "page=1&" in args[-1]:
                return [{"iid": i, "state": "opened", "title": "Review", "author": {"id": 8}, "reviewers": [{"id": 7}]} for i in range(1, 101)]
            return subprocess.CompletedProcess(args, 1, "private secret", "401 Unauthorized")
        client, _ = self.client(respond)
        report, error = client.reviews()
        self.assertIsNone(report)
        self.assertEqual(error, "GitLab authentication failed (HTTP 401)")

    def test_empty_and_malformed_review_responses_are_distinct(self):
        client, _ = self.client(lambda args: {"id": 7, "username": "me"} if args[-1] == "user" else [])
        report, error = client.reviews()
        self.assertIsNone(error)
        self.assertEqual(report["rows"], [])
        client, _ = self.client(lambda args: {"id": 7, "username": "me"} if args[-1] == "user" else [{}])
        self.assertEqual(client.reviews(), (None, "GitLab returned invalid review assignments"))
        client, _ = self.client(lambda _: {"message": "401 Unauthorized"})
        self.assertEqual(client.reviews(), (None, "GitLab returned invalid user data"))

    def test_filtered_nonempty_review_batch_can_still_return_empty_queue(self):
        client, _ = self.client(lambda args: {"id": 7, "username": "me"} if args[-1] == "user" else [
            {"iid": 1, "state": "opened", "title": "Review", "author": {"id": 7}, "reviewers": [{"id": 7}]}])
        report, error = client.reviews()
        self.assertIsNone(error)
        self.assertEqual(report["rows"], [])

    def test_commit_count_paginates_and_deduplicates_mr_commits(self):
        def respond(args):
            self.assertIn("/merge_requests/12/commits?", args[-1])
            if args[-1].endswith("page=1"):
                return [{"id": f"sha-{i}"} for i in range(100)]
            self.assertTrue(args[-1].endswith("page=2"))
            return [{"id": "sha-99"}, {"id": "sha-100"}]
        client, calls = self.client(respond)
        self.assertEqual(client.commit_count(12), (101, None))
        self.assertEqual(len(calls), 2)

    def test_commit_count_failure_never_reports_partial_or_false_zero(self):
        def respond(args):
            if args[-1].endswith("page=1"):
                return [{"id": f"sha-{i}"} for i in range(100)]
            return subprocess.CompletedProcess(args, 124, "SECRET", "SECRET")
        client, _ = self.client(respond)
        self.assertEqual(client.commit_count(12), (None, "GitLab request timed out"))
        client, _ = self.client(lambda _: [{}])
        self.assertEqual(client.commit_count(12), (None, "GitLab returned invalid commit data"))
        client, _ = self.client(lambda _: [])
        self.assertEqual(client.commit_count(12), (0, None))

    def test_review_ticket_prefers_title_then_source_branch_without_guessing_from_target(self):
        for title, source, expected in (
                ("TEST-42 fix", "feature/TEST-99_other", "TEST-42"),
                ("Fix behavior", "feature/TEST-99_other", "TEST-99"),
                ("No ticket", "feature/without-ticket", None),
                ("XTEST-42a", "feature/without-ticket", None)):
            with self.subTest(title=title):
                def respond(args):
                    if args[-1] == "user":
                        return {"id": 7, "username": "me"}
                    if "/commits?" in args[-1]:
                        return []
                    extra = review_metadata(args[-1])
                    if extra is not NotImplemented:
                        return extra
                    return [{"iid": 1, "state": "opened", "title": title, "source_branch": source,
                             "target_branch": "feature/TEST-55_target", "author": {"id": 8}, "reviewers": [{"id": 7}]}]
                client, _ = self.client(respond)
                report, error = client.reviews()
                self.assertIsNone(error)
                self.assertEqual(report["rows"][0]["ticket"], expected)
                self.assertEqual(report["rows"][0]["commits"], 0)

    def test_unavailable_commit_count_keeps_assignments_with_unknown_count_and_warning(self):
        def respond(args):
            if args[-1] == "user":
                return {"id": 7, "username": "me"}
            if "/1/commits?" in args[-1]:
                return subprocess.CompletedProcess(args, 1, "SECRET", "403 Forbidden")
            if "/2/commits?" in args[-1]:
                return [{"id": "sha-1"}, {"id": "sha-2"}]
            extra = review_metadata(args[-1])
            if extra is not NotImplemented:
                return extra
            return [{"iid": i, "state": "opened", "title": f"TEST-{i}",
                     "author": {"id": 8}, "reviewers": [{"id": 7}]} for i in (1, 2)]
        client, _ = self.client(respond)
        report, error = client.reviews()
        self.assertIsNone(error)
        self.assertEqual(len(report["rows"]), 2)
        self.assertIsNone(report["rows"][0]["commits"])
        self.assertEqual(report["rows"][1]["commits"], 2)
        self.assertEqual(report["warnings"], ["Commit counts unavailable for 1 MR(s)"])
        self.assertNotIn("SECRET", json.dumps(report))

    def test_review_threads_count_discussions_started_by_me_not_replies(self):
        def note(author, resolved, resolvable=True, system=False):
            return {"author": {"id": author}, "resolved": resolved, "resolvable": resolvable, "system": system}
        discussions = [
            {"id": "mine-open", "notes": [note(7, False), note(8, False)]},
            {"id": "other-replied-by-me", "notes": [note(8, True), note(7, True)]},
            {"id": "mine-resolved", "notes": [note(7, True)]},
            {"id": "plain-comment", "notes": [note(7, False, resolvable=False)]},
            {"id": "system", "notes": [note(7, False, resolvable=False, system=True)]},
        ]
        client, calls = self.client(lambda _: discussions)
        total, mine, error = client.review_threads(12, 7)
        self.assertIsNone(error)
        self.assertEqual(total, {"resolved": 2, "total": 3})
        self.assertEqual(mine, {"resolved": 1, "total": 2})
        self.assertIn("/merge_requests/12/discussions?per_page=100&page=1", calls[0][0][-1])

    def test_review_discussions_are_paginated_and_never_report_partial_clear(self):
        def discussion(i):
            return {"id": f"d-{i}", "notes": [{"resolvable": True, "resolved": True, "author": {"id": 7}}]}
        def respond(args):
            return [discussion(i) for i in range(100)] if args[-1].endswith("page=1") else [discussion(99), discussion(100)]
        client, _ = self.client(respond)
        total, mine, error = client.review_threads(12, 7)
        self.assertIsNone(error)
        self.assertEqual(total, {"resolved": 101, "total": 101})
        self.assertEqual(mine, total)
        client, _ = self.client(lambda args: [discussion(i) for i in range(100)] if args[-1].endswith("page=1")
                                else subprocess.CompletedProcess(args, 124, "SECRET", "SECRET"))
        self.assertEqual(client.review_threads(12, 7), (None, None, "GitLab request timed out"))
        client, _ = self.client(lambda _: [])
        self.assertEqual(client.review_threads(12, 7), ({"resolved": 0, "total": 0}, {"resolved": 0, "total": 0}, None))

    def test_missing_thread_authors_only_make_personal_ownership_unknown(self):
        client, _ = self.client(lambda _: [{"id": "unknown-owner", "notes": [{"resolvable": True, "resolved": False}]}])
        total, mine, error = client.review_threads(12, 7)
        self.assertEqual(total, {"resolved": 0, "total": 1})
        self.assertIsNone(mine)
        self.assertEqual(error, "Thread authors unavailable")
        client, _ = self.client(lambda _: [{"id": "bad-resolution", "notes": [{"resolvable": True, "resolved": "yes"}]}])
        self.assertEqual(client.review_threads(12, 7), (None, None, "GitLab returned invalid discussion resolution"))

    def test_review_metadata_uses_head_pipeline_unique_approvers_and_current_user(self):
        def respond(args):
            path = args[-1]
            self.assertNotIn("/pipelines", path)
            if path == "user":
                return {"id": 7, "username": "me"}
            if "/commits?" in path:
                return [{"id": "sha-one"}]
            if path.endswith("/approvals"):
                return {"approved_by": [{"user": {"id": 8}}, {"user": {"id": 8}}, {"user": {"id": 9}}], "approvals_left": 2}
            if "/discussions?" in path:
                return [
                    {"id": "mine", "notes": [{"resolvable": True, "resolved": False, "author": {"id": 7}}]},
                    {"id": "other", "notes": [
                        {"resolvable": True, "resolved": True, "author": {"id": 8}},
                        {"resolvable": True, "resolved": True, "author": {"id": 7}}]},
                ]
            if path.endswith("/12"):
                return {"iid": 12, "head_pipeline": {"status": "failed", "id": 99}}
            return [{"iid": 12, "state": "opened", "title": "TEST-12", "author": {"id": 8},
                     "reviewers": [{"id": 7}], "head_pipeline": {"status": "success"}}]
        client, _ = self.client(respond)
        report, error = client.reviews()
        self.assertIsNone(error)
        row = report["rows"][0]
        self.assertEqual((row["ci"], row["approved"], row["commits"]), ("failed", 2, 1))
        self.assertEqual((row["my_approved"], row["other_approvals"]), (False, 2))
        self.assertEqual(row["threads"], {"resolved": 1, "total": 2})
        self.assertEqual(row["my_threads"], {"resolved": 0, "total": 1})
        self.assertFalse(report["warnings"])

    def test_failed_review_metadata_stays_unknown_without_discarding_assignments(self):
        def respond(args):
            path = args[-1]
            if path == "user":
                return {"id": 7, "username": "me"}
            if "/commits?" in path:
                return []
            if path.endswith("/approvals"):
                return {"approved_by": "invalid"}
            if path.endswith("/12") or "/discussions?" in path:
                return subprocess.CompletedProcess(args, 1, "SECRET", "403 Forbidden")
            return [{"iid": 12, "state": "opened", "title": "TEST-12", "author": {"id": 8}, "reviewers": [{"id": 7}]}]
        client, _ = self.client(respond)
        report, error = client.reviews()
        self.assertIsNone(error)
        row = report["rows"][0]
        self.assertEqual(row["commits"], 0)
        for field in ("ci", "approved", "my_approved", "other_approvals", "threads", "my_threads"):
            self.assertIsNone(row[field])
        self.assertEqual(len(report["warnings"]), 6)
        self.assertNotIn("SECRET", json.dumps(report))

    def test_confirmed_absence_of_pipeline_differs_from_missing_pipeline_data(self):
        for missing in (False, True):
            def respond(args):
                path = args[-1]
                if path == "user":
                    return {"id": 7, "username": "me"}
                if "/commits?" in path:
                    return []
                if path.endswith("/12"):
                    return {"iid": 12} if missing else {"iid": 12, "head_pipeline": None}
                extra = review_metadata(path)
                if extra is not NotImplemented:
                    return extra
                return [{"iid": 12, "state": "opened", "title": "TEST-12", "author": {"id": 8}, "reviewers": [{"id": 7}]}]
            client, _ = self.client(respond)
            report, _ = client.reviews()
            self.assertEqual(report["rows"][0]["ci"], None if missing else "none")
            self.assertEqual(bool(report["warnings"]), missing)

    def test_personal_approvals_exclude_me_from_distinct_other_count(self):
        approvals = {"approved_by": [
            {"user": {"id": 7}}, {"user": {"id": 7}},
            {"user": {"id": 8}}, {"user": {"id": 8}}, {"user": {"id": 9}},
        ]}
        self.assertEqual(backend.personal_approvals(approvals, 7), (True, 2))
        self.assertEqual(backend.personal_approvals(approvals, 12), (False, 3))
        self.assertEqual(backend.personal_approvals({"approved_by": []}, 7), (False, 0))

    def test_personal_approvals_do_not_guess_from_display_names_or_failures(self):
        self.assertEqual(backend.personal_approvals(None, 7), (None, None))
        self.assertEqual(backend.personal_approvals({"approved_by": "bad"}, 7), (None, None))
        self.assertEqual(backend.personal_approvals({"approved_by": [{"user": {"name": "Me"}}]}, 7), (None, None))
        value = {"approved_by": [{"user": {"id": 7}}, {"user": {"name": "Unknown"}}]}
        self.assertEqual(backend.personal_approvals(value, 7), (True, None))

    def test_no_implicit_credential_helper_and_no_gitlab_calls_in_jira_only_mode(self):
        def forbidden(*args, **kwargs):
            self.fail("No credential/API call should occur")
        with patch.dict(os.environ, {}, clear=True):
            client = backend.Client("gitlab.example.invalid", "example/project", None, forbidden)
            self.assertNotIn("GITLAB_TOKEN", client.env)
            jira_only = backend.Client("gitlab.example.invalid", "", None, forbidden,
                                       token_command=["secret-helper", "example"], gitlab_enabled=False)
        self.assertEqual(jira_only.mr("TEST-1", []), (None, None))

    def test_explicit_credential_helper_is_argv_and_only_runs_when_needed(self):
        calls = []
        def runner(args, **opts):
            calls.append(args)
            return subprocess.CompletedProcess(args, 0, "fixture-secret\n", "")
        with patch.dict(os.environ, {}, clear=True):
            client = backend.Client("gitlab.example.invalid", "example/project", None, runner,
                                    token_command=["secret-helper", "example"])
        self.assertEqual(calls, [["secret-helper", "example"]])
        self.assertEqual(client.env["GITLAB_TOKEN"], "fixture-secret")

    def test_timeout_and_missing_cli_are_safe_sanitized_errors(self):
        client, _ = self.client(lambda _: {})
        client.runner = lambda *a, **k: (_ for _ in ()).throw(subprocess.TimeoutExpired(a[0], 1))
        result = client.run(["jira", "me"])
        self.assertEqual(backend.error_reason("Jira", result), "Jira request timed out")
        client.runner = lambda *a, **k: (_ for _ in ()).throw(FileNotFoundError())
        self.assertEqual(client.run(["jira"]).returncode, 127)


if __name__ == "__main__":
    unittest.main()
