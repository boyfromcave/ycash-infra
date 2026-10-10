// The faucet page: four GETs against the same origin (/faucet/*). No framework, no inline script
// (the page's CSP allows only app.js).
const base = location.pathname.replace(/\/+$/, "") || "/faucet";
const $ = (id) => document.getElementById(id);
const paramsUrl = location.origin + base + "/params/";
$("paramsurl").textContent = paramsUrl;
let walletUrl = "/";
async function get(path, out, pending) {
  if (out) { out.className = "out"; out.textContent = pending || "…"; }
  const r = await fetch(base + path, { cache: "no-store" });
  const text = await r.text();
  if (!r.ok) throw new Error(`${r.status}: ${text}`);
  return text;
}
async function info() {
  try {
    const i = JSON.parse(await get("/info"));
    $("tip").textContent = i.tip ?? "?";
    $("mempool").textContent = `${i.mempool ?? "?"} transaction${i.mempool === 1 ? "" : "s"}`;
    $("params").textContent = i.params.length === 2 ? "served from this cluster" : "not fetched yet (the init container is downloading them)";
    $("nodeaddr").textContent = i.nodeAddress;
    $("rate").textContent = i.rateSeconds;
    walletUrl = i.walletUrl || "/";
    $("wallet").href = walletUrl;
    $("walletparams").href = walletUrl + (walletUrl.includes("?") ? "&" : "?") + "params=" + encodeURIComponent(paramsUrl);
  } catch (e) { $("tip").textContent = `node unreachable (${e.message})`; }
}
function busy(on) { for (const id of ["send", "send05", "mine"]) $(id).disabled = on; }
async function send(zat) {
  const addr = $("addr").value.trim(), out = $("sendout");
  if (!addr) { out.className = "out err"; out.textContent = "Paste an address first."; return; }
  busy(true);
  try {
    const kind = addr.startsWith("yregtestsapling1") ? "private" : "public";
    const txid = await get(`/send?addr=${encodeURIComponent(addr)}&zat=${zat}`, out, `sending ${zat / 1e8} YEC (${kind})… a private send that shields coinbase first takes 10–20 s`);
    out.className = "out ok"; out.textContent = `sent ${zat / 1e8} YEC (${kind}) in ${txid}. It shows in the wallet as pending now and confirmed after the next block (≤ 5 s); press Sync in the wallet if it does not appear.`;
  } catch (e) { out.className = "out err"; out.textContent = e.message; }
  busy(false); info();
}
$("send").onclick = () => send(200000000);
$("send05").onclick = () => send(50000000);
$("mine").onclick = async () => {
  const out = $("mineout"); busy(true);
  try { const r = JSON.parse(await get("/mine?n=1", out)); out.className = "out ok"; out.textContent = `mined 1 block, tip ${r.tip}`; }
  catch (e) { out.className = "out err"; out.textContent = e.message; }
  busy(false); info();
};
$("copy").onclick = async () => {
  const out = $("copyout");
  try { await navigator.clipboard.writeText($("nodeaddr").textContent); out.className = "out ok"; out.textContent = "copied"; }
  catch (e) { out.className = "out err"; out.textContent = `select it by hand (${e.message})`; }
};
info(); setInterval(info, 5000);
