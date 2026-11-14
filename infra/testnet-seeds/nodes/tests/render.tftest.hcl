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
    condition     = jsondecode(base64decode(output.network_configs["yb-fast"])).prefix.network == "zcash-testnet" && jsondecode(base64decode(output.network_configs["yb-slow"])).prefix.network == "ycash-mainnet" && jsondecode(base64decode(output.network_configs["yb-slow"])).prefix.last_height == 3079999 && jsondecode(base64decode(output.network_configs["legacy"])).prefix.sums_sha256 == "456e820511ade7d9ffd8db41b168ee6063050bb05e2af6a651072bbfb74eecd3"
    error_message = "the prefix per profile from the chart's values files: fast zcash-testnet, slow and legacy mainnet-prefix-v1"
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
    condition     = startswith(local.cloud_config["seed-0"], "#cloud-config\n") && strcontains(local.cloud_config["seed-0"], "\"path\": \"/opt/ycash-seed/seedctl\"") && !strcontains(local.cloud_config["seed-0"], "\"path\": \"/opt/ycash-seed/frame.py\"")
    error_message = "cloud-init carries seedctl; the prefix tools come with the deploy workflow (host_files)"
  }
  assert {
    condition     = jsonencode(sort(keys(jsondecode(base64decode(base64encode(jsonencode(local.host_files))))))) == jsonencode(["frame.py", "prefix-restore.sh"]) && output.host_files != "" && length(aws_vpc_security_group_ingress_rule.explorer) == 0
    error_message = "host_files: the prefix tools only (no explorer here); no explorer port"
  }
  assert {
    condition     = !contains(keys(jsondecode(base64decode(output.network_configs["yb-fast"]))), "insight") && !contains(keys(jsondecode(base64decode(output.network_configs["yb-fast"]))), "zmq_port") && !contains(keys(jsondecode(base64decode(output.network_configs["yb-fast"]))), "explorer")
    error_message = "a network without insight, zmq or explorer has no such key (its config is what it was before the options existed)"
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
    condition     = output.host_files == ""
    error_message = "no prefix tools (and so no host files) without a prefix"
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

# The pool host (README.md, "The pool"): one host, fast only, a yolo pool beside its node.
run "pool_host" {
  variables {
    seeds = {
      "seed-0" = { allocation_id = "eipalloc-00000000000000000", public_ip = "192.0.2.20" }
    }
    networks = {
      yb-fast = {
        profile    = "fast"
        extra_args = "-listen=0 -addnode=fastnet-seed.example.org:18833"
        pool = {
          image       = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222"
          payout      = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb"
          share_ratio = 32
        }
      }
    }
    p2p_ingress_cidrs = []
  }
  assert {
    condition     = jsondecode(base64decode(output.network_configs["yb-fast"])).extra_args == "-maxtipage=999999999 -dbcache=256 -maxconnections=64 -listen=0 -addnode=fastnet-seed.example.org:18833 -disablewallet -mineraddress=smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb -minetolocalwallet=0"
    error_message = "a pool's node: no wallet, the payout address as -mineraddress, not required to be a wallet address"
  }
  assert {
    condition     = jsonencode(jsondecode(base64decode(output.network_configs["yb-fast"])).pool) == jsonencode({ image = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb", port = 3333, status_port = 3334, text = "", share_ratio = 32 })
    error_message = "the pool's config: image, payout, stratum port 3333, status page on 3334"
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.p2p) == 0 && jsonencode([for r in aws_vpc_security_group_ingress_rule.stratum : [r.from_port, r.cidr_ipv4]]) == jsonencode([[3333, "0.0.0.0/0"]])
    error_message = "inbound: the stratum port to everyone, no P2P (the pool's node only connects out), nothing else"
  }
  assert {
    condition     = output.networks["yb-fast"].pool_port == 3333
    error_message = "the networks output names the stratum port"
  }
}

run "no_pool_no_stratum_port" {
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.stratum) == 0 && jsondecode(base64decode(output.network_configs["yb-fast"])).pool == null
    error_message = "the seeds (no pool) open no stratum port and carry pool = null"
  }
}

run "refuses_a_pool_on_mainnet" {
  command = plan
  variables {
    networks = { main = { profile = "main", pool = { image = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout = "t1ExampleExampleExampleExample1234" } } }
    prefix   = null
  }
  expect_failures = [var.networks]
}

run "refuses_a_pool_by_tag_or_on_a_node_port" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", pool = { image = "ghcr.io/example/yolo:latest", payout = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb", port = 18832 } } }
  }
  expect_failures = [var.networks]
}

