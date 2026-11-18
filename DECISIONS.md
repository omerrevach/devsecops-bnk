# Decisions

## 1. Stale feeds: fail open or fail closed?

Fail closed: if the vulnerability database is missing or older than 48 hours, the pipeline stops and no new release is built (`scripts/feed-check.sh`). A scan with an old database can miss the newest CVEs, and in a bank it is better to delay a release than to ship something that was not properly checked. The version already running in production is not affected, so the only impact is a delayed release until the mirror is fixed.

## 2. Legacy VM in an Active Directory domain

I would keep the pull model by installing a small agent on the VM that pulls the release from Harbor and checks its cosign signature before installing it. The agent runs under a dedicated AD service account with only the rights it needs to update this one service (a gMSA on Windows so AD rotates the password, or a rotated keytab on Linux). The CI runner never gets credentials in the production domain, and no inbound connection to the VM is needed.

## 3. Critical CVE in a transitive dependency with no fix

The scanner stays on, and the developer opens a merge request that adds one exception to `security/exceptions.yaml` for that exact CVE and package version, with a reason, a ticket and an expiry date of at most 30 days. Security must approve it, and the pipeline checks in GitLab that the approver is not the author before the exception is accepted. Only that one CVE is allowed through, every other Critical still blocks the build, and when the exception expires the build fails again until the package is patched.
