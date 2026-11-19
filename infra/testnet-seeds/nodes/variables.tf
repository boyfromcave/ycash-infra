# Everything that is account- or operator-specific is a variable here; nothing in this directory
# names an account, a bucket, a person or a region.

variable "seeds" {
  description = "The seed host addresses, as the ips layer's `seeds` output: { seed-0 = { allocation_id, public_ip }, ... }. One instance per entry; every instance serves every enabled network."
  type = map(object({
    allocation_id = string
    public_ip     = string
  }))
  validation {
    condition     = length(var.seeds) >= 1 && alltrue([for k, s in var.seeds : can(regex("^[a-z0-9-]{1,32}$", k)) && can(regex("^eipalloc-[0-9a-f]+$", s.allocation_id)) && can(cidrhost("${s.public_ip}/32", 0))])
    error_message = "seeds: at least one entry; keys of lowercase letters, digits and dashes; allocation_id eipalloc-...; public_ip an IPv4 address."
  }
}

variable "availability_zones" {
  description = "Zones to spread the hosts over, round robin in key order (seed-0 in the first). Two or more is recommended."
  type        = list(string)
  validation {
    condition     = length(var.availability_zones) >= 1 && length(var.availability_zones) <= 6
    error_message = "availability_zones: 1 to 6 zones of the provider's region."
  }
}

variable "name_prefix" {
  description = "Prefix of every resource's Name tag and of the IAM role name. Keep it generic."
  type        = string
  default     = "testnet-seed"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.name_prefix))
    error_message = "name_prefix: lowercase letters, digits and dashes, starting with a letter, at most 31 characters."
  }
}

variable "tags" {
  description = "Extra tags on every resource. Keep them generic: no names, no account details."
  type        = map(string)
  default     = {}
}

variable "vpc_cidr" {
  description = "The hosts' own small VPC (one public subnet per zone, a /24 each, no NAT)."
  type        = string
  default     = "10.77.0.0/16"
  validation {
    condition     = can(cidrsubnet(var.vpc_cidr, 8, 0))
    error_message = "vpc_cidr must be an IPv4 CIDR of /16 to /20 (each zone gets a subnet 8 bits longer)."
  }
}

variable "image" {
  description = "The default ycashd image of every network, by digest: <repository>@sha256:<64 hex> (for example the node-image workflow's ghcr.io/<owner>/ycashd@sha256:...). One image serves every profile: the profile is a runtime argument. A network's own `image` overrides it. Changing it changes no AWS resource: seedctl rolls it out (README.md, \"Per-network lifecycle\")."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}$", var.image))
    error_message = "image must be pinned by digest: <repository>@sha256:<64 lowercase hex>."
  }
}

