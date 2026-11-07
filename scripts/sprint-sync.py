#!/usr/bin/env python3
"""Refresh Jira/GitLab independently; never discard cached data on API failure."""
import argparse
import concurrent.futures
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import quote

KEY = re.compile(r"^[A-Z][A-Z0-9]*-\d+\b")
TICKET_KEY = re.compile(r"(?<![A-Za-z0-9])([A-Z][A-Z0-9]*-\d+)(?![A-Za-z0-9])")
TODO = re.compile(r"^-\s*\[([ xX])\]\s*(.*)$")
STATUS_ICONS = {"done": "✅", "in progress": "🚧", "to do": "📋", "to review": "👀", "in review": "👀", "blocked": "🚫"}
TYPE_ICONS = {"bug": "🐛", "task": "🧩", "sub-task": "🔗", "subtask": "🔗", "story": "📖", "epic": "📦"}
CI = {"success": "[OK]", "failed": "[FAIL]", "running": "[RUN]", "pending": "[WAIT]", "preparing": "[WAIT]", "created": "[WAIT]", "skipped": "[SKIP]", "canceled": "[CANCEL]", "manual": "[MANUAL]"}


def approved_count(approvals):
    """Count distinct approvers, not how many rules one person satisfies."""
    if not isinstance(approvals, dict) or not isinstance(approvals.get("approved_by"), list):
        return None
    users = set()
    for entry in approvals["approved_by"]:
        user = entry.get("user") if isinstance(entry, dict) else None
        if not isinstance(user, dict):
            return None
        identity = next(((key, str(user[key])) for key in ("id", "username", "name") if user.get(key) is not None), None)
        if identity is None:
            return None
        users.add(identity)
    return len(users)


def personal_approvals(approvals, user_id):
    """My approval and the distinct other approvers; never guess from names."""
    if approved_count(approvals) is None:
        return None, None
    users, complete = set(), True
    for entry in approvals["approved_by"]:
        identity = entry["user"].get("id")
        if type(identity) is int:
            users.add(identity)
        else:
            complete = False
    mine = user_id in users
    if not complete:
        return True if mine else None, None
    return mine, len(users - {user_id})


def merge_readiness(detail, approvals):
    """Positive only when GitLab's full merge checks AND approval policy agree.

    Legacy merge_status alone only proves absence of conflicts. A green CI or
    an arbitrary number of votes does not prove that the required rules passed.
    """
    state = detail.get("state")
    if state == "merged":
        return "merged"
    if state == "closed":
        return "closed"
    if state != "opened":
        return "unknown"
    if detail.get("draft") is True or detail.get("work_in_progress") is True:
        return "draft"
    if detail.get("has_conflicts") is True:
        return "conflict"
    if detail.get("blocking_discussions_resolved") is False:
        return "threads"
    if (detail.get("user") or {}).get("can_merge") is False:
        return "permissions"
    status = detail.get("detailed_merge_status")
    blockers = {
        "not_approved": "approvals", "discussions_not_resolved": "threads",
        "ci_must_pass": "ci", "ci_still_running": "ci", "conflict": "conflict",
        "need_rebase": "rebase", "draft_status": "draft", "requested_changes": "changes",
        "merge_time": "scheduled",
    }
    if status in blockers:
        return blockers[status]
    if status in ("checking", "unchecked", "preparing", "approvals_syncing"):
        return "checking"
    if status != "mergeable":
        return "blocked" if status else "unknown"
    if not isinstance(approvals, dict):
        return "unknown"
    left = approvals.get("approvals_left")
    valid_left = isinstance(left, (int, float)) and not isinstance(left, bool) and left >= 0
    if approvals.get("approved") is False or (valid_left and left > 0):
        return "approvals"
    if approvals.get("approved") is True or (valid_left and left == 0):
        return "yes"
    return "unknown"


def cached_approved(cols):
    value = cols[6].lstrip("~") if len(cols) > 6 else ""
    return "~" + value if value.isdigit() else "?"


