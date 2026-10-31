# Offline: the module against a mocked AWS provider (no credentials, nothing created). Checks the
# launch template (one-shot: shutdown terminates, IMDSv2, tags readable, encrypted gp3 volumes
# deleted with the instance), what the instance's cloud-init carries, the instance role's reach
# (runs/ and prefix/ of its own bucket only, no delete), and the bucket's public paths: none by
# default, prefix/* read-only with public_prefix. Every value below is a placeholder.
# Run: terraform init -backend=false && terraform test
mock_provider "aws" {
  mock_data "aws_ssm_parameter" {
    defaults = { insecure_value = "ami-00000000000000000", value = "ami-00000000000000000" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
}

variables {
  bucket_name        = "example-bucket"
  availability_zones = ["xx-example-1a", "xx-example-1b"]
  infra_repo_url     = "https://example.org/example/ycash-infra.git"
  infra_commit       = "0123456789abcdef0123456789abcdef01234567"
}

run "one_shot_launch_template" {
  command = plan

  assert {
    condition     = aws_launch_template.harvest.instance_initiated_shutdown_behavior == "terminate" && aws_launch_template.harvest.name == "mainnet-harvest"
    error_message = "a shutdown terminates the instance"
  }
  assert {
    condition     = aws_launch_template.harvest.metadata_options[0].http_tokens == "required" && aws_launch_template.harvest.metadata_options[0].instance_metadata_tags == "enabled" && aws_launch_template.harvest.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "IMDSv2 only, hop limit 1, tags readable (the run id)"
  }
  assert {
    condition     = length(aws_launch_template.harvest.instance_market_options) == 0
    error_message = "no market options in the template: the workflow picks spot or on demand per launch"
  }
  assert {
    condition     = alltrue([for b in aws_launch_template.harvest.block_device_mappings : b.ebs[0].encrypted == "true" && b.ebs[0].delete_on_termination == "true" && b.ebs[0].volume_type == "gp3"])
    error_message = "both volumes encrypted gp3, deleted with the instance"
  }
  assert {
    condition     = one([for b in aws_launch_template.harvest.block_device_mappings : b.ebs[0].volume_size if b.device_name == "/dev/sdf"]) == 500 && aws_launch_template.harvest.instance_type == "m7a.2xlarge"
    error_message = "defaults: a 500 GiB data volume on m7a.2xlarge"
  }
  assert {
    condition     = startswith(local.cloud_config, "#cloud-config\n") && strcontains(local.cloud_config, "\"path\": \"/opt/ycash-harvest/harvest-run.sh\"") && strcontains(local.cloud_config, "/opt/ycash-harvest/harvest-run.sh")
    error_message = "cloud-init carries the run script and runs it"
  }
  assert {
    condition     = strcontains(local.harvest_env, "BUCKET=example-bucket\n") && strcontains(local.harvest_env, "INFRA_COMMIT=0123456789abcdef0123456789abcdef01234567\n") && strcontains(local.harvest_env, "MAX_HOURS=48\n") && strcontains(local.harvest_env, "CROSSCHECK=sync\n") && strcontains(local.harvest_env, "SPLIT_HEIGHT=auto\n") && strcontains(local.harvest_env, "RELEASE_TAG=mainnet-prefix-v1\n")
    error_message = "harvest.env: bucket, commit, lifetime cap and the run defaults"
  }
  assert {
    condition     = length(base64gzip(local.cloud_config)) * 3 / 4 <= 16384
    error_message = "user_data fits EC2's 16 KB"
  }
  assert {
    condition     = length(aws_subnet.public) == 2 && aws_subnet.public["xx-example-1b"].cidr_block == "10.78.1.0/24" && aws_subnet.public["xx-example-1a"].map_public_ip_on_launch
    error_message = "one public /24 per zone"
  }
}

run "instance_role_reach" {
  command = plan

  assert {
    condition     = jsonencode(sort(flatten([for s in jsondecode(aws_iam_role_policy.harvest.policy).Statement : s.Resource]))) == jsonencode(sort(["arn:aws:s3:::example-bucket", "arn:aws:s3:::example-bucket/runs/*", "arn:aws:s3:::example-bucket/prefix/*", "arn:aws:s3:::example-bucket/prefix/*"]))
    error_message = "the instance role reaches only its own bucket's runs/ and prefix/"
  }
  assert {
    condition     = !strcontains(aws_iam_role_policy.harvest.policy, "Delete") && !strcontains(aws_iam_role_policy.harvest.policy, "s3:*")
    error_message = "the instance can never delete or overwrite with wildcard rights"
  }
  assert {
    condition     = aws_iam_role_policy_attachment.ssm.policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    error_message = "SSM core for a shell"
  }
}

run "private_by_default" {
  command = plan

  assert {
    condition     = aws_s3_bucket_public_access_block.results.block_public_policy && aws_s3_bucket_public_access_block.results.restrict_public_buckets && aws_s3_bucket_public_access_block.results.block_public_acls
    error_message = "every public path blocked without public_prefix"
  }
  assert {
    condition     = length(jsondecode(aws_s3_bucket_policy.results.policy).Statement) == 1 && jsondecode(aws_s3_bucket_policy.results.policy).Statement[0].Effect == "Deny"
    error_message = "the bucket policy only refuses plain HTTP"
  }
  assert {
    condition     = !aws_s3_bucket.results.force_destroy
    error_message = "a destroy never deletes a published bundle"
  }
}

run "public_prefix_only" {
  command = plan

  variables {
    public_prefix = true
  }

  assert {
    condition     = !aws_s3_bucket_public_access_block.results.block_public_policy && aws_s3_bucket_public_access_block.results.block_public_acls && aws_s3_bucket_public_access_block.results.ignore_public_acls
    error_message = "a public policy allowed, ACLs still blocked"
  }
  assert {
    condition     = jsonencode([for s in jsondecode(aws_s3_bucket_policy.results.policy).Statement : [s.Action, s.Resource] if s.Effect == "Allow"]) == jsonencode([["s3:GetObject", "arn:aws:s3:::example-bucket/prefix/*"]])
    error_message = "public read of prefix/* and nothing else"
  }
}

run "overrides" {
  command = plan

  variables {
    instance_type    = "m7a.xlarge"
    data_volume_size = 400
    max_hours        = 30
    split_height     = "19999"
    crosscheck       = "none"
    release_tag      = "trial-1"
    addnodes_url     = "https://example.org/peers"
  }

  assert {
    condition     = strcontains(local.harvest_env, "MAX_HOURS=30\n") && strcontains(local.harvest_env, "SPLIT_HEIGHT=19999\n") && strcontains(local.harvest_env, "CROSSCHECK=none\n") && strcontains(local.harvest_env, "RELEASE_TAG=trial-1\n") && strcontains(local.harvest_env, "ADDNODES_URL=https://example.org/peers\n")
    error_message = "the run defaults follow the variables"
  }
}

run "refuses_bad_values" {
  command = plan

  variables {
    infra_commit  = "main"
    bucket_name   = "Example_Bucket"
    instance_type = "m7g.xlarge"
    max_hours     = 500
  }

  expect_failures = [var.infra_commit, var.bucket_name, var.instance_type, var.max_hours]
}