variable "networks" {
  description = <<-EOT
    The networks every host serves, one container each: { <key> = { profile, enabled, image,
    bootstrap, extra_args } }. The key names the network in seedctl, in the container name
    (ycashd-<key>) and in its data directory; the profile picks the ports, the magic and the node
    arguments (locals.tf, `profiles`): fast, slow and legacy are the three testnets
    (-testnet -testnetprofile=<profile>), main is mainnet (no -testnet; a separate stack, never
    beside a testnet). Adding or removing a network is one entry. `image` overrides var.image for
    that network; `bootstrap` (default true) imports var.prefix into an empty datadir (testnet
    profiles only); `extra_args` is appended after var.extra_args.

    `pool` (testnet profiles only; default none) runs a yolo stratum pool beside that network's node
    on every host (README.md, "The pool"): `image` the yolo image by digest (yolo-image.yml),
    `payout` a transparent address, always the node's -mineraddress (the node runs with
    -disablewallet -minetolocalwallet=0: no key on the host) and, unless `per_miner`, the address
    every block pays (yolo --payout), `port` the stratum port (default 3333, opened to
    var.pool_ingress_cidrs; yolo's status page is on port + 1, loopback only), `text` an optional
    coinbase text (yolo --text), `share_ratio` yolo's --share-ratio (default 1, the block target;
    above 1 needs a yolo with the flag). `per_miner` (default false) pays each miner at its stratum
    username instead (yolo without --payout; a transparent, Sapling or post-quantum address,
    optionally `<address>.<label>`; any other username is refused, there is no fallback address):
    it needs a yolo with paired jobs (yolo#16) and, for Sapling and post-quantum miners, a node with
    getcoinbasetemplatefor (6.22.0-beta3 or later). With it, `coinbase_concurrency` (default 2,
    1-64; yolo --coinbase-concurrency; above 2 the node also gets -rpcthreads of it plus 2, so do
    not set -rpcthreads in extra_args) and `max_paired_per_ip` (default 8, 1-4096; yolo
    --max-paired-per-ip). `min_block_interval` (default 0 = off, 0-300 seconds; yolo
    --min-block-interval, which yolo refuses on mainnet: needs a yolo with block pacing, yolo#19)
    holds a block the pool finds until that many seconds after its job's time, so a rented GPU on a
    testnet at minimum difficulty does not drive the difficulty up (README.md, "The pool"). The pool reaches the node only through its stock mining RPCs (and
    getcoinbasetemplatefor) on 127.0.0.1. `quote` (default null = off) runs the Yellowback quote agent
    beside the node (README.md, "The pool": "Pool quotes"): `image` the quote image by digest
    (quote-image.yml, from a ycash6 commit with the beta4 cadence), `poll_seconds` (default 75,
    the block time; 30-600) how often it fetches the price and calls yed_setquote; with it the node also gets
    -yellowbackpayoutaddress=<payout>, so `payout` must then be a P2PKH address (sm…, the tag's payout
    key; its key stays off the host). Until Yellowback is active on the network the node ignores the
    option and the agent waits (it logs once and asks again every poll).

    `insight` (default false) builds the node's transaction and address indexes (-txindex
    -insightexplorer -experimentalfeatures, the image's YCASHD_INSIGHT=1). Set it before the network's
    first import: turning it on later costs a reindex. `zmq` (default null = off) is a port: the node
    publishes hashblock and hashtx there (on 127.0.0.1, or on the explorer's internal network when the
    network has an explorer), from the end of the prefix import on.

    `explorer` (default none) runs a public block explorer beside that network's node (README.md,
    "The explorer"): Inzyght, PostgreSQL and a TLS proxy (Caddy), the same four-service shape as
    explorer/compose.yaml. It needs `insight = true`; `zmq` defaults to 28332 for it. `hostname` is the
    public name the proxy obtains a Let's Encrypt certificate for (its A record must point at the
    host's address; the optional certificate contact is var.explorer_acme_email); `tls` (default
    true; false = plain HTTP on port 80, for a test without a name). The Inzyght image is either `image` (a published image by digest) or `build` = { repo,
    commit, jobs }: the host builds images/inzyght/Dockerfile itself (from this module's revision,
    delivered by the deploy workflow) against that repository at that full commit, and runs the
    locally built tag; this is the mode while Inzyght has no licence (no published image).
    `postgres_image` and `proxy_image` by digest. `threads`, `mem_limit_mb` and `log_level` (INFO, WARN
    or ERROR; DEBUG would log the database password) tune Inzyght; `pg_shared_buffers_mb` PostgreSQL;
    `node_mem_limit_mb` (default 2304, 512-65536) is the explorer's node container's memory limit, with
    2 GiB of swap allowed beyond it (README.md, "Host size"). `p2p_inbound` (default false) lets the
    explorer's node accept inbound P2P: its container publishes the network's P2P port (that port
    only, IPv4, on every host interface; RPC and ZMQ stay on the internal network), it advertises the
    host's address (-externalip, as every node here), and the security group opens that port to
    var.p2p_ingress_cidrs; the module refuses it with no p2p_ingress_cidrs or with a -listen in either
    extra_args. Without it the explorer's node publishes no port and the security group opens none
    for that network (README.md, "The explorer": "Inbound P2P"). `pools` (default none) adds the
    value-pools page under /pools/ (README.md, "The explorer": "Value pools"): our own small service
    (images/value-pools, `image` by digest, published by value-pools-image.yml) on the explorer's
    internal network, a second read-only RPC client of the node at its own fixed address;
    `mem_limit_mb` (default 128, 64-4096) its memory limit, `title` the network's name in the page's
    heading (letters, digits, spaces and ._()-, at most 60). Without it nothing is rendered for it and
    the network's config is what it was before the option.
    One explorer per host (it owns ports 80 and 443), never beside a pool.

    `lightwallet` (default none) runs a public light-wallet server beside that network's node
    (README.md, "The lightwallet"): lightwalletd-dd with --yellowback (`image`, by digest:
    lightwalletd-image.yml), a gRPC-web proxy (Envoy, `grpcweb_image`) and a TLS proxy (Caddy,
    `proxy_image`). It needs `insight = true` (lightwalletd's address calls read the node's address
    index). `hostname` is the public name the proxy obtains a Let's Encrypt certificate for (its A
    record must point at the host's address; the optional contact is var.lightwallet_acme_email);
    `tls` (default true; false = plain HTTP on port 80, with h2c for native gRPC, for a test without
    a name). Both protocols are served on that one name and port: native gRPC (the apps) and
    gRPC-web (the web wallet); every request goes through the gRPC-web proxy, whose filter
    translates gRPC-web and passes native gRPC through untouched. `grpcweb_origins` (required, no
    default) the CORS origins a browser page may call it from, each `http(s)://host[:port]`: the
    web wallet's real origins, named one by one; `*` is refused. `mem_limit_mb` (default 768) is lightwalletd's
    memory limit, `node_mem_limit_mb` (default 2304) the node container's, with 2 GiB of swap beyond
    it; `log_level` lightwalletd's (logrus 1-6, default 4 = info). The node's RPC is reachable from
    lightwalletd's fixed address on the host's internal network only; nothing but the proxy
    publishes a port. One lightwallet per host (it owns ports 80 and 443): never beside a pool or an
    explorer.

    `x402` (default none) runs the x402 demonstration beside that network's node (README.md, "The
    x402 host"; workspace docs/plans/x402-demonstrations.md §3.2): the paid chain-data API
    (`api_image`, x402-ycash examples/chain-api), the x402 facilitator (`facilitator_image`), the
    testnet faucet (`faucet_image`, images/faucet in testnet mode) and a TLS proxy (Caddy,
    `proxy_image`), all by digest. It needs `insight = true` (the API reads the address index) and
    a testnet profile. The node keeps its wallet: the faucet's, the only spending key on the host;
    the API's payTo is one of its transparent addresses, and the faucet sweeps what agents pay
    there back into its Sapling address. `hostname` is the public name the proxy obtains a Let's
    Encrypt certificate for over the TLS-ALPN challenge on 443 (the only port opened; the optional
    contact is var.x402_acme_email); `tls` false = plain HTTP on port 80, for a test without a name.
    Prices in zatoshis (decision D-10: `price_exact_zat` 10000 = 0.0001 YEC a paid request,
    `price_broadcast_zat` the paid broadcast route's, `zero_conf_cap_zat` 100000 = mempool
    settlement up to 0.001 YEC). `faucet`: a
    fixed `amount_zat` per payment, `daily_cap_zat` in any 24 h, `per_ip` and `per_address`
    payments per `window_seconds`, `pow_bits` of proof of work, `sweep_min_zat` (payTo balance that
    triggers a sweep). `paid_per_minute`, `unpaid_per_minute`, `free_per_minute`: the API's own
    requests a minute per client address; `conn_rate_limit` new TCP connections a minute per client
    address (the host's firewall). `explorer_url` and `lightwalletd` (host:port) the links the API's
    page shows. Memory limits, MiB: `node_mem_limit_mb` (default
    1536, with 2 GiB of swap beyond it), `api_mem_limit_mb`, `facilitator_mem_limit_mb`,
    `faucet_mem_limit_mb`. The node's RPC is reachable from the API's, the facilitator's and the
    faucet's fixed addresses on the host's internal network only; nothing but the proxy publishes a
    port. One x402 per host: never beside a pool, an explorer or a lightwallet.
    `shielded` (default none) adds the private routes (x402-ycash `sapling-proof`, /v1/private/…):
    the node's wallet issues a fresh diversified address of a Sapling address made for them on the
    host (NET/x402/zbase) per request, the API and the facilitator share the issued-address
    registry, and the facilitator signs receipts with a key made on the host (NET/x402/secrets/
    receipt-key; never in git or a GitHub secret). `price_zat` a private request's price,
    `confirmations` the policy each request carries (-1 = the mempool, up to the facilitator's
    maximum of 1), `max_outstanding` the issued requests held at once (each unpaid 402 issues one),
    `note_wait_ms` how long a settle waits for the client's note to reach the host's node.
  EOT
  type = map(object({
    profile    = string
    enabled    = optional(bool, true)
    image      = optional(string)
    bootstrap  = optional(bool, true)
    extra_args = optional(string, "")
    pool = optional(object({
      image       = string
      payout      = string
      port        = optional(number, 3333)
      text        = optional(string, "")
      share_ratio = optional(number, 1)
      # per-miner mode (yolo without --payout: each miner paid at its username)
      per_miner            = optional(bool, false)
      coinbase_concurrency = optional(number, 2)
      max_paired_per_ip    = optional(number, 8)
      # block pacing (yolo --min-block-interval; 0 = off, the flag not passed)
      min_block_interval = optional(number, 0)
      # pool quotes (yellowback-quote beside the node; null = off, nothing rendered)
      quote = optional(object({
        image        = string
        poll_seconds = optional(number, 75)
      }))
    }))
    insight = optional(bool, false)
    zmq     = optional(number)
    explorer = optional(object({
      hostname       = string
      tls            = optional(bool, true)
      image          = optional(string)
      build          = optional(object({ repo = string, commit = string, jobs = optional(number, 2) }))
      postgres_image = string
      proxy_image    = string
      threads        = optional(number, 4)
      mem_limit_mb   = optional(number, 768)
      log_level      = optional(string, "INFO")
      # PostgreSQL's shared_buffers, MiB (Inzyght's pg_tune.sh value for a small host)
      pg_shared_buffers_mb = optional(number, 256)
      # the node container's memory limit, MiB (its swap allowance is 2048 MiB beyond it)
      node_mem_limit_mb = optional(number, 2304)
      # accept inbound P2P: publish the network's P2P port, open it to var.p2p_ingress_cidrs
      p2p_inbound = optional(bool, false)
      # the value-pools page under /pools/ (images/value-pools), our own sidecar beside Inzyght
      pools = optional(object({
        image        = string
        mem_limit_mb = optional(number, 128)
        title        = optional(string, "")
      }))
    }))
    lightwallet = optional(object({
      hostname      = string
      tls           = optional(bool, true)
      image         = string
      grpcweb_image = string
      proxy_image   = string
      # the web wallet's origins (CORS), each http(s)://host[:port]; required, never "*"
      grpcweb_origins = list(string)
      # lightwalletd's memory limit, MiB
      mem_limit_mb = optional(number, 768)
      # the node container's memory limit, MiB (its swap allowance is 2048 MiB beyond it)
      node_mem_limit_mb = optional(number, 2304)
      # lightwalletd's --log-level (logrus: 4 = info)
      log_level = optional(number, 4)
    }))
    x402 = optional(object({
      hostname          = string
      tls               = optional(bool, true)
      api_image         = string
      facilitator_image = string
      faucet_image      = string
      proxy_image       = string
      explorer_url      = optional(string, "")
      lightwalletd      = optional(string, "") # the light-wallet server agents pay through, host:port
      # prices and settlement, zatoshis (D-10)
      price_exact_zat     = optional(number, 10000)
      price_broadcast_zat = optional(number, 10000)
      zero_conf_cap_zat   = optional(number, 100000)
      # per client address: the API's requests a minute (paid, unpaid, free routes); new connections
      # a minute (the host's firewall)
      paid_per_minute   = optional(number, 120)
      unpaid_per_minute = optional(number, 30)
      free_per_minute   = optional(number, 120)
      conn_rate_limit   = optional(number, 60)
      faucet = optional(object({
        amount_zat     = optional(number, 10000000)   # 0.1 testnet YEC a payment
        daily_cap_zat  = optional(number, 1000000000) # 10 testnet YEC in any 24 h
        per_ip         = optional(number, 1)
        per_address    = optional(number, 1)
        window_seconds = optional(number, 86400)
        pow_bits       = optional(number, 16)
        sweep_min_zat  = optional(number, 1000000) # sweep payTo into the faucet once it holds 0.01
      }), {})
      node_mem_limit_mb        = optional(number, 1536)
      api_mem_limit_mb         = optional(number, 256)
      facilitator_mem_limit_mb = optional(number, 192)
      faucet_mem_limit_mb      = optional(number, 96)
      # the private routes (sapling-proof); null = transparent routes only
      shielded = optional(object({
        price_zat       = optional(number, 10000) # 0.0001 testnet YEC a private request
        confirmations   = optional(number, -1)    # the mempool, as the transparent routes
        max_outstanding = optional(number, 1000)
        note_wait_ms    = optional(number, 30000)
      }))
    }))
  }))
  default = {
    yb-fast = { profile = "fast" }
    yb-slow = { profile = "slow" }
    legacy  = { profile = "legacy" }
    main    = { profile = "main", enabled = false }
  }
  validation {
    condition     = alltrue([for k, n in var.networks : can(regex("^[a-z][a-z0-9-]{0,15}$", k)) && contains(["fast", "slow", "legacy", "main"], n.profile)])
    error_message = "networks: keys of lowercase letters, digits and dashes (at most 16, starting with a letter); profile one of fast, slow, legacy, main."
  }
  validation {
    condition     = alltrue([for k, n in var.networks : n.image == null || can(regex("^[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}$", coalesce(n.image, "-")))])
    error_message = "networks: every image override must be pinned by digest."
  }
  validation {
    condition     = alltrue([for k, n in var.networks : can(regex("^[A-Za-z0-9=:._,/ +-]*$", n.extra_args))])
    error_message = "networks: extra_args: letters, digits, spaces and = : . _ , / + - only."
  }
  validation {
    condition = alltrue([for k, n in var.networks : n.pool == null ? true : (
      n.profile != "main" &&
      can(regex("^[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}$", n.pool.image)) &&
      can(regex("^[1-9A-HJ-NP-Za-km-z]{26,40}$", n.pool.payout)) &&
      n.pool.port >= 1024 && n.pool.port <= 65534 && floor(n.pool.port) == n.pool.port &&
      !contains([18832, 18833, 18932, 18933, 19032, 19033, 8832, 8833], n.pool.port) &&
      !contains([18832, 18833, 18932, 18933, 19032, 19033, 8832, 8833], n.pool.port + 1) &&
      can(regex("^[A-Za-z0-9 ._:/-]{0,60}$", n.pool.text)) &&
      n.pool.share_ratio >= 1 && n.pool.share_ratio <= 1000000 && floor(n.pool.share_ratio) == n.pool.share_ratio &&
      n.pool.coinbase_concurrency >= 1 && n.pool.coinbase_concurrency <= 64 && floor(n.pool.coinbase_concurrency) == n.pool.coinbase_concurrency &&
      n.pool.max_paired_per_ip >= 1 && n.pool.max_paired_per_ip <= 4096 && floor(n.pool.max_paired_per_ip) == n.pool.max_paired_per_ip &&
      n.pool.min_block_interval >= 0 && n.pool.min_block_interval <= 300 && floor(n.pool.min_block_interval) == n.pool.min_block_interval
    )])
    error_message = "networks: pool on a testnet profile only, image pinned by digest, payout a base58 transparent address, port 1024-65534 clear of every node port (port + 1 is the status page), text of at most 60 letters, digits, spaces and . _ : / -, share_ratio a whole number from 1 to 1000000, coinbase_concurrency a whole number from 1 to 64, max_paired_per_ip a whole number from 1 to 4096, min_block_interval a whole number of seconds from 0 to 300."
  }
  validation {
    condition = alltrue([for k, n in var.networks : n.pool == null ? true : n.pool.quote == null ? true : (
      can(regex("^[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}$", n.pool.quote.image)) &&
      can(regex("^sm[1-9A-HJ-NP-Za-km-z]{33}$", n.pool.payout)) &&
      n.pool.quote.poll_seconds >= 30 && n.pool.quote.poll_seconds <= 600 && floor(n.pool.quote.poll_seconds) == n.pool.quote.poll_seconds &&
      !can(regex("(^| )-yellowbackpayout", n.extra_args))
    )])
    error_message = "networks: a pool's quote needs its image pinned by digest, a P2PKH payout (sm..., 35 characters: the coinbase tag's payout key), poll_seconds a whole number from 30 to 600, and no -yellowbackpayout* in extra_args (the module sets -yellowbackpayoutaddress)."
  }
  validation {
    # yolo needs the node's -rpcthreads at least coinbase_concurrency + 2; above 2 the module sets it
    condition = alltrue([for k, n in var.networks : n.pool == null ? true : (
      !n.pool.per_miner || n.pool.coinbase_concurrency <= 2 || !can(regex("(^| )-rpcthreads=", n.extra_args))
    )])
    error_message = "networks: a per-miner pool with coinbase_concurrency above 2 sets the node's -rpcthreads itself; remove -rpcthreads from extra_args."
  }
  validation {
    condition     = length(distinct([for k, n in var.networks : n.pool.port if n.enabled && n.pool != null])) == length([for k, n in var.networks : k if n.enabled && n.pool != null])
    error_message = "networks: two pools share a stratum port."
  }
  validation {
    condition = alltrue([for k, n in var.networks : n.zmq == null ? true : (
      n.zmq >= 1024 && n.zmq <= 65535 && floor(n.zmq) == n.zmq &&
      !contains([18832, 18833, 18932, 18933, 19032, 19033, 8832, 8833], n.zmq)
    )])
    error_message = "networks: zmq is a port from 1024 to 65535 clear of every node port (null = off)."
  }
  validation {
    condition = alltrue([for k, n in var.networks : n.explorer == null ? true : (
      n.insight && n.pool == null &&
      can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", n.explorer.hostname)) &&
      (n.explorer.image == null) != (n.explorer.build == null) &&
      (n.explorer.image == null || can(regex("^[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}$", coalesce(n.explorer.image, "-")))) &&
      can(regex("^[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}$", n.explorer.postgres_image)) &&
      can(regex("^[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}$", n.explorer.proxy_image)) &&
      contains(["INFO", "WARN", "ERROR"], n.explorer.log_level) &&
      n.explorer.threads >= 1 && n.explorer.threads <= 64 && floor(n.explorer.threads) == n.explorer.threads &&
      n.explorer.mem_limit_mb >= 256 && n.explorer.mem_limit_mb <= 65536 && floor(n.explorer.mem_limit_mb) == n.explorer.mem_limit_mb &&
      n.explorer.pg_shared_buffers_mb >= 32 && n.explorer.pg_shared_buffers_mb <= 16384 && floor(n.explorer.pg_shared_buffers_mb) == n.explorer.pg_shared_buffers_mb &&
      n.explorer.node_mem_limit_mb >= 512 && n.explorer.node_mem_limit_mb <= 65536 && floor(n.explorer.node_mem_limit_mb) == n.explorer.node_mem_limit_mb &&
      (n.explorer.pools == null ? true : (
        can(regex("^[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}$", n.explorer.pools.image)) &&
        n.explorer.pools.mem_limit_mb >= 64 && n.explorer.pools.mem_limit_mb <= 4096 && floor(n.explorer.pools.mem_limit_mb) == n.explorer.pools.mem_limit_mb &&
        can(regex("^[A-Za-z0-9 ._()-]{0,60}$", n.explorer.pools.title))
      ))
    )])
    error_message = "networks: an explorer needs insight = true and no pool; hostname a lowercase DNS name; exactly one of image (by digest) and build; postgres_image and proxy_image by digest; log_level INFO, WARN or ERROR; threads 1-64, mem_limit_mb 256-65536, pg_shared_buffers_mb 32-16384, node_mem_limit_mb 512-65536, whole numbers; pools (optional): image by digest, mem_limit_mb 64-4096, title letters, digits, spaces and ._()- (at most 60)."
  }
  validation {
    condition = alltrue([for k, n in var.networks : try(n.explorer.build, null) == null ? true : (
      can(regex("^https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", n.explorer.build.repo)) &&
      can(regex("^[0-9a-f]{40}$", n.explorer.build.commit)) &&
      n.explorer.build.jobs >= 1 && n.explorer.build.jobs <= 16 && floor(n.explorer.build.jobs) == n.explorer.build.jobs
    )])
    error_message = "networks: explorer.build: repo https://github.com/<owner>/<repo>, commit a full 40-hex SHA, jobs a whole number from 1 to 16."
  }
  validation {
    condition     = length([for k, n in var.networks : k if n.enabled && n.explorer != null]) <= 1
    error_message = "networks: one explorer per host (it owns ports 80 and 443)."
  }
  validation {
    condition = alltrue([for k, n in var.networks : n.lightwallet == null ? true : (
      n.insight && n.pool == null && n.explorer == null && n.profile != "main" &&
      can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", n.lightwallet.hostname)) &&
      alltrue([for i in [n.lightwallet.image, n.lightwallet.grpcweb_image, n.lightwallet.proxy_image] :
      can(regex("^[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}$", i))]) &&
      length(n.lightwallet.grpcweb_origins) >= 1 &&
      alltrue([for o in n.lightwallet.grpcweb_origins : can(regex("^https?://[a-z0-9.-]+(:[0-9]{1,5})?$", o))]) &&
      n.lightwallet.mem_limit_mb >= 256 && n.lightwallet.mem_limit_mb <= 65536 && floor(n.lightwallet.mem_limit_mb) == n.lightwallet.mem_limit_mb &&
      n.lightwallet.node_mem_limit_mb >= 512 && n.lightwallet.node_mem_limit_mb <= 65536 && floor(n.lightwallet.node_mem_limit_mb) == n.lightwallet.node_mem_limit_mb &&
      n.lightwallet.log_level >= 1 && n.lightwallet.log_level <= 6 && floor(n.lightwallet.log_level) == n.lightwallet.log_level
    )])
    error_message = "networks: a lightwallet needs insight = true, a testnet profile, no pool and no explorer; hostname a lowercase DNS name; image, grpcweb_image and proxy_image pinned by digest; grpcweb_origins one or more http(s)://host[:port], never \"*\"; mem_limit_mb 256-65536, node_mem_limit_mb 512-65536, log_level 1-6, whole numbers."
  }
  validation {
    condition = alltrue([for k, n in var.networks : n.x402 == null ? true : (
      n.insight && n.pool == null && n.explorer == null && n.lightwallet == null && n.profile != "main" &&
      can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", n.x402.hostname)) &&
      alltrue([for i in [n.x402.api_image, n.x402.facilitator_image, n.x402.faucet_image, n.x402.proxy_image] :
      can(regex("^[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}$", i))]) &&
      can(regex("^(https://[a-z0-9.-]+(/[A-Za-z0-9._~/-]*)?)?$", n.x402.explorer_url)) &&
      can(regex("^([a-z0-9.-]{1,253}(:[0-9]{1,5})?)?$", n.x402.lightwalletd)) &&
      alltrue([for v in [n.x402.price_exact_zat, n.x402.price_broadcast_zat] : v >= 1 && v <= 100000000 && floor(v) == v]) &&
      n.x402.zero_conf_cap_zat >= 1 && n.x402.zero_conf_cap_zat <= 100000000 && floor(n.x402.zero_conf_cap_zat) == n.x402.zero_conf_cap_zat &&
      alltrue([for v in [n.x402.paid_per_minute, n.x402.unpaid_per_minute, n.x402.free_per_minute, n.x402.conn_rate_limit] : v >= 1 && v <= 100000 && floor(v) == v]) &&
      n.x402.faucet.amount_zat >= 1 && n.x402.faucet.amount_zat <= 10000000000 && floor(n.x402.faucet.amount_zat) == n.x402.faucet.amount_zat &&
      n.x402.faucet.daily_cap_zat >= n.x402.faucet.amount_zat && n.x402.faucet.daily_cap_zat <= 1000000000000 && floor(n.x402.faucet.daily_cap_zat) == n.x402.faucet.daily_cap_zat &&
      alltrue([for v in [n.x402.faucet.per_ip, n.x402.faucet.per_address] : v >= 1 && v <= 1000 && floor(v) == v]) &&
      n.x402.faucet.window_seconds >= 60 && n.x402.faucet.window_seconds <= 2592000 && floor(n.x402.faucet.window_seconds) == n.x402.faucet.window_seconds &&
      n.x402.faucet.pow_bits >= 0 && n.x402.faucet.pow_bits <= 28 && floor(n.x402.faucet.pow_bits) == n.x402.faucet.pow_bits &&
      n.x402.faucet.sweep_min_zat >= 1 && n.x402.faucet.sweep_min_zat <= 10000000000 && floor(n.x402.faucet.sweep_min_zat) == n.x402.faucet.sweep_min_zat &&
      n.x402.node_mem_limit_mb >= 512 && n.x402.node_mem_limit_mb <= 65536 && floor(n.x402.node_mem_limit_mb) == n.x402.node_mem_limit_mb &&
      n.x402.api_mem_limit_mb >= 64 && n.x402.api_mem_limit_mb <= 8192 && floor(n.x402.api_mem_limit_mb) == n.x402.api_mem_limit_mb &&
      n.x402.facilitator_mem_limit_mb >= 64 && n.x402.facilitator_mem_limit_mb <= 8192 && floor(n.x402.facilitator_mem_limit_mb) == n.x402.facilitator_mem_limit_mb &&
      n.x402.faucet_mem_limit_mb >= 32 && n.x402.faucet_mem_limit_mb <= 4096 && floor(n.x402.faucet_mem_limit_mb) == n.x402.faucet_mem_limit_mb
    )])
    error_message = "networks: an x402 needs insight = true, a testnet profile, no pool, explorer or lightwallet; hostname a lowercase DNS name; api_image, facilitator_image, faucet_image and proxy_image pinned by digest; explorer_url empty or https://host[/path]; lightwalletd empty or host[:port]; prices and zero_conf_cap_zat 1-100000000 zat; rate limits 1-100000; faucet: amount_zat 1-10000000000, daily_cap_zat at least amount_zat, per_ip and per_address 1-1000, window_seconds 60-2592000, pow_bits 0-28, sweep_min_zat 1-10000000000; node_mem_limit_mb 512-65536, api and facilitator 64-8192, faucet 32-4096; whole numbers."
  }
  validation {
    condition = alltrue([for k, n in var.networks : n.x402 == null ? true : n.x402.shielded == null ? true : (
      n.x402.shielded.price_zat >= 1 && n.x402.shielded.price_zat <= 100000000 && floor(n.x402.shielded.price_zat) == n.x402.shielded.price_zat &&
      n.x402.shielded.confirmations >= -1 && n.x402.shielded.confirmations <= 1 && floor(n.x402.shielded.confirmations) == n.x402.shielded.confirmations &&
      n.x402.shielded.max_outstanding >= 1 && n.x402.shielded.max_outstanding <= 100000 && floor(n.x402.shielded.max_outstanding) == n.x402.shielded.max_outstanding &&
      n.x402.shielded.note_wait_ms >= 0 && n.x402.shielded.note_wait_ms <= 60000 && floor(n.x402.shielded.note_wait_ms) == n.x402.shielded.note_wait_ms
    )])
    error_message = "networks: an x402's shielded: price_zat 1-100000000, confirmations -1 to 1 (the facilitator settles up to one block deep), max_outstanding 1-100000, note_wait_ms 0-60000; whole numbers."
  }
  validation {
    condition     = length([for k, n in var.networks : k if n.enabled && (n.explorer != null || n.lightwallet != null || n.x402 != null)]) <= 1
    error_message = "networks: one explorer, lightwallet or x402 per host (each owns the host's HTTPS port)."
  }
  validation {
    condition     = length([for k, n in var.networks : k if n.enabled]) >= 1
    error_message = "networks: at least one network must be enabled."
  }
  validation {
    condition     = length(distinct([for k, n in var.networks : n.profile if n.enabled])) == length([for k, n in var.networks : k if n.enabled])
    error_message = "networks: two enabled networks share a profile (and so its ports and magic)."
  }
  validation {
    condition     = !contains([for k, n in var.networks : n.profile if n.enabled], "main") || length([for k, n in var.networks : k if n.enabled]) == 1
    error_message = "networks: main is a stack of its own (own state, own addresses, own account), never enabled beside a testnet."
  }
}

