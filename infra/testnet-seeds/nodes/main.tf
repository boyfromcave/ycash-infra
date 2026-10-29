# One instance per seed host; every host serves every enabled network, one container each.
# What lives how long (../README.md, "What survives what"):
#
#   Elastic IP          ../ips, forever (prevent_destroy there)
#   network interface   this layer; carries the Elastic IP and the security group, so the address
#                       is in place before an instance boots and never moves between instances
#   data volume         this layer; every network's chain, side by side. Kept across upgrades,
#                       resets (a reset deletes one network's directory on it, nothing more) and
#                       instance replacements
#   instance            replaced only for host-level reasons (a new data volume, a -replace by hand);
#                       its user_data is read at creation only (ignore_changes below)
#
# The networks themselves are not AWS resources: their configs are an output (network_configs)
# that the operator's deploy workflow hands to seedctl on each host through SSM Run Command. A new
# image, a reset or a new network therefore touches only the containers of that network; the
# security group's P2P rules follow the enabled networks.

data "aws_partition" "current" {}

data "aws_ssm_parameter" "ubuntu" {
  count = var.ami_id == "" ? 1 : 0
  name  = "/aws/service/canonical/ubuntu/server/24.04/stable/current/${var.architecture == "arm64" ? "arm64" : "amd64"}/hvm/ebs-gp3/ami-id"
}

locals {
  ami       = var.ami_id != "" ? var.ami_id : data.aws_ssm_parameter.ubuntu[0].insecure_value
  zone_of   = { for i, k in local.seed_keys : k => var.availability_zones[i % length(var.availability_zones)] }
  repo_root = "${path.module}/../../.."
  setup_sh  = file("${path.module}/files/setup.sh")
  seedctl   = file("${path.module}/files/seedctl")
  # the prefix tools: seedctl uses them for any network with a prefix (the chart's own scripts)
  restore_sh = var.prefix == null ? "" : file("${local.repo_root}/charts/ycash-testnet/files/prefix-restore.sh")
  frame_py   = var.prefix == null ? "" : file("${local.repo_root}/bundles/prefix/import/frame.py")

  # /opt/ycash-seed/seed.env: the host's own settings only (no network, no image). Every value is
  # validated in variables.tf to a character set that needs no quoting.
  seed_env = { for k in local.seed_keys : k => join("\n", [
    "SEED_NAME=${k}",
    "VOLUME_ID=${aws_ebs_volume.data[k].id}",
    "EXTERNAL_IP=${var.seeds[k].public_ip}",
    "SWAP_MB=${var.swap_mb}",
    "",
  ]) }

  cloud_init = { for k in local.seed_keys : k => {
    write_files = concat([
      { path = "/opt/ycash-seed/seed.env", permissions = "0644", content = local.seed_env[k] },
      { path = "/opt/ycash-seed/setup.sh", permissions = "0755", content = local.setup_sh },
      { path = "/opt/ycash-seed/seedctl", permissions = "0755", content = local.seedctl },
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
  description = "Seed hosts: SSM Session Manager and Run Command only"
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

  user_data_base64 = base64gzip(local.cloud_config[each.key])

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.key}" })

  lifecycle {
    # A newer Ubuntu AMI is picked up at the next replacement, never forces one by itself. The
    # user_data is read at creation only: a module update reaches running hosts through the deploy
    # workflow (it installs the module's seedctl before every run), so bumping the module never
    # replaces every host at once. A host whose data volume is replaced is replaced with it.
    ignore_changes       = [ami, user_data_base64]
    replace_triggered_by = [aws_ebs_volume.data[each.key].id]
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
