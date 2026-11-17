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
  # The explorer's build context (images/inzyght, this module's revision): what a host with an
  # explorer in build mode builds the Inzyght image from. It reaches the host beside seedctl (the
  # explorer_build output); its sha256 is in the network's config, and seedctl refuses to build from
  # a context that does not match it.
  # Read only when an explorer builds (as main.tf reads the prefix tools only with a prefix), so a
  # caller that validates against a copy of this directory alone never needs images/.
  explorer_build_json = anytrue([for k, n in var.networks : n.enabled && try(n.explorer.build, null) != null]) ? jsonencode({
    "Dockerfile"    = file("${path.module}/../../../images/inzyght/Dockerfile")
    "entrypoint.sh" = file("${path.module}/../../../images/inzyght/entrypoint.sh")
  }) : ""

  # What seedctl applies for each network (files/seedctl, check_config): the same document on every
  # host; each host drops its own address from `peers`. It reaches the hosts through the deploy
  # workflow (SSM Run Command), never through user_data, so a change here replaces no instance.
  # Testnets get -maxtipage=999999999 first in extra_args: a testnet can stall for days when no one
  # mines, and a node restarted after a day without blocks would think it is still syncing; it then
  # ignores peers' getheaders and refuses getblocktemplate, so no one can join and no miner can
  # restart the chain.
  # insight, zmq_port and explorer appear only when set, so a network without them has exactly the
  # config it had before these options existed (and seedctl renders it byte for byte the same).
  network_config = { for k, n in local.enabled : k => merge({
    name      = k
    profile   = n.profile
    network   = n.testnet ? "testnet" : "mainnet"
    image     = coalesce(n.image, var.image)
    p2p_port  = n.p2p_port
    rpc_port  = n.rpc_port
    node_args = n.testnet ? "-testnet -testnetprofile=${n.profile}" : ""
    dnsseed   = !n.testnet
    # A pool's node builds the block template for the pool's payout address and holds no wallet:
    # -mineraddress must then not be required to be a wallet address (-minetolocalwallet=0). An
    # explorer's node only answers reads, a lightwallet's only serves lightwalletd: no wallet either.
    # An x402 host's node keeps its wallet (the faucet's) and gets an export directory inside its
    # datadir (seedctl x402-backup) and more RPC threads (the API, the facilitator and the faucet).
    extra_args = trimspace(join(" ", compact([n.testnet ? "-maxtipage=999999999" : "", var.extra_args, n.extra_args,
      n.pool == null ? "" : "-disablewallet -mineraddress=${n.pool.payout} -minetolocalwallet=0",
      # yolo's paired jobs: getcoinbasetemplatefor calls in flight plus the template poll and submitblock
      # (the node's default, 4, covers the default concurrency of 2)
      n.pool == null ? "" : n.pool.per_miner && n.pool.coinbase_concurrency > 2 ? "-rpcthreads=${n.pool.coinbase_concurrency + 2}" : "",
      n.explorer == null && n.lightwallet == null ? "" : "-disablewallet",
    n.x402 == null ? "" : "-exportdir=/var/lib/ycash/export -rpcthreads=8 -rpcworkqueue=64"])))
    peers = [for s in local.seed_keys : format("%s:%d", var.seeds[s].public_ip, n.p2p_port)]
    # The yolo pool beside this network's node (files/seedctl render), or null. The per-miner fields
    # appear only with per_miner, and min_block_interval only when above 0, so a pool without them
    # keeps exactly the config it had before.
    pool = n.pool == null ? null : merge({
      image       = n.pool.image
      payout      = n.pool.payout
      port        = n.pool.port
      status_port = n.pool.port + 1
      text        = n.pool.text
      share_ratio = n.pool.share_ratio
      }, n.pool.per_miner ? { per_miner = true } : {},
      n.pool.per_miner ? { coinbase_concurrency = n.pool.coinbase_concurrency, max_paired_per_ip = n.pool.max_paired_per_ip } : {},
    n.pool.min_block_interval > 0 ? { min_block_interval = n.pool.min_block_interval } : {})
    prefix = n.testnet && n.bootstrap && var.prefix != null ? {
      base_url    = local.profile_prefix[n.profile].base_url
      sums_sha256 = local.profile_prefix[n.profile].sums_sha256
      last_height = local.profile_prefix[n.profile].last_height
      network     = local.profile_prefix[n.profile].network
      magic       = lookup(var.prefix_magic_overrides, k, n.magic)
    } : null
    },
    n.insight ? { insight = true } : {},
    n.zmq != null || n.explorer != null ? { zmq_port = coalesce(n.zmq, 28332) } : {},
    # The explorer beside this network's node (files/seedctl render_explorer).
    # p2p_inbound appears only when true, so an explorer without it keeps the config it had before.
    n.explorer == null ? {} : { explorer = merge({
      hostname             = n.explorer.hostname
      acme_email           = var.explorer_acme_email
      tls                  = n.explorer.tls
      image                = n.explorer.image
      build                = n.explorer.build == null ? null : merge(n.explorer.build, { context_sha256 = sha256(local.explorer_build_json) })
      postgres_image       = n.explorer.postgres_image
      proxy_image          = n.explorer.proxy_image
      threads              = n.explorer.threads
      mem_limit_mb         = n.explorer.mem_limit_mb
      log_level            = n.explorer.log_level
      pg_shared_buffers_mb = n.explorer.pg_shared_buffers_mb
      node_mem_limit_mb    = n.explorer.node_mem_limit_mb
    }, n.explorer.p2p_inbound ? { p2p_inbound = true } : {}) },
    # The light-wallet server beside this network's node (files/seedctl-lightwallet).
    n.lightwallet == null ? {} : { lightwallet = {
      hostname          = n.lightwallet.hostname
      acme_email        = var.lightwallet_acme_email
      tls               = n.lightwallet.tls
      image             = n.lightwallet.image
      grpcweb_image     = n.lightwallet.grpcweb_image
      proxy_image       = n.lightwallet.proxy_image
      grpcweb_origins   = n.lightwallet.grpcweb_origins
      mem_limit_mb      = n.lightwallet.mem_limit_mb
      node_mem_limit_mb = n.lightwallet.node_mem_limit_mb
      log_level         = n.lightwallet.log_level
    } },
    # The x402 demonstration beside this network's node (files/seedctl-x402).
    n.x402 == null ? {} : { x402 = {
      hostname                 = n.x402.hostname
      acme_email               = var.x402_acme_email
      tls                      = n.x402.tls
      api_image                = n.x402.api_image
      facilitator_image        = n.x402.facilitator_image
      faucet_image             = n.x402.faucet_image
      proxy_image              = n.x402.proxy_image
      explorer_url             = n.x402.explorer_url
      lightwalletd             = n.x402.lightwalletd
      price_exact_zat          = n.x402.price_exact_zat
      price_broadcast_zat      = n.x402.price_broadcast_zat
      zero_conf_cap_zat        = n.x402.zero_conf_cap_zat
      paid_per_minute          = n.x402.paid_per_minute
      unpaid_per_minute        = n.x402.unpaid_per_minute
      free_per_minute          = n.x402.free_per_minute
      conn_rate_limit          = n.x402.conn_rate_limit
      faucet                   = n.x402.faucet
      node_mem_limit_mb        = n.x402.node_mem_limit_mb
      api_mem_limit_mb         = n.x402.api_mem_limit_mb
      facilitator_mem_limit_mb = n.x402.facilitator_mem_limit_mb
      faucet_mem_limit_mb      = n.x402.faucet_mem_limit_mb
    } }
  ) }
}
