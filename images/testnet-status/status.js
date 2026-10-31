// The status page: one GET of status.json every 30 s, rendered with textContent only (no HTML from data).
const $ = (id) => document.getElementById(id);
const base = location.pathname.replace(/\/+$/, "").replace(/\/index\.html$/, "");
function ago(t) {
  if (!t) return "?";
  const s = Math.max(0, Math.round(Date.now() / 1000 - t));
  return s < 120 ? `${s} s ago` : s < 7200 ? `${Math.round(s / 60)} min ago` : `${Math.round(s / 3600)} h ago`;
}
function flag(el, v, yes, no) {
  el.className = v === true ? "ok" : v === false ? "bad" : "";
  el.textContent = v === true ? yes : v === false ? no : "not measured";
}
async function refresh() {
  try {
    const r = await fetch(base + "/status.json", { cache: "no-store" });
    const s = await r.json();
    if (s.stale) { $("updated").textContent = "never (the probe is not answering)"; return; }
    $("network").textContent = s.network ?? "?";
    $("updated").textContent = ago(s.updated);
    $("height").textContent = s.height ?? "?";
    $("tip").textContent = ago(s.tipTime);
    $("peers").textContent = s.peers ?? "?";
    flag($("agree"), s.agree === null ? null : s.agree && s.stateAgree !== false, "yes", "NO: see the notices");
    $("seeds").textContent = `${s.seeds?.up ?? "?"} of ${s.seeds?.total ?? "?"}`;
    const h = s.vault?.activationHeight;
    $("vaultheight").textContent = h === undefined || h === null ? "?" : h < 0 ? "not scheduled" : h;
    $("vaultactive").textContent = s.vault?.active === true ? "yes" : s.vault?.active === false ? "no" : "?";
    $("set").textContent = s.attestorSet || "none yet";
    $("release").textContent = s.release || "not named";
    $("version").textContent = s.version || "?";
    const b = s.bundle;
    $("bundle").textContent = b ? `height ${b.height}, ${b.created ?? ""}${b.tarball ? `, ${b.tarball}` : ""}` : "none published";
    const ul = $("notices");
    ul.replaceChildren(...(s.notices || []).map((n) => { const li = document.createElement("li"); li.textContent = `${n.date}: ${n.text}`; return li; }));
    $("noticecard").hidden = !(s.notices || []).length;
  } catch (e) { $("updated").textContent = `unreachable (${e.message})`; }
}
refresh(); setInterval(refresh, 30000);
