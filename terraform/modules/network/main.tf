# One VPC split into security zones (one subnet each).
# Only the public zone can reach the internet; every other zone has a local-only route table.

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name}-vpc" }
}

# Take over the default security group and leave it with no rules (CIS benchmark).
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.this.id
}

resource "aws_subnet" "zone" {
  for_each = var.zones

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = "${var.region}${each.value.az}"
  map_public_ip_on_launch = false

  tags = { Name = "${var.name}-${each.key}", Zone = each.key }
}

# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name}-public" }
}

# No routes besides the implicit "local" one: these zones have no path to the internet at all.
resource "aws_route_table" "isolated" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name}-isolated" }
}

resource "aws_route_table_association" "zone" {
  for_each = aws_subnet.zone

  subnet_id      = each.value.id
  route_table_id = each.key == var.public_zone ? aws_route_table.public.id : aws_route_table.isolated.id
}

# ---------------------------------------------------------------------------
# Network ACLs: subnet-level firewall that blocks whole zones from each other.
# Stateless, so every deny is applied in both directions.
# ---------------------------------------------------------------------------

resource "aws_network_acl" "isolated" {
  for_each = var.nacl_deny

  vpc_id     = aws_vpc.this.id
  subnet_ids = [aws_subnet.zone[each.key].id]

  dynamic "ingress" {
    for_each = each.value
    content {
      rule_no    = 50 + ingress.key
      action     = "deny"
      protocol   = "-1"
      cidr_block = var.zones[ingress.value].cidr
      from_port  = 0
      to_port    = 0
    }
  }

  dynamic "egress" {
    for_each = each.value
    content {
      rule_no    = 50 + egress.key
      action     = "deny"
      protocol   = "-1"
      cidr_block = var.zones[egress.value].cidr
      from_port  = 0
      to_port    = 0
    }
  }

  # Everything else inside the VPC is allowed here; security groups do the fine-grained filtering.
  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    cidr_block = var.vpc_cidr
    from_port  = 0
    to_port    = 0
  }

  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    cidr_block = var.vpc_cidr
    from_port  = 0
    to_port    = 0
  }

  tags = { Name = "${var.name}-${each.key}-nacl" }
}

# ---------------------------------------------------------------------------
# VPC Flow Logs: a record of every accepted and rejected connection.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/${var.name}/vpc-flow-logs"
  retention_in_days = 365
}

resource "aws_iam_role" "flow_logs" {
  name                 = "${var.name}-flow-logs"
  permissions_boundary = var.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "write-flow-logs"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    }]
  })
}

resource "aws_flow_log" "this" {
  vpc_id          = aws_vpc.this.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn
}

# ---------------------------------------------------------------------------
# VPC interface endpoints: private access to AWS APIs without internet.
# ---------------------------------------------------------------------------

resource "aws_security_group" "endpoints" {
  name        = "${var.name}-endpoints"
  description = "VPC interface endpoints for AWS APIs"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name}-endpoints" }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints.id
  description       = "HTTPS to AWS APIs from inside the VPC"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(var.interface_endpoints)

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.zone[var.endpoints_zone].id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.name}-${each.key}" }
}
