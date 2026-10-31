# The network profiles this module knows: what each `networks` entry's `profile` selects. The
# testnet rows are the owner's Revision 3 table (workspace docs/plans/yellowback-testnet-plan.md,
# "The three networks", decision T-14): each testnet has its own magic, P2P port (RPC one below)
# and datadir name, all compiled into the node and selected by `-testnet -testnetprofile=<name>`.
# `main` is mainnet (T-18): its compiled ports, no -testnet, and its DNS seeds stay on.
#
# `magic` is what the shared, magic-neutral prefix is framed with (it must equal the node's compiled
# magic for that profile); mainnet has no prefix. `datadir` is informational (the node picks it).
locals {
  profiles = {
    fast   = { testnet = true, p2p_port = 18833, rpc_port = 18832, magic = "f77962d3", datadir = "testnet-yb-fast" }
    slow   = { testnet = true, p2p_port = 18933, rpc_port = 18932, magic = "f77962d4", datadir = "testnet-yb-slow" }
    legacy = { testnet = true, p2p_port = 19033, rpc_port = 19032, magic = "f77962d5", datadir = "testnet-legacy" }
    main   = { testnet = false, p2p_port = 8833, rpc_port = 8832, magic = "24e92764", datadir = "" }
  }

  enabled   = { for k, n in var.networks : k => merge(n, local.profiles[n.profile]) if n.enabled }
  seed_keys = sort(keys(var.seeds))

  # What seedctl applies for each network (files/seedctl, check_config): the same document on every
  # host; each host drops its own address from `peers`. It reaches the hosts through the deploy
  # workflow (SSM Run Command), never through user_data, so a change here replaces no instance.
  network_config = { for k, n in local.enabled : k => {
    name       = k
    profile    = n.profile
    network    = n.testnet ? "testnet" : "mainnet"
    image      = coalesce(n.image, var.image)
    p2p_port   = n.p2p_port
    rpc_port   = n.rpc_port
    node_args  = n.testnet ? "-testnet -testnetprofile=${n.profile}" : ""
    dnsseed    = !n.testnet
    # -maxtipage: a testnet can stall for days when no one mines. Without it a node restarted after
    # a day without blocks thinks it is still syncing: it ignores peers' getheaders and refuses
    # getblocktemplate, so no one can join and the miner cannot restart the chain.
    extra_args = trimspace(join(" ", compact([n.testnet ? "-maxtipage=999999999" : "", var.extra_args, n.extra_args])))
    peers      = [for s in local.seed_keys : format("%s:%d", var.seeds[s].public_ip, n.p2p_port)]
    prefix = n.testnet && n.bootstrap && var.prefix != null ? {
      base_url    = var.prefix.base_url
      sums_sha256 = var.prefix.sums_sha256
      last_height = var.prefix.last_height
      magic       = lookup(var.prefix_magic_overrides, k, n.magic)
    } : null
  } }
}