def error_reason(service, result):
    text = (result.stderr or "").lower()
    if "401" in text or "login required" in text or "unauthorized" in text:
        return f"{service} authentication failed (HTTP 401)"
    if "403" in text or "forbidden" in text:
        return f"{service} permission denied (HTTP 403)"
    if result.returncode == 124:
        return f"{service} request timed out"
    return f"{service} query unavailable"


class Client:
    def __init__(self, host, project, proxy, runner=subprocess.run, token_command=None, gitlab_enabled=True, jira_project=None):
        self.host, self.project, self.runner = host, quote(project, safe=""), runner
        self.project_path = project
        self.jira_project = jira_project
        self.gitlab_enabled = gitlab_enabled
        self.env = dict(os.environ)
        if proxy:
            self.env["https_proxy"] = proxy
        # Keep a valid inherited token. The old script overwrote it with an
        # empty/older pass result, silently losing all GitLab enrichment.
        if gitlab_enabled and token_command and not any(self.env.get(k) for k in ("GITLAB_TOKEN", "GITLAB_ACCESS_TOKEN", "GLAB_TOKEN")):
            credential = self.run(token_command, timeout=5)
            if credential.returncode == 0 and credential.stdout.strip():
                self.env["GITLAB_TOKEN"] = credential.stdout.strip().splitlines()[0]

    def run(self, args, timeout=15, gitlab=False):
        if args[0] == "jira" and self.jira_project:
            args = [*args, "--project", self.jira_project]
        try:
            return self.runner(args, capture_output=True, text=True, timeout=timeout,
                               env=self.env if gitlab else None)
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess(args, 124, "", "")
        except OSError:
            return subprocess.CompletedProcess(args, 127, "", "")

    def jira_issue(self, key):
        result = self.run(["jira", "issue", "view", key, "--raw"])
        try:
            value = json.loads(result.stdout)
            if result.returncode == 0 and value.get("key") == key and isinstance(value.get("fields"), dict):
                return value["fields"], None
        except (ValueError, AttributeError):
            pass
        return None, error_reason("Jira", result)

    def jira_tickets(self, cached):
        me = self.run(["jira", "me"], timeout=10)
        if me.returncode != 0 or not me.stdout.strip():
            return None, error_reason("Jira", me)
        result = self.run(["jira", "sprint", "list", "--current", "--jql", "assignee = currentUser()",
                           "--plain", "--no-headers", "--no-truncate", "--delimiter", "|",
                           "--columns", "key,status,type,created"])
        rows = []
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                cols = [part.strip() for part in line.split("|")]
                if len(cols) >= 4 and KEY.fullmatch(cols[0]):
                    if self.jira_project and not cols[0].startswith(self.jira_project + "-"):
                        return None, "Jira returned tickets from another project"
                    rows.append((cols[1].lower() == "done", cols[0], cols[1], cols[2]))
            if rows:
                return rows, None
        # jira-cli can mask a 401 as "No result found". `jira me` is only the
        # cached configured login, NOT proof of valid authentication.
        if cached:
            _, probe_error = self.jira_issue(next(iter(cached)))
            if probe_error:
                return None, probe_error
            if "no result found" in (result.stderr or "").lower() or result.returncode == 0:
                return [], None
        return None, error_reason("Jira", result)

    def sprint(self):
        result = self.run(["jira", "sprint", "list", "--state", "active", "--plain", "--no-headers",
                           "--columns", "name,start,end"])
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                parts = [s.strip() for s in line.split("\t")]
                if len(parts) >= 3 and all(parts[:3]):
                    name = re.match(r"Sprint\s+\d+", parts[0])
                    return "SPRINT|" + "|".join([name[0] if name else parts[0], *parts[1:3]])
        return None

    def api(self, path):
        result = self.run(["glab", "api", "--hostname", self.host, "-X", "GET", path], timeout=12, gitlab=True)
        if result.returncode == 0:
            try:
                return json.loads(result.stdout), None
            except ValueError:
                pass
        return None, error_reason("GitLab", result)

    def commit_count(self, iid):
        """Count the MR's commits, not changed files or project history."""
        seen = set()
        for page in range(1, 51):
            commits, error = self.api(f"projects/{self.project}/merge_requests/{iid}/commits?per_page=100&page={page}")
            if error or not isinstance(commits, list):
                return None, error or "GitLab returned invalid commit data"
            for commit in commits:
                if not isinstance(commit, dict) or not isinstance(commit.get("id"), str) or not commit["id"]:
                    return None, "GitLab returned invalid commit data"
                seen.add(commit["id"])
            if len(commits) < 100:
                return len(seen), None
        return None, "Commit pagination limit reached"

    def review_threads(self, iid, user_id):
        """Resolved/total resolvable discussions, and the subset started by me.

        Replies do not create ownership. An incomplete discussions page makes
        both counts unknown; missing root authors only make my count unknown.
        """
        total = {"resolved": 0, "total": 0}
        mine = {"resolved": 0, "total": 0}
        seen, ownership_known = set(), True
        for page in range(1, 51):
            discussions, error = self.api(f"projects/{self.project}/merge_requests/{iid}/discussions?per_page=100&page={page}")
            if error or not isinstance(discussions, list):
                return None, None, error or "GitLab returned invalid discussion data"
            for discussion in discussions:
                if (not isinstance(discussion, dict) or not isinstance(discussion.get("id"), str)
                        or not discussion["id"] or not isinstance(discussion.get("notes"), list)
                        or not discussion["notes"]):
                    return None, None, "GitLab returned invalid discussion data"
                if discussion["id"] in seen:
                    continue
                seen.add(discussion["id"])
                notes = discussion["notes"]
                if any(not isinstance(n, dict) or type(n.get("resolvable")) is not bool
                       or ("system" in n and type(n["system"]) is not bool) for n in notes):
                    return None, None, "GitLab returned invalid discussion data"
                resolvable = [n for n in notes if n["resolvable"] and not n.get("system")]
                if not resolvable:
                    continue
                if any(type(n.get("resolved")) is not bool for n in resolvable):
                    return None, None, "GitLab returned invalid discussion resolution"
                resolved = int(all(n["resolved"] for n in resolvable))
                total["total"] += 1
                total["resolved"] += resolved
                root = next((n for n in notes if not n.get("system")), {})
                author = root.get("author")
                if not isinstance(author, dict) or type(author.get("id")) is not int:
                    ownership_known = False
                elif author["id"] == user_id:
                    mine["total"] += 1
                    mine["resolved"] += resolved
            if len(discussions) < 100:
                return total, mine if ownership_known else None, None if ownership_known else "Thread authors unavailable"
        return None, None, "Discussion pagination limit reached"

    def reviews(self):
        """Complete open-review assignment snapshot, independent of Jira.

        UI pagination is local, so a failed later API page must never replace a
        complete cached list with a partial one. MR metadata is fetched by at
        most six workers; failed individual fields stay unknown, never zero.
        """
        def clean(value):
            return re.sub(r"[\x00-\x1f\x7f]", " ", str(value or ""))

        user, error = self.api("user")
        if (error or not isinstance(user, dict) or type(user.get("id")) is not int
                or not isinstance(user.get("username"), str) or not user["username"]):
            return None, error or "GitLab returned invalid user data"
        rows, seen = [], set()
        for page in range(1, 51):
            path = (f"projects/{self.project}/merge_requests?scope=all&state=opened"
                    f"&reviewer_id={user['id']}&per_page=100&page={page}&order_by=updated_at&sort=desc")
            batch, error = self.api(path)
            if error or not isinstance(batch, list):
                return None, error or "GitLab returned invalid review assignments"
            for mr in batch:
                if (not isinstance(mr, dict) or type(mr.get("iid")) is not int or mr["iid"] < 1
                        or not isinstance(mr.get("reviewers"), list) or not isinstance(mr.get("author"), dict)
                        or type(mr["author"].get("id")) is not int or not isinstance(mr.get("state"), str)
                        or not isinstance(mr.get("title"), str)):
                    return None, "GitLab returned invalid review assignments"
                # Defence in depth: do not show unrelated or self-authored MRs
                # even if a server/proxy ignores the reviewer filter.
                if (mr.get("state") != "opened" or mr["author"].get("id") == user["id"]
                        or not any(isinstance(r, dict) and type(r.get("id")) is int and r["id"] == user["id"] for r in mr["reviewers"])):
                    continue
                if mr["iid"] in seen:
                    continue
                seen.add(mr["iid"])
                rows.append({
                    "iid": mr["iid"], "title": clean(mr.get("title")),
                    "author": clean(mr["author"].get("username") or mr["author"].get("name")),
                    "draft": bool(mr.get("draft") or mr.get("work_in_progress")),
                    "source_branch": clean(mr.get("source_branch")),
                    "target_branch": clean(mr.get("target_branch")),
                    "ticket": next((match[1] for value in (mr.get("title"), mr.get("source_branch"))
                                    if isinstance(value, str) and (match := TICKET_KEY.search(value))), None),
                    "updated_at": clean(mr.get("updated_at")),
                    "project": self.project_path,
                    "web_url": f"https://{self.host}/{self.project_path}/-/merge_requests/{mr['iid']}",
                })
            if len(batch) < 100:
                break
        else:
            return None, "Review assignment pagination limit reached; keeping cached list"

        def enrich(row):
            row["commits"], _ = self.commit_count(row["iid"])
            root = f"projects/{self.project}/merge_requests/{row['iid']}"
            detail, error = self.api(root)
            row["ci"] = None
            if not error and isinstance(detail, dict) and str(detail.get("iid")) == str(row["iid"]):
                pipeline = detail.get("head_pipeline")
                if "head_pipeline" in detail and pipeline is None:
                    row["ci"] = "none"  # confirmed absence is not an API failure
                elif isinstance(pipeline, dict) and isinstance(pipeline.get("status"), str):
                    row["ci"] = clean(pipeline["status"]) or None
            approvals, error = self.api(root + "/approvals")
            row["approved"] = approved_count(approvals) if not error else None
            row["my_approved"], row["other_approvals"] = personal_approvals(approvals, user["id"]) if not error else (None, None)
            row["threads"], row["my_threads"], _ = self.review_threads(row["iid"], user["id"])

        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(enrich, rows))
        warnings = []
        for field, label in (("commits", "Commit counts"), ("ci", "CI status"), ("approved", "Approval counts"),
                             ("my_approved", "My approval"), ("other_approvals", "Other approvals"),
                             ("threads", "Thread counts"), ("my_threads", "My thread counts")):
            unknown = sum(row[field] is None for row in rows)
            if unknown:
                warnings.append(f"{label} unavailable for {unknown} MR(s)")
        return {"version": 1, "ok": True,
                "user": {"id": user["id"], "username": clean(user["username"])},
                "rows": rows, "warnings": warnings}, None

    def mr(self, key, old_cols):
        if not self.gitlab_enabled:
            return None, None
        old_iid = re.search(r"!(\d+)", old_cols[4]) if len(old_cols) > 4 else None
        root = f"projects/{self.project}/merge_requests"
        iid = old_iid[1] if old_iid else None
        if not iid:
            found, error = self.api(f"{root}?search={quote(key)}&in=title&state=all&per_page=20&order_by=created_at&sort=desc")
            if error or not isinstance(found, list):
                return None, error or "GitLab returned invalid MR data"
            exact = re.compile(r"(?<![A-Za-z0-9])" + re.escape(key) + r"(?![A-Za-z0-9])")
            matches = [mr for mr in found if exact.search(mr.get("title", "")) or exact.search(mr.get("source_branch", ""))]
            matches.sort(key=lambda mr: mr.get("state") != "opened")
            if not matches:
                return {"mr": "–", "threads": "–", "approved": "–", "ready": "–", "merged": "–"}, None
            iid = str(matches[0]["iid"])
        detail, error = self.api(f"{root}/{iid}")
        if error or not isinstance(detail, dict) or str(detail.get("iid")) != iid:
            return None, error or "GitLab returned invalid MR details"
        # Match the GitLab MR widget, including merged-result pipelines. The
        # first pipeline in a list need not be the MR's current head pipeline.
        pipeline = detail.get("head_pipeline") or {}
        status = CI.get(pipeline.get("status"), "[?]")
        approvals, _ = self.api(f"{root}/{iid}/approvals")
        count = approved_count(approvals)
        approved = str(count) if count is not None else cached_approved(old_cols)
        ready = merge_readiness(detail, approvals)
        merged = "–"
        if detail.get("state") == "merged":
            # Keep the actual target, not a guessed main/develop branch. Avoid
            # introducing separators/control characters into the pipe snapshot.
            target = detail.get("target_branch")
            merged = target.replace("|", "∣").replace("\r", " ").replace("\n", " ") if isinstance(target, str) and target else "?"
        thread_col = old_cols[5] if len(old_cols) > 5 else "–"
        resolved, total, page = 0, 0, 1
        while True:
            discussions, discussion_error = self.api(f"{root}/{iid}/discussions?per_page=100&page={page}")
            if discussion_error or not isinstance(discussions, list):
                break  # Unknown is never presented as zero open discussions.
            for discussion in discussions:
                notes = [n for n in discussion.get("notes", []) if n.get("resolvable")]
                if notes:
                    total += 1
                    resolved += int(all(n.get("resolved") for n in notes))
            if len(discussions) < 100:
                thread_col = ("✅" if resolved == total else "🔴") + (f" {resolved}/{total}" if total else "")
                break
            page += 1
            if page > 50:
                break
        return {"mr": f"🔀 !{iid} {status}", "threads": thread_col,
                "approved": approved, "ready": ready, "merged": merged}, None


