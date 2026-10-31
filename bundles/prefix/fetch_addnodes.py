#!/usr/bin/env python3
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""Fetch the current Ycash mainnet peer list for the harvest node, at run time.

In plain words: Ycash's built-in ways of finding peers (the DNS seed and two compiled-in addresses)
no longer work, so a fresh node finds no one. The Ycash explorer publishes the peers its own node
sees, on its network page and as an `addnode=` download. This script reads that page (and the
download it links to), keeps the public IPv4/IPv6 addresses, and writes them one `host:port` per
line, so the harvest node can `-addnode` them. Nothing is hardcoded: the list is whatever the
explorer shows when the harvest runs.

Usage: fetch_addnodes.py [--url URL] [--out FILE] [--max N] [--port P]
Exit 0 with at least one peer written; exit 1 if none was found (the page's links are listed, not
its addresses). Addresses are never printed: only a count goes to stdout.
"""
import argparse
import html
import ipaddress
import re
import sys
import urllib.parse
import urllib.request

DEFAULT_URL = "https://explorer.ycash.xyz/network.html"
DEFAULT_PORT = 8833
UA = "ycash-infra-harvest/1 (peer list for a mainnet sync)"
MAX_BYTES = 2_000_000

# `addnode=1.2.3.4`, `addnode=1.2.3.4:8833`, `addnode=[::1]:8833`
ADDNODE_RE = re.compile(r"addnode\s*=\s*(\[[0-9A-Fa-f:]+\](?::\d{1,5})?|[0-9]{1,3}(?:\.[0-9]{1,3}){3}(?::\d{1,5})?)")
# getpeerinfo-shaped JSON: "addr": "1.2.3.4:8833"
ADDR_JSON_RE = re.compile(r'"addr"\s*:\s*"(\[[0-9A-Fa-f:]+\]:\d{1,5}|[0-9]{1,3}(?:\.[0-9]{1,3}){3}:\d{1,5})"')
# a table of peers: `1.2.3.4:8833`, or `<td>1.2.3.4</td>`
HOSTPORT_RE = re.compile(r"(?<![0-9.])([0-9]{1,3}(?:\.[0-9]{1,3}){3}:\d{1,5})(?![0-9.])")
CELL_RE = re.compile(r"<td[^>]*>\s*([0-9]{1,3}(?:\.[0-9]{1,3}){3})\s*</td>", re.I)
LINK_RE = re.compile(r"""(?:href|src)\s*=\s*["']([^"'#]+)["']""", re.I)
LINK_HINT_RE = re.compile(r"addnode|peer|node|network|conf", re.I)


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:  # noqa: S310 (https URL from the caller)
        return r.read(MAX_BYTES).decode("utf-8", errors="replace")


def normalize(token, port):
    """'1.2.3.4' / '1.2.3.4:8833' / '[::1]:8833' -> 'host:port' for a global address, else None."""
    token = html.unescape(token).strip()
    m = re.fullmatch(r"\[([0-9A-Fa-f:]+)\](?::(\d{1,5}))?", token) or re.fullmatch(r"([0-9.]+)(?::(\d{1,5}))?", token)
    if not m:
        return None
    try:
        ip = ipaddress.ip_address(m.group(1))
    except ValueError:
        return None
    if not ip.is_global:
        return None
    p = int(m.group(2) or port)
    if not 0 < p < 65536:
        return None
    return f"[{ip}]:{p}" if ip.version == 6 else f"{ip}:{p}"


def extract(text, port):
    """Peers in a page, from the most specific shape to the least: `addnode=` lines, then
    getpeerinfo-shaped `"addr"` values, then `ip:port` tokens or table cells holding an address."""
    for pattern in (ADDNODE_RE, ADDR_JSON_RE, HOSTPORT_RE, CELL_RE):
        found = [f for f in (normalize(t, port) for t in pattern.findall(text)) if f]
        if found:
            return found
    return []


def peers_from(url, port):
    """The page's own peers, plus those of same-site links that look like the peer download."""
    page = fetch(url)
    peers = extract(page, port)
    base = urllib.parse.urlsplit(url)
    links = []
    for href in LINK_RE.findall(page):
        u = urllib.parse.urljoin(url, html.unescape(href))
        s = urllib.parse.urlsplit(u)
        if s.scheme == "https" and s.netloc == base.netloc and u != url and LINK_HINT_RE.search(s.path + "?" + s.query):
            links.append(u)
    for u in dict.fromkeys(links):
        try:
            peers += extract(fetch(u), port)
        except OSError as e:
            print(f"fetch_addnodes: skipped a link ({type(e).__name__})", file=sys.stderr)
    return list(dict.fromkeys(peers)), links


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--url", default=DEFAULT_URL)
    ap.add_argument("--out", default="-")
    ap.add_argument("--max", type=int, default=40)
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    a = ap.parse_args(argv)
    if not a.url.startswith("https://"):
        ap.error("--url must be https")
    try:
        peers, links = peers_from(a.url, a.port)
    except OSError as e:
        print(f"fetch_addnodes: could not read {a.url}: {type(e).__name__}: {e}", file=sys.stderr)
        return 1
    peers = peers[: a.max]
    if not peers:
        print(f"fetch_addnodes: no peer addresses found at {a.url}; links followed: {links or 'none'}", file=sys.stderr)
        return 1
    body = "".join(p + "\n" for p in peers)
    if a.out == "-":
        sys.stdout.write(body)
    else:
        with open(a.out, "w") as f:
            f.write(body)
        print(f"fetch_addnodes: {len(peers)} peers from {a.url}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
