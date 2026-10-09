# ycash-infra — agent instructions

This repository deploys the Ycash light-wallet backend (node pool, `lightwalletd-dd`, `yindex`,
Redis, Envoy Gateway, the `yew/web` bundle) on Kubernetes. It is a component of the
yellowback-workspace (`../../AGENTS.md`), on `upgrade/vault` like the other clients.

## Rules

1. **No node change, no lightwalletd change.** This repo reaches `ycashd` only through stock
   JSON-RPC and reaches `lightwalletd-dd` only by running its image. `yindex` serves three
   methods of the stock `CompactTxStreamer` proto, unchanged, from its own index; it never
   answers a `YellowbackStreamer` method (verdicts and the YED token set are the node's,
   contract rule 3 of `docs/plans/yellowback-lightwalletd-plan.md`). A node ask is recorded in
   the plan's §5, never assumed.
2. **One chart, value sets only.** Anything that differs between kind and EKS is a value, never
   a second template. If a template needs `if .Values.cloud`, the thing it guards is a value.
3. **Nothing shared between replicas.** No RWX volumes, no shared caches, no shared datadirs.
   The chain is the shared state and the protocol replicates it.
4. **Non-custodial.** Nothing in this cluster ever holds a seed, a spending key or an unsigned
   transaction for a user. `rpcuser`/`rpcpassword` are the only secrets and they are the
   node's.
5. **Images are built from the workspace trees at their pinned commits** (`images/*/Dockerfile`
   read `../../ycash6`, `../../lightwalletd-dd`); the Makefile records the commit in the tag.
   Never copy node or lightwalletd source into this repo.
6. **Naming:** Yellowback is the thing, YED is the unit (workspace rule 6). No `DigiDollar`.
7. **Secrets never in git.** `values-eks.yaml` references External Secrets; `values-kind.yaml`
   uses the regtest default credentials, which are not secrets.

## Commands

`make` lists targets. `make lint` runs `helm lint`, `kubeconform` and `go vet ./...`.
