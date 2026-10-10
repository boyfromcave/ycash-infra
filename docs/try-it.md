# Try it: the web wallet on the kind cluster

A tester's guide to the demo kit (`make demo`, plan §2 Demo). It is written for someone who has
not seen the wallet. Nothing here touches real money: the cluster runs a throw-away **regtest**
chain on one laptop, the faucet pays from the in-cluster miner's wallet, and the whole thing can
be reset.

## What the wallet is

YEW is the Ycash light wallet. The browser shell (`yew/web`) is the same Rust core that the iOS
and Android apps use, compiled to WebAssembly and wrapped in a small TypeScript app: the seed is
generated in your browser and encrypted at rest there (a passphrase, or a passkey where the
browser has one), the chain is scanned in a web worker through the cluster's gateway
(lightwalletd over gRPC-web), private transactions are proved in the browser, and the server
never sees a key or an unsigned transaction. It holds **YEC** (public and private balances) and
**YED**, the Yellowback dollar, which is minted against public YEC locked in a vault.

## Start it

```bash
cd ycash-infra            # the workspace's wt/infra-demo or ycash-infra tree
make images               # once: ycashd (1–2 h), lightwalletd-dd, yindex, web, faucet
make demo                 # idempotent: cluster, images loaded, certificate, monitoring, the chart
```

`make demo` ends by printing the URLs:

| | URL | What it is |
|---|---|---|
| wallet | `https://localhost/` | the YEW web shell, served by the gateway |
| faucet | `https://localhost/faucet/` | regtest only: pays your wallet, mines a block, shows the node's address |
| Grafana | `https://localhost/grafana/` | `admin` / the password `make demo` prints; dashboard "Ycash light-wallet backend" |

Three rules:

1. **One browser session per wallet at a time.** The wallet's store is one directory per browser
   profile and origin; a second tab or window on the same profile is told the store is **busy**.
   For a second wallet (the restore walk below) use a second Chrome profile or an incognito
   window.
2. **Chrome** (or another Chromium browser). Safari and Firefox lack what the proving worker needs
   today.
3. **Keep the Mac awake.** A sleeping Mac pauses Docker, so the chain and the gateway stop, and
   that looks exactly like a stalled wallet. The wallet's own scripts run under `caffeinate`; a
   person just has to know. (`caffeinate -i` in a terminal does it.)

### The certificate

`make demo` installs a certificate for `localhost` from **mkcert**'s local CA (`make kind-cert`;
`brew install mkcert` if it is missing). `mkcert -install` puts that CA into the **system trust
store** (macOS asks for your password once): after it Chrome shows the padlock. If you did not
run it, or mkcert is absent, the gateway uses the chart's self-signed certificate and Chrome shows
"Your connection is not private": click **Advanced → Proceed to localhost (unsafe)**. The wallet
works the same either way; only the padlock differs.

## The screens, in two lines each

- **Onboarding** — "Create a new wallet" or "Restore from a recovery phrase". Create shows the
  12-word phrase once, asks you to confirm a few words, checks the server (defaults to this
  origin), tells you what the wallet trusts, then takes a passphrase (or a passkey).
- **Home** — the balances: Ycash (public and private YEC, a pending line while something is in
  the mempool) and Yellowback (YED held, "Mint, vaults, claims"). Buttons: Send, Receive, Move…
  (public → private) and Sync.
- **Receive** — your address with a Public / Private toggle and Copy. "New private address"
  derives another one from the seed; a Ywallet phrase restores the same addresses.
- **Send** — recipient, amount (YEC or YED), a message field once the recipient is a private
  address; **Preview** shows what is paid from where and the fee, then a slider to confirm.
  Private spends are proved in the browser and take 10–30 s.
- **History** — one row per transaction (received, sent, private, an envelope for a memo); tap
  a row for the txid and the message; a pending row is still in the mempool.
- **Settings** — the server (set at onboarding), the **Private sending files** card (the
  Sapling proving parameters, fetched once: 52 MB; a "source" field for a mirror), import a WIF
  private key, and **Forget this wallet**.
- **Yellowback** — YED you hold, your vaults, **Mint** (two steps: amount, then the mint), and
  **Claimable** (underwater vaults any YED holder may claim).

## The walk

Everything in it takes ten minutes. The chain mines a block every 5 s; the faucet page shows the
tip height so you can see it moving.

1. **Create.** Open `https://localhost/` → Create a new wallet → write the phrase down (you will
   use it in step 9) → confirm → Check server ("Server ok · tip N") → Continue → tick the trust
   box → a passphrase → Create wallet. Home shows `$0.00` and `0.00000000 YEC`.
2. **Faucet, public.** Receive → Public → Copy. Open `https://localhost/faucet/` in another tab,
   paste, **Send 2 YEC**. The page answers with a txid. Back in the wallet: a pending line,
   then `2.00000000 YEC` public within a block or two (press Sync if it does not move).
