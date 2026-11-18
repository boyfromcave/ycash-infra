# images/inzyght

[Inzyght](https://github.com/miodragpop/inzyght), the Ycash block explorer (C++23, Drogon,
PostgreSQL), as a container for the explorer stack ([`explorer/`](../../explorer/README.md)).

**Local builds only.** Inzyght's repository has no licence file. Until its author has answered, we
build and run it on our own machines and hosts, and we do not publish the image to any registry.
The build makes a few one-line edits to its clone ("What the build changes", below); no Inzyght
source and no patch of it is kept in this repository. There is deliberately no image-publishing workflow for it yet.

```
make image-inzyght                       # ycash/inzyght:local and ycash/inzyght:<commit12>
make image-inzyght INZYGHT_COMMIT=<sha>  # another commit (full 40-hex SHA)
```

The build argument `INZYGHT_REPO` (default `https://github.com/miodragpop/inzyght`) names another
GitHub repository to clone, for a fork. The explorer host builds this directory itself, from the
seeds module's own revision, with both arguments from its config
([`infra/testnet-seeds/README.md`](../../infra/testnet-seeds/README.md), "The explorer").

## How it is built

- The build stage clones `INZYGHT_REPO` (`https://github.com/miodragpop/inzyght`) at `INZYGHT_COMMIT` (a full SHA,
  default `17f505f273c053247b59d20270e4d6a7b74994fb` = version 1.0.9, the workspace's
  `ref/inzyght` pin) and checks the checked-out commit. Nothing from Inzyght is copied into this
  repository. The clone then gets the edits listed under "What the build changes".
- Its `CMakeLists.txt` fetches four dependencies by tag (FetchContent). A tag can move, so the
  build stage clones each at the full commit its tag resolved to on 2026-11-14 (build args, the tag
  beside each), checks `git rev-parse HEAD`, and hands the trees to CMake with
  `FETCHCONTENT_SOURCE_DIR_<NAME>`; the CMake step runs with `--network=none` and
  `FETCHCONTENT_FULLY_DISCONNECTED=ON`, so nothing else can be fetched. The commits are also in the
  image, `/opt/inzyght/DEPENDENCIES`:

  | Dependency | Tag in `CMakeLists.txt` | Commit (build arg) |
  |---|---|---|
  | curl | `curl-8_18_0` | `2eebc58c4b8d68c98c8344381a9f6df4cca838fd` (`CURL_COMMIT`) |
  | libzmq | `v4.3.5` | `622fc6dde99ee172ebaa9c8628d85a7a1995a21d` (`ZEROMQ_COMMIT`) |
  | glaze | `v7.7.0` | `dc90e3a31ef9b93e53efb8320aae1a36f7abd80f` (`GLAZE_COMMIT`) |
  | Drogon | `v1.9.13` | `4c5430757ea5451a7c38fbbef4b4bef7dbb47f2f` (`DROGON_COMMIT`) |
  | trantor (Drogon's submodule) | the commit Drogon v1.9.13 records | `63a4e5e164e219dc3bf30cdbfa1462ae5602fa97` (`TRANTOR_COMMIT`, checked against Drogon's tree) |

  libzmq gets the one `sed` that Inzyght's `CMakeLists.txt` applies to it as its `PATCH_COMMAND`
  (a given source directory skips that step). A new
  `INZYGHT_COMMIT` needs these re-resolved from the tags its `CMakeLists.txt` names. Built on
  Debian 13 (GCC 14).
- The runtime stage is `debian:trixie-slim` with the shared libraries the binary links, plus
  `postgresql-client` for the schema. It holds `/opt/inzyght/{inzyght,public/,sql/,templates/}` and
  runs as uid 2005 with a read-only root filesystem (the stack mounts a tmpfs at `/run/inzyght`).

## What the build changes

