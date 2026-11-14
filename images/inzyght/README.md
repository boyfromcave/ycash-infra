# images/inzyght

[Inzyght](https://github.com/miodragpop/inzyght), the Ycash block explorer (C++23, Drogon,
PostgreSQL), as a container for the explorer stack ([`explorer/`](../../explorer/README.md)).

**Local builds only.** Inzyght's repository has no licence file. Until its author has answered, we
build and run it, unmodified, on our own machines and hosts, and we do not publish the image to any
registry. There is deliberately no image-publishing workflow for it yet.

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
  repository and nothing is patched.
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
  (a given source directory skips that step). Inzyght's own source is not changed. A new
  `INZYGHT_COMMIT` needs these re-resolved from the tags its `CMakeLists.txt` names. Built on
  Debian 13 (GCC 14).
- The runtime stage is `debian:trixie-slim` with the shared libraries the binary links, plus
  `postgresql-client` for the schema. It holds `/opt/inzyght/{inzyght,public/,sql/,templates/}` and
  runs as uid 2005 with a read-only root filesystem (the stack mounts a tmpfs at `/run/inzyght`).

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
