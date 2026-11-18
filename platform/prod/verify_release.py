#!/usr/bin/env python3
"""Decide whether prod runs exactly the expected, verified, healthy release.

Input: a JSON file with the cluster objects (collected by verify.sh) and the health check result:
  {"ocirepository": {...}, "helmrelease": {...}, "deployment": {...}, "health": {"code": 200, "body": "..."}}
Usage: verify_release.py <state.json> <expected version> <expected image digest>
Prints each check; exits 0 only if every check passes. Used by verify.sh and by tests/verify-test.py.
"""
import json
import sys


def condition(obj, kind):
    for c in obj.get("status", {}).get("conditions", []):
        if c.get("type") == kind:
            return c
    return {}


def fresh(obj):
    """The status describes the current spec, not an older one."""
    return obj.get("status", {}).get("observedGeneration") == obj.get("metadata", {}).get("generation")


def checks(state, version, digest):
    oci, hr, dep, health = state["ocirepository"], state["helmrelease"], state["deployment"], state["health"]
    artifact = oci.get("status", {}).get("artifact", {}).get("revision", "")
    history = (hr.get("status", {}).get("history") or [{}])[0]
    images = [c.get("image", "") for c in dep.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])]
    dstatus = dep.get("status", {})
    want_replicas = dep.get("spec", {}).get("replicas", 1)
    yield "source signature verified (SourceVerified=True)", condition(oci, "SourceVerified").get("status") == "True"
    yield "source ready and up to date", condition(oci, "Ready").get("status") == "True" and fresh(oci)
    yield f"source holds release {version}", artifact.startswith(f"{version}@")
    yield "helm release ready and up to date", condition(hr, "Ready").get("status") == "True" and fresh(hr)
    yield f"installed chart is {version}", str(history.get("chartVersion", "")).split("+")[0] == version
    yield "last install/upgrade succeeded", history.get("status") == "deployed"
    yield f"app runs image digest {digest[:19]}...", any(i.endswith(f"@{digest}") for i in images)
    yield "rollout complete (all replicas updated and ready)", (
        fresh(dep) and dstatus.get("updatedReplicas") == want_replicas
        and dstatus.get("readyReplicas") == want_replicas and dstatus.get("availableReplicas") == want_replicas
        and not dstatus.get("unavailableReplicas"))
    try:
        body = json.loads(health.get("body") or "null")
    except ValueError:
        body = None
    yield "GET /healthz -> 200 {\"status\": \"ok\"}", health.get("code") == 200 and body == {"status": "ok"}


def main(path, version, digest):
    state = json.load(open(path))
    ok = True
    for name, passed in checks(state, version, digest):
        print(f"  {'ok  ' if passed else 'FAIL'} {name}")
        ok &= bool(passed)
    return ok


if __name__ == "__main__":
    sys.exit(0 if main(*sys.argv[1:4]) else 1)
