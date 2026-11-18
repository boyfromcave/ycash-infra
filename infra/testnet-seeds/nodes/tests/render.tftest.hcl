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

# A per-miner pool (README.md, "The pool": "Per-miner mode"): the node keeps -mineraddress; above a
# coinbase_concurrency of 2 it gets -rpcthreads of it plus 2; the config carries the per-miner fields.
run "pool_host_per_miner" {
  variables {
    seeds = {
      "seed-0" = { allocation_id = "eipalloc-00000000000000000", public_ip = "192.0.2.20" }
    }
    networks = {
      yb-fast = {
        profile    = "fast"
        extra_args = "-addnode=fastnet-seed.example.org:18833"
        pool = {
          image                = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222"
          payout               = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb"
          per_miner            = true
          coinbase_concurrency = 3
        }
      }
    }
    p2p_ingress_cidrs = []
  }
  assert {
    condition     = jsondecode(base64decode(output.network_configs["yb-fast"])).extra_args == "-maxtipage=999999999 -dbcache=256 -maxconnections=64 -addnode=fastnet-seed.example.org:18833 -disablewallet -mineraddress=smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb -minetolocalwallet=0 -rpcthreads=5"
    error_message = "a per-miner pool's node: -mineraddress kept, -rpcthreads = coinbase_concurrency + 2"
  }
  assert {
    condition     = jsonencode(jsondecode(base64decode(output.network_configs["yb-fast"])).pool) == jsonencode({ image = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb", port = 3333, status_port = 3334, text = "", share_ratio = 1, per_miner = true, coinbase_concurrency = 3, max_paired_per_ip = 8 })
    error_message = "the per-miner pool's config: per_miner, coinbase_concurrency 3, max_paired_per_ip 8 (default)"
  }
}

run "pool_host_per_miner_default_concurrency" {
  variables {
    networks = {
      yb-fast = {
        profile = "fast"
        pool    = { image = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb", per_miner = true }
      }
    }
  }
  assert {
    condition     = !strcontains(jsondecode(base64decode(output.network_configs["yb-fast"])).extra_args, "-rpcthreads")
    error_message = "the default concurrency (2) leaves the node's -rpcthreads at its default (4)"
  }
}

# Block pacing (README.md, "The pool": "Block pacing"): min_block_interval above 0 is carried in the
# pool's config; 0, given or left out, renders the config exactly as before (pool_host above).
run "pool_host_paced" {
  variables {
    networks = {
      yb-fast = {
        profile = "fast"
        pool    = { image = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb", share_ratio = 32, min_block_interval = 60 }
      }
    }
  }
  assert {
    condition     = jsonencode(jsondecode(base64decode(output.network_configs["yb-fast"])).pool) == jsonencode({ image = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb", port = 3333, status_port = 3334, text = "", share_ratio = 32, min_block_interval = 60 })
    error_message = "a paced pool's config: min_block_interval 60 beside the other pool fields"
  }
  assert {
    condition     = jsondecode(base64decode(output.network_configs["yb-fast"])).extra_args == "-maxtipage=999999999 -dbcache=256 -maxconnections=64 -disablewallet -mineraddress=smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb -minetolocalwallet=0"
    error_message = "pacing changes nothing on the node's command line"
  }
}

run "pool_host_pacing_zero_is_off" {
  variables {
    networks = {
      yb-fast = {
        profile = "fast"
        pool    = { image = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb", share_ratio = 32, min_block_interval = 0 }
      }
    }
  }
  assert {
    condition     = jsonencode(jsondecode(base64decode(output.network_configs["yb-fast"])).pool) == jsonencode({ image = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb", port = 3333, status_port = 3334, text = "", share_ratio = 32 })
    error_message = "min_block_interval 0 renders the pool's config exactly as without it"
  }
}

run "refuses_a_pacing_above_300" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", pool = { image = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb", min_block_interval = 301 } } }
  }
  expect_failures = [var.networks]
}

run "refuses_a_negative_pacing" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", pool = { image = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb", min_block_interval = -1 } } }
  }
  expect_failures = [var.networks]
}

run "refuses_a_fractional_pacing" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", pool = { image = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb", min_block_interval = 2.5 } } }
  }
  expect_failures = [var.networks]
}