3. **Send public.** On the faucet page copy the **Node address**. Wallet → Send → YEC → paste →
   `0.5` → Preview ("your public balance") → slide to send → "Sent", Copy txid, Done.
4. **Faucet, private.** Receive → Private → Copy → faucet page → Send 2 YEC. The first private
   funding also shields the miner's coinbase first, so it takes 10–20 s; the page says so. Home
   shows the private balance.
5. **Proving files.** Settings → Private sending files → **Fetch**. From download.z.cash by
   default; the cluster also serves a verified copy at `https://localhost/faucet/params/`
   (paste it into the source field first, or open the wallet from the faucet page's "source
   preset" link). "Ready (…)" when loaded.
6. **Shield.** Home → Move… → `0.4` → Preview → slide. Proved in the browser (about 5 s), then
   "Moved". The public balance drops and the private one rises after the next block.
7. **Private send with a memo.** Receive → Private → New private address → Copy. Send → paste →
   `0.3` → tap outside the field: a "Message" field appears → type one → Preview ("your private
   balance") → slide. About 20 s of proving. History shows "sent private YEC" with an envelope;
   tap the row for the memo.
8. **History.** Every step above is a row. Wait until no row is pending; the private balance
   now includes the 0.3 you sent yourself (the scan credits it one sync after the block).
9. **Restore on a second profile.** Open an incognito window (or another Chrome profile) at
   `https://localhost/` → Restore from a recovery phrase → the 12 words → birthday height `1`
   (or 0) → a passphrase. The same addresses and, after the scan, the same balances and history.
   Close that window before going back to the first (rule 1).
10. **Forget.** Settings → Forget this wallet → confirm. The seed is gone from that browser; the
    phrase restores it. Try the unlock screen too: reload the page and enter the passphrase.

### The Yellowback walk — after K0c

Minting needs a live price: three registered attestors and a quoting pool, which the K0c work
(`make kind-personas-up` on the K0c branch) brings to the cluster. Until then **Mint** says
"halted" (no price), the vault list says "No open vault" and Claimable says "Nothing is
claimable right now." — that is the expected state of a bare `make demo`. Once the personas run:

1. **Mint.** Yellowback → Mint → an amount of YED (the screen shows the mint price in YEC and
   the collateral it will lock) → step 2 confirms the carrier transaction. After a block the
   vault appears under "Your vaults" and the YED under "YED you hold"; Home shows the dollar
   balance.
2. **Vault.** Tap the vault: its collateral, debt, the lock height and the claim height. Send
   some YED to another address (Send → YED) and watch the balance.
3. **Redeem.** From the vault: Redeem burns the debt and releases the collateral to your public
   balance after the lock. The vault closes.
4. **Claim.** Yellowback → Claimable lists underwater vaults (the price walk of the personas can
   push one under). Claiming burns your YED for the collateral less the fee and the owner's
   residual; the core refuses to sign if the server's numbers would burn more or pay less than
   shown.

## Troubleshooting

- **"Your connection is not private"** — the certificate is self-signed or mkcert's CA is not
  installed: `mkcert -install` once, then reload; or Advanced → Proceed. See "The certificate".
- **The faucet says `429 one request per 5 s`** — it is rate-limited, one acting request (send,
  mine, reorg) every 5 s for everybody. `busy: another request is in flight` means a private
  funding is still shielding; wait for it.
- **The wallet says the store is busy** — another tab or window of the same profile has the
  wallet open (rule 1). Close it and reload.
- **A pending line on Home** — a transaction of yours is in the mempool; the next block (≤ 5 s)
  confirms it and the next sync moves it. A pending row in History is the same thing. After a
  private send to yourself the private total is lower by that amount until the scan sees the
  note as received, one sync later.
- **"Server ok" never comes at onboarding** — the gateway is down or the Mac slept: `kubectl -n
  ycash get pods`, and `curl -sk https://localhost/faucet/info` should answer JSON with the tip.
- **Nothing arrives from the faucet** — check its page's tip height moves (the miner mines every
  5 s); `kubectl -n ycash logs deploy/ycash-faucet` shows what it sent.
- **Reset the chain** — `make kind-reset-chain` wipes the regtest chain and rebuilds it in a few
  minutes; every wallet then has to be forgotten and recreated (its balances were on the old
  chain). Do not do it while someone else is using the cluster.
- **Grafana shows no data** — `make demo` with `MONITORING=1` (the default) installs
  kube-prometheus-stack; the dashboard needs a minute of scrapes. The lightwalletd panels fill
  as the wallet syncs, yindex lag is the index behind the node (0 or 1 normally), the node probe
  is the faucet's `getblockcount` every 15 s.
