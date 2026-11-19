# Decisions

## 1. Stale feeds: fail open or fail closed?

Fail closed: if the vulnerability database is missing or older than 48 hours, the pipeline stops and no new release is built (`scripts/feed-check.sh`). A scan with an old database can miss the newest CVEs, and in a bank it is better to delay a release than to ship something that was not properly checked, while the version already running in production is not affected. In this lab it blocks on every branch; in a real team I would show it as an orange warning on feature branches so developers are not stuck, and keep it blocking on `main` and releases, so nothing reaches production without a fresh scan.

## 2. Legacy VM in an Active Directory domain

I would use the same pull idea as Flux: a small agent installed on the VM checks Harbor for a new release, verifies its cosign signature and installs it, so the CI runner never connects to the server. The agent logs in with its own AD service account that can only update this one app, and on Windows that account is a gMSA, so AD creates and rotates the password and nobody ever stores or sees it (on Linux, a service account key file that is rotated regularly). The pipeline never gets any login in the production domain, and every install is logged so we can see what was deployed and when.

## 3. Critical CVE in a transitive dependency with no fix

The scanner stays on, and the developer opens a merge request that adds one exception to `security/exceptions.yaml` for that exact CVE and package version, with a reason, a ticket and an expiry date of at most 30 days. Security must approve it, and the pipeline checks in GitLab that the approver is not the author before the exception is accepted. Only that one CVE is allowed through, every other Critical still blocks the build, and when the exception expires the build fails again until the package is patched.