variable "architecture" {
  description = "CPU architecture of the instances and the image: x86_64 or arm64. The image must have a variant for it (the node-image workflow builds linux/amd64 only)."
  type        = string
  default     = "x86_64"
  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "architecture: x86_64 or arm64."
  }
}

variable "instance_type" {
  description = "Instance type; must match `architecture` (t3a.* / t3.* for x86_64, t4g.* for arm64). t3a.medium (2 vCPU, 4 GiB) runs the three testnets."
  type        = string
  default     = "t3a.medium"
}

variable "cpu_credits" {
  description = "Burstable CPU credit mode: unlimited lets a first sync or an import run at full speed (a few cents of surplus credits), standard caps the bill and throttles."
  type        = string
  default     = "unlimited"
  validation {
    condition     = contains(["standard", "unlimited"], var.cpu_credits)
    error_message = "cpu_credits: standard or unlimited."
  }
}

variable "ami_id" {
  description = "AMI override. Empty = Canonical's current Ubuntu 24.04 LTS for `architecture`, read from AWS's public SSM parameter at instance creation (later AMI releases never replace a running instance)."
  type        = string
  default     = ""
}

variable "root_volume_size" {
  description = "Root volume (OS, Docker, the images, swap), GiB, gp3, encrypted. Replaced with the instance."
  type        = number
  default     = 20
}

