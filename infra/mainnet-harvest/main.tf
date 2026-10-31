# The mainnet harvest (README.md): a results bucket, an instance role that may write only there,
# and a launch template for one-shot instances that run bundles/prefix/run-local-mainnet.sh and
# terminate themselves. Nothing here runs an instance: the operator's workflow launches one from
# the template per run (aws ec2 run-instances --launch-template), with the run id as a tag.
#
# What lives how long (README.md, "What survives what"):
#   bucket, prefix/   the published bundles: kept until deleted by hand (force_destroy off)
#   bucket, runs/     status, logs, results: expire after run_log_days
#   VPC, role, template, security group: free while idle; kept between runs
#   instance and both volumes: one run, then terminated (shutdown = terminate; max_hours cap)

data "aws_partition" "current" {}

data "aws_ssm_parameter" "ubuntu" {
  count = var.ami_id == "" ? 1 : 0
  name  = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

locals {
  ami        = var.ami_id != "" ? var.ami_id : data.aws_ssm_parameter.ubuntu[0].insecure_value
  bucket_arn = "arn:${data.aws_partition.current.partition}:s3:::${var.bucket_name}"

  # /opt/ycash-harvest/harvest.env: every value is validated in variables.tf to a character set that
  # needs no quoting. The run id and the per-run overrides come from the instance's tags.
  harvest_env = join("\n", [
    "BUCKET=${var.bucket_name}",
    "INFRA_REPO=${var.infra_repo_url}",
    "INFRA_COMMIT=${var.infra_commit}",
    "MAX_HOURS=${var.max_hours}",
    "RESERVE_MIN=${var.reserve_minutes}",
    "SPLIT_HEIGHT=${var.split_height}",
    "CROSSCHECK=${var.crosscheck}",
    "RELEASE_TAG=${var.release_tag}",
    "ADDNODES_URL=${var.addnodes_url}",
    "DBCACHE=${var.dbcache}",
    "STATUS_INTERVAL_SEC=${var.status_interval_seconds}",
    "",
  ])
  cloud_init = {
    write_files = [
      { path = "/opt/ycash-harvest/harvest.env", permissions = "0644", content = local.harvest_env },
      { path = "/opt/ycash-harvest/harvest-run.sh", permissions = "0755", content = file("${path.module}/files/harvest-run.sh") },
    ]
    runcmd = [["/opt/ycash-harvest/harvest-run.sh"]]
  }
  cloud_config = join("\n", ["#cloud-config", yamlencode(local.cloud_init)])
}

# ---- the results bucket -----------------------------------------------------------------------
resource "aws_s3_bucket" "results" {
  #checkov:skip=CKV_AWS_18:access logging would cost more than it shows; prefix/ is the only shared part and it is public by design when shared
  #checkov:skip=CKV_AWS_144:cross-region replication: the bundle is reproducible by rerunning the harvest
  #checkov:skip=CKV_AWS_145:SSE-S3 (AES256) is enough: the contents are public blockchain data and logs
  #checkov:skip=CKV2_AWS_62:no event notifications: the workflow polls runs/
  #checkov:skip=CKV_AWS_21:versioning off by design: bundles are write-once (publish-s3.sh refuses an existing one) and logs expire
  #checkov:skip=CKV2_AWS_6:the bucket has aws_s3_bucket_public_access_block.results; its two policy flags follow public_prefix, which checkov cannot evaluate
  bucket        = var.bucket_name
  force_destroy = false # a destroy fails while a bundle is in it
  tags          = merge(var.tags, { Name = var.name_prefix })
}

resource "aws_s3_bucket_ownership_controls" "results" {
  bucket = aws_s3_bucket.results.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  bucket = aws_s3_bucket.results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Without public_prefix every public path is blocked. With it, only the bucket policy below may
# grant public access, and it grants exactly s3:GetObject on prefix/*.
resource "aws_s3_bucket_public_access_block" "results" {
  #checkov:skip=CKV_AWS_54:public_prefix shares prefix/* (and nothing else) by bucket policy when the operator turns it on
  #checkov:skip=CKV_AWS_56:as above
  bucket                  = aws_s3_bucket.results.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = !var.public_prefix
  restrict_public_buckets = !var.public_prefix
}

resource "aws_s3_bucket_lifecycle_configuration" "results" {
  bucket = aws_s3_bucket.results.id
  rule {
    id     = "runs-expire"
    status = "Enabled"
    filter {
      prefix = "runs/"
    }
    expiration {
      days = var.run_log_days
    }
  }
  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

locals {
  bucket_policy = {
    Version = "2012-10-17"
    Statement = concat([{
      Sid       = "TLSOnly"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [local.bucket_arn, "${local.bucket_arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }], var.public_prefix ? [{
      Sid       = "PublicReadPublishedBundles"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${local.bucket_arn}/prefix/*"
    }] : [])
  }
}

resource "aws_s3_bucket_policy" "results" {
  bucket     = aws_s3_bucket.results.id
  policy     = jsonencode(local.bucket_policy)
  depends_on = [aws_s3_bucket_public_access_block.results, aws_s3_bucket_ownership_controls.results]
}

# ---- IAM: the instance writes runs/ and prefix/ of this bucket, and SSM for a shell -------------
resource "aws_iam_role" "harvest" {
  name_prefix = "${var.name_prefix}-"
  description = "Mainnet harvest instances: write the results bucket's runs/ and prefix/, SSM"
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
  role       = aws_iam_role.harvest.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

locals {
  instance_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        # publish-s3.sh checks for an existing bundle with `aws s3 ls`
        Sid       = "ListOwnPrefixes"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = local.bucket_arn
        Condition = { StringLike = { "s3:prefix" = ["prefix/*", "runs/*"] } }
      },
      {
        Sid      = "WriteRunsAndBundles"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
        Resource = ["${local.bucket_arn}/runs/*", "${local.bucket_arn}/prefix/*"]
      },
      {
        # the read-back check after the upload; no delete anywhere: a bundle is write-once
        Sid      = "ReadBundles"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${local.bucket_arn}/prefix/*"
      },
    ]
  }
}

resource "aws_iam_role_policy" "harvest" {
  name_prefix = "${var.name_prefix}-"
  role        = aws_iam_role.harvest.id
  policy      = jsonencode(local.instance_policy)
}

resource "aws_iam_instance_profile" "harvest" {
  name_prefix = "${var.name_prefix}-"
  role        = aws_iam_role.harvest.name
  tags        = var.tags
}

# ---- the launch template -------------------------------------------------------------------------
# No market options here: the workflow asks for spot (or on demand) per launch, because a launch
# template's spot setting cannot be removed by a launch that falls back to on demand.
resource "aws_launch_template" "harvest" {
  name                                 = var.name_prefix
  description                          = "Ycash mainnet harvest: one run, then terminate"
  image_id                             = local.ami
  instance_type                        = var.instance_type
  ebs_optimized                        = true
  instance_initiated_shutdown_behavior = "terminate"
  update_default_version               = true
  vpc_security_group_ids               = [aws_security_group.harvest.id]
  user_data                            = base64gzip(local.cloud_config)

  iam_instance_profile {
    arn = aws_iam_instance_profile.harvest.arn
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # the containers need no instance metadata
    instance_metadata_tags      = "enabled"  # the run id and per-run settings are tags
  }

  monitoring {
    enabled = false # basic metrics; the instance reports to the bucket
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size
      encrypted             = true
      kms_key_id            = var.kms_key_id
      delete_on_termination = true
    }
  }

  block_device_mappings {
    device_name = "/dev/sdf"
    ebs {
      volume_type           = "gp3"
      volume_size           = var.data_volume_size
      iops                  = var.data_volume_iops
      throughput            = var.data_volume_throughput
      encrypted             = true
      kms_key_id            = var.kms_key_id
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = var.name_prefix })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = var.name_prefix })
  }

  tags = merge(var.tags, { Name = var.name_prefix })

  lifecycle {
    precondition {
      condition     = length(base64gzip(local.cloud_config)) * 3 / 4 <= 16384
      error_message = "user_data is over EC2's 16 KB limit."
    }
  }
}
