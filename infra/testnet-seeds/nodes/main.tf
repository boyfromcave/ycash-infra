# One instance per seed. What lives how long (../README.md, "What survives what"):
#
#   Elastic IP          ../ips, forever (prevent_destroy there)
#   network interface   this layer; carries the Elastic IP and the security group, so the address
#                       is in place before an instance boots and never moves between instances
#   data volume         this layer; kept when an instance is replaced, replaced only by a reset
#                       (`terraform apply -replace` of the volumes, ../README.md "Reset")
#   instance            replaced whenever its user_data changes: a new image, new settings, or a new
#                       data volume (the volume id is part of the user_data)
#
# Redeploy is destroy-then-create per instance, not create_before_destroy: the data volume and
# the network interface can each be attached to one instance at a time, so a second instance could
# not take them while the first still runs. A replaced seed is down for a few minutes; with
# image_overrides, one seed can be upgraded first (a canary) while the others keep serving.

data "aws_partition" "current" {}

data "aws_ssm_parameter" "ubuntu" {
  count = var.ami_id == "" ? 1 : 0
  name  = "/aws/service/canonical/ubuntu/server/24.04/stable/current/${var.architecture == "arm64" ? "arm64" : "amd64"}/hvm/ebs-gp3/ami-id"
}

locals {
  ami        = var.ami_id != "" ? var.ami_id : data.aws_ssm_parameter.ubuntu[0].insecure_value
  seed_keys  = sort(keys(var.seeds))
  zone_of    = { for i, k in local.seed_keys : k => var.availability_zones[i % length(var.availability_zones)] }
  image_of   = { for k in local.seed_keys : k => lookup(var.image_overrides, k, var.image) }
  peers_of   = { for k in local.seed_keys : k => [for o in local.seed_keys : format("%s:%d", var.seeds[o].public_ip, var.p2p_port) if o != k] }
  repo_root  = "${path.module}/../../.."
  setup_sh   = file("${path.module}/files/setup.sh")
  done_sh    = file("${path.module}/files/prefix-done.sh")
  restore_sh = var.prefix == null ? "" : file("${local.repo_root}/charts/ycash-testnet/files/prefix-restore.sh")
  frame_py   = var.prefix == null ? "" : file("${local.repo_root}/bundles/prefix/import/frame.py")

  # /opt/ycash-seed/seed.env, read by setup.sh and prefix-done.sh. Every value is validated in
  # variables.tf to a character set that needs no quoting.
  seed_env = { for k in local.seed_keys : k => join("\n", [
    "SEED_NAME=${k}",
    "VOLUME_ID=${aws_ebs_volume.data[k].id}",
    "IMAGE=${local.image_of[k]}",
    "P2P_PORT=${var.p2p_port}",
    "EXTERNAL_IP=${var.seeds[k].public_ip}",
    format("ADDNODES='%s'", join(" ", local.peers_of[k])),
    format("EXTRA_ARGS='%s'", var.extra_args),
    "SWAP_MB=${var.swap_mb}",
    "PREFIX_ENABLED=${var.prefix == null ? 0 : 1}",
    "PREFIX_BASE_URL=${var.prefix == null ? "" : var.prefix.base_url}",
    "PREFIX_SUMS_SHA256=${var.prefix == null ? "" : var.prefix.sums_sha256}",
    "PREFIX_LAST_HEIGHT=${var.prefix == null ? 0 : var.prefix.last_height}",
    "PREFIX_MAGIC=${var.prefix == null ? "" : var.prefix.magic}",
    "",
  ]) }

  cloud_init = { for k in local.seed_keys : k => {
    write_files = concat([
      { path = "/opt/ycash-seed/seed.env", permissions = "0644", content = local.seed_env[k] },
      { path = "/opt/ycash-seed/setup.sh", permissions = "0755", content = local.setup_sh },
      { path = "/opt/ycash-seed/prefix-done.sh", permissions = "0755", content = local.done_sh },
      ], var.prefix == null ? [] : [
      { path = "/opt/ycash-seed/prefix-restore.sh", permissions = "0755", content = local.restore_sh },
      { path = "/opt/ycash-seed/frame.py", permissions = "0644", content = local.frame_py },
    ])
    runcmd = [["/opt/ycash-seed/setup.sh"]]
  } }
  cloud_config = { for k in local.seed_keys : k => join("\n", ["#cloud-config", yamlencode(local.cloud_init[k])]) }
}

# ---- IAM: the instance role is SSM Session Manager and nothing else ---------------------------
resource "aws_iam_role" "seed" {
  name_prefix = "${var.name_prefix}-"
  description = "Testnet seed instances: SSM Session Manager only"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.seed.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "seed" {
  name_prefix = "${var.name_prefix}-"
  role        = aws_iam_role.seed.name
  tags        = var.tags
}

# ---- per seed ---------------------------------------------------------------------------------
resource "aws_network_interface" "seed" {
  for_each = var.seeds

  subnet_id       = aws_subnet.public[local.zone_of[each.key]].id
  security_groups = [aws_security_group.seed.id]
  description     = "${var.name_prefix}-${each.key}"
  tags            = merge(var.tags, { Name = "${var.name_prefix}-${each.key}" })
}

resource "aws_eip_association" "seed" {
  for_each = var.seeds

  allocation_id        = each.value.allocation_id
  network_interface_id = aws_network_interface.seed[each.key].id
}

resource "aws_ebs_volume" "data" {
  for_each = var.seeds

  availability_zone = local.zone_of[each.key]
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true
  kms_key_id        = var.kms_key_id
  tags              = merge(var.tags, { Name = "${var.name_prefix}-${each.key}-data" })
}

resource "aws_instance" "seed" {
  for_each = var.seeds

  ami                  = local.ami
  instance_type        = var.instance_type
  iam_instance_profile = aws_iam_instance_profile.seed.name
  ebs_optimized        = true
  # Basic (5-minute) metrics only: detailed monitoring would add about $2/month per seed for a
  # testnet node whose health the operator reads through SSM (getblockchaininfo, getpeerinfo).
  #checkov:skip=CKV_AWS_126:basic monitoring is enough for a testnet seed (cost)
  monitoring = false

  primary_network_interface {
    network_interface_id = aws_network_interface.seed[each.key].id
  }

  credit_specification {
    cpu_credits = var.cpu_credits
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # the node runs in host networking; nothing in a container needs IMDS
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    kms_key_id            = var.kms_key_id
    delete_on_termination = true
    tags                  = merge(var.tags, { Name = "${var.name_prefix}-${each.key}-root" })
  }

  user_data_base64            = base64gzip(local.cloud_config[each.key])
  user_data_replace_on_change = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.key}" })

  lifecycle {
    # a newer Ubuntu AMI is picked up at the next replacement, never forces one by itself
    ignore_changes = [ami]
    precondition {
      condition     = length(base64gzip(local.cloud_config[each.key])) * 3 / 4 <= 16384
      error_message = "user_data is over EC2's 16 KB limit."
    }
  }

  depends_on = [aws_eip_association.seed, aws_route_table_association.public]
}

resource "aws_volume_attachment" "data" {
  for_each = var.seeds

  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data[each.key].id
  instance_id = aws_instance.seed[each.key].id
  # stop the instance (and so ycashd, cleanly) before the volume is detached on a replacement
  stop_instance_before_detaching = true
}
