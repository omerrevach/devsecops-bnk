# The whole lab in one command. Settings: lab.env (cp lab.env.example lab.env). Details: README.md.
.PHONY: up demo demo-reset passwords vpn status down check test test-lab

up:         ## Build everything and run the demo (~26 min from scratch; safe to run again)
	@scripts/lab.sh up

demo:       ## Only the demo: CVE gate -> exception -> approval -> signed release -> deployed
	@scripts/lab.sh demo

demo-reset: ## Fresh GitLab project with the code re-imported, to run the demo again (~6 min)
	@scripts/lab.sh demo-reset

passwords:  ## GitLab and Harbor logins
	@scripts/lab.sh passwords

vpn:        ## Write the Client VPN profile (bank-lab.ovpn) to open the web UIs
	@scripts/lab.sh vpn

status:     ## VMs, and what Flux has deployed in prod
	@scripts/lab.sh status

down:       ## Delete the lab (keeps the Terraform state bucket)
	@scripts/lab.sh down

test:       ## Negative tests for every control that can run locally (no AWS; needs Docker)
	@bash tests/run-local.sh

test-lab:   ## Negative tests against the running lab (IAM, Flux, database, egress)
	@bash tests/lab/run.sh

check:      ## The local gates CI also runs (needs helm, checkov, gitleaks)
	sh scripts/render-chart.sh
	sh scripts/iac-scan.sh terraform .lab/iac-terraform terraform
	sh scripts/iac-scan.sh kubernetes .lab/iac-k8s rendered platform/flux
	python3 scripts/check_exceptions.py security/exceptions.yaml
	gitleaks git --redact .