# The explorer host (README.md, "The explorer"): one host, fast only, Inzyght built on the host.
run "explorer_host" {
  variables {
    seeds = {
      "seed-0" = { allocation_id = "eipalloc-00000000000000000", public_ip = "192.0.2.30" }
    }
    networks = {
      yb-fast = {
        profile    = "fast"
        extra_args = "-listen=0 -addnode=fastnet-seed.example.org:18833"
        insight    = true
        explorer = {
          hostname       = "explorer.example.org"
          build          = { repo = "https://github.com/example/inzyght", commit = "17f505f273c053247b59d20270e4d6a7b74994fb" }
          postgres_image = "docker.io/library/postgres@sha256:3333333333333333333333333333333333333333333333333333333333333333"
          proxy_image    = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444"
        }
      }
    }
    p2p_ingress_cidrs   = []
    explorer_acme_email = "ops@example.org"
  }
  assert {
    condition     = jsondecode(base64decode(output.network_configs["yb-fast"])).insight && jsondecode(base64decode(output.network_configs["yb-fast"])).zmq_port == 28332 && endswith(jsondecode(base64decode(output.network_configs["yb-fast"])).extra_args, "-listen=0 -addnode=fastnet-seed.example.org:18833 -disablewallet")
    error_message = "an explorer's node: the indexes, ZMQ on 28332 by default, no wallet"
  }
  assert {
    condition     = jsonencode(jsondecode(base64decode(output.network_configs["yb-fast"])).explorer) == jsonencode({ acme_email = "ops@example.org", build = { commit = "17f505f273c053247b59d20270e4d6a7b74994fb", context_sha256 = sha256(local.explorer_build_json), jobs = 2, repo = "https://github.com/example/inzyght" }, hostname = "explorer.example.org", image = null, log_level = "INFO", mem_limit_mb = 768, pg_shared_buffers_mb = 256, postgres_image = "docker.io/library/postgres@sha256:3333333333333333333333333333333333333333333333333333333333333333", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444", threads = 4, tls = true })
    error_message = "the explorer's config: name, contact, build (with the build context's sha256), images, defaults"
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.p2p) == 0 && length(aws_vpc_security_group_ingress_rule.stratum) == 0 && jsonencode(sort([for r in aws_vpc_security_group_ingress_rule.explorer : "${r.from_port} ${r.cidr_ipv4}"])) == jsonencode(["443 0.0.0.0/0", "80 0.0.0.0/0"])
    error_message = "inbound: 443 and 80 to everyone, no P2P, nothing else"
  }
  assert {
    condition     = jsonencode(sort(keys(local.host_files))) == jsonencode(["frame.py", "inzyght-build.json", "prefix-restore.sh", "seedctl-explorer"]) && local.host_files["inzyght-build.json"].content == local.explorer_build_json && strcontains(jsondecode(local.explorer_build_json)["Dockerfile"], "ARG INZYGHT_REPO")
    error_message = "host_files: the prefix tools, seedctl's explorer half and the Inzyght build context (images/inzyght)"
  }
  assert {
    condition     = output.explorers["yb-fast"].url == "https://explorer.example.org/" && !strcontains(jsonencode(output.explorers), "ops@example.org") && !strcontains(local.cloud_config["seed-0"], "explorer.example.org")
    error_message = "the explorers output names the URL, never the contact; user_data carries no explorer setting"
  }
}

run "explorer_by_digest_plain_http" {
  variables {
    networks = {
      yb-fast = {
        profile = "fast", insight = true, zmq = 29332
        explorer = {
          hostname = "explorer.example.org", tls = false
          image    = "ghcr.io/example/inzyght@sha256:5555555555555555555555555555555555555555555555555555555555555555"
        postgres_image = "docker.io/library/postgres@sha256:3333333333333333333333333333333333333333333333333333333333333333", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" }
      }
      yb-slow = { profile = "slow" }
    }
  }
  assert {
    condition     = jsondecode(base64decode(output.network_configs["yb-fast"])).zmq_port == 29332 && jsondecode(base64decode(output.network_configs["yb-fast"])).explorer.build == null && !contains(keys(local.host_files), "inzyght-build.json") && contains(keys(local.host_files), "seedctl-explorer")
    error_message = "by digest: no build context; seedctl's explorer half still"
  }
  assert {
    condition     = !contains(keys(jsondecode(base64decode(output.network_configs["yb-slow"]))), "explorer") && output.explorers["yb-fast"].url == "http://explorer.example.org/"
    error_message = "the explorer is fast's only"
  }
}

run "insight_and_zmq_without_explorer" {
  variables {
    networks = { yb-fast = { profile = "fast", insight = true, zmq = 28332 } }
  }
  assert {
    condition     = jsondecode(base64decode(output.network_configs["yb-fast"])).insight && jsondecode(base64decode(output.network_configs["yb-fast"])).zmq_port == 28332 && !contains(keys(jsondecode(base64decode(output.network_configs["yb-fast"]))), "explorer") && length(aws_vpc_security_group_ingress_rule.explorer) == 0
    error_message = "insight and zmq alone: the node's options, no explorer, no port"
  }
}

run "refuses_an_explorer_without_insight" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", explorer = { hostname = "explorer.example.org", image = "ghcr.io/example/inzyght@sha256:5555555555555555555555555555555555555555555555555555555555555555", postgres_image = "docker.io/library/postgres@sha256:3333333333333333333333333333333333333333333333333333333333333333", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } } }
  }
  expect_failures = [var.networks]
}

run "refuses_an_explorer_with_image_and_build" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", insight = true, explorer = { hostname = "explorer.example.org", image = "ghcr.io/example/inzyght@sha256:5555555555555555555555555555555555555555555555555555555555555555", build = { repo = "https://github.com/example/inzyght", commit = "17f505f273c053247b59d20270e4d6a7b74994fb" }, postgres_image = "docker.io/library/postgres@sha256:3333333333333333333333333333333333333333333333333333333333333333", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } } }
  }
  expect_failures = [var.networks]
}

run "refuses_a_debug_log_tag_or_short_commit" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", insight = true, explorer = { hostname = "explorer.example.org", log_level = "DEBUG", build = { repo = "https://github.com/example/inzyght", commit = "17f505f" }, postgres_image = "postgres:17-alpine", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } } }
  }
  expect_failures = [var.networks]
}

run "refuses_an_explorer_beside_a_pool" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", insight = true, pool = { image = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb" }, explorer = { hostname = "explorer.example.org", image = "ghcr.io/example/inzyght@sha256:5555555555555555555555555555555555555555555555555555555555555555", postgres_image = "docker.io/library/postgres@sha256:3333333333333333333333333333333333333333333333333333333333333333", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } } }
  }
  expect_failures = [var.networks]
}