# Pool quotes (README.md, "The pool": "Pool quotes"): the agent's settings in the pool's config (the
# defaults filled in) and -yellowbackpayoutaddress naming the payout address on the node; without
# `quote` neither appears (pool_host above).
run "pool_host_quotes" {
  variables {
    networks = {
      yb-fast = {
        profile = "fast"
        pool    = { image = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb", per_miner = true, quote = { image = "ghcr.io/example/ycash-quote@sha256:3333333333333333333333333333333333333333333333333333333333333333" } }
      }
    }
  }
  assert {
    condition     = endswith(jsondecode(base64decode(output.network_configs["yb-fast"])).extra_args, "-disablewallet -mineraddress=smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb -minetolocalwallet=0 -yellowbackpayoutaddress=smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb")
    error_message = "a quoting pool's node: the payout address as -yellowbackpayoutaddress too"
  }
  assert {
    condition     = jsonencode(jsondecode(base64decode(output.network_configs["yb-fast"])).pool.quote) == jsonencode({ heartbeat_seconds = 600, image = "ghcr.io/example/ycash-quote@sha256:3333333333333333333333333333333333333333333333333333333333333333", min_move_bps = 10, poll_seconds = 75 })
    error_message = "the quote agent's config: image, poll 75 s, 10 bps, heartbeat 600 s (the defaults)"
  }
  assert {
    condition     = contains(keys(local.host_files), "seedctl-quote")
    error_message = "host_files: seedctl's quote half travels with the deploy workflow"
  }
}

run "refuses_a_quote_with_a_heartbeat_past_1200" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", pool = { image = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb", quote = { image = "ghcr.io/example/ycash-quote@sha256:3333333333333333333333333333333333333333333333333333333333333333", heartbeat_seconds = 1800 } } } }
  }
  expect_failures = [var.networks]
}

run "refuses_a_quote_with_a_heartbeat_below_the_poll" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", pool = { image = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb", quote = { image = "ghcr.io/example/ycash-quote@sha256:3333333333333333333333333333333333333333333333333333333333333333", poll_seconds = 120, heartbeat_seconds = 60 } } } }
  }
  expect_failures = [var.networks]
}

run "refuses_a_quote_without_a_p2pkh_payout" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", pool = { image = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout = "t2UNzUUx8mWBCRYPRezvA363EYXyEpHokyi", quote = { image = "ghcr.io/example/ycash-quote@sha256:3333333333333333333333333333333333333333333333333333333333333333" } } } }
  }
  expect_failures = [var.networks]
}

run "refuses_a_quote_image_by_tag" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", pool = { image = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb", quote = { image = "ghcr.io/example/ycash-quote:latest" } } } }
  }
  expect_failures = [var.networks]
}

run "refuses_a_payout_option_beside_a_quote" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", extra_args = "-yellowbackpayoutaddress=smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb", pool = { image = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb", quote = { image = "ghcr.io/example/ycash-quote@sha256:3333333333333333333333333333333333333333333333333333333333333333" } } } }
  }
  expect_failures = [var.networks]
}

run "refuses_a_bad_per_miner_pool" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", pool = { image = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb", per_miner = true, coinbase_concurrency = 65, max_paired_per_ip = 0 } } }
  }
  expect_failures = [var.networks]
}

