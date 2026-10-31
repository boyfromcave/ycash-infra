# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""Offline tests of fetch_addnodes.py: the page shapes it reads and the addresses it keeps.
Documentation addresses (RFC 5737, RFC 3849) stand in for peers: they are not global, so the
tests patch the global check to accept them.

Run: python3 -I -m unittest discover -s bundles/prefix/tests
"""

import ipaddress
import os
import sys
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import fetch_addnodes as F  # noqa: E402

DOC_NETS = [ipaddress.ip_network(n) for n in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24", "2001:db8::/32")]


def doc_global(self):
    return any(self in n for n in DOC_NETS)


@mock.patch.object(ipaddress.IPv4Address, "is_global", property(doc_global))
@mock.patch.object(ipaddress.IPv6Address, "is_global", property(doc_global))
class Extract(unittest.TestCase):
    def test_addnode_lines(self):
        text = "addnode=192.0.2.1\naddnode=198.51.100.7:18833\naddnode=192.0.2.1\naddnode=[2001:db8::5]:8833\n"
        self.assertEqual(F.extract(text, 8833), ["192.0.2.1:8833", "198.51.100.7:18833", "192.0.2.1:8833", "[2001:db8::5]:8833"])

    def test_private_and_bad_addresses_are_dropped(self):
        text = "addnode=10.0.0.1\naddnode=127.0.0.1\naddnode=999.1.1.1\naddnode=192.0.2.9:0\naddnode=203.0.113.4\n"
        self.assertEqual(F.extract(text, 8833), ["203.0.113.4:8833"])

    def test_getpeerinfo_json(self):
        text = '[{"addr": "192.0.2.3:8833", "subver": "/MagicBean:4.5.0/"}, {"addr": "10.1.1.1:8833"}]'
        self.assertEqual(F.extract(text, 8833), ["192.0.2.3:8833"])

    def test_table(self):
        self.assertEqual(F.extract("<tr><td>198.51.100.2:8833</td><td>4.5.0</td></tr>", 8833), ["198.51.100.2:8833"])
        self.assertEqual(F.extract("<tr><td> 198.51.100.3 </td><td>/MagicBean:4.5.0/</td></tr>", 8833), ["198.51.100.3:8833"])

    def test_addnode_lines_win_over_other_shapes(self):
        text = '<td>203.0.113.9:8833</td> addnode=192.0.2.8'
        self.assertEqual(F.extract(text, 8833), ["192.0.2.8:8833"])

    def test_nothing(self):
        self.assertEqual(F.extract("<html>no peers; version 4.5.0.1</html>", 8833), [])


@mock.patch.object(ipaddress.IPv4Address, "is_global", property(doc_global))
class PeersFrom(unittest.TestCase):
    PAGES = {
        "https://explorer.example/network.html": '<a href="/download/addnodes.txt">addnodes</a> <a href="https://other.example/addnode">x</a> <a href="/about.html">about</a> <td>192.0.2.40:8833</td>',
        "https://explorer.example/download/addnodes.txt": "addnode=192.0.2.41\naddnode=192.0.2.40\n",
    }

    def fake_fetch(self, url):
        if url not in self.PAGES:
            raise AssertionError(f"fetched an unexpected URL: {url}")
        return self.PAGES[url]

    def test_follows_same_site_peer_links_only(self):
        with mock.patch.object(F, "fetch", self.fake_fetch):
            peers, links = F.peers_from("https://explorer.example/network.html", 8833)
        self.assertEqual(peers, ["192.0.2.40:8833", "192.0.2.41:8833"])
        self.assertEqual(links, ["https://explorer.example/download/addnodes.txt"])

    def test_main_writes_the_file_and_never_prints_addresses(self):
        import io
        import tempfile
        out = os.path.join(tempfile.mkdtemp(), "peers")
        buf = io.StringIO()
        with mock.patch.object(F, "fetch", self.fake_fetch), mock.patch("sys.stdout", buf):
            rc = F.main(["--url", "https://explorer.example/network.html", "--out", out, "--max", "1"])
        self.assertEqual(rc, 0)
        with open(out) as f:
            self.assertEqual(f.read(), "192.0.2.40:8833\n")
        self.assertNotIn("192.0.2", buf.getvalue())

    def test_main_fails_without_peers(self):
        with mock.patch.object(F, "fetch", lambda u: "<html></html>"), mock.patch("sys.stderr"):
            self.assertEqual(F.main(["--url", "https://explorer.example/network.html", "--out", os.devnull]), 1)

    def test_main_refuses_http(self):
        with self.assertRaises(SystemExit), mock.patch("sys.stderr"):
            F.main(["--url", "http://explorer.example/network.html"])


if __name__ == "__main__":
    unittest.main()
