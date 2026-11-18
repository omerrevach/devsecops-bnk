#!/usr/bin/env python3
"""Prove that the current security/exceptions.yaml was approved by Security, from GitLab's own records.

The name in "approved-by=" is only text anyone can type. The proof: the last commit that changed the file came
from a MERGED merge request that was approved by a project Maintainer (Security) who is not its author.
Runs in CI on main (exception-approvals) and again right before release (release-policy).
Writes the record it checked to <output.json> for the release evidence.

Needs GITLAB_AUDIT_TOKEN: a read-only (read_api) project token, stored as a protected, masked CI variable.
"""
import json
import os
import ssl
import sys
import urllib.parse
import urllib.request

import yaml

MAINTAINER = 40


def api(path: str):
    url = f"{os.environ['CI_API_V4_URL']}/projects/{os.environ['CI_PROJECT_ID']}{path}"
    request = urllib.request.Request(url, headers={"PRIVATE-TOKEN": os.environ["GITLAB_AUDIT_TOKEN"]})
    context = ssl.create_default_context(cafile=os.environ.get("SSL_CERT_FILE"))
    with urllib.request.urlopen(request, context=context, timeout=20) as response:
        return json.load(response)


def main(path: str, output: str) -> int:
    entries = (yaml.safe_load(open(path, encoding="utf-8")) or {}).get("vulnerabilities") or []
    record = {"file": path, "entries": [e.get("id") for e in entries]}
    if not entries:
        record["result"] = "no exceptions: nothing to approve"
        json.dump(record, open(output, "w"), indent=2)
        print(record["result"])
        return 0

    query = urllib.parse.urlencode({"ref_name": os.environ["CI_COMMIT_SHA"], "path": path, "per_page": 1})
    commit = api(f"/repository/commits?{query}")[0]
    record["last_change"] = {"commit": commit["id"], "title": commit["title"]}
    merged = [mr for mr in api(f"/repository/commits/{commit['id']}/merge_requests") if mr["state"] == "merged"]
    if not merged:
        return fail(record, output, f"commit {commit['short_id']} changed {path} without a merged merge request")

    mr = merged[0]
    approvals = api(f"/merge_requests/{mr['iid']}/approvals")
    approvers = []
    for approval in approvals.get("approved_by", []):
        user = approval["user"]
        member = api(f"/members/all/{user['id']}")
        approvers.append({"username": user["username"], "access_level": member["access_level"],
                          "is_author": user["id"] == mr["author"]["id"]})
    record["merge_request"] = {"iid": mr["iid"], "url": mr["web_url"], "author": mr["author"]["username"],
                               "merged_by": (mr.get("merged_by") or {}).get("username"), "approvers": approvers}
    valid = [a for a in approvers if a["access_level"] >= MAINTAINER and not a["is_author"]]
    if not valid:
        return fail(record, output, f"merge request !{mr['iid']} has no approval from a Maintainer other than its author")
    record["result"] = f"approved in !{mr['iid']} by {', '.join(a['username'] for a in valid)}"
    json.dump(record, open(output, "w"), indent=2)
    print(f"OK: {path} {record['result']}")
    return 0


def fail(record: dict, output: str, reason: str) -> int:
    record["result"] = f"REJECTED: {reason}"
    json.dump(record, open(output, "w"), indent=2)
    print(f"FAIL: {reason}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
