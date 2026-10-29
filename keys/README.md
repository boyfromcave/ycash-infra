# keys — public keys that sign release files

## In plain words

A checksum file (`SHA256SUMS`) says what every downloaded file must look like, but anyone could
publish a checksum file. A signature on it, made with a secret key only the release owner holds,
proves the owner published it. This directory holds the matching **public** keys, so anyone can
check those signatures. Nothing secret is ever here.

| File | Key id | Signs |
|---|---|---|
| `ycash-release.pub` | `02C923A6C593AF18` | the owner's [minisign](https://jedisct1.github.io/minisign/) key (testnet plan decision T-6): `SHA256SUMS` of the release bundles (`bundles/prefix`, `bundles/zcash-params`) and of node release candidates, as `SHA256SUMS.minisig` beside it |

Verify a release you downloaded (`minisign` 0.11 or later):

```bash
minisign -Vm SHA256SUMS -P RWQYr5PFpiPJAigk86vf89bPYrJCXj5tskgRAPRYFsEXyciZo8dveOGQ    # SHA256SUMS.minisig beside it; or -p keys/ycash-release.pub
sha256sum -c SHA256SUMS                              # then every file against the signed sums
```

The key's id is printed in the first line of this file and of every `.minisig` it made: compare
them. A key change is a reviewed commit to this file; a `.minisig` from any other key is not the
owner's.

Bundle statements on the testnet (plan §4) may be signed by two verifier keys run by the owner;
on mainnet at least one verifier must be independent of the owner.
