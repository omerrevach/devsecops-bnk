# Hardened Enterprise Pipeline: internal banking service

**Contents**

1. [The assignment](#the-assignment)
2. [Architecture: the flow](#architecture-the-flow)
3. [How it works](#how-it-works)
4. [The pipeline](#the-pipeline)
5. [What the demo shows, with screenshots](#what-the-demo-shows-step-by-step)
6. [How outside content stays up to date](#how-outside-content-stays-up-to-date-and-under-control)
7. [Security considerations](#security-considerations)
8. [Tools and why](#tools-and-why)
9. [Users](#users)
10. [Repository layout, and what would differ in a real company](#repository-layout-and-what-would-differ-in-a-real-company)
11. [Run it yourself: set up, log in, check everything](#run-it-yourself-set-up-log-in-check-everything)

## The assignment

Build a Git repository from scratch with a secure, automated CI/CD pipeline for an internal banking service,
under two constraints:

- **No outbound internet.** CI runners work in an isolated network with no access to public repositories or
  vulnerability feeds while they run.
- **Domain isolation.** The runners sit in a different zone than production, and direct connections from the
  runners into production (SSH, WinRM) are blocked.

What was asked:

1. **Application and SCA.** A small web service (under 50 lines) with a database connection and a health check,
   whose dependencies include a known High/Critical CVE. An offline dependency scanner that fails the pipeline on
   Critical findings, plus a clean, auditable way to accept one specific CVE in an emergency.
2. **IaC and scanning.** Infrastructure as code for the runtime (workloads, network rules, configuration), hardened
   to limit the blast radius, and scanned by an IaC scanner before anything is deployed.
3. **Cross-domain deployment.** Since CI cannot push into production, a pull-based (GitOps) design, with the
   integrity of every artifact verifiable between the zones.
4. **DECISIONS.md.** Short answers on stale vulnerability feeds, deploying to legacy AD-joined servers, and
   handling an unpatched dependency.

## Architecture: the flow

```mermaid
flowchart LR
  DEV["Developer<br/>and Security<br/>(laptop)"]
  subgraph AWS["AWS account · eu-central-1"]
    subgraph VPC["VPC 10.20.0.0/16 · no NAT gateway · subnet firewalls between zones"]
      subgraph VPNS["vpn subnet<br/>10.20.50.0/24"]
        CVPN["Client VPN<br/>certificate login"]
      end
      subgraph DMZA["dmz subnets<br/>10.20.20.0/24 + .21.0/24"]
        ALB["Internal load balancer<br/>TLS · per-host allowlist"]
      end
      subgraph BUILD["build subnet 10.20.10.0/24 · no internet"]
        GL["GitLab<br/>code · reviews · CI"]
        BR["Build runner<br/>scan · build"]
        RR["Release runner<br/>main only · signs"]
      end
      subgraph EPS["endpoints subnet<br/>10.20.40.0/24"]
        VPCE["VPC endpoints<br/>SSM · KMS"]
      end
      subgraph DMZB["dmz subnets (registry)"]
        HARBOR["Harbor<br/>staging · release (signed only) · mirror"]
      end
      subgraph PUB["public subnet<br/>10.20.0.0/24"]
        PROXY["Egress proxy<br/>allowlist, logged"]
      end
      subgraph PROD["prod subnet 10.20.30.0/24 · no inbound"]
        K3S["k3s<br/>Flux → bank-app + Postgres"]
      end
    end
    KMS["KMS<br/>signing key"]
  end
  REG["Public registries"]

  DEV -->|"1 VPN"| CVPN --> ALB -->|"web UI, git"| GL
  GL -->|"2 jobs"| BR
  GL -->|"2 jobs (main)"| RR
  BR -->|"3 image to staging"| HARBOR
  RR -->|"4 sign"| VPCE --> KMS
  RR -->|"5 signed release"| HARBOR
  HARBOR -->|"6 Flux pulls + verifies"| K3S
  HARBOR -->|"daily mirror"| PROXY --> REG
```

How to read it: the arrows follow a release from left to right. Two details the drawing keeps simple: the runners
and prod also reach Harbor through the internal load balancer (which lets prod reach Harbor but never GitLab), and
step 6 is a **pull**: prod opens the connection, nothing connects into prod. Shells on the servers go through AWS
SSM (no SSH), and secrets live in Parameter Store, each server able to read only its own.

A secure CI/CD pipeline for a small banking service. CI and production have **no internet**, every
dependency is checked, every release is **signed** and approved by a person, and production **pulls**
releases itself. Nothing ever pushes into it. The whole lab comes up with one command, `make up`, and every
security control has a negative test that proves it blocks what it should (`make test`, `make test-lab`).

## How it works

1. **Harbor brings outside content in.** Harbor (the registry) copies a fixed list of pinned images from public
   registries once a day: CI tools, base images, the database image, Flux, and Trivy's vulnerability database.
   It is the only server allowed out, through a proxy that allows only those registries.
2. **Python packages come in once, checked.** The exact versions and hashes in `app/requirements.txt` are
   uploaded to GitLab's internal package registry. CI installs only from there.
3. **A developer pushes a branch** to GitLab. The pipeline runs on the **build runner**: no internet, no cloud
   permissions, cannot sign.
4. **Security gates run first:** vulnerability database fresh, no Critical CVE in dependencies (Trivy), Terraform
   and Kubernetes files secure (Checkov), no secrets in Git history (gitleaks), exceptions valid.
5. **A Critical CVE stops the pipeline.** The only way through is a merge request adding a short, documented
   exception for that one CVE in that one package version. Only Security can merge it, and the pipeline checks
   GitLab's record that Security really approved it.
6. **The images are built and scanned again**: the app image and the database image the release uses.
7. **Only `main` can be released, only by a person.** The **release runner** signs the image with a key in
   **AWS KMS** (the key never leaves KMS). The pipeline then waits for Security to press **promote**.
8. **Re-checked, then published.** After the approval, exceptions, approvals, database freshness and a rescan of
   both images are checked again. Then the image goes to Harbor `release` with a signed **evidence record**, and a
   signed Helm chart (with the image digest inside) is published. Harbor `release` accepts only signed artifacts.
9. **Production pulls it.** Flux inside prod sees the new version, **verifies the signature**, and installs it
   with permissions for one namespace only.

```mermaid
flowchart LR
  REG["Public registries"]
  subgraph VPC["AWS VPC · no internet except the proxy"]
    PROXY["Egress proxy<br/>allowlist"]
    H["Harbor<br/>mirror · staging · release"]
    GL["GitLab + runners<br/>build zone"]
    K["k3s + Flux<br/>prod zone"]
    KMS["KMS signing key"]
  end
  H -->|daily mirror| PROXY --> REG
  GL -->|push images & charts| H
  GL -->|sign| KMS
  K -->|pull + verify signature| H
```

**Nothing connects into prod.** Build and prod are in separate network zones that cannot reach each other.
Harbor is the only bridge: CI writes to it, prod reads from it.

## The pipeline

| Stage | Jobs | What and why |
|---|---|---|
| feeds | `feed-check` | Gets the vulnerability DB from Harbor; stops if it is missing, older than 48 h, or dated in the future. |
| validate | `exceptions-lint`, `secrets-scan`, `chart-lint` | Exceptions are strict and short-lived; no secrets in Git; the chart is valid. |
| scan | `sca`, `iac-terraform`, `iac-k8s` | Trivy: no Critical CVE in Python packages. Checkov: Terraform and Kubernetes in separate jobs, each failing if it scanned nothing. |
| build | `wheels`, `build` | Installs packages only from the internal registry, builds the image into Harbor `staging`. |
| verify | `image-scan`, `exception-approvals` | Scans the app image **and** the database image. On `main`, proves every exception was approved by Security. |
| sign | `sign-image` | `main` only, on the release runner: signs with the KMS key. |
| release | `promote` (manual), `release-check`, `release-policy`, `publish-image`, `publish-chart`, `sign-chart` | Security approves; everything that can expire is re-checked; the signed image, its signed evidence and the signed chart go to Harbor `release`. |

**Branch vs `main`:** a merge request pipeline only checks, builds and scans. It has no signing or release jobs.
After merging, `main` runs everything again on the exact merged code, signs it, and waits for the manual release.

### What the demo shows (step by step)

**1. The first pipeline on `main` is blocked.**

![Pipeline on main fails at sca](docs/images/1-main-blocked.png)

`sca` fails and everything after it is skipped: no build, no signing, no release. Gates fail closed.

**2. Why it failed: a Critical CVE in a dependency.**

![sca job log](docs/images/2-sca-log.png)

Trivy, scanning offline with the database from the Harbor mirror, found **CVE-2022-21797** (Critical) in
`joblib 1.1.0`. **Status `fixed`** means a patched version exists (1.2.0): the real fix is to upgrade.

**3. The same finding, without reading logs: the pipeline's Tests tab.**

![Tests tab: joblib CVE-2022-21797 as a failed test](docs/images/1b-tests-tab.png)

Every blocking Critical is published as a failed test, so it shows in the Tests tab and in merge requests.

**4. The exception, through a merge request.** When a team cannot upgrade right away, the developer adds one
short-lived entry to `security/exceptions.yaml`:

```yaml
vulnerabilities:
  - id: CVE-2022-21797
    purls:
      - "pkg:pypi/joblib@1.1.0"        # exactly one package, exactly this version
    expired_at: 2026-12-02             # at most 30 days ahead
    statement: "ticket=SEC-101; approved-by=security-lead; reason=...; compensating=..."
```

![Merge request pipeline](docs/images/3-merge-request-pipeline.png)

The merge request pipeline is green: Trivy skips only that CVE in that exact version (another version, or any
other Critical, still fails). It has **no signing or release jobs**, and the developer cannot merge it.

**5. Two-person approval, enforced** (the person who asks for an exception cannot approve it).

![exception-approvals blocks a self-approved exception](docs/images/5-self-approval-blocked.png)

Before anything is signed, the `exception-approvals` job looks up who did what in GitLab: someone from Security
must have clicked **Approve** on the merge request, and that person must be different from the developer who
asked for the exception. If the same person asked and approved, or nobody approved at all, the pipeline stops
here, as in this screenshot.

**6. The release, approved by a person.**

![Main pipeline with release](docs/images/4-main-release-pipeline.png)

With a proper approval, `main` runs every gate again, `exception-approvals` passes, and `sign-image` signs the image
with the KMS key. The pipeline then waits until Security presses **promote**. `release-check` and `release-policy`
re-check everything that can expire and build the evidence record; `publish-image`, `publish-chart` and
`sign-chart` publish the signed release.

**7. The signed release in Harbor.**

![Harbor release/bank-app: signed images and their evidence records](docs/images/6-harbor-release-image.png)

`release/bank-app`: each release image (`1.0.N`) is **Signed** with the KMS key. The small `sha256-…` artifact next to
it is that release's **evidence record** (a cosign attestation: what was scanned, which exception applied, who
approved). Its signature is inside the record and is checked with `cosign verify-attestation`, which is why
Harbor's "Signed" column shows ✗ for it.

![Harbor release/charts/bank-app: signed charts](docs/images/7-harbor-release-chart.png)

`release/charts/bank-app`: the Helm chart of each release, signed, with the image digest baked in. This is what Flux
in prod pulls; it verifies the signature before installing, within about a minute.

**8. Production pulled, verified and deployed it** (commands run on the prod VM).

![flux get sources oci](docs/images/8-flux-source.png)

`flux get sources oci -A`: Flux pulled release `1.0.17` from Harbor's `release` project, by digest. Prod fetched it
itself; nothing pushed into prod.

![SourceVerified message](docs/images/9-flux-signature.png)

The `SourceVerified` condition: Flux checked the chart's cosign signature against the KMS public key **before**
using it. The digest is the same as the signed chart in Harbor (`sha256:2bcf7698…`).

![flux get helmreleases](docs/images/10-flux-helmrelease.png)

`flux get helmreleases -A`: Helm upgrade succeeded with chart `bank-app@1.0.17`, so that release is what runs.

![kubectl get pods](docs/images/11-prod-pods.png)

`kubectl -n bank-app get pods`: both app replicas and the database are `1/1 Running`. An app pod is only Ready when
its `/healthz` check passes, and that check queries the database, so the app is connected to Postgres (over TLS).

**How Flux knows what to pull.** It does not just take "the newest thing". It follows the rule in
[platform/flux/bank-app.yaml](platform/flux/bank-app.yaml):

```yaml
url: oci://harbor.lab.internal/release/charts/bank-app
ref:
  semver: ">=1.0.0"
```

1. Every minute, Flux lists the chart versions in Harbor's `release` project.
2. It picks the **highest version** matching `>=1.0.0`, compared as version numbers (now `1.0.17` over `1.0.3`).
3. It **verifies that chart's signature** with the KMS public key. If it is unsigned or signed by another key, Flux
   refuses it and keeps running the current release.
4. If the version is new, it upgrades the app to that chart. The image digest is baked into the chart, so the exact
   signed image is what runs.

Only the pipeline's release jobs can put charts into `release`, and only after Security's approval; release
versions can never be overwritten, and an older version can't be "replayed" because Flux always takes the highest.

## How outside content stays up to date (and under control)

Only the vulnerability database updates itself. Every tool, base image and Python package is pinned and changes
only through a reviewed merge request.

**1. The Trivy vulnerability database: refreshed every day, automatically.**
- Harbor has one replication rule per image, created by `platform/harbor/configure.sh` from the list in
  `platform/harbor/mirror.txt`, each on a daily schedule (02:00 UTC).
- At that time Harbor pulls `ghcr.io/aquasecurity/trivy-db:2` through the egress proxy. Harbor is the only server
  allowed out, and only to the feed registries on its allowlist.
- Aqua republishes that database several times a day under the same tag (`2`), so each daily run brings in the
  latest CVE data.
- In CI, every scan job downloads it from Harbor, never from the internet, and `feed-check` stops the pipeline if
  it is older than 48 hours. If the daily refresh breaks, pipelines fail closed instead of scanning with old data.

**2. CI tools (Trivy, Checkov, gitleaks, Helm, Buildah, cosign) and the Flux images: pinned, never change by
themselves.**
- They are mirrored by the same daily rules, but each is pinned to an exact version and digest, in both
  `platform/harbor/mirror.txt` and `.gitlab-ci.yml`.
- Harbor setup fails if a mirrored tool does not match its reviewed digest, and CI pulls by digest, so a daily
  refresh can never swap in a different scanner.
- To upgrade one: change the version and digest in those two files through a merge request, Security reviews it,
  and the mirror picks it up.

**3. Base images (Python, distroless, Chainguard PostgreSQL): mirrored daily, used only when pinned.**
- Their tags are refreshed daily in the mirror, so security patches arrive there.
- The Dockerfile and the chart use them by digest, pinned when the code is imported. A newer base image is used
  only after a reviewed change bumps the digest, and it is scanned again (`image-scan`) before any release.

**4. Python packages: no automatic updates, by design.**
- They do not come through Harbor but through a one-time intake (`platform/gitlab/intake.sh`, run by `make up`):
  the exact versions in `app/requirements.txt` are downloaded, checked against their SHA-256 hashes, and uploaded
  to GitLab's internal package registry.
- CI installs only from that registry, with `--require-hashes`; forwarding to pypi.org is turned off.
- To update a package: change `app/requirements.in`, regenerate `requirements.txt` with hashes
  (`pip-compile --generate-hashes`), open a merge request (the dependency scan checks the new versions), and after
  the merge re-run the intake (`make up`).

## Security considerations

Each point says what is enforced and how it is proven. Local tests: `make test` (no AWS). Lab tests:
`make test-lab` (against the running lab).

**Network**
- No internet for any server except the egress proxy, which allows only listed domains and logs every request.
- Installers get internet only during setup, as a **maintenance window**: CI runners are stopped first, the
  window closes on success or failure (and by itself after 60 minutes), and the runners start again only after
  a check proves they have no internet, directly or through the proxy. *(make up verifies it; test-lab)*
- Build and prod zones are blocked from each other at the subnet firewall; prod accepts no incoming connections.
- Inside Kubernetes, network policies deny everything except app → database and DNS.

**Identity and least privilege**
- Each server has its own AWS role and can read and decrypt **only its own secrets**: a custom SSM agent policy
  (not AWS's managed one, which allows reading every parameter), every read action scoped, and a dedicated KMS
  key that lets each role decrypt only its own paths. *(test-lab: IAM policy simulation)*
- Only the release runner's role can use the signing key, and only for `main`. *(test-lab)*
- The lab's AWS user can create roles only with a **permissions boundary** it cannot remove, and can pass roles
  only to EC2, so it cannot turn a role into an administrator. *(test-lab: escalation paths denied)*
- **Flux least privilege:** its default cluster-admin binding is removed; it installs the app only by
  impersonating one service account that has rights in the `bank-app` namespace for the chart's resource kinds;
  anything else gets no permissions. *(test-lab: `kubectl auth can-i`)*
- The app logs in to the database as a normal role: no superuser, cannot create roles or databases. The admin
  password exists only in the database pod. *(make test: real database; test-lab)*
- Developers cannot merge to `main` or release; Security approves every merge and every release.

**Secrets**
- No secrets in Git (gitleaks checks the whole history).
- Passwords and tokens are generated during setup and kept in AWS Parameter Store, encrypted with the lab's own
  KMS key. The database passwords and its TLS keys are created inside the cluster and never leave it.
- The signing key's private half exists only in AWS KMS; its public half is not secret.

**Supply chain**
- Every CI tool image is pinned **by digest**, and Harbor checks each mirrored tool against that reviewed digest.
  Base images are pinned by digest at import; Python packages by version and hash.
- Gates fail closed: stale or future-dated vulnerability DB, Critical CVEs in packages, the app image or the
  database image, insecure IaC, leaked secrets. *(make test: feed boundaries, IaC gate with the exact CI image)*
- Exceptions: one CVE, one exact package version, ticket, reason, compensating control, at most 30 days, and
  proof of Security's approval from GitLab. *(make test: invalid exceptions rejected; scope limited to one version)*
- Re-checked at release time, after the manual approval, so nothing expired can be published.
- Images and charts are signed; Harbor `release` serves only signed artifacts and never overwrites a version;
  Flux verifies before installing; the chart pins the exact image digest.
- **Audit evidence:** full scan reports including findings an exception suppressed, plus a signed evidence record
  attached to the released image (commit, digests, scanner and DB version, exception, approvals), kept 1 year.

**Data and runtime**
- App ↔ database traffic is **TLS-only**: the database refuses plaintext logins, and the app checks the server
  certificate and hostname. *(make test: untrusted CA, wrong hostname and plaintext server all refused)*
- Pods run as non-root, read-only, with no privileges, no capabilities and no service-account token, enforced by
  Kubernetes (Pod Security `restricted`). Minimal images: distroless app, Chainguard database.
- Deployment is verified against the **exact expected** version and image digest, with a verified signature and
  a real `{"status": "ok"}`. *(make test: old release, unverified source, stale status, failed rollout rejected)*

**Infrastructure**
- `make up` checks the Terraform code (format, validation, Checkov) **before** changing anything in AWS, then
  applies exactly the checked plan. *(make test: an insecure rule never reaches `terraform apply`)*
- Encrypted disks, IMDSv2, VPC flow logs, TLS everywhere with a dedicated lab CA, no SSH (SSM only).
- Terraform state is in an encrypted, private, versioned S3 bucket.

## Tools and why

| Tool | Why |
|---|---|
| Terraform | Infrastructure as code: reviewable, repeatable, scanned before apply. |
| GitLab (self-hosted) | Code, reviews, CI and a package registry in one tool that runs **fully inside the air gap**. GitHub Actions was not an option: it is a cloud service, and its self-hosted runners still need to reach GitHub over the internet, which the build zone does not have. |
| Harbor | Self-hosted registry with scheduled mirroring, signed-only releases and immutable tags. |
| Squid | Simple, proven egress proxy with domain allowlists and full logs. |
| Trivy | Offline vulnerability scanning with exact, expiring exceptions. |
| Checkov | Security checks for Terraform and Kubernetes files. |
| gitleaks | Finds secrets in code and history, offline. |
| cosign + AWS KMS | Signing where the private key can never be copied. |
| Helm | Packages the release; the signed chart pins the image digest. |
| Buildah | Builds the container image from the Dockerfile, like `docker build`, but without needing Docker. Plain `docker build` inside a CI job would need the server's Docker socket or "privileged" mode, letting any job (even a merge request) take over a build server that is shared and permanent here. On cloud CI each job gets a fresh throwaway VM, so `docker build` is fine there. |
| k3s | Certified Kubernetes in one small VM: cheap (no control-plane fee), starts in minutes, and installs fully offline from its image bundle. EKS would cost more (~$0.10/h for the control plane plus nodes), needs extra private endpoints, and adds nothing to what this assignment demonstrates; the chart and Flux setup would carry over to EKS unchanged. |
| Flux | Pull-based: it runs inside prod and fetches releases, so prod opens no port. It **verifies cosign signatures natively** before installing, can install each release with a limited service account (least privilege), and is light (2 controllers, no UI to expose). Argo CD is a good tool too, but it is heavier, centres on a web UI and API server that must be secured, and has no built-in cosign verification of OCI charts. |
| Chainguard PostgreSQL | Minimal database image with no Critical or High CVEs (the official images ship a vulnerable helper). |
| AWS SSM | Shell access with no SSH keys or open ports. |

## Users

| Who | Role |
|---|---|
| AWS `bank-lab-admin` | Builds the lab; bound so it cannot give itself or any role more rights. |
| AWS VM roles | One per server: its own secrets only; only the release runner may sign. |
| GitLab `omeriko` | Developer: branches and merge requests only. |
| GitLab `security-lead` | Security: approves and merges, approves releases. |
| GitLab `exception-audit` token | Read-only: lets CI check approvals on merge requests. |
| Harbor robots | `ci-build` (staging), `ci-release` (staging + release, main only), `prod-pull` (read release only). |
| Flux `bank-app-deployer` | Installs the app, only in its namespace. |
| Postgres `postgres` / `bank_app` | Admin (only inside the database pod) / the app's normal login. |

## Repository layout, and what would differ in a real company

```
terraform/     the AWS lab (network, servers, load balancer, VPN, KMS)       -> scanned by CI, applied by make up
app/           the banking service, its pinned dependencies, its Dockerfile   -> built and scanned by CI
charts/        the Helm chart: how the app runs in Kubernetes                 -> scanned, signed and published by CI
platform/      setup scripts per server, plus the Flux config for prod        -> run by make up
scripts/       the pipeline's gate scripts, and the lab automation            -> CI jobs and make up
security/      the CVE exceptions file                                         -> read by every vulnerability scan
tests/         negative tests that prove each control                         -> make test, make test-lab
```

**One repository is a choice for the assignment.** In a real company:

- **Terraform** would live in its **own infrastructure repo**, with its own pipeline (plan, review, apply by a
  dedicated identity) and its own owners. Here the Terraform is the lab and part of the deliverable, and CI only
  scans it (it never applies it), so one repo keeps the assignment easy to review.
- **The Helm chart** would usually stay **with the app**, owned by the team that builds the app, so a code change
  and its deployment change are reviewed and released together (as here). What would move out is the
  **environment configuration**: the Flux objects that say "prod runs `bank-app` from Harbor, verified with this
  key" (`platform/flux/` here) would live in a separate **GitOps repo** per environment, owned by the platform
  team, so who may deploy where is controlled separately from the application code. Shared building blocks
  (a common chart library, policies) would come from a platform repo or chart registry.
- **The scripts** in `platform/` exist so the whole lab can be built and torn down in one command for the home
  assignment. In production these servers would be built from hardened images (e.g. Packer) and managed
  services or configuration management (e.g. Ansible), not one-off scripts.

### What the scripts do

**Lab setup (run from the laptop by `make up`, never in CI)**

| Script | What it does |
|---|---|
| `scripts/lab.sh` | The orchestrator behind every `make` command: checks Terraform, applies it, then runs the steps below in order |
| `scripts/ssm-run.sh` | Runs a script on a server through AWS SSM (no SSH); secrets never pass through it |
| `scripts/create-lab-user.sh` | One-time admin setup: the AWS user and its permissions boundary |
| `platform/gitlab/` | Install GitLab; configure users, groups, project, CI variables and runners; take Python packages in; import the code; the scripted demo |
| `platform/harbor/` | Install Harbor; configure projects, the pinned mirror (`mirror.txt`) and robot accounts |
| `platform/runner/` | Install and register the two CI runners; stop them during maintenance and prove they have no internet |
| `platform/prod/` | Install k3s and Flux; check the exact release is running; the cluster security tests |
| `platform/proxy/` | Open and close the installers' temporary internet allowlist |

**Pipeline gates (run by the CI jobs)**

| Script | Job | What it does |
|---|---|---|
| `feed-check.sh` | every Trivy job | Stops if the vulnerability database is stale, missing or dated in the future |
| `trivy-scan.sh` | `sca`, `image-scan`, `release-check` | Full report, a test report for GitLab, then the Critical gate |
| `iac-scan.sh` | `iac-terraform`, `iac-k8s` | Checkov for one framework; fails if it scanned nothing |
| `check_exceptions.py` | `exceptions-lint`, `release-policy` | Strict exception format and expiry |
| `check_exception_approval.py` | `exception-approvals`, `release-policy` | Proves Security approved the exception, from GitLab's records |
| `release-evidence.py` | `release-policy` | Builds the release evidence record that gets signed |
| `render-chart.sh`, `chart-image.sh` | `chart-lint`, `image-scan` | Renders the chart for scanning; reads the database image from the chart |

**Why every pipeline runs every scan.** A release must prove the whole repository is clean with today's
vulnerability database, because new CVEs appear daily even when the code does not change, and "only run when
this folder changed" rules can silently skip a gate. The scans take seconds to a minute. In a bigger setup,
merge requests could skip unrelated scans while `main` still runs everything before a release.

## Run it yourself: set up, log in, check everything

**1. Requirements (laptop).** AWS CLI v2 with the Session Manager plugin, Terraform 1.11 or newer, Checkov, Docker,
`jq`, `git`, `openssl`, `make`, and an OpenVPN client (Linux: `network-manager-openvpn`; macOS/Windows: AWS VPN Client).

**2. AWS access, once.** In a dedicated AWS account, as an administrator (AWS CloudShell is easiest):
```bash
bash scripts/create-lab-user.sh      # IAM user bank-lab-admin with a permissions boundary, CLI profile "bank-lab"
```

**3. Settings.**
```bash
cp lab.env.example lab.env           # set AWS_PROFILE, AWS_REGION; DEMO=manual to do the demo yourself
```

**4. Build everything (about 15 minutes, 26 with DEMO=auto).**
```bash
make up
```

**5. Log in.**
```bash
make passwords                       # GitLab: root, omeriko (developer), security-lead (Security) · Harbor: admin
make vpn                             # writes bank-lab.ovpn and prints how to import and connect it
terraform -chdir=terraform output -raw ca_cert_pem > lab-ca.crt
```
Connect the VPN, import `lab-ca.crt` in your browser as a trusted authority (Chrome: Settings, Privacy and
security, Security, Manage certificates, Authorities, Import. Firefox: Settings, Privacy & Security, View
Certificates, Authorities, Import), then open:
- GitLab: **https://gitlab.lab.internal** (use a private window for `security-lead` to stay logged in as both)
- Harbor: **https://harbor.lab.internal**

**6. Do the demo** in GitLab: the steps under "What the demo shows" above. `omeriko` opens the exception merge
request; `security-lead` clicks **Approve**, then **Merge**, then **promote** in the `main` pipeline.

**7. Check everything.**

| What | How |
|---|---|
| The pipeline and the CVE | GitLab: `bank/bank` → Build → Pipelines; the `sca` job log and the **Tests** tab |
| Signed release in Harbor | Harbor: Projects → `release` → `bank-app` and `charts/bank-app` (Signed column) |
| Signature from the terminal | `SSL_CERT_FILE=lab-ca.crt cosign verify --key .lab/cosign.pub --insecure-ignore-tlog=true harbor.lab.internal/release/bank-app:1.0.N` (after `cosign login harbor.lab.internal -u admin`) |
| What runs in prod | `make status` (Flux source, signature, installed version, pods) |
| Shell on the prod server | `aws ssm start-session --target <prod instance id>`, then `sudo -i`, then `flux get sources oci -A`, `flux get helmreleases -A`, `kubectl -n bank-app get pods` |
| Every security control | `make test` (local, no AWS) and `make test-lab` (against the lab) |

**8. Again or clean up.** `make demo-reset` gives a fresh GitLab project to run the demo again (about 5 minutes).
`make down` deletes everything. Cost while running: about $0.55 per hour.

Trade-off decisions: `DECISIONS.md`.
