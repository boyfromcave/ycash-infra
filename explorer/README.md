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
make explorer-down     # stop; the chain and the index stay in their volumes
make explorer-wipe     # stop and delete the volumes (chain, index, certificates)
make explorer-psql     # psql into the index
```

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
                RPC 18832, ZMQ 28332
                       ┌──────▼──────┐  edge network: P2P out to fastnet-seed.ycash.team:18833
                       │    node     │  ycashd beta2, -txindex -insightexplorer, ZMQ, listen=0
                       └─────────────┘  volume node-data; RPC also on 127.0.0.1:18872
```

| Service | Image | Runs as | Notes |
|---|---|---|---|
| `node` | `ghcr.io/boyfromcave/ycashd@sha256:70c0a29f…ad340` (6.22.0-beta2, the yb-fast seeds' digest; linux/amd64) | uid 2001, read-only root, no capabilities | `YCASHD_INSIGHT=1`, `YCASHD_LISTEN=0`, ZMQ `hashblock`/`hashtx` on the backend network, `YCASHD_BOOTSTRAP=prefix` |
| `postgres` | `postgres:17-alpine` (by digest) | the image drops to `postgres` | `postgres-init/10-inzyght.sh` creates the database and a non-superuser owner role on first start; Inzyght's tuning values on the command line |
| `inzyght` | `ycash/inzyght:local` | uid 2005, read-only root, no capabilities, 2 GB limit | applies its schema on first start; trusts `X-Forwarded-For` only from the proxy's fixed address |
| `proxy` | `caddy:2.10-alpine` (by digest) | root in the container, every capability dropped except binding low ports, read-only root | the only service with a port meant for browsers |

Bindings: the proxy publishes on `PROXY_BIND` (127.0.0.1 by default); the node's RPC is published on
127.0.0.1 only, for inspection; PostgreSQL and Inzyght publish nothing.

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

## Outside calls

- Inzyght's network page sends the node's peer IP addresses to `http://ip-api.com/batch`. The URL is
  hard-coded and has no switch. Here Inzyght sits only on the internal `backend` network, so the call
  cannot leave the host (it fails and the peer map stays empty). Nothing else in Inzyght needs egress.
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

The host node needs `-experimentalfeatures -insightexplorer -txindex` from its first sync,
`-zmqpubhashblock` and `-zmqpubhashtx` on `tcp://127.0.0.1:<port>`, and RPC on 127.0.0.1. Inzyght then
needs a route to the host, so it also joins the `edge` network; its HTTP client is pointed at a
proxy address that refuses connections (`http_proxy`, with the node exempt), which keeps the
peer-location call from leaving.

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