def read_reminder(path):
    try:
        lines = path.read_text().splitlines()
    except FileNotFoundError:
        lines = []
    cached, personal, sprint = {}, [], None
    for line in lines:
        match = TODO.match(line.strip())
        if line.startswith("SPRINT|"):
            sprint = line
        elif match and KEY.match(match[2]):
            cols = match[2].split("|")
            cached[cols[0]] = (match[1].lower() == "x", cols)
        elif not re.match(r"^synced \d\d:\d\d$", line.strip()):
            personal.append(line)
    return cached, personal, sprint


def sync(reminder, client, workers=6):
    reminder = Path(reminder)
    cached, _, old_sprint = read_reminder(reminder)
    tickets, jira_error = client.jira_tickets(cached)
    jira_ok = tickets is not None
    warnings = [jira_error] if jira_error else []
    sprint = client.sprint() if jira_ok else old_sprint
    sprint = sprint or old_sprint
    if not jira_ok:
        tickets = [(done, key, None, None) for key, (done, _) in cached.items()]
    if not tickets and not jira_ok:
        return {"version": 1, "ok": False, "sources": {"jira": False, "gitlab": False}, "warnings": warnings}

    def enrich(ticket):
        done, key, status, kind = ticket
        old = cached.get(key, (False, []))[1]
        detail_error = None
        if jira_ok:
            fields, detail_error = client.jira_issue(key)
            tracking = (fields or {}).get("timetracking") or {}
            if tracking.get("remainingEstimate"):
                time = tracking["remainingEstimate"] + "↓"
            elif tracking.get("timeSpent"):
                time = tracking["timeSpent"] + "✓"
            else:
                time = tracking.get("originalEstimate")
            cols = [key, STATUS_ICONS.get(status.lower(), "▪") + " " + status,
                    TYPE_ICONS.get(kind.lower(), "▪") + " " + kind, time or (old[3] if len(old) > 3 else "--")]
        else:
            cols = (old + ["–"] * 4)[:4]
        mr, mr_error = client.mr(key, old)
        # Columns 1–6 stay compatible with old reminders. Append approvals,
        # readiness, and the merged target. Never retain a cached positive
        # readiness verdict when fresh GitLab checks cannot be verified.
        if mr:
            cols.extend([mr["mr"], mr["threads"], mr.get("approved", "?"),
                         mr.get("ready", "unknown"), mr.get("merged", "–")])
        else:
            previous = (old + ["–"] * 9)
            cols.extend([previous[4], previous[5], cached_approved(old), "unknown", previous[8]])
        return done, cols, mr is not None, mr_error, detail_error

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        enriched = list(pool.map(enrich, tickets))
    gitlab_ok = any(row[2] for row in enriched)
    for _, _, _, mr_error, detail_error in enriched:
        for error in (mr_error, detail_error):
            if error and error not in warnings:
                warnings.append(error)
    if not jira_ok and not gitlab_ok:
        return {"version": 1, "ok": False, "sources": {"jira": False, "gitlab": False}, "warnings": warnings}
    # Re-read personal notes immediately before an atomic write, so edits made
    # during the network requests are not lost. Preserve cached fields on error.
    _, personal, _ = read_reminder(reminder)
    output = ([sprint] if sprint else []) + personal + ["synced " + dt.datetime.now().strftime("%H:%M")]
    for done, cols, *_ in enriched:
        output.append(f"- [{'x' if done else ' '}] " + "|".join(cols))
    reminder.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=reminder.parent, delete=False) as handle:
        temp = handle.name
        try:
            handle.write("\n".join(output) + "\n")
            handle.flush()
            if reminder.exists():
                os.chmod(temp, reminder.stat().st_mode & 0o777)
            os.replace(temp, reminder)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)
    return {"version": 1, "ok": True, "sources": {"jira": jira_ok, "gitlab": gitlab_ok}, "warnings": warnings}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reminder", help="Explicit snapshot path (required unless --reviews)")
    parser.add_argument("--host", default=os.environ.get("GITLAB_HOST", "gitlab.com"))
    parser.add_argument("--project", default="")
    parser.add_argument("--jira-project", help="Explicit Jira project key, independent of the GitLab project")
    parser.add_argument("--no-gitlab", action="store_true", help="Jira-only mode; no GitLab/credential calls")
    parser.add_argument("--token-command", type=json.loads, help="Optional JSON argv credential helper; never a token value")
    parser.add_argument("--reviews", action="store_true", help="Read-only JSON list of MRs assigned to me for review")
    parser.add_argument("--proxy", default=os.environ.get("SPRINT_GITLAB_PROXY", ""))
    args = parser.parse_args()
    if args.jira_project and not re.fullmatch(r"[A-Z][A-Z0-9_]*", args.jira_project):
        parser.error("Invalid Jira project key")
    if not args.reviews and not args.reminder:
        parser.error("--reminder is required for snapshot writes")
    if not args.no_gitlab and not args.project:
        parser.error("--project is required when GitLab is enabled")
    if args.reviews and args.no_gitlab:
        parser.error("--reviews requires GitLab")
    if args.token_command is not None and (not isinstance(args.token_command, list) or not args.token_command
            or not all(isinstance(value, str) and value for value in args.token_command)):
        parser.error("--token-command must be a nonempty JSON string array")
    try:
        client = Client(args.host, args.project, args.proxy, token_command=args.token_command, gitlab_enabled=not args.no_gitlab, jira_project=args.jira_project)
        if args.reviews:
            report, error = client.reviews()
            report = report or {"version": 1, "ok": False, "warnings": [error]}
        else:
            report = sync(args.reminder, client)
    except Exception:
        # Never log CLI output or exception strings that could contain secrets.
        report = {"version": 1, "ok": False, "warnings": ["Sprint sync failed before completion"]}
    print(json.dumps(report))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
