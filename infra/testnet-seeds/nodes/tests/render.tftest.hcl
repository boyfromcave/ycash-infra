# Offline: the nodes layer against a mocked AWS provider (no credentials, nothing created). Checks
# what each host's cloud-init carries (and that it fits EC2's 16 KB user_data limit: the
# precondition on aws_instance.seed), the security group's ports per enabled network, and the
# per-network configs seedctl applies. Run: terraform init -backend=false && terraform test
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
  prefix = {
    base_url    = "https://example.org/prefix"
    sums_sha256 = "c7b55a2a6770df8108d910572cca2dbf643a0418eb0b2d556879928a43cbc403"
    last_height = 510247
  }
}

run "three_testnets_by_default" {
  assert {
    condition     = length(aws_instance.seed) == 3 && length(aws_ebs_volume.data) == 3 && length(aws_eip_association.seed) == 3
    error_message = "one instance, data volume and address association per host"
  }
  assert {
    condition     = local.zone_of["seed-0"] == "xx-example-1a" && local.zone_of["seed-1"] == "xx-example-1b" && local.zone_of["seed-2"] == "xx-example-1a"
    error_message = "hosts go round robin over the zones in key order"
  }
  assert {
    condition     = jsonencode(sort(keys(output.network_configs))) == jsonencode(["legacy", "yb-fast", "yb-slow"])
    error_message = "the default serves the three testnets; main is disabled"
  }
  assert {
    condition     = jsonencode(sort([for r in aws_vpc_security_group_ingress_rule.p2p : tostring(r.from_port)])) == jsonencode(["18833", "18933", "19033"])
    error_message = "the security group opens exactly the enabled networks' P2P ports"
  }
  assert {
    condition     = jsondecode(base64decode(output.network_configs["yb-fast"])).node_args == "-testnet -testnetprofile=fast" && jsondecode(base64decode(output.network_configs["yb-fast"])).rpc_port == 18832 && jsondecode(base64decode(output.network_configs["yb-fast"])).prefix.magic == "f77962d3"
    error_message = "fast: its profile argument, RPC port and magic"
  }
  assert {
    condition     = jsondecode(base64decode(output.network_configs["yb-slow"])).p2p_port == 18933 && jsondecode(base64decode(output.network_configs["yb-slow"])).prefix.magic == "f77962d4" && jsondecode(base64decode(output.network_configs["legacy"])).p2p_port == 19033 && jsondecode(base64decode(output.network_configs["legacy"])).prefix.magic == "f77962d5"
    error_message = "slow and legacy: their ports and magics"
  }
  assert {
    condition     = jsonencode(jsondecode(base64decode(output.network_configs["legacy"])).peers) == jsonencode(["192.0.2.10:19033", "192.0.2.11:19033", "192.0.2.12:19033"]) && !jsondecode(base64decode(output.network_configs["legacy"])).dnsseed
    error_message = "every host is a peer on the network's own port; testnets have no DNS seed"
  }
  assert {
    condition     = jsonencode(output.fixed_seeds["yb-slow"]) == jsonencode(["192.0.2.10:18933", "192.0.2.11:18933", "192.0.2.12:18933"])
    error_message = "fixed_seeds lists every address:port per network, sorted"
  }
  assert {
    condition     = strcontains(local.seed_env["seed-0"], "EXTERNAL_IP=192.0.2.10\n") && !strcontains(local.seed_env["seed-0"], "IMAGE") && !strcontains(local.cloud_config["seed-0"], "sha256:0000")
    error_message = "user_data carries the host's own settings only, never a network's config or image"
  }
  assert {
    condition     = startswith(local.cloud_config["seed-0"], "#cloud-config\n") && strcontains(local.cloud_config["seed-0"], "\"path\": \"/opt/ycash-seed/seedctl\"") && strcontains(local.cloud_config["seed-0"], "\"path\": \"/opt/ycash-seed/frame.py\"")
    error_message = "cloud-init carries seedctl and the prefix tools"
  }
  assert {
    condition     = aws_instance.seed["seed-0"].metadata_options[0].http_tokens == "required" && aws_instance.seed["seed-0"].root_block_device[0].encrypted && aws_ebs_volume.data["seed-0"].encrypted
    error_message = "IMDSv2 and encrypted volumes"
  }
  assert {
    condition     = aws_instance.seed["seed-0"].instance_type == "t3a.medium"
    error_message = "t3a.medium by default"
  }
}