run "refuses_rpcthreads_beside_a_raised_concurrency" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", extra_args = "-rpcthreads=8", pool = { image = "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb", per_miner = true, coinbase_concurrency = 4 } } }
  }
  expect_failures = [var.networks]
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
    condition     = jsonencode(jsondecode(base64decode(output.network_configs["yb-fast"])).explorer) == jsonencode({ acme_email = "ops@example.org", build = { commit = "17f505f273c053247b59d20270e4d6a7b74994fb", context_sha256 = sha256(local.explorer_build_json), jobs = 2, repo = "https://github.com/example/inzyght" }, hostname = "explorer.example.org", image = null, log_level = "INFO", mem_limit_mb = 768, node_mem_limit_mb = 2304, pg_shared_buffers_mb = 256, postgres_image = "docker.io/library/postgres@sha256:3333333333333333333333333333333333333333333333333333333333333333", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444", threads = 4, tls = true })
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
  assert {
    condition     = jsonencode(sort(keys(aws_vpc_security_group_ingress_rule.p2p))) == jsonencode(["yb-slow 0.0.0.0/0"])
    error_message = "P2P inbound for slow only: the explorer's node publishes no P2P port without p2p_inbound, so none is opened for it"
  }
}

# The value-pools page beside the explorer (README.md, "The explorer": "Value pools"): the option in
# the network's config only when set, its image by digest, no new port and no new host file.
run "explorer_value_pools" {
  variables {
    networks = { yb-fast = { profile = "fast", insight = true, explorer = { hostname = "explorer.example.org", image = "ghcr.io/example/inzyght@sha256:5555555555555555555555555555555555555555555555555555555555555555", postgres_image = "docker.io/library/postgres@sha256:3333333333333333333333333333333333333333333333333333333333333333", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444", pools = { image = "ghcr.io/example/ycash-value-pools@sha256:7777777777777777777777777777777777777777777777777777777777777777", title = "Ycash fast testnet" } } } }
  }
  assert {
    condition     = jsonencode(local.network_config["yb-fast"].explorer.pools) == jsonencode({ image = "ghcr.io/example/ycash-value-pools@sha256:7777777777777777777777777777777777777777777777777777777777777777", mem_limit_mb = 128, title = "Ycash fast testnet" })
    error_message = "explorer.pools reaches the network's config: the image, the default limit, the title"
  }
  assert {
    condition     = alltrue([for k in keys(local.host_files) : contains(["frame.py", "prefix-restore.sh", "seedctl-explorer"], k)]) && contains(keys(local.host_files), "seedctl-explorer") && alltrue([for r in aws_vpc_security_group_ingress_rule.explorer : contains([80, 443], r.from_port)]) && length(aws_vpc_security_group_ingress_rule.p2p) == 0
    error_message = "the value-pools page adds no host file and opens no port (it is served by the explorer's proxy)"
  }
}

run "explorer_without_value_pools_has_no_key" {
  variables {
    networks = { yb-fast = { profile = "fast", insight = true, explorer = { hostname = "explorer.example.org", image = "ghcr.io/example/inzyght@sha256:5555555555555555555555555555555555555555555555555555555555555555", postgres_image = "docker.io/library/postgres@sha256:3333333333333333333333333333333333333333333333333333333333333333", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } } }
  }
  assert {
    condition     = !contains(keys(local.network_config["yb-fast"].explorer), "pools")
    error_message = "an explorer without pools keeps the config it had before the option"
  }
}

run "refuses_a_value_pools_image_by_tag" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", insight = true, explorer = { hostname = "explorer.example.org", image = "ghcr.io/example/inzyght@sha256:5555555555555555555555555555555555555555555555555555555555555555", postgres_image = "docker.io/library/postgres@sha256:3333333333333333333333333333333333333333333333333333333333333333", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444", pools = { image = "ghcr.io/example/ycash-value-pools:latest" } } } }
  }
  expect_failures = [var.networks]
}

run "refuses_a_value_pools_title_with_markup" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", insight = true, explorer = { hostname = "explorer.example.org", image = "ghcr.io/example/inzyght@sha256:5555555555555555555555555555555555555555555555555555555555555555", postgres_image = "docker.io/library/postgres@sha256:3333333333333333333333333333333333333333333333333333333333333333", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444", pools = { image = "ghcr.io/example/ycash-value-pools@sha256:7777777777777777777777777777777777777777777777777777777777777777", title = "<b>x</b>" } } } }
  }
  expect_failures = [var.networks]
}

# Inbound P2P on the explorer's node (README.md, "The explorer": "Inbound P2P"): the option in the
# config, the P2P port opened to p2p_ingress_cidrs, the host's address advertised as on every node.
run "explorer_p2p_inbound" {
  variables {
    seeds = {
      "seed-0" = { allocation_id = "eipalloc-00000000000000000", public_ip = "192.0.2.30" }
    }
    networks = {
      yb-fast = {
        profile    = "fast"
        extra_args = "-addnode=fastnet-seed.example.org:18833"
        insight    = true
        explorer = {
          hostname       = "explorer.example.org"
          build          = { repo = "https://github.com/example/inzyght", commit = "17f505f273c053247b59d20270e4d6a7b74994fb" }
          postgres_image = "docker.io/library/postgres@sha256:3333333333333333333333333333333333333333333333333333333333333333"
          proxy_image    = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444"
          p2p_inbound    = true
        }
      }
    }
    extra_args        = "-dbcache=256 -maxconnections=32"
    p2p_ingress_cidrs = ["0.0.0.0/0"]
  }
  assert {
    condition     = jsondecode(base64decode(output.network_configs["yb-fast"])).explorer.p2p_inbound == true && jsondecode(base64decode(output.network_configs["yb-fast"])).extra_args == "-maxtipage=999999999 -dbcache=256 -maxconnections=32 -addnode=fastnet-seed.example.org:18833 -disablewallet"
    error_message = "p2p_inbound reaches the config; no -listen of the module's own"
  }
  assert {
    condition     = jsonencode([for r in aws_vpc_security_group_ingress_rule.p2p : "${r.from_port}-${r.to_port} ${r.cidr_ipv4}"]) == jsonencode(["18833-18833 0.0.0.0/0"]) && length(aws_vpc_security_group_ingress_rule.explorer) == 2 && length(aws_vpc_security_group_ingress_rule.stratum) == 0
    error_message = "inbound: the P2P port to p2p_ingress_cidrs, besides 443 and 80"
  }
  assert {
    condition     = strcontains(local.seed_env["seed-0"], "EXTERNAL_IP=192.0.2.30\n")
    error_message = "the host's address reaches seedctl, which advertises it (-externalip)"
  }
}