variable "data_volume_size" {
  description = "Data volume (every network's datadir side by side, and the shared verified prefix), GiB, gp3, encrypted. Kept across upgrades, resets and instance replacements. fast: a few GB (the 510,248-block testnet prefix plus the new chain, 1.1 GB framed while it imports, 1.1 GB cache). slow and legacy restore mainnet-prefix-v1: about 23 GB framed per network while it imports, 18.7 GB for its cache, and the imported mainnet history; with the bootstrap on all three, size it as the chart does (120 GiB per mainnet-prefix node) or more."
  type        = number
  default     = 80
}

variable "kms_key_id" {
  description = "KMS key for both volumes. Null = the account's default EBS key (aws/ebs)."
  type        = string
  default     = null
}

variable "swap_mb" {
  description = "Swap file on the root volume, MiB (0 = none). Headroom for three nodes on 4 GiB during imports."
  type        = number
  default     = 4096
}

variable "p2p_ingress_cidrs" {
  description = "Who may open a P2P connection, on each enabled network's port (a network with an explorer: only with explorer.p2p_inbound, which needs this non-empty). Seeds serve everyone: 0.0.0.0/0. Nothing else is ever opened inbound (no SSH, no RPC; management is SSM)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "pool_ingress_cidrs" {
  description = "Who may open a stratum connection to a network's pool (networks.<key>.pool.port). Rented GPU miners connect from arbitrary addresses, so the default is everyone; yolo bounds what a connection can do (README.md, \"The pool\"). Only used where a network has a pool."
  type        = list(string)
  default     = ["0.0.0.0/0"]
  validation {
    condition     = alltrue([for c in var.pool_ingress_cidrs : can(cidrhost(c, 0))])
    error_message = "pool_ingress_cidrs: IPv4 CIDRs."
  }
}