Inzyght has no licence, so this repository holds none of its source and no patch file (a patch's
context lines are the source). Instead the Dockerfile's `edit FILE ANCHOR REPLACEMENT` step rewrites
single spots in the clone. An anchor is a short plain string that must occur in its file **exactly
once**: zero or several occurrences stop the build with the anchor's name, so a new `INZYGHT_COMMIT`
cannot drop an edit silently (if the author has fixed the line, delete our edit). The image lists
the edits it was built with in `/opt/inzyght/EDITS`. These changes are reported to the author; each
goes away when upstream has it.

| File | Anchor → replacement | Why |
|---|---|---|
| `schema.sql` | `miner_address … character varying(50)` → `(128)` | A post-quantum address (`sqf…`, `sqs…`, `tqf…`, `tqs…`) is 53 characters; the column held 50, so a block mined to one showed a cut address that links nowhere |
| `src/services/BlockIndexer.cc` | `miner_address.size() > 50) miner_address.resize(50)` → `128` twice | The indexer's own cut, made to fit that column |
| `public/js/main.js` | `(s[13]\|t[13]\|ys1\|zs1)` → `(…\|sm\|s2\|[st]q)` | The search box sent only mainnet-style prefixes to `/address/…`; testnet (`sm`, `s2`) and post-quantum (`sq`, `tq`) addresses were "unrecognized input" |
| `public/js/transaction.js` | `isCoinbase && confirmations < 100` → `isCoinbase && (tx.vout \|\| []).length > 0 && confirmations < 100` | The "immature" banner and badges were shown for every coinbase younger than 100 blocks. The node applies coinbase maturity to a coinbase's transparent outputs only (`ycash6` `src/main.cpp`, the check is in the loop over transparent inputs; post-quantum outputs are transparent-style and do mature); Sapling outputs of a coinbase are spendable at once. A coinbase with shielded outputs only now gets no banner |
| `public/js/transaction.js` | `Coinbase outputs are` → `${saplingOutputs > 0 ? "Transparent coinbase" : "Coinbase"} outputs are` | A coinbase with both kinds (a shielded reward beside a transparent fund output) says which outputs wait: "Transparent coinbase outputs are immature — …". The badges were already drawn on transparent outputs only |
| `public/partials/header.html` | `<a class="nav-link" href="/api">API</a>` → a `Value pools` item (`/pools/`) before it | The top menu (every page fetches this partial) links our value-pools page ([`images/value-pools`](../value-pools/README.md)), served under `/pools/` by the same proxy. Ours, not the author's: this edit stays as long as the explorer serves that page |

`public/js/address.js` has the same `is_coinbase && confirmations < 100` rule and is left alone: an
address page lists a transparent or post-quantum address's own entries, so a coinbase row there is
always a transparent output and "Immature" is right.

**Why 128:** the widest address the node prints into a transparent-style output is the post-quantum
one, 53 characters (P2PKH and P2SH are 35); a shielded coinbase is stored as the word `private`.
128 leaves room for any address encoding the node has (a Sapling address is 78 characters, 88 on
testnet; a Sprout one 95) and keeps the author's design, a bounded column with a matching cut in the
indexer so that one odd value can never reject a whole batch. Widening a `varchar` rewrites no rows.

**The existing index** (entrypoint, every start, before Inzyght runs):

1. *Migration.* If `blocks.miner_address` is a `varchar` narrower than 128 it becomes
   `varchar(128)`; otherwise nothing happens.
2. *Backfill.* Inzyght's index holds blocks and transaction ids, not outputs, so the cut miners
   cannot be restored with SQL alone. For every block whose `miner_address` is exactly 50
   characters, the entrypoint asks the node (`getblock <height> 1`, then `getrawtransaction <first
   txid> 1`) and rewrites the row only if exactly one address among the coinbase's outputs is longer
   than the stored text and begins with it. Rows it cannot settle are named in the log and left
   alone. If the node does not answer, Inzyght starts anyway and the next start tries again. It needs
   `-txindex`, which the explorer's node has. With no such rows it costs one query.

## The entrypoint

`entrypoint.sh` renders `inzyght.conf` and `config/drogon_config.json` into `INZYGHT_RUNDIR`
(default `/run/inzyght`, mode 0600 for the config), links `public/`, waits for PostgreSQL, applies
and checks the schema (below), and execs `inzyght` in that directory.

