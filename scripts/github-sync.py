#!/usr/bin/env python3
"""Read-only GitHub issues/review requests through gh; never write a partial list."""
import argparse
import concurrent.futures
import json
import re
import subprocess
from urllib.parse import urlencode


def clean(value):
    return re.sub(r"[\x00-\x1f\x7f]", " ", value) if isinstance(value, str) else ""


def integer(value):
    return type(value) is int and value >= 0


class GitHub:
    def __init__(self, project, runner=subprocess.run):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", project) or any(p in (".", "..") for p in project.split("/")):
            raise ValueError("Invalid GitHub repository")
        self.project, self.runner = project, runner

    def request(self, path, fields=None):
        args = ["gh", "api", "--hostname", "github.com", "--method", "POST" if fields else "GET", path]
        if fields:
            for key, value in fields.items():
                args.extend(["-F" if type(value) is int else "-f", f"{key}={value}"])
        try:
            result = self.runner(args, capture_output=True, text=True, timeout=12)
            if result.returncode == 0:
                value = json.loads(result.stdout)
                if not (isinstance(value, dict) and value.get("errors")):
                    return value, None
            text = (result.stderr or "").lower()
            reason = ("authentication failed (HTTP 401)" if any(v in text for v in ("401", "login", "unauthorized"))
                      else "permission denied (HTTP 403)" if "403" in text or "forbidden" in text
                      else "query unavailable")
            return None, "GitHub " + reason
        except subprocess.TimeoutExpired:
            return None, "GitHub request timed out"
        except (OSError, ValueError):
            return None, "GitHub CLI or response unavailable"

    def pages(self, path):
        rows = []
        for page in range(1, 51):
            batch, error = self.request(path + "?" + urlencode({"per_page": 100, "page": page}))
            if error or not isinstance(batch, list):
                return None
            rows.extend(batch)
            if len(batch) < 100:
                return rows
        return None

    def approvals(self, number, username):
        reviews = self.pages(f"repos/{self.project}/pulls/{number}/reviews")
        if reviews is None:
            return None, None, None
        latest = {}
        for review in reviews:
            if (not isinstance(review, dict) or not isinstance(review.get("user"), dict)
                    or not isinstance(review["user"].get("login"), str) or not integer(review.get("id"))
                    or review.get("state") not in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED", "COMMENTED", "PENDING")):
                return None, None, None
            if review["state"] in ("COMMENTED", "PENDING"):
                continue
            login = review["user"]["login"].lower()
            if login not in latest or review["id"] > latest[login][0]:
                latest[login] = (review["id"], review["state"])
        approved = {login for login, (_, state) in latest.items() if state == "APPROVED"}
        return len(approved), username.lower() in approved, len(approved - {username.lower()})

    def ci(self, sha):
        if not isinstance(sha, str) or not re.fullmatch(r"[a-fA-F0-9]{40,64}", sha):
            return None
        status, error = self.request(f"repos/{self.project}/commits/{sha}/status")
        checks, check_error = self.request(f"repos/{self.project}/commits/{sha}/check-runs?per_page=100")
        if (error or check_error or not isinstance(status, dict) or not integer(status.get("total_count"))
                or not isinstance(checks, dict) or not integer(checks.get("total_count"))
                or not isinstance(checks.get("check_runs"), list) or checks["total_count"] != len(checks["check_runs"])):
            return None
        states = []
        if status["total_count"]:
            if status.get("state") not in ("success", "pending", "failure", "error"):
                return None
            states.append({"success": "success", "pending": "pending", "failure": "failed", "error": "failed"}[status["state"]])
        for check in checks["check_runs"]:
            if not isinstance(check, dict):
                return None
            if check.get("status") in ("queued", "in_progress", "waiting", "pending", "requested"):
                states.append("running")
            elif check.get("status") == "completed":
                conclusion = check.get("conclusion")
                if conclusion in ("success", "neutral", "skipped"):
                    states.append("success")
                elif conclusion in ("failure", "cancelled", "timed_out", "action_required", "startup_failure", "stale"):
                    states.append("failed")
                else:
                    return None
            else:
                return None
        return next((s for s in ("failed", "running", "pending") if s in states), "success" if states else "none")

    def threads(self, number, username):
        # This is a read-only GraphQL query, never a mutation. Root comments,
        # not replies, determine ownership of a review thread.
        query = """query($owner:String!,$name:String!,$number:Int!,$cursor:String){
          repository(owner:$owner,name:$name){pullRequest(number:$number){
            reviewThreads(first:100,after:$cursor){nodes{isResolved comments(first:1){nodes{author{login}}}}
              pageInfo{hasNextPage endCursor}}
          }}
        }"""
        owner, name = self.project.split("/")
        fields = {"query": query, "owner": owner, "name": name, "number": number}
        total, mine, known, cursors = {"resolved": 0, "total": 0}, {"resolved": 0, "total": 0}, True, set()
        for _ in range(50):
            data, error = self.request("graphql", fields)
            try:
                threads = data["data"]["repository"]["pullRequest"]["reviewThreads"]
                if error or not isinstance(threads["nodes"], list) or type(threads["pageInfo"]["hasNextPage"]) is not bool:
                    return None, None
                for thread in threads["nodes"]:
                    if type(thread["isResolved"]) is not bool:
                        return None, None
                    total["total"] += 1
                    total["resolved"] += int(thread["isResolved"])
                    comments = thread["comments"]["nodes"]
                    author = comments[0].get("author") if comments else None
                    if not isinstance(author, dict) or not isinstance(author.get("login"), str):
                        known = False
                    elif author["login"].lower() == username.lower():
                        mine["total"] += 1
                        mine["resolved"] += int(thread["isResolved"])
                if not threads["pageInfo"]["hasNextPage"]:
                    return total, mine if known else None
                cursor = threads["pageInfo"]["endCursor"]
                if not isinstance(cursor, str) or not cursor or cursor in cursors:
                    return None, None
                cursors.add(cursor)
                fields["cursor"] = cursor
            except (TypeError, KeyError, IndexError, AttributeError):
                return None, None
        return None, None

    def queue(self, kind):
        user, error = self.request("user")
        if error or not isinstance(user, dict) or not isinstance(user.get("login"), str) or not user["login"]:
            return None, error or "GitHub returned invalid user data"
        username = user["login"]
        if not re.fullmatch(r"[A-Za-z0-9-]+", username):
            return None, "GitHub returned invalid username"
        qualifier = f"is:issue assignee:{username}" if kind == "issues" else f"is:pr review-requested:{username} -author:{username}"
        rows, seen, fetched = [], set(), 0
        for page in range(1, 11):
            result, error = self.request("search/issues?" + urlencode({"q": f"repo:{self.project} is:open {qualifier}",
                                                                       "sort": "updated", "order": "desc", "per_page": 100, "page": page}))
            if (error or not isinstance(result, dict) or result.get("incomplete_results") is not False
                    or not integer(result.get("total_count")) or result["total_count"] > 1000
                    or not isinstance(result.get("items"), list)):
                return None, error or "GitHub returned an incomplete or invalid queue; keeping cached list"
            fetched += len(result["items"])
            for item in result["items"]:
                if (not isinstance(item, dict) or not integer(item.get("number")) or item["number"] < 1
                        or not isinstance(item.get("title"), str) or not isinstance(item.get("user"), dict)
                        or not isinstance(item["user"].get("login"), str)):
                    return None, "GitHub returned invalid assignments"
                if item.get("repository_url") != f"https://api.github.com/repos/{self.project}" or item.get("state") != "open":
                    continue
                if kind == "issues":
                    if "pull_request" in item:
                        continue
                    if not isinstance(item.get("assignees"), list):
                        return None, "GitHub returned invalid assignees"
                    if not any(isinstance(a, dict) and str(a.get("login", "")).lower() == username.lower() for a in item["assignees"]):
                        continue
                elif "pull_request" not in item or item["user"]["login"].lower() == username.lower():
                    continue
                if item["number"] in seen:
                    continue
                seen.add(item["number"])
                labels = item.get("labels")
                label = ", ".join(clean(v.get("name")) for v in labels if isinstance(v, dict)) if isinstance(labels, list) else ""
                rows.append({"iid": item["number"], "title": clean(item["title"]), "author": clean(item["user"]["login"]),
                             "project": self.project, "state": "open", "labels": label, "target_branch": "",
                             "web_url": f"https://github.com/{self.project}/{'issues' if kind == 'issues' else 'pull'}/{item['number']}"})
            if len(result["items"]) < 100:
                break
        if fetched < result["total_count"]:
            return None, "GitHub search pagination incomplete; keeping cached list"
        warnings = []
        if kind == "reviews":
            def enrich(row):
                detail, error = self.request(f"repos/{self.project}/pulls/{row['iid']}")
                if (not error and isinstance(detail, dict) and detail.get("number") == row["iid"]
                        and isinstance(detail.get("base"), dict) and isinstance(detail["base"].get("ref"), str)):
                    # A request may have disappeared since the search snapshot.
                    # Recheck direct review assignments when detail is available.
                    reviewers = detail.get("requested_reviewers")
                    if detail.get("state") != "open" or (isinstance(reviewers, list) and not any(
                            isinstance(r, dict) and str(r.get("login", "")).lower() == username.lower() for r in reviewers)):
                        return False
                    row["target_branch"] = clean(detail["base"]["ref"])
                    row["commits"] = detail.get("commits") if integer(detail.get("commits")) else None
                    row["ci"] = self.ci((detail.get("head") or {}).get("sha"))
                else:
                    row["commits"], row["ci"] = None, None
                row["approved"], row["my_approved"], row["other_approvals"] = self.approvals(row["iid"], username)
                row["threads"], row["my_threads"] = self.threads(row["iid"], username)
                return True
            with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
                kept = list(pool.map(enrich, rows))
            rows = [row for row, keep in zip(rows, kept) if keep]
            if any(not row["target_branch"] or any(row.get(f) is None for f in ("commits", "ci", "approved", "my_approved", "other_approvals", "threads", "my_threads")) for row in rows):
                warnings.append("GitHub review metadata incomplete; unavailable fields stay unknown")
        return {"version": 1, "ok": True, "user": {"username": username}, "rows": rows, "warnings": warnings}, None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--kind", choices=("issues", "reviews"), required=True)
    args = parser.parse_args()
    try:
        report, error = GitHub(args.project).queue(args.kind)
        report = report or {"version": 1, "ok": False, "warnings": [error]}
    except Exception:
        report = {"version": 1, "ok": False, "warnings": ["GitHub refresh failed before completion"]}
    print(json.dumps(report))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