variable "explorer_ingress_cidrs" {
  description = "Who may reach a network's explorer (networks.<key>.explorer) on ports 443 and 80 (80 for the Let's Encrypt HTTP-01 challenge and the redirect to HTTPS). A public explorer: everyone. Only used where a network has an explorer; nothing is opened without one."
  type        = list(string)
  default     = ["0.0.0.0/0"]
  validation {
    condition     = alltrue([for c in var.explorer_ingress_cidrs : can(cidrhost(c, 0))])
    error_message = "explorer_ingress_cidrs: IPv4 CIDRs."
  }
}

variable "explorer_acme_email" {
  description = "The contact an explorer's proxy gives Let's Encrypt for its certificate (optional; empty = none). Pass it from a secret, never commit it. Sensitive: it reaches only the network configs (seedctl renders it into the host's Caddyfile), never a plan line or another output."
  type        = string
  default     = ""
  sensitive   = true
  validation {
    condition     = can(regex("^([A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+)?$", var.explorer_acme_email))
    error_message = "explorer_acme_email: empty or an e-mail address."
  }
}

variable "lightwallet_ingress_cidrs" {
  description = "Who may reach a network's light-wallet server (networks.<key>.lightwallet) on ports 443 and 80 (80 for the Let's Encrypt HTTP-01 challenge and the redirect to HTTPS). A public server: everyone. Only used where a network has a lightwallet; nothing is opened without one."
  type        = list(string)
  default     = ["0.0.0.0/0"]
  validation {
    condition     = alltrue([for c in var.lightwallet_ingress_cidrs : can(cidrhost(c, 0))])
    error_message = "lightwallet_ingress_cidrs: IPv4 CIDRs."
  }
}