run "refuses_p2p_inbound_without_ingress" {
  command = plan
  variables {
    networks          = { yb-fast = { profile = "fast", insight = true, explorer = { hostname = "explorer.example.org", p2p_inbound = true, image = "ghcr.io/example/inzyght@sha256:5555555555555555555555555555555555555555555555555555555555555555", postgres_image = "docker.io/library/postgres@sha256:3333333333333333333333333333333333333333333333333333333333333333", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } } }
    p2p_ingress_cidrs = []
  }
  expect_failures = [aws_security_group.seed]
}

run "refuses_p2p_inbound_with_listen_0" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", insight = true, extra_args = "-listen=0 -addnode=fastnet-seed.example.org:18833", explorer = { hostname = "explorer.example.org", p2p_inbound = true, image = "ghcr.io/example/inzyght@sha256:5555555555555555555555555555555555555555555555555555555555555555", postgres_image = "docker.io/library/postgres@sha256:3333333333333333333333333333333333333333333333333333333333333333", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } } }
  }
  expect_failures = [aws_security_group.seed]
}

run "refuses_p2p_inbound_with_a_module_wide_nolisten" {
  command = plan
  variables {
    networks   = { yb-fast = { profile = "fast", insight = true, explorer = { hostname = "explorer.example.org", p2p_inbound = true, image = "ghcr.io/example/inzyght@sha256:5555555555555555555555555555555555555555555555555555555555555555", postgres_image = "docker.io/library/postgres@sha256:3333333333333333333333333333333333333333333333333333333333333333", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } } }
    extra_args = "-dbcache=256 -nolisten"
  }
  expect_failures = [aws_security_group.seed]
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

run "explorer_node_memory" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", insight = true, explorer = { hostname = "explorer.example.org", node_mem_limit_mb = 3072, image = "ghcr.io/example/inzyght@sha256:5555555555555555555555555555555555555555555555555555555555555555", postgres_image = "docker.io/library/postgres@sha256:3333333333333333333333333333333333333333333333333333333333333333", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } } }
  }
  assert {
    condition     = local.network_config["yb-fast"].explorer.node_mem_limit_mb == 3072
    error_message = "node_mem_limit_mb reaches the network's config"
  }
}

run "refuses_a_small_or_fractional_node_memory" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", insight = true, explorer = { hostname = "explorer.example.org", node_mem_limit_mb = 256.5, image = "ghcr.io/example/inzyght@sha256:5555555555555555555555555555555555555555555555555555555555555555", postgres_image = "docker.io/library/postgres@sha256:3333333333333333333333333333333333333333333333333333333333333333", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } } }
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

