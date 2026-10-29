# Obviously fake example values. The real ones live in the operator's private repository, where
# `seeds` comes from the ips layer's state (terraform_remote_state), not from a file.
seeds = {
  "seed-0" = { allocation_id = "eipalloc-00000000000000000", public_ip = "192.0.2.10" }
  "seed-1" = { allocation_id = "eipalloc-11111111111111111", public_ip = "192.0.2.11" }
}
availability_zones = ["xx-example-1a", "xx-example-1b"]
name_prefix        = "testnet-seed"
tags               = { Project = "example-project" }

# one image for every network (the profile is a runtime argument) ...
image = "ghcr.io/example/ycashd@sha256:0000000000000000000000000000000000000000000000000000000000000000"

# ... and the networks every host serves. Adding or removing one is one entry; `image` overrides the
# default for that network only (e.g. the rc on fast first). main is for a separate mainnet stack.
networks = {
  yb-fast = { profile = "fast", image = "ghcr.io/example/ycashd@sha256:1111111111111111111111111111111111111111111111111111111111111111" }
  yb-slow = { profile = "slow" }
  legacy  = { profile = "legacy" }
  main    = { profile = "main", enabled = false }
}

architecture     = "x86_64"
instance_type    = "t3a.medium"
data_volume_size = 80

# the published Zcash-testnet prefix (testnet-prefix-v1), shared by the three testnets; each network
# frames it with its own magic (f77962d3 / d4 / d5)
prefix = {
  base_url    = "https://github.com/example/ycash-infra/releases/download/testnet-prefix-v1"
  sums_sha256 = "c7b55a2a6770df8108d910572cca2dbf643a0418eb0b2d556879928a43cbc403"
  last_height = 510247
}