variable "lightwallet_acme_email" {
  description = "The contact a lightwallet's proxy gives Let's Encrypt for its certificate (optional; empty = none). Pass it from a secret, never commit it. Sensitive: it reaches only the network configs (seedctl renders it into the host's Caddyfile), never a plan line or another output."
  type        = string
  default     = ""
  sensitive   = true
  validation {
    condition     = can(regex("^([A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+)?$", var.lightwallet_acme_email))
    error_message = "lightwallet_acme_email: empty or an e-mail address."
  }
}

variable "x402_ingress_cidrs" {
  description = "Who may reach a network's x402 host (networks.<key>.x402) on port 443 (80 with tls = false, the only port then). A public demonstration: everyone. Only used where a network has an x402; nothing is opened without one."
  type        = list(string)
  default     = ["0.0.0.0/0"]
  validation {
    condition     = alltrue([for c in var.x402_ingress_cidrs : can(cidrhost(c, 0))])
    error_message = "x402_ingress_cidrs: IPv4 CIDRs."
  }
}

variable "x402_acme_email" {
  description = "The contact an x402 host's proxy gives Let's Encrypt for its certificate (optional; empty = none). Pass it from a secret, never commit it. Sensitive: it reaches only the network configs (seedctl renders it into the host's Caddyfile), never a plan line or another output."
  type        = string
  default     = ""
  sensitive   = true
  validation {
    condition     = can(regex("^([A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+)?$", var.x402_acme_email))
    error_message = "x402_acme_email: empty or an e-mail address."
  }
}