# The lightwallet host (README.md, "The lightwallet"): one host, fast only, lightwalletd-dd, the
# gRPC-web proxy and the TLS proxy.
run "lightwallet_host" {
  variables {
    seeds = {
      "seed-0" = { allocation_id = "eipalloc-00000000000000000", public_ip = "192.0.2.40" }
    }
    networks = {
      yb-fast = {
        profile    = "fast"
        extra_args = "-listen=0 -addnode=fastnet-seed.example.org:18833"
        insight    = true
        lightwallet = {
          hostname        = "lightwallet.example.org"
          grpcweb_origins = ["https://wallet.example.org"]
          image           = "ghcr.io/example/lightwalletd@sha256:6666666666666666666666666666666666666666666666666666666666666666"
          grpcweb_image   = "docker.io/envoyproxy/envoy@sha256:7777777777777777777777777777777777777777777777777777777777777777"
          proxy_image     = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444"
        }
      }
    }
    p2p_ingress_cidrs      = ["0.0.0.0/0"]
    lightwallet_acme_email = "ops@example.org"
  }
  assert {
    condition     = jsondecode(base64decode(output.network_configs["yb-fast"])).insight && !contains(keys(jsondecode(base64decode(output.network_configs["yb-fast"]))), "zmq_port") && endswith(jsondecode(base64decode(output.network_configs["yb-fast"])).extra_args, "-listen=0 -addnode=fastnet-seed.example.org:18833 -disablewallet")
    error_message = "a lightwallet's node: the indexes, no ZMQ, no wallet"
  }
  assert {
    condition     = jsonencode(jsondecode(base64decode(output.network_configs["yb-fast"])).lightwallet) == jsonencode({ acme_email = "ops@example.org", grpcweb_image = "docker.io/envoyproxy/envoy@sha256:7777777777777777777777777777777777777777777777777777777777777777", grpcweb_origins = ["https://wallet.example.org"], hostname = "lightwallet.example.org", image = "ghcr.io/example/lightwalletd@sha256:6666666666666666666666666666666666666666666666666666666666666666", log_level = 4, mem_limit_mb = 768, node_mem_limit_mb = 2304, proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444", tls = true })
    error_message = "the lightwallet's config: name, contact, images, defaults"
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.p2p) == 0 && length(aws_vpc_security_group_ingress_rule.stratum) == 0 && length(aws_vpc_security_group_ingress_rule.explorer) == 0 && jsonencode(sort([for r in aws_vpc_security_group_ingress_rule.lightwallet : "${r.from_port} ${r.cidr_ipv4}"])) == jsonencode(["443 0.0.0.0/0", "80 0.0.0.0/0"])
    error_message = "inbound: 443 and 80 to everyone, no P2P (the node publishes none), nothing else"
  }
  assert {
    condition     = jsonencode(sort(keys(local.host_files))) == jsonencode(["frame.py", "prefix-restore.sh", "seedctl-lightwallet"]) && local.host_files["seedctl-lightwallet"].content == file("${path.module}/files/seedctl-lightwallet")
    error_message = "host_files: the prefix tools and seedctl's lightwallet half"
  }
  assert {
    condition     = jsonencode(output.lightwallets["yb-fast"]) == jsonencode({ grpc = "lightwallet.example.org:443", hostname = "lightwallet.example.org", lightwalletd = "ghcr.io/example/lightwalletd@sha256:6666666666666666666666666666666666666666666666666666666666666666", tls = true, url = "https://lightwallet.example.org" }) && !strcontains(jsonencode(output.lightwallets), "ops@example.org") && !strcontains(local.cloud_config["seed-0"], "lightwallet.example.org")
    error_message = "the lightwallets output names the endpoints, never the contact; user_data carries no lightwallet setting"
  }
}

run "lightwallet_plain_http_and_origins" {
  variables {
    networks = {
      yb-fast = {
        profile = "fast", insight = true
        lightwallet = {
          hostname     = "lightwallet.example.org", tls = false, grpcweb_origins = ["https://wallet.example.org", "http://localhost:5173"]
          mem_limit_mb = 512, node_mem_limit_mb = 3072, log_level = 5
          image        = "ghcr.io/example/lightwalletd@sha256:6666666666666666666666666666666666666666666666666666666666666666"
        grpcweb_image = "docker.io/envoyproxy/envoy@sha256:7777777777777777777777777777777777777777777777777777777777777777", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" }
      }
      yb-slow = { profile = "slow" }
    }
  }
  assert {
    condition     = output.lightwallets["yb-fast"].url == "http://lightwallet.example.org" && output.lightwallets["yb-fast"].grpc == "lightwallet.example.org:80" && jsonencode(jsondecode(base64decode(output.network_configs["yb-fast"])).lightwallet.grpcweb_origins) == jsonencode(["https://wallet.example.org", "http://localhost:5173"])
    error_message = "plain HTTP: port 80; the origins as given"
  }
  assert {
    condition     = !contains(keys(jsondecode(base64decode(output.network_configs["yb-slow"]))), "lightwallet") && jsonencode(sort(keys(aws_vpc_security_group_ingress_rule.p2p))) == jsonencode(["yb-slow 0.0.0.0/0"])
    error_message = "the lightwallet is fast's only; P2P inbound for slow only"
  }
}

run "refuses_a_lightwallet_without_insight" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", lightwallet = { hostname = "lw.example.org", grpcweb_origins = ["https://wallet.example.org"], image = "ghcr.io/example/lightwalletd@sha256:6666666666666666666666666666666666666666666666666666666666666666", grpcweb_image = "docker.io/envoyproxy/envoy@sha256:7777777777777777777777777777777777777777777777777777777777777777", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } } }
  }
  expect_failures = [var.networks]
}

