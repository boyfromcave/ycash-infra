// Copyright (c) 2026 The Ycash developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or https://www.opensource.org/licenses/mit-license.php .

package addr

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
)

// pqVectorsSHA256 is the sha256 of testdata/pq_address_vectors.json, a byte-identical copy of the
// node lines' shared post-quantum address vectors (ycash-dd / ycash6 src/test/data/
// pq_address_vectors.json, decision D-9; lightwalletd-dd carries the same copy). A change to the
// copy fails here: take the new file from the node lines and update the hash with it.
const pqVectorsSHA256 = "dbbd1da05d995d659e1e9f8a671197e141c272998722d6cca85cdbdb52b61797"

type pqVectorFile struct {
	Format string `json:"format"`
	Valid  []struct {
		Network string `json:"network"`
		Coin    string `json:"coin"`
		Scheme  byte   `json:"scheme"`
		Version string `json:"version"`
		KeyHash string `json:"keyhash"`
		Address string `json:"address"`
	} `json:"valid"`
	Invalid []struct {
		Network string `json:"network"`
		Coin    string `json:"coin"`
		Reason  string `json:"reason"`
		Address string `json:"address"`
	} `json:"invalid"`
}

// TestPQSharedVectors: every valid vector decodes to its own network, coin, scheme and key hash
// (so it is never taken for another network's or the other coin's address), re-encodes to itself,
// and Transparent keeps a plain one as is and maps a YED one to the plain address of the same
// network, scheme and key hash; every invalid vector (the pre-D-9 form, truncated, extended, bad
// checksum, unknown version) is refused by decodePQ and by Transparent.
func TestPQSharedVectors(t *testing.T) {
	data, err := os.ReadFile("testdata/pq_address_vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	if sum := sha256.Sum256(data); hex.EncodeToString(sum[:]) != pqVectorsSHA256 {
		t.Fatalf("pq_address_vectors.json sha256 %x, want %s: the copy drifted from the node lines' file", sum, pqVectorsSHA256)
	}
	var f pqVectorFile
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatal(err)
	}
	if f.Format != "ycash-pq-address-vectors-1" || len(f.Valid) != 72 || len(f.Invalid) != 60 {
		t.Fatalf("format %q, %d valid, %d invalid; want ycash-pq-address-vectors-1, 72, 60", f.Format, len(f.Valid), len(f.Invalid))
	}

	plainOf := map[string]string{} // network/scheme/keyhash -> the plain address
	for _, v := range f.Valid {
		if v.Coin == "yec" {
			plainOf[v.Network+string(rune('0'+v.Scheme))+v.KeyHash] = v.Address
		}
	}
	checked := 0
	for _, v := range f.Valid {
		yed := v.Coin == "yed"
		k, keyHash, ok := decodePQ(v.Address)
		if !ok || k.network != v.Network || k.yed != yed || k.scheme != v.Scheme || hex.EncodeToString(keyHash) != v.KeyHash {
			t.Errorf("%s: decoded %+v %x %v, want %s %s scheme %d %s", v.Address, k, keyHash, ok, v.Network, v.Coin, v.Scheme, v.KeyHash)
			continue
		}
		if ver := pqVersionOf[k]; hex.EncodeToString(ver[:]) != v.Version {
			t.Errorf("%s: version %x, want %s", v.Address, ver, v.Version)
		}
		if again, err := encodePQ(k, keyHash); err != nil || again != v.Address {
			t.Errorf("%s: re-encodes to %q, %v", v.Address, again, err)
		}
		want := v.Address
		if yed {
			want = plainOf[v.Network+string(rune('0'+v.Scheme))+v.KeyHash]
		}
		if want == "" {
			t.Errorf("%s: no plain vector of the same network, scheme and key hash", v.Address)
		} else if got, err := Transparent(v.Address); err != nil || got != want {
			t.Errorf("Transparent(%s) = %q, %v; want %s", v.Address, got, err, want)
		}
		checked++
	}
	for _, v := range f.Invalid {
		if k, _, ok := decodePQ(v.Address); ok {
			t.Errorf("%s (%s %s, %s) decoded as %+v", v.Address, v.Network, v.Coin, v.Reason, k)
		}
		if got, err := Transparent(v.Address); err == nil {
			t.Errorf("Transparent(%s) (%s %s, %s) = %q, want ErrInvalid", v.Address, v.Network, v.Coin, v.Reason, got)
		}
		checked++
	}
	if checked != 132 {
		t.Fatalf("checked %d vectors, want 132", checked)
	}
	if len(pqVersions) != 12 || len(pqVersionOf) != 12 {
		t.Fatalf("pqVersions %d, pqVersionOf %d: want 12 distinct versions", len(pqVersions), len(pqVersionOf))
	}
}
