# images/

| Image | Dockerfile | Context |
|---|---|---|
| `ycash/ycashd` | `ycash6/contrib/docker/ycashd/Dockerfile` (in the node repo; `ycash-dd` has the same for the v4.5.0 line) | the node tree |
| `ycash/lightwalletd` | `lightwalletd-dd/Dockerfile` (in its repo) | the lightwalletd tree |
| `ycash/yindex` | `images/yindex/Dockerfile` | this repo |
| `ycash/web` | `images/web/Dockerfile` | `yew/web` after `npm run build` |
| `ycash/faucet` | `images/faucet/Dockerfile` ([README](faucet/README.md): the kind demo's regtest faucet and a testnet's faucet) | `images/faucet` |
| `ycash/testnet-status` | `images/testnet-status/Dockerfile` ([README](testnet-status/README.md): a testnet's probe and status page) | `images/testnet-status` |
| `ycash/personas` | `images/personas/Dockerfile` | see the file |

The node and lightwalletd images are owned by their repositories (rule 5 in AGENTS.md); this
directory holds only what is net new here.
