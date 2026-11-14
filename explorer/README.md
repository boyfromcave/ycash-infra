# explorer: a block explorer stack (ycashd + PostgreSQL + Inzyght + proxy)

A Docker Compose stack that runs the [Inzyght](https://github.com/miodragpop/inzyght) block
explorer, unmodified, against a ycashd 6.22.0-beta2 node. It is the local proof (phases E1 and E2)
of the workspace's explorer plan (`docs/plans/explorer/explorer-plan.md`), and the same four
containers are what the `fastnet-explorer.ycash.team` host runs (phase E3: the seeds module's
`explorer` option, [`infra/testnet-seeds/README.md`](../infra/testnet-seeds/README.md), "The
explorer", renders this file's design with seedctl).

```
make explorer-up       # first run: writes explorer/.env with new passwords, builds the Inzyght image
make explorer-status   # containers, node height, Inzyght's sync progress
make explorer-logs     # S=node | postgres | inzyght | proxy for one
make explorer-down         # stop; the chain, the index and the certificates stay in their volumes
make explorer-wipe-index   # re-index: delete only the PostgreSQL index (pg-data) and start again
make explorer-wipe         # stop and delete the chain and the index; the certificates stay
make explorer-wipe WIPE_CERTS=1   # ... and the proxy's certificates (caddy-data, caddy-config) too
make explorer-psql         # psql into the index
make explorer-lint         # offline: shellcheck the scripts, docker compose config -q (CI runs it)
```

What to wipe: a broken or outdated index needs only `explorer-wipe-index` (about 4 minutes to
re-index yb-fast; the node keeps its chain). `explorer-wipe` costs the 20-minute prefix import as
well. Keep the certificates unless they are the problem: Let's Encrypt issues at most 5 certificates
a week for the same name, and every wipe with `WIPE_CERTS=1` on a host with a domain spends one. A
`NODE_DATA` or `PG_DATA` host directory is never deleted by these targets (they say so; delete it
yourself).

The explorer is then at <http://127.0.0.1:8090/>.

**Inzyght has no licence file.** Its image is built on the machine that runs it (`make
image-inzyght`, [`images/inzyght/README.md`](../images/inzyght/README.md)) and is never pushed to a
registry. There is no image-publishing workflow for it until its author has answered.

## The services

```
          browser ── 127.0.0.1:8090 (HTTP)  or  :443 (HTTPS, EXPLORER_SITE=<domain>)
                              │
                       ┌──────▼──────┐  edge network (published ports; ACME)
                       │    proxy    │  Caddy: TLS on demand, headers, compression, WebSocket
                       └──────┬──────┘
   backend network ═══════════╪════════════════════════ internal: no route out
                       ┌──────▼──────┐        ┌────────────┐
                       │   inzyght   ├───────►│  postgres  │  volume pg-data
                       └──────┬──────┘        └────────────┘
                RPC 18832, ZMQ 28332 (backend only)
                       ┌──────▼──────┐  edge network: P2P out to fastnet-seed.ycash.team:18833
                       │    node     │  ycashd beta2, -txindex -insightexplorer, ZMQ, listen=0
                       └─────────────┘  volume node-data
```

| Service | Image | Runs as | Notes |
|---|---|---|---|
| `node` | `ghcr.io/boyfromcave/ycashd@sha256:70c0a29f…ad340` (6.22.0-beta2, the yb-fast seeds' digest; linux/amd64) | uid 2001, read-only root, no capabilities, `NODE_MEM_LIMIT` 1536m | `YCASHD_INSIGHT=1`, `YCASHD_LISTEN=0`, `YCASHD_BOOTSTRAP=prefix`; ZMQ `hashblock`/`hashtx` bound to its backend address (.11); RPC admits 127.0.0.1 and the backend subnet only (`YCASHD_RPC_ALLOWIP`) |
| `postgres` | `postgres:17-alpine` (by digest) | starts as root, drops to `postgres`; only CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID kept; `PG_MEM_LIMIT` 768m | `postgres-init/10-inzyght.sh` creates the database and a non-superuser owner role on first start; Inzyght's tuning values on the command line; 60 s to stop cleanly |
| `inzyght` | `ycash/inzyght:local` | uid 2005, read-only root, no capabilities, `INZYGHT_MEM_LIMIT` 768m | checks (and repairs) its schema on every start; trusts `X-Forwarded-For` only from the proxy's fixed address |
| `proxy-volumes` | `caddy:2.10-alpine` | root, CHOWN and DAC_READ_SEARCH only, no network | one shot before the proxy: hands the certificate volumes to uid 2006 |
| `proxy` | `caddy:2.10-alpine` (by digest) | uid 2006, read-only root, every capability dropped except NET_BIND_SERVICE (the image's `caddy` binary carries it as a file capability and cannot be exec'd without it), `PROXY_MEM_LIMIT` 128m | the only service with published ports |

Bindings: the proxy publishes on `PROXY_BIND` (127.0.0.1 by default); nothing else publishes a port.
The node's RPC is for Inzyght and for `docker compose exec node ycash-cli …` (what `make
explorer-status` uses). On the backend network the proxy (.10) and the node (.11) have fixed
addresses; every other container takes one from the upper half (.128/25), so recreating containers
in any order never collides with them.

**Memory:** every service has a `mem_limit`; the defaults (about 3.2 GiB together) are for a 4 GiB
host. `YCASHD_DBCACHE` (512 MB) stays well under the node's limit.

**Logs:** every container logs to Docker's `json-file` driver, 20 MB × 3 files each. The proxy writes
one JSON access-log line per request to stdout (client address, method, URI, status, duration);
Inzyght writes to stdout only (its `inzyght.log` is `/dev/null`, and Drogon's own log goes to stdout
at WARN, so no rotated files collect in its 256 MB tmpfs).

## First start (yb-fast)

1. The node finds an empty datadir and restores the yb-fast block prefix (blocks 0..510,247,
   `testnet-prefix-v1`, pinned by sha256) with the image's `ycash-bootstrap`. The import runs with the
   stack's `ycash.conf`, so the transaction and address indexes are built during the import itself;
   no reindex follows.
2. The node then syncs the rest (the Ycash fork at 510,248, the vault upgrade from 510,400) from
   `fastnet-seed.ycash.team:18833`.
3. Inzyght applies its schema and indexes every block into PostgreSQL from genesis, then follows the
   tip through ZMQ (polling if ZMQ is silent for 5 minutes).

Measured on an arm64 Mac (the node image under emulation): the prefix download about 2 minutes, the
import about 18 minutes, Inzyght's full index about 4 minutes. The node's volume holds about 2.5 GB
of chain and indexes, plus the 2 GB download kept in `bootstrap-work/` if the restore fails.

**If the restore fails** (`make explorer-logs S=node` shows `ycash-bootstrap: refused` or `the restore
failed`), wipe and start again: `make explorer-wipe && make explorer-up`. Docker restarts the node
container, and on that second start the entrypoint finds blocks in the datadir and starts the node
without a restore, so a failed restore does not stay visible. Keep `addnode` and other peer
settings out of `YCASHD_CONF_EXTRA`: the restore's offline import node reads `ycash.conf`, and a peer
there lets it sync past the prefix during the import, which fails the restore.

## TLS: one variable

`EXPLORER_SITE` in `.env` decides it:

- `:80` (default): plain HTTP, for a laptop.
- a domain name, e.g. `fastnet-explorer.ycash.team`: Caddy obtains a Let's Encrypt certificate by
  itself (HTTP-01 on port 80), renews it, redirects HTTP to HTTPS, and keeps the certificate in the
  `caddy-data` volume. The host must then publish 80 and 443 to the internet: `PROXY_BIND=0.0.0.0`,
  `PROXY_HTTP_PORT=80`, `PROXY_HTTPS_PORT=443`, and the name's A record must point at the host.
  HTTPS responses carry `Strict-Transport-Security: max-age=31536000` (this name only, no preload);
  plain-HTTP runs never send it.

HTTP/3 is off (`protocols h1 h2`): it would need UDP 443 published and opened as well, for no gain
an explorer needs. Browsers use HTTP/2 over TCP 443.

## Limits

What the stack limits without a Caddy plugin:

- **Request size and slow clients:** request bodies over 1 MB are refused (Inzyght's API is
  read-only), request headers must arrive within 10 s, idle keep-alive connections close after 2 min.
  There is no read or write timeout, which would cut Inzyght's WebSocket.
- **Request rate per client:** Inzyght's own per-IP limiter (`INZYGHT_API_MAX_REQUESTS` 120 a
  minute for the API, `INZYGHT_ADDRESS_MAX_REQUESTS` 20 a minute for address lookups), keyed on the
  real client address (the proxy sets `X-Forwarded-For`, Inzyght trusts it only from the proxy).
- **Memory:** each container's `mem_limit`.

What it does not limit: concurrent connections per client, request rate at the proxy itself, and
static files and `/ws` (outside Inzyght's API limiter). Stock Caddy has no connection or rate limit
directive (those are third-party plugins and would need a custom Caddy build, which this stack
avoids). If abuse appears, the answer is a CDN or a filtering front (for example CloudFront with AWS
WAF rate rules) in front of the host, not a bigger proxy here.

## Outside calls

- Inzyght's network page sends the node's peer IP addresses to `http://ip-api.com/batch`. The URL is
  hard-coded and has no switch. Here Inzyght sits only on the internal `backend` network, so the call
  cannot leave the host (it fails and the peer map stays empty). Nothing else in Inzyght needs egress.
- The API itself publishes the node's peers: `/api/v1/network/peers` returns each connected peer's
  IP address and port (from `getpeerinfo`). Accepted for the testnet (its peers are the project's
  seeds); reconsider before a mainnet explorer.
- The frontend loads its JavaScript and CSS libraries from `cdn.jsdelivr.net`, `cdn.datatables.net`
  and `code.jquery.com` in the visitor's browser. Left as is; the plan (EX-7) serves them from the
  host later.

## A node on the host

When the linux/amd64 node image is too slow under emulation on an arm64 Mac, or to point Inzyght at
a node that already exists, use the override `compose.host-node.yaml`: the `node` service is not
started and Inzyght reads `host.docker.internal`.

```
# in .env: the host node's RPC user and password, and
HOST_RPC_PORT=<its rpcport>
HOST_ZMQ_PORT=<its zmqpubhashblock port>
make explorer-up EXPLORER_HOST_NODE=1
```

This is a development aid; the public host runs the bundled node. The host node needs
`-experimentalfeatures -insightexplorer -txindex` from its first sync and `-zmqpubhashblock` /
`-zmqpubhashtx`. Where it listens depends on the engine:

- **Docker Desktop (macOS, Windows):** `host.docker.internal` reaches the host's loopback, so
  `rpcbind=127.0.0.1`, `rpcallowip=127.0.0.1` and `zmqpubhashblock=tcp://127.0.0.1:<port>` (same for
  `zmqpubhashtx`) work.
- **Linux:** `host-gateway` resolves to the `docker0` bridge address (`ip -4 addr show docker0`,
  usually 172.17.0.1), not to the loopback, so a node on 127.0.0.1 is unreachable from the
  container. Inzyght's connections arrive from its address on the stack's `edge` network. The node
  needs, in `ycash.conf`:

  ```
  rpcbind=127.0.0.1
  rpcbind=172.17.0.1                 # the docker0 address (docker0 must exist before ycashd starts)
  rpcallowip=127.0.0.1
  rpcallowip=172.16.0.0/12           # Docker's bridge networks; or exactly the edge subnet:
                                     #   docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' ycash-explorer_edge
  zmqpubhashblock=tcp://172.17.0.1:<port>
  zmqpubhashtx=tcp://172.17.0.1:<port>
  ```

  Do not bind 0.0.0.0 on a host with a public interface. A host firewall (ufw, firewalld) may drop
  container-to-host traffic; then allow the edge subnet to the RPC and ZMQ ports on `docker0`.

Inzyght then needs a route to the host, so it also joins the `edge` network; its HTTP client is
pointed at a proxy address that refuses connections (`http_proxy`, with the node exempt), which
keeps the peer-location call from leaving.

## A second stack

Another settings file runs a second, independent stack (its own containers, volumes and ports), for
example a mainnet explorer against a host node:

```
cp explorer/.env explorer/.env.main     # then: EXPLORER_PROJECT=ycash-explorer-main, new ports,
                                        # HOST_RPC_PORT/HOST_ZMQ_PORT, the node's RPC credentials
make explorer-up EXPLORER_ENV=explorer/.env.main EXPLORER_HOST_NODE=1
```

## Not yet here

TLS on the testnet host, its Terraform module and ops layer (phase E3), a published image (needs the
licence), the vault and post-quantum views (E5).