**Schema:** Inzyght's binary does not create its tables. On a database without `public.blocks` the
entrypoint applies `schema.sql` in one transaction. Then, on **every** start, it applies
`schema_reorg_support.sql` (so a first start killed between the two files, or an object dropped
since, is repaired) and checks that every table, view, function, column and index of both files
exists; the container stops if one is missing. The second file is idempotent except four
`CREATE INDEX` statements without `IF NOT EXISTS`; as upstream's `setup_postgresql.sh` does, it runs
without stopping on errors, and those four "already exists" errors are the only ones accepted. It
runs as Inzyght's own role (the database owner), so no superuser is needed after the database is
created.

**Logs:** Inzyght logs to stdout (its `./inzyght.log` copy is linked to `/dev/null`). Drogon's own
log also goes to stdout, at WARN (`log_path` empty in the rendered `drogon_config.json`): the
upstream example's file-rotation keys are not ones Drogon 1.9 reads, so files would collect in the
tmpfs.

| Variable | Default | Meaning |
|---|---|---|
| `INZYGHT_RPC_HOST`, `INZYGHT_RPC_PORT` | required | the node's JSON-RPC |
| `INZYGHT_RPC_USER`, `INZYGHT_RPC_PASSWORD` | required | its credentials |
| `INZYGHT_RPC_TIMEOUT` | `60.0` | seconds per request |
| `INZYGHT_ZMQ_ENDPOINT` | empty | e.g. `tcp://node:28332` (the node's `zmqpubhashblock`/`zmqpubhashtx`); empty turns ZMQ off and Inzyght polls |
| `INZYGHT_POLLING_FALLBACK_TIMEOUT`, `INZYGHT_POLLING_INTERVAL` | `300`, `120` | seconds |
| `INZYGHT_PG_HOST` | required | a name or address reached over TCP. Not `localhost`/`127.0.0.1`: Inzyght turns those into the Unix socket `/var/run/postgresql` |
| `INZYGHT_PG_PORT`, `INZYGHT_PG_DATABASE` | `5432`, `inzyght` | |
| `INZYGHT_PG_USER`, `INZYGHT_PG_PASSWORD` | required | the database owner role |
| `INZYGHT_PG_QUERY_POOL` | `8` | read connections |
| `INZYGHT_PORT`, `INZYGHT_THREADS` | `8080`, `4` | the HTTP listener (plain HTTP; TLS is the proxy's job) |
| `INZYGHT_LOG_LEVEL` | `INFO` | `DEBUG` logs the PostgreSQL connection string with its password: do not use it on a shared host |
| `INZYGHT_BLOCK_BATCH_SIZE`, `INZYGHT_BLOCK_HEADERS_BATCH_SIZE`, `INZYGHT_QUEUE_DEPTH` | `25`, `1000`, `5` | the indexer |
| `INZYGHT_RATE_LIMIT` | `true` | Inzyght's per-IP limiter |
| `INZYGHT_TRUST_PROXY`, `INZYGHT_TRUSTED_PROXIES` | `false`, `127.0.0.1,::1` | honour `X-Forwarded-For` only from these exact peer addresses |
| `INZYGHT_ADDRESS_MAX_REQUESTS`, `INZYGHT_API_MAX_REQUESTS` | `20`, `120` | per minute |

Values go into an INI file, so a value with a newline, `;` or `#` is refused.

## Outside calls

- **Peer locations:** the network page sends the node's peer IP addresses to
  `http://ip-api.com/batch` (`src/services/GeoLocationService.cc`). The URL is hard-coded and there
  is no setting to turn it off. The stack blocks it by giving the container no route out (an internal
  Docker network); the peer map then stays empty.
- **Frontend libraries:** the pages load jQuery, Bootstrap, DataTables and others from
  `cdn.jsdelivr.net`, `cdn.datatables.net` and `code.jquery.com` in the visitor's browser. Left as
  is for now (explorer plan EX-7: serve them from the host in phase E5).
