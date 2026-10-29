# Offline: the nodes layer against a mocked AWS provider (no credentials, nothing created). Checks
# what each seed's cloud-init carries and that it fits EC2's 16 KB user_data limit (the
# precondition on aws_instance.seed). Run: terraform init -backend=false && terraform test
mock_provider "aws" {
  mock_data "aws_ssm_parameter" {
    defaults = { insecure_value = "ami-00000000000000000", value = "ami-00000000000000000" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_resource "aws_ebs_volume" {
    defaults = { id = "vol-0123456789abcdef0" }
  }
}

variables {
  seeds = {
    "seed-0" = { allocation_id = "eipalloc-00000000000000000", public_ip = "192.0.2.10" }
    "seed-1" = { allocation_id = "eipalloc-11111111111111111", public_ip = "192.0.2.11" }
    "seed-2" = { allocation_id = "eipalloc-22222222222222222", public_ip = "192.0.2.12" }
  }
  availability_zones = ["xx-example-1a", "xx-example-1b"]
  image              = "ghcr.io/example/ycashd@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  image_overrides    = { "seed-1" = "ghcr.io/example/ycashd@sha256:1111111111111111111111111111111111111111111111111111111111111111" }
  extra_args         = "-dbcache=512"
  prefix = {
    base_url    = "https://example.org/prefix"
    sums_sha256 = "c7b55a2a6770df8108d910572cca2dbf643a0418eb0b2d556879928a43cbc403"
    last_height = 510247
    magic       = "f77962d3"
  }
}

run "with_prefix" {
  assert {
    condition     = length(aws_instance.seed) == 3 && length(aws_ebs_volume.data) == 3 && length(aws_eip_association.seed) == 3
    error_message = "one instance, data volume and address association per seed"
  }
  assert {
    condition     = local.zone_of["seed-0"] == "xx-example-1a" && local.zone_of["seed-1"] == "xx-example-1b" && local.zone_of["seed-2"] == "xx-example-1a"
    error_message = "seeds go round robin over the zones in key order"
  }
  assert {
    condition     = strcontains(local.seed_env["seed-0"], "EXTERNAL_IP=192.0.2.10\n") && strcontains(local.seed_env["seed-0"], "ADDNODES='192.0.2.11:18833 192.0.2.12:18833'\n")
    error_message = "seed-0 advertises its own address and adds the other two"
  }
  assert {
    condition     = strcontains(local.seed_env["seed-1"], "IMAGE=ghcr.io/example/ycashd@sha256:1111") && strcontains(local.seed_env["seed-2"], "IMAGE=ghcr.io/example/ycashd@sha256:0000")
    error_message = "image_overrides applies to its seed only"
  }
  assert {
    condition     = startswith(local.cloud_config["seed-0"], "#cloud-config\n") && strcontains(local.cloud_config["seed-0"], "\"path\": \"/opt/ycash-seed/frame.py\"") && strcontains(local.seed_env["seed-0"], "PREFIX_MAGIC=f77962d3\n")
    error_message = "cloud-init carries the prefix tools and settings"
  }
  assert {
    condition     = jsonencode(output.fixed_seeds) == jsonencode(["192.0.2.10:18833", "192.0.2.11:18833", "192.0.2.12:18833"])
    error_message = "fixed_seeds lists every address:port, sorted"
  }
  assert {
    condition     = aws_instance.seed["seed-0"].metadata_options[0].http_tokens == "required" && aws_instance.seed["seed-0"].root_block_device[0].encrypted && aws_ebs_volume.data["seed-0"].encrypted
    error_message = "IMDSv2 and encrypted volumes"
  }
}

run "without_prefix" {
  variables {
    prefix = null
  }
  assert {
    condition     = !strcontains(local.cloud_config["seed-0"], "\"path\": \"/opt/ycash-seed/frame.py\"") && strcontains(local.seed_env["seed-0"], "PREFIX_ENABLED=0\n")
    error_message = "no prefix tools without a prefix"
  }
}

run "refuses_a_tag" {
  command = plan
  variables {
    image = "ghcr.io/example/ycashd:latest"
  }
  expect_failures = [var.image]
}