run "refuses_a_placeholder_digest" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", insight = true, lightwallet = { hostname = "lw.example.org", grpcweb_origins = ["https://wallet.example.org"], image = "ghcr.io/example/lightwalletd@sha256:0000000000000000000000000000000000000000000000000000000000000000", grpcweb_image = "docker.io/envoyproxy/envoy@sha256:7777777777777777777777777777777777777777777777777777777777777777", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } } }
  }
  expect_failures = [aws_security_group.seed]
}

run "refuses_an_origin_with_a_path" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", insight = true, lightwallet = { hostname = "lw.example.org", grpcweb_origins = ["https://x.example.org/path"], image = "ghcr.io/example/lightwalletd@sha256:6666666666666666666666666666666666666666666666666666666666666666", grpcweb_image = "docker.io/envoyproxy/envoy@sha256:7777777777777777777777777777777777777777777777777777777777777777", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } } }
  }
  expect_failures = [var.networks]
}

run "refuses_a_wildcard_origin" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", insight = true, lightwallet = { hostname = "lw.example.org", grpcweb_origins = ["https://wallet.example.org", "*"], image = "ghcr.io/example/lightwalletd@sha256:6666666666666666666666666666666666666666666666666666666666666666", grpcweb_image = "docker.io/envoyproxy/envoy@sha256:7777777777777777777777777777777777777777777777777777777777777777", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } } }
  }
  expect_failures = [var.networks]
}

run "refuses_no_origin" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", insight = true, lightwallet = { hostname = "lw.example.org", grpcweb_origins = [], image = "ghcr.io/example/lightwalletd@sha256:6666666666666666666666666666666666666666666666666666666666666666", grpcweb_image = "docker.io/envoyproxy/envoy@sha256:7777777777777777777777777777777777777777777777777777777777777777", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } } }
  }
  expect_failures = [var.networks]
}

run "refuses_a_lightwallet_beside_an_explorer" {
  command = plan
  variables {
    networks = {
      yb-fast = { profile = "fast", insight = true, lightwallet = { hostname = "lw.example.org", grpcweb_origins = ["https://wallet.example.org"], image = "ghcr.io/example/lightwalletd@sha256:6666666666666666666666666666666666666666666666666666666666666666", grpcweb_image = "docker.io/envoyproxy/envoy@sha256:7777777777777777777777777777777777777777777777777777777777777777", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } }
      yb-slow = { profile = "slow", insight = true, explorer = { hostname = "explorer.example.org", image = "ghcr.io/example/inzyght@sha256:5555555555555555555555555555555555555555555555555555555555555555", postgres_image = "docker.io/library/postgres@sha256:3333333333333333333333333333333333333333333333333333333333333333", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } }
    }
  }
  expect_failures = [var.networks]
}

run "refuses_a_lightwallet_beside_a_pool" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", insight = true, pool = { image = "ghcr.io/example/yolo@sha256:1111111111111111111111111111111111111111111111111111111111111111", payout = "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb" }, lightwallet = { hostname = "lw.example.org", grpcweb_origins = ["https://wallet.example.org"], image = "ghcr.io/example/lightwalletd@sha256:6666666666666666666666666666666666666666666666666666666666666666", grpcweb_image = "docker.io/envoyproxy/envoy@sha256:7777777777777777777777777777777777777777777777777777777777777777", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } } }
  }
  expect_failures = [var.networks]
}