variable "extra_args" {
  description = "Appended to ycashd's command line on every network of every host (a network's own extra_args follow it). Each node already gets -port, -externalip=<its address>, -addnode=<the other hosts on that network's port>, the profile's arguments and, on a testnet, -dnsseed=0. The default keeps three nodes inside 4 GiB."
  type        = string
  default     = "-dbcache=256 -maxconnections=64"
  validation {
    condition     = can(regex("^[A-Za-z0-9=:._,/ +-]*$", var.extra_args))
    error_message = "extra_args: letters, digits, spaces and = : . _ , / + - only (no quotes or shell characters)."
  }
}

variable "prefix" {
  description = <<-EOT
    Turns on the bootstrap from the published prefix (bundles/prefix/FORMAT.md, magic-neutral). Each
    profile restores the prefix its chart values file names (charts/ycash-testnet/values-yb-fast.yaml,
    values-yb-slow.yaml, values-legacy.yaml: prefixRestore baseUrl, sha256sums, network, lastHeight):
    fast testnet-prefix-v1 (zcash-testnet 0..510,247), slow and legacy mainnet-prefix-v1
    (ycash-mainnet 0..3,079,999). On a testnet network's empty datadir the host downloads it once into
    a cache per pin, refuses unless SHA256SUMS hashes to the pin, every file checks and the manifest
    names that network and last height, frames it with that network's magic (the profile's,
    locals.tf) and imports it with -loadblock. A reset reuses the verified cache. The fields, when
    set, override the chart's values for the zcash-testnet profile (fast) only. Null = no bootstrap:
    each network syncs from its peers.
  EOT
  type = object({
    base_url    = optional(string)
    sums_sha256 = optional(string)
    last_height = optional(number)
  })
  default = null
  validation {
    condition = var.prefix == null ? true : (
      (var.prefix.base_url == null || can(regex("^https://[A-Za-z0-9._~/%-]+$", coalesce(var.prefix.base_url, "-")))) &&
      (var.prefix.sums_sha256 == null || can(regex("^[0-9a-f]{64}$", coalesce(var.prefix.sums_sha256, "-")))) &&
      (var.prefix.last_height == null || coalesce(var.prefix.last_height, 0) > 0)
    )
    error_message = "prefix: base_url https://..., sums_sha256 64 lowercase hex, last_height > 0."
  }
}

variable "prefix_magic_overrides" {
  description = "Per network key, the magic the prefix is framed with instead of its profile's: only for a node image from before the profiles existed (its compiled testnet magic, fa1af9bf). A wrong magic makes the node skip every framed block."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for k, m in var.prefix_magic_overrides : can(regex("^[0-9a-f]{8}$", m))])
    error_message = "prefix_magic_overrides: 8 lowercase hex digits each."
  }
}