run "per_network_image_and_args" {
  variables {
    networks = {
      yb-fast = { profile = "fast", image = "ghcr.io/example/ycashd@sha256:1111111111111111111111111111111111111111111111111111111111111111", extra_args = "-debug=net" }
      yb-slow = { profile = "slow", bootstrap = false }
      legacy  = { profile = "legacy", enabled = false }
    }
    prefix_magic_overrides = { yb-fast = "fa1af9bf" }
  }
  assert {
    condition     = endswith(jsondecode(base64decode(output.network_configs["yb-fast"])).image, "1111111111111111111111111111111111111111111111111111111111111111") && endswith(jsondecode(base64decode(output.network_configs["yb-slow"])).image, "0000000000000000000000000000000000000000000000000000000000000000")
    error_message = "a network's image overrides the default for that network only"
  }
  assert {
    condition     = jsondecode(base64decode(output.network_configs["yb-fast"])).extra_args == "-maxtipage=999999999 -dbcache=256 -maxconnections=64 -debug=net" && jsondecode(base64decode(output.network_configs["yb-fast"])).prefix.magic == "fa1af9bf" && jsondecode(base64decode(output.network_configs["yb-slow"])).prefix == null
    error_message = "extra_args stack; the magic override; bootstrap off"
  }
  assert {
    condition     = !contains(keys(output.network_configs), "legacy") && jsonencode(sort([for r in aws_vpc_security_group_ingress_rule.p2p : tostring(r.from_port)])) == jsonencode(["18833", "18933"])
    error_message = "a disabled network has no config and no open port"
  }
}

run "mainnet_stack" {
  variables {
    networks = { main = { profile = "main" } }
    prefix   = null
  }
  assert {
    condition     = jsondecode(base64decode(output.network_configs["main"])).node_args == "" && jsondecode(base64decode(output.network_configs["main"])).network == "mainnet" && jsondecode(base64decode(output.network_configs["main"])).dnsseed && jsondecode(base64decode(output.network_configs["main"])).prefix == null
    error_message = "main: no -testnet, mainnet, DNS seeds on, no prefix"
  }
  assert {
    condition     = jsonencode([for r in aws_vpc_security_group_ingress_rule.p2p : r.from_port]) == jsonencode([8833]) && jsondecode(base64decode(output.network_configs["main"])).rpc_port == 8832
    error_message = "main: P2P 8833 open, RPC 8832"
  }
  assert {
    condition     = !strcontains(local.cloud_config["seed-0"], "\"path\": \"/opt/ycash-seed/frame.py\"")
    error_message = "no prefix tools without a prefix"
  }
}

run "refuses_main_beside_a_testnet" {
  command = plan
  variables {
    networks = { main = { profile = "main" }, yb-fast = { profile = "fast" } }
  }
  expect_failures = [var.networks]
}

run "refuses_a_shared_profile" {
  command = plan
  variables {
    networks = { a = { profile = "fast" }, b = { profile = "fast" } }
  }
  expect_failures = [var.networks]
}

run "refuses_a_tag" {
  command = plan
  variables {
    image = "ghcr.io/example/ycashd:latest"
  }
  expect_failures = [var.image]
}

run "refuses_a_tag_override" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", image = "ghcr.io/example/ycashd:rc1" } }
  }
  expect_failures = [var.networks]
}
