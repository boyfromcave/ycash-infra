# The x402 host: threats and limits

The fast-testnet x402 demonstration host (`infra/testnet-seeds/README.md`, "The x402 host"; workspace
`docs/plans/x402-demonstrations.md` §3.2): what someone gains by attacking it, the ways it can be
abused, and the limit that answers each. Testnet only: no mainnet value is on the host, and the
module refuses an `x402` on the mainnet profile.

## In plain words

The host sells chain data for worthless testnet coins and gives those coins away through a faucet.
The only thing of any value on it is the faucet's wallet, and that holds testnet coins. Breaking in
gets an attacker a testnet wallet and a small machine with no access to anything else. The abuse
that matters is denial of service, and every way in has a limit in front of it.

## What an attacker gains

| Foothold | Gains | Does not gain |
|---|---|---|
| The API, the facilitator or the faucet (a remote-code bug in one of them) | The node's RPC credential (every service that talks to the node holds it; ycashd has no per-method RPC permissions), so **the faucet wallet's balance**: testnet YEC, whatever the lead architect funded it with, bypassing the faucet's own caps | The internet: the three services sit on an internal Docker network with no route out, so nothing is exfiltrated except through answers to the attacker's own requests. AWS: the metadata address is refused to both networks, the instance role is SSM only and no container can reach it. Other hosts: each host has its own RPC credential and no inbound P2P. Mainnet: no mainnet key or node exists here |
| The TLS proxy (Caddy) | The certificate's private key for this one name (testnet demonstration only) | The node's RPC: it is not on the node's RPC allow list, and holds no credential |
| The host itself (root) | All of the above, and the instance's SSM-only role | The deploy role, the state bucket, other layers' hosts (each layer's role is denied the others' resources; ycash-ops `docs/aws-setup.md`) |

**Answer:** keep the faucet's balance small (a few days of its daily cap; `seedctl status` shows
it), and treat everything on the host as hot. A lost or drained wallet costs testnet coins: fund a new
one from the pool. Nothing on the host is a dependency of any other service.

## Abuse cases

| Abuse | What it costs us | The limits that answer it |
|---|---|---|
| **Faucet draining**: many requests for free coins, from many addresses or many recipients | The faucet's balance, then the demo stops paying out | A fixed amount per payment (`faucet.amount_zat`, 0.1 YEC); one payment per client address (IPv6 per /64) and one per recipient per `window_seconds` (24 h); a daily cap in any 24 h (`daily_cap_zat`, 10 YEC); `pow_bits` (16) of SHA-256 proof of work per request; one payment at a time, `RATE_SECONDS` apart; the client's address is the one the proxy writes (a client's `X-Forwarded-For` is replaced), so it cannot be forged through the proxy; the faucet's balance is kept small; what agents pay flows back (the sweep), so the faucet refills from use |
| **402 flooding**: unpaid requests to paid routes, to burn CPU and node RPC | The API's CPU and the node's RPC queue; a slower demo | The API answers a 402 before any node call or signature check (a requirement on the API, examples/chain-api); the host firewall drops a client address's new connections above `conn_rate_limit` (60 a minute, bursts of 120); the API's own per-client limits for requests inside a kept-alive connection (`unpaid_per_minute` 30, `paid_per_minute` 120, `free_per_minute` 120), counting the address the proxy writes (Caddy replaces any `X-Forwarded-For` a client sends, and the API's port is reachable only from the proxy, so the address cannot be forged); Caddy's header (10 s), body (30 s), write and idle timeouts, 64 KB of headers, 256 KB of body; memory limits per container so a flood cannot starve the node; `cpu_credits = "standard"` after the first import, so a flood throttles the host instead of running up surplus-credit charges |
| **Paid-attempt flooding**: well-formed but invalid payments, so each costs the facilitator a check | A few node RPC calls per attempt (decode, script check) | The API's per-client limit before the facilitator is called; the facilitator's own limit (`rateLimit`, 1200 a minute, the whole host, since its only client is the API) and its 512 KB body limit; it is reachable from the API only, with the API key; the node's RPC work queue is bounded (`-rpcworkqueue=64`, 8 threads) |
| **Relay abuse through the paid broadcast route** (`POST /v1/broadcast`): pushing spam, oversized or invalid transactions to the network through our node | Our node relaying spam; its mempool and peers' bandwidth | Every relay is paid (`price_broadcast_zat`, 0.0001 YEC, settled before the relay), so spam costs the sender per transaction, and the faucet's per-day cap bounds how many free coins can be turned into relays; at most 100,000 bytes of transaction (the API) and 256 KB of body (the proxy); the API's per-client limits; the node applies its ordinary mempool policy (fees, standardness, size), so a transaction it would not relay for anyone is refused (422, not charged); the facilitator's own `settle` is not public (internal network, API key) and relays only a payment to `payTo` at the price, recording each txid once. A relayed transaction is ordinary: anyone can send one to any node directly |
| **Double spends at the mempool**: pay, get the answer, then replace the payment | The answer, unpaid | Mempool settlement only up to `zero_conf_cap_zat` (0.001 YEC) per payment; above it the payment waits for a confirmation; the store refuses a replayed txid. Testnet coins and a chain-data answer anyone could compute: the loss is bounded and accepted (x402 plan §8) |
| **Wrong network**: the services pointed at another testnet or at mainnet | Paying or settling on the wrong chain | The facilitator (`testnetProfile`) and the faucet (`FAUCET_PROFILE`) refuse unless the node reports this testnet profile (D-6); the module and seedctl refuse an `x402` on mainnet |
| **Scraping or reselling answers** | Nothing | Allowed: the data is public chain data (the note's "free-riding") |

## What is not covered

- **ycashd's RPC has no per-method permissions**: any service holding the credential can call
  wallet methods. This is why the wallet's balance is kept small; a filtering proxy in front of the
  node's RPC would close it and is the first thing to add before a mainnet host (the mainnet plan
  keeps no spending key on the host at all: revenue to an offline key).
- **The faucet's limits live in memory**: a restart forgets the per-address and per-IP windows; the
  daily cap and the proof of work still apply, and restarts are rare.
- **Distributed abuse** (many addresses) is bounded by the daily cap, not stopped; the faucet then
  says it has paid its daily amount.
