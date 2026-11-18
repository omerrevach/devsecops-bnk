# Decisions

## 1. Stale feeds: fail open or fail closed?

Fail closed. If the Trivy database can't be pulled from the mirror or is older than 48 hours, the scan jobs stop and nothing new gets released (`scripts/feed-check.sh`). A clean scan on an old database isn't really clean, and in a bank I'd rather delay a release than ship something we never properly checked. What's already running in prod stays up, so a mirror outage only blocks new releases.

## 2. Legacy VM in an Active Directory domain

I'd keep the pull model and put a small agent on the VM that polls Harbor over HTTPS and runs `cosign verify` before installing anything. On Windows the agent runs as a gMSA, so AD rotates its password and nothing is stored on the box. On Linux it uses a dedicated service account with a root-only keytab that gets rotated, plus a sudo rule that allows only the install script. The runner never gets credentials in the prod domain and nothing connects into the VM.

## 3. Critical CVE in a transitive dependency with no fix

The scanner stays on. The developer opens a merge request that adds one entry to `security/exceptions.yaml` with the CVE, the exact package version, the reason, a ticket and an expiry date (30 days max). Security has to approve it, and the pipeline checks GitLab to confirm that someone other than the author approved it. Only that CVE in that version is let through; everything else still blocks, and when the exception expires the build fails again until the package is fixed or the exception is renewed.