# The x402 host (README.md, "The x402 host"): one host, fast only, the chain API, the facilitator, the
# faucet with its wallet in the node, and the TLS proxy on 443 alone.
run "x402_host" {
  variables {
    seeds = {
      "seed-0" = { allocation_id = "eipalloc-00000000000000000", public_ip = "192.0.2.50" }
    }
    networks = {
      yb-fast = {
        profile    = "fast"
        extra_args = "-listen=0 -addnode=192.0.2.10:18833"
        insight    = true
        x402 = {
          hostname          = "x402.example.org"
          explorer_url      = "https://explorer.example.org"
          lightwalletd      = "lightwallet.example.org:443"
          api_image         = "ghcr.io/example/x402-ycash-chain-api@sha256:8888888888888888888888888888888888888888888888888888888888888888"
          facilitator_image = "ghcr.io/example/x402-ycash-facilitator@sha256:9999999999999999999999999999999999999999999999999999999999999999"
          faucet_image      = "ghcr.io/example/faucet@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
          proxy_image       = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444"
        }
      }
    }
    p2p_ingress_cidrs = []
    x402_acme_email   = "ops@example.org"
  }
  assert {
    condition     = jsondecode(base64decode(output.network_configs["yb-fast"])).insight && !strcontains(jsondecode(base64decode(output.network_configs["yb-fast"])).extra_args, "-disablewallet") && endswith(jsondecode(base64decode(output.network_configs["yb-fast"])).extra_args, "-listen=0 -addnode=192.0.2.10:18833 -exportdir=/var/lib/ycash/export -rpcthreads=8 -rpcworkqueue=64")
    error_message = "an x402 host's node: the indexes, its wallet (no -disablewallet), the export directory, more RPC threads"
  }
  assert {
    condition = jsonencode(jsondecode(base64decode(output.network_configs["yb-fast"])).x402) == jsonencode({
      acme_email        = "ops@example.org", api_image = "ghcr.io/example/x402-ycash-chain-api@sha256:8888888888888888888888888888888888888888888888888888888888888888",
      api_mem_limit_mb  = 256, conn_rate_limit = 60, explorer_url = "https://explorer.example.org", free_per_minute = 120, lightwalletd = "lightwallet.example.org:443",
      facilitator_image = "ghcr.io/example/x402-ycash-facilitator@sha256:9999999999999999999999999999999999999999999999999999999999999999", facilitator_mem_limit_mb = 192,
      faucet            = { amount_zat = 10000000, daily_cap_zat = 1000000000, per_address = 1, per_ip = 1, pow_bits = 16, sweep_min_zat = 1000000, window_seconds = 86400 },
      faucet_image      = "ghcr.io/example/faucet@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", faucet_mem_limit_mb = 96,
      hostname          = "x402.example.org", node_mem_limit_mb = 1536, paid_per_minute = 120, price_broadcast_zat = 10000, price_exact_zat = 10000, unpaid_per_minute = 30,
    proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444", tls = true, zero_conf_cap_zat = 100000 })
    error_message = "the x402's config: name, contact, images, the D-10 prices, the faucet's limits, the memory limits"
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.p2p) == 0 && length(aws_vpc_security_group_ingress_rule.stratum) == 0 && length(aws_vpc_security_group_ingress_rule.explorer) == 0 && length(aws_vpc_security_group_ingress_rule.lightwallet) == 0 && jsonencode([for r in aws_vpc_security_group_ingress_rule.x402 : "${r.from_port}-${r.to_port} ${r.cidr_ipv4}"]) == jsonencode(["443-443 0.0.0.0/0"])
    error_message = "inbound: 443 to everyone and nothing else (no 80: the certificate comes over TLS-ALPN; no P2P)"
  }
  assert {
    condition     = jsonencode(sort(keys(local.host_files))) == jsonencode(["frame.py", "prefix-restore.sh", "seedctl-x402"]) && local.host_files["seedctl-x402"].content == file("${path.module}/files/seedctl-x402")
    error_message = "host_files: the prefix tools and seedctl's x402 half"
  }
  assert {
    condition     = output.x402s["yb-fast"].url == "https://x402.example.org" && output.x402s["yb-fast"].faucet == "https://x402.example.org/faucet/" && !strcontains(jsonencode(output.x402s), "ops@example.org") && !strcontains(local.cloud_config["seed-0"], "x402.example.org")
    error_message = "the x402s output names the URLs, never the contact; user_data carries no x402 setting"
  }
}

run "x402_plain_http_and_limits" {
  variables {
    networks = {
      yb-fast = {
        profile = "fast", insight = true
        x402 = {
          hostname  = "x402.example.org", tls = false, price_exact_zat = 20000, conn_rate_limit = 30
          faucet    = { amount_zat = 50000000, pow_bits = 20 }
          api_image = "ghcr.io/example/x402-ycash-chain-api@sha256:8888888888888888888888888888888888888888888888888888888888888888", facilitator_image = "ghcr.io/example/x402-ycash-facilitator@sha256:9999999999999999999999999999999999999999999999999999999999999999"
        faucet_image = "ghcr.io/example/faucet@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" }
      }
      yb-slow = { profile = "slow" }
    }
  }
  assert {
    condition     = output.x402s["yb-fast"].url == "http://x402.example.org" && jsonencode([for r in aws_vpc_security_group_ingress_rule.x402 : r.from_port]) == jsonencode([80])
    error_message = "plain HTTP: port 80 only"
  }
  assert {
    condition     = jsonencode(jsondecode(base64decode(output.network_configs["yb-fast"])).x402.faucet) == jsonencode({ amount_zat = 50000000, daily_cap_zat = 1000000000, per_address = 1, per_ip = 1, pow_bits = 20, sweep_min_zat = 1000000, window_seconds = 86400 })
    error_message = "a partly given faucet keeps the other defaults"
  }
  assert {
    condition     = !contains(keys(jsondecode(base64decode(output.network_configs["yb-slow"]))), "x402") && strcontains(jsondecode(base64decode(output.network_configs["yb-slow"])).extra_args, "") && !strcontains(jsondecode(base64decode(output.network_configs["yb-slow"])).extra_args, "-exportdir") && jsonencode(sort(keys(aws_vpc_security_group_ingress_rule.p2p))) == jsonencode(["yb-slow 0.0.0.0/0"])
    error_message = "the x402 is fast's only; slow's node has no export directory; P2P inbound for slow only"
  }
}

run "refuses_an_x402_without_insight" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", x402 = { hostname = "x.example.org", api_image = "ghcr.io/example/a@sha256:8888888888888888888888888888888888888888888888888888888888888888", facilitator_image = "ghcr.io/example/f@sha256:9999999999999999999999999999999999999999999999999999999999999999", faucet_image = "ghcr.io/example/faucet@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } } }
  }
  expect_failures = [var.networks]
}

