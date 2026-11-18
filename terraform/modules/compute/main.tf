# The six lab VMs. All of them: IMDSv2 only, encrypted disks, no SSH key, no public IP
# (except the egress proxy, which accepts nothing from the internet).

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

locals {
  proxy_url = "http://proxy.${var.domain}:3128"

  # imds_hops = how many network hops may reach the instance metadata service.
  # 1 keeps containers away from the VM's credentials. Only the release runner needs 2,
  # because its signing job runs in a container and must use the VM's IAM role.
  vms = {
    gitlab         = { zone = "build", security_group = "gitlab", disk_gb = 60, imds_hops = 1 }
    build-runner   = { zone = "build", security_group = "runner", disk_gb = 40, imds_hops = 1 }
    release-runner = { zone = "build", security_group = "runner", disk_gb = 20, imds_hops = 2 }
    harbor         = { zone = "dmz", security_group = "harbor", disk_gb = 80, imds_hops = 1 }
    prod           = { zone = "prod", security_group = "prod", disk_gb = 40, imds_hops = 1 }
  }
}

resource "aws_instance" "vm" {
  for_each = local.vms

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_types[each.key]
  subnet_id                   = var.subnet_ids[each.value.zone]
  vpc_security_group_ids      = [var.security_group_ids[each.value.security_group]]
  iam_instance_profile        = var.instance_profiles[each.key]
  associate_public_ip_address = false
  ebs_optimized               = true
  monitoring                  = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = each.value.imds_hops
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = each.value.disk_gb
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/common-init.sh.tftpl", {
    hostname  = each.key
    proxy_url = local.proxy_url
    domain    = var.domain
    region    = var.region
    ca_cert   = var.ca_cert_pem
  })

  tags = { Name = "${var.name}-${each.key}", Role = each.key }

  # A newer Ubuntu image or edited first-boot script must not replace a running server.
  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

resource "aws_instance" "proxy" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_types["proxy"]
  subnet_id                   = var.subnet_ids["public"]
  vpc_security_group_ids      = [var.security_group_ids["proxy"]]
  iam_instance_profile        = var.instance_profiles["proxy"]
  associate_public_ip_address = true # needed to reach the internet; its security group allows nothing in from it
  ebs_optimized               = true
  monitoring                  = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 10
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/proxy-init.sh.tftpl", {
    squid_conf = templatefile("${path.module}/templates/squid.conf.tftpl", {
      build_cidr = var.zone_cidrs["build"]
      dmz_cidr   = var.zone_cidrs["dmz"]
      prod_cidr  = var.zone_cidrs["prod"]
    })
    harbor_domains    = join("\n", var.harbor_feed_domains)
    bootstrap_domains = join("\n", var.bootstrap_domains)
  })

  tags = { Name = "${var.name}-proxy", Role = "proxy" }

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}
