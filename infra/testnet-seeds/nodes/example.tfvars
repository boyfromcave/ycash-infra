# Obviously fake example values. The real ones live in the operator's private repository, where
# `seeds` comes from the ips layer's state (terraform_remote_state), not from a file.
seeds = {
  "seed-0" = { allocation_id = "eipalloc-00000000000000000", public_ip = "192.0.2.10" }
  "seed-1" = { allocation_id = "eipalloc-11111111111111111", public_ip = "192.0.2.11" }
  "seed-2" = { allocation_id = "eipalloc-22222222222222222", public_ip = "192.0.2.12" }
}
availability_zones = ["xx-example-1a", "xx-example-1b", "xx-example-1c"]
name_prefix        = "testnet-seed"
tags               = { Project = "example-project" }

image = "ghcr.io/example/ycashd@sha256:0000000000000000000000000000000000000000000000000000000000000000"
# canary: seed-0 first, then move `image` and drop the override
# image_overrides = { "seed-0" = "ghcr.io/example/ycashd@sha256:1111111111111111111111111111111111111111111111111111111111111111" }

architecture     = "x86_64"
instance_type    = "t3a.small"
data_volume_size = 40

# the published Zcash-testnet prefix (testnet-prefix-v1), framed with the new testnet magic
prefix = {
  base_url    = "https://github.com/boyfromcave/ycash-infra/releases/download/testnet-prefix-v1"
  sums_sha256 = "c7b55a2a6770df8108d910572cca2dbf643a0418eb0b2d556879928a43cbc403"
  last_height = 510247
  magic       = "f77962d3"
}
