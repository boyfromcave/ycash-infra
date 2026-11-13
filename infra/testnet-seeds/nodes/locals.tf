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

  # The prefix each testnet profile restores. These files live in this module: a git module
  # source downloads only this directory, so a path up into charts/ is not available to file().
  # They match charts/ycash-testnet (make seeds-validate checks the fields used here). fast restores
  # testnet-prefix-v1 (zcash-testnet 0..510,247); slow and legacy restore mainnet-prefix-v1
  # (ycash-mainnet 0..3,079,999 = H_S).
  chart_dir      = "${path.module}/prefix"
  chart_defaults = yamldecode(file("${local.chart_dir}/values.yaml")).prefixRestore
  chart_files    = { fast = "values-yb-fast.yaml", slow = "values-yb-slow.yaml", legacy = "values-legacy.yaml" }
  chart_prefix = { for p, f in local.chart_files : p => merge(
    { network = local.chart_defaults.network, lastHeight = local.chart_defaults.lastHeight },
    yamldecode(file("${local.chart_dir}/${f}")).prefixRestore
  ) }
  # var.prefix (testnet-prefix-v1) may override the chart's values for the zcash-testnet profile only.
  profile_prefix = { for p, c in local.chart_prefix : p => {
    base_url    = c.network == "zcash-testnet" && var.prefix != null ? coalesce(try(var.prefix.base_url, null), c.baseUrl) : c.baseUrl
    sums_sha256 = c.network == "zcash-testnet" && var.prefix != null ? coalesce(try(var.prefix.sums_sha256, null), c.sha256sums) : c.sha256sums
    last_height = c.network == "zcash-testnet" && var.prefix != null ? coalesce(try(var.prefix.last_height, null), c.lastHeight) : c.lastHeight
    network     = c.network
  } }

  enabled   = { for k, n in var.networks : k => merge(n, local.profiles[n.profile]) if n.enabled }
  seed_keys = sort(keys(var.seeds))

  # What seedctl applies for each network (files/seedctl, check_config): the same document on every
  # host; each host drops its own address from `peers`. It reaches the hosts through the deploy
  # workflow (SSM Run Command), never through user_data, so a change here replaces no instance.
  # Testnets get -maxtipage=999999999 first in extra_args: a testnet can stall for days when no one
  # mines, and a node restarted after a day without blocks would think it is still syncing; it then
  # ignores peers' getheaders and refuses getblocktemplate, so no one can join and no miner can
  # restart the chain.
  network_config = { for k, n in local.enabled : k => {
    name      = k
    profile   = n.profile
    network   = n.testnet ? "testnet" : "mainnet"
    image     = coalesce(n.image, var.image)
    p2p_port  = n.p2p_port
    rpc_port  = n.rpc_port
    node_args = n.testnet ? "-testnet -testnetprofile=${n.profile}" : ""
    dnsseed   = !n.testnet
    # A pool's node builds the block template for the pool's payout address and holds no wallet:
    # -mineraddress must then not be required to be a wallet address (-minetolocalwallet=0).
    extra_args = trimspace(join(" ", compact([n.testnet ? "-maxtipage=999999999" : "", var.extra_args, n.extra_args,
    n.pool == null ? "" : "-disablewallet -mineraddress=${n.pool.payout} -minetolocalwallet=0"])))
    peers = [for s in local.seed_keys : format("%s:%d", var.seeds[s].public_ip, n.p2p_port)]
    # The yolo pool beside this network's node (files/seedctl render), or null.
    pool = n.pool == null ? null : {
      image       = n.pool.image
      payout      = n.pool.payout
      port        = n.pool.port
      status_port = n.pool.port + 1
      text        = n.pool.text
    }
    prefix = n.testnet && n.bootstrap && var.prefix != null ? {
      base_url    = local.profile_prefix[n.profile].base_url
      sums_sha256 = local.profile_prefix[n.profile].sums_sha256
      last_height = local.profile_prefix[n.profile].last_height
      network     = local.profile_prefix[n.profile].network
      magic       = lookup(var.prefix_magic_overrides, k, n.magic)
    } : null
  } }
}
