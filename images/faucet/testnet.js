// The testnet faucet page: GETs against the same origin. No framework, no inline script (the page's CSP
// allows only this file). With a proof-of-work challenge on (/info powBits > 0) it solves one first:
// the smallest decimal nonce for which SHA-256("<challenge>:<nonce>") starts with powBits zero bits.
const base = location.pathname.replace(/\/+$/, "").replace(/\/index\.html$/, "");
const $ = (id) => document.getElementById(id);
let info = null;
async function get(path) {
  const r = await fetch(base + path, { cache: "no-store" });
  const text = await r.text();
  if (!r.ok) throw new Error(text || `HTTP ${r.status}`);
  return text;
}
function zeroBits(bytes) {
  let n = 0;
  for (const b of bytes) {
    if (b === 0) { n += 8; continue; }
    return n + Math.clz32(b) - 24;
  }
  return n;
}
async function solve(challenge, bits) {
  const enc = new TextEncoder();
  for (let nonce = 0; ; nonce++) {
    const d = new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(`${challenge}:${nonce}`)));
    if (zeroBits(d) >= bits) return String(nonce);
  }
}
function hours(s) { return s >= 3600 ? `${Math.round(s / 3600)} h` : `${Math.round(s / 60)} min`; }
async function refresh() {
  try {
    info = JSON.parse(await get("/info"));
    $("network").textContent = info.network;
    $("network2").textContent = info.network;
    $("amount").textContent = info.amountZat / 1e8;
    $("window").textContent = hours(Math.max(info.perIp.windowSeconds, info.perAddress.windowSeconds));
    $("tip").textContent = info.tip ?? "?";
    $("available").textContent = info.available ? "yes" : "not right now (empty, or its node is not ready)";
  } catch (e) { $("tip").textContent = `unreachable (${e.message})`; }
}
$("send").onclick = async () => {
  const addr = $("addr").value.trim(), out = $("sendout");
  if (!addr) { out.className = "out err"; out.textContent = "Paste an address first."; return; }
  $("send").disabled = true;
  out.className = "out"; out.textContent = "…";
  try {
    let q = `/send?addr=${encodeURIComponent(addr)}`;
    if (info && info.powBits > 0) {
      out.textContent = "solving a small challenge (a few seconds)…";
      const c = JSON.parse(await get("/challenge"));
      const nonce = await solve(c.challenge, c.bits);
      q += `&challenge=${encodeURIComponent(c.challenge)}&nonce=${nonce}`;
    }
    out.textContent = "sending… (up to a few minutes when the faucet has to shield new funds first)";
    const r = JSON.parse(await get(q));
    out.className = "out ok";
    out.textContent = `sent ${r.amountZat / 1e8} testnet YEC (${r.kind}) in transaction ${r.txid}. It confirms with the next block (about 75 s).`;
  } catch (e) { out.className = "out err"; out.textContent = e.message; }
  $("send").disabled = false;
  refresh();
};
refresh(); setInterval(refresh, 30000);