run "refuses_an_x402_placeholder_digest" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", insight = true, x402 = { hostname = "x.example.org", api_image = "ghcr.io/example/a@sha256:0000000000000000000000000000000000000000000000000000000000000000", facilitator_image = "ghcr.io/example/f@sha256:9999999999999999999999999999999999999999999999999999999999999999", faucet_image = "ghcr.io/example/faucet@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } } }
  }
  expect_failures = [aws_security_group.seed]
}

run "refuses_an_x402_image_by_tag" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", insight = true, x402 = { hostname = "x.example.org", api_image = "ghcr.io/example/a:latest", facilitator_image = "ghcr.io/example/f@sha256:9999999999999999999999999999999999999999999999999999999999999999", faucet_image = "ghcr.io/example/faucet@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } } }
  }
  expect_failures = [var.networks]
}

run "refuses_a_faucet_cap_below_one_payment" {
  command = plan
  variables {
    networks = { yb-fast = { profile = "fast", insight = true, x402 = { hostname = "x.example.org", faucet = { amount_zat = 100000000, daily_cap_zat = 1000 }, api_image = "ghcr.io/example/a@sha256:8888888888888888888888888888888888888888888888888888888888888888", facilitator_image = "ghcr.io/example/f@sha256:9999999999999999999999999999999999999999999999999999999999999999", faucet_image = "ghcr.io/example/faucet@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } } }
  }
  expect_failures = [var.networks]
}

run "refuses_an_x402_beside_a_lightwallet" {
  command = plan
  variables {
    networks = {
      yb-fast = { profile = "fast", insight = true, x402 = { hostname = "x.example.org", api_image = "ghcr.io/example/a@sha256:8888888888888888888888888888888888888888888888888888888888888888", facilitator_image = "ghcr.io/example/f@sha256:9999999999999999999999999999999999999999999999999999999999999999", faucet_image = "ghcr.io/example/faucet@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } }
      yb-slow = { profile = "slow", insight = true, lightwallet = { hostname = "lw.example.org", grpcweb_origins = ["https://wallet.example.org"], image = "ghcr.io/example/lightwalletd@sha256:6666666666666666666666666666666666666666666666666666666666666666", grpcweb_image = "docker.io/envoyproxy/envoy@sha256:7777777777777777777777777777777777777777777777777777777777777777", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } }
    }
  }
  expect_failures = [var.networks]
}

run "refuses_an_x402_on_mainnet" {
  command = plan
  variables {
    networks = { main = { profile = "main", insight = true, x402 = { hostname = "x.example.org", api_image = "ghcr.io/example/a@sha256:8888888888888888888888888888888888888888888888888888888888888888", facilitator_image = "ghcr.io/example/f@sha256:9999999999999999999999999999999999999999999999999999999999999999", faucet_image = "ghcr.io/example/faucet@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", proxy_image = "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444" } } }
  }
  expect_failures = [var.networks]
}
