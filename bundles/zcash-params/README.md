# Zcash parameter files: the GitHub mirror (release `zcash-params-v1`)

## In plain words

The ycash-dd node (the v4.5.0 line, which the testnet runs as its cross-line verifier) will not
start without three public files that Zcash published for its shielded (private) transactions:
`sapling-spend.params`, `sapling-output.params` and `sprout-groth16.params`, about 777 MB together.
They are the same files for every Zcash-family node and they never change. Zcash serves them from
`download.z.cash`; this repository keeps a copy on a GitHub release so that the Ycash testnet does
not depend on Zcash's server staying up (owner decision D3, 2026-10-28: on GitHub, under the
`boyfromcave` account, not on ycash.xyz).

Where the files come from does not matter for safety. Each file has a fingerprint (its SHA-256)
written into ycash-dd's own download script, `zcutil/fetch-params.sh`; the copy here is checked
against those fingerprints before it is published, the testnet chart checks them again before the
node uses a file, and anyone can check them by hand (below). A file that was changed, by anyone,
does not match and is refused.

## The files

| File | Bytes | SHA-256 (`zcutil/fetch-params.sh` line) |
|---|---|---|
| `sapling-spend.params` | 47,958,396 | `8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13` (223) |
| `sapling-output.params` | 3,592,860 | `2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4` (224) |
| `sprout-groth16.params` | 725,523,612 | `b685d700c60328498fbde589c8c7c484c722b788b265b72af448a5bf0ee55b50` (225) |

- **The sums** are copied from ycash-dd `zcutil/fetch-params.sh:223-225` (the names at lines 17-19,
  the origin `https://download.z.cash/downloads` at line 20). `SHA256SUMS` in this directory is the
  single source in this repository; `charts/ycash-testnet/files/zcash-params.SHA256SUMS` is a
  byte-identical copy (Helm cannot read files outside the chart), and `make zcash-params-test`
  asserts both that the copy matches and, when a ycash-dd tree is at `../ycash-dd` (or
  `YCASH_DD=`), that the sums equal the script's.
- **The sizes** are not in `fetch-params.sh`; they are the constants in `zcash_proofs`
  (librustzcash6 `zcash_proofs/src/lib.rs:55-57`). Every file is far below GitHub's 2 GiB asset
  limit, which the workflow checks.
- **How the origin serves them:** `fetch-params.sh` downloads every file, not only
  `sprout-groth16.params`, as two parts, `<name>.part.1` and `<name>.part.2`, and joins them
  (lines 109-128; `zcash_proofs` gives the reason: Cloudflare's 512 MB cache limit, and a part can be
  empty). The mirror publishes each file whole, already joined, so a download is one request per file.

## Download and verify by hand

```sh
base=https://github.com/boyfromcave/ycash-infra/releases/download/zcash-params-v1
mkdir -p ~/.zcash-params && cd ~/.zcash-params
curl -fL -O "$base/sapling-spend.params"
curl -fL -O "$base/sapling-output.params"
curl -fL -O "$base/sprout-groth16.params"
curl -fL -O "$base/SHA256SUMS"
sha256sum -c SHA256SUMS        # three OKs, or do not use the files
```

The URLs, one per file:

- https://github.com/boyfromcave/ycash-infra/releases/download/zcash-params-v1/sapling-spend.params
- https://github.com/boyfromcave/ycash-infra/releases/download/zcash-params-v1/sapling-output.params
- https://github.com/boyfromcave/ycash-infra/releases/download/zcash-params-v1/sprout-groth16.params
- https://github.com/boyfromcave/ycash-infra/releases/download/zcash-params-v1/SHA256SUMS

Check the `SHA256SUMS` you downloaded against the table above (or against your own copy of
ycash-dd's `fetch-params.sh`), not only the files against it: the release's own sums file proves
nothing on its own. Provenance (which workflow run built the release, from which commit):
`gh attestation verify <file> -R boyfromcave/ycash-infra`.

ycashd 4.5 looks for the files in `~/.zcash-params` (`-paramsdir` to change it); with them in
place, `fetch-params.sh` finds them and downloads nothing.

## How the release is made

`.github/workflows/zcash-params.yml`, started by hand (`workflow_dispatch`):

1. `test`: `make zcash-params-test` (offline).
2. `mirror`: downloads `<name>.part.1` and `<name>.part.2` of each file from
   `https://download.z.cash/downloads` exactly as `fetch-params.sh` does, joins them, and fails
   unless `sha256sum -c --strict` passes against `SHA256SUMS` here. Uploads the artifact
   `zcash-params`.
3. `publish` (only with `publish: true`, only from `upgrade/vault`): re-verifies the artifact,
   refuses if release `zcash-params-v1` exists, attests build provenance for the three files, and
   creates the release with the three files and `SHA256SUMS`.

The release is immutable: different files would be a new tag, and there is no reason to expect
any (the parameters are fixed for the life of the Sapling and Sprout circuits).

## Where it is used

`charts/ycash-testnet`: every role with `zcashParams.enabled` (the verifier, `verifierDd`) gets the
`zcash-params` init container (`files/zcash-params.sh`). It downloads each file whole from
`zcashParams.url` (default: the release above) into the params volume, refuses unless it matches
the chart's `SHA256SUMS`, keeps a present file that checks and refetches one that does not. The
image's entrypoint then finds the files and skips its own `fetch-params.sh` run. ycash6 compiles
the parameters in and needs none of this.
