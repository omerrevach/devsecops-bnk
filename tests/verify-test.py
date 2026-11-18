#!/usr/bin/env python3
"""Mocked cluster states for platform/prod/verify_release.py: only the exact, verified, healthy release passes."""
import copy
import json
import os
import subprocess
import sys
import tempfile

V, D = "1.0.42", "sha256:" + "a" * 64
GOOD = {
    "ocirepository": {"metadata": {"generation": 3}, "status": {"observedGeneration": 3,
        "artifact": {"revision": f"{V}@sha256:" + "c" * 64},
        "conditions": [{"type": "Ready", "status": "True"}, {"type": "SourceVerified", "status": "True"}]}},
    "helmrelease": {"metadata": {"generation": 2}, "status": {"observedGeneration": 2,
        "history": [{"chartVersion": f"{V}+cccccccccccc", "status": "deployed"}],
        "conditions": [{"type": "Ready", "status": "True"}]}},
    "deployment": {"metadata": {"generation": 5}, "spec": {"replicas": 2, "template": {"spec": {"containers": [
        {"image": f"harbor.lab.internal/release/bank-app@{D}"}]}}},
        "status": {"observedGeneration": 5, "updatedReplicas": 2, "readyReplicas": 2, "availableReplicas": 2}},
    "health": {"code": 200, "body": '{"status": "ok"}'},
}


def case(change):
    state = copy.deepcopy(GOOD)
    change(state)
    return state


CASES = [
    ("the expected release, verified and healthy", GOOD, 0),
    ("old release still running (chart 1.0.41)", case(lambda s: s["helmrelease"]["status"]["history"][0].update(chartVersion="1.0.41+bbbb")), 1),
    ("source not yet at the new version", case(lambda s: s["ocirepository"]["status"]["artifact"].update(revision="1.0.41@sha256:x")), 1),
    ("signature not verified (SourceVerified=False)", case(lambda s: s["ocirepository"]["status"]["conditions"][1].update(status="False")), 1),
    ("stale Ready (status of an older generation)", case(lambda s: s["helmrelease"]["metadata"].update(generation=3)), 1),
    ("new rollout failed (1 of 2 replicas updated)", case(lambda s: s["deployment"]["status"].update(updatedReplicas=1, unavailableReplicas=1)), 1),
    ("app runs another image digest", case(lambda s: s["deployment"]["spec"]["template"]["spec"]["containers"][0].update(image="harbor.lab.internal/release/bank-app@sha256:" + "b" * 64)), 1),
    ("upgrade failed (history status failed)", case(lambda s: s["helmrelease"]["status"]["history"][0].update(status="failed")), 1),
    ("health 503", case(lambda s: s["health"].update(code=503, body='{"status": "database unreachable"}')), 1),
    ("health 200 but body only contains 'ok'", case(lambda s: s["health"].update(body='{"status": "not ok"}')), 1),
    ("objects missing", {"ocirepository": {}, "helmrelease": {}, "deployment": {}, "health": {"code": 0, "body": ""}}, 1),
]

failed = 0
with tempfile.TemporaryDirectory() as tmp:
    for name, state, expected in CASES:
        path = os.path.join(tmp, "state.json")
        json.dump(state, open(path, "w"))
        code = subprocess.run([sys.executable, "platform/prod/verify_release.py", path, V, D], capture_output=True).returncode
        ok = (code == 0) == (expected == 0)
        failed += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {'verified' if code == 0 else 'rejected'}: {name}")
print("PASS: release verifier" if not failed else f"FAIL: {failed} case(s)")
sys.exit(1 if failed else 0)
