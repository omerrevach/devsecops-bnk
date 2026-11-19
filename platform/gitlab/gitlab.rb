# Complete /etc/gitlab/gitlab.rb. Installed by platform/gitlab/install.sh.
# After changing it, run install.sh again: it copies this file and runs gitlab-ctl reconfigure.
external_url 'https://gitlab.lab.internal'
letsencrypt['enable'] = false
nginx['ssl_certificate'] = "/etc/gitlab/ssl/gitlab.lab.internal.crt"
nginx['ssl_certificate_key'] = "/etc/gitlab/ssl/gitlab.lab.internal.key"
nginx['redirect_http_to_https'] = true

# Container registry is Harbor's job; GitLab keeps only the PyPI package registry.
registry['enable'] = false
gitlab_rails['packages_enabled'] = true

# Fit an 8 GB VM and reduce attack surface.
puma['worker_processes'] = 2
sidekiq['concurrency'] = 10
prometheus_monitoring['enable'] = false
gitlab_kas['enable'] = false
gitlab_rails['usage_ping_enabled'] = false
gitlab_rails['gitlab_default_projects_features_container_registry'] = false

# Behind the internal load balancer: log the real client IP, trusting only the ALB subnets.
nginx['real_ip_trusted_addresses'] = ['10.20.20.0/24', '10.20.21.0/24']
nginx['real_ip_header'] = 'X-Forwarded-For'
nginx['real_ip_recursive'] = 'on'
