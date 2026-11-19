package txparse

import (
	"bufio"
	"encoding/hex"
	"os"
	"strings"
	"testing"
)

// TestIsCoinbaseBlocks: the first transaction of every block in testdata/blocks (lightwalletd-dd's
// testdata/blocks, four mainnet blocks) is a coinbase, read from its prefix alone.
func TestIsCoinbaseBlocks(t *testing.T) {
	f, err := os.Open("testdata/blocks")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	scan := bufio.NewScanner(f)
	scan.Buffer(make([]byte, 1<<20), 1<<24)
	blocks := 0
	for scan.Scan() {
		data, err := hex.DecodeString(scan.Text())
		if err != nil {
			t.Fatal(err)
		}
		// version, hashPrevBlock, hashMerkleRoot, hashFinalSaplingRoot, nTime, nBits, nNonce
		p := 4 + 32 + 32 + 32 + 4 + 4 + 32
		sol, n, err := compactSize(data[p:])
		if err != nil {
			t.Fatal(err)
		}
		p += n + int(sol)
		txs, n, err := compactSize(data[p:])
		if err != nil || txs < 1 {
			t.Fatalf("block %d: tx count %d %v", blocks, txs, err)
		}
		p += n
		got, err := IsCoinbase(data[p:])
		if err != nil || !got {
			t.Fatalf("block %d: first transaction IsCoinbase = %v, %v", blocks, got, err)
		}
		if got, err := IsCoinbase(data[p : p+PrefixLen]); err != nil || !got {
			t.Fatalf("block %d: the %d-byte prefix alone: %v, %v", blocks, PrefixLen, got, err)
		}
		blocks++
	}
	if blocks == 0 {
		t.Fatal("no test blocks")
	}
}

// TestIsCoinbaseCases mirrors lightwalletd-dd's parser.TestIsCoinbase on hand-built prefixes.
func TestIsCoinbaseCases(t *testing.T) {
	null := strings.Repeat("00", 32) + "ffffffff"
	v4 := "0400008085202f89"
	v5 := "050000800a27a726" + "b4d0d6c2" + "00000000" + "00000000"
	for _, c := range []struct {
		name, hex string
		want      bool
	}{
		{"v4 coinbase", v4 + "01" + null + "00ffffffff", true},
		{"v5 coinbase", v5 + "01" + null, true},
		{"v1 coinbase", "01000000" + "01" + null, true},
		{"v2 (not overwintered) coinbase", "02000000" + "01" + null, true},
		{"spend of index 0xffffffff of a non-null txid", v4 + "01" + "01" + strings.Repeat("00", 31) + "ffffffff", false},
		{"null txid with another index", v4 + "01" + strings.Repeat("00", 32) + "00000000", false},
		{"two inputs, the first null", v4 + "02" + null + "00ffffffff" + null, false},
		{"no transparent inputs", v4 + "00" + "00", false},
		// zip243 test vectors 1 and 2 (lightwalletd-dd testdata/zip243_raw_tx), prefixes
		{"zip243 vector 1", "0400008085202f890002e7719811893e0000095200ac6551ac636565b2835a0805750200025151481cdd86b3cc4318", false},
		{"zip243 vector 2", "0400008085202f890256e551406a7ee8355656a21e43e38ce129fdadb759eddfa08f00fc8e567cef93c6792d010763656300ac63ac8df042451a3359", false},
	} {
		data, err := hex.DecodeString(c.hex)
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if got, err := IsCoinbase(data); err != nil || got != c.want {
			t.Fatalf("%s: IsCoinbase = %v, %v; want %v", c.name, got, err, c.want)
		}
	}
	for _, short := range []string{"", "04000080", "0400008085202f89", v4 + "01" + "00", v5[:24] + "01", v4 + "fd"} {
		data, _ := hex.DecodeString(short)
		if _, err := IsCoinbase(data); err == nil {
			t.Fatalf("%q: a truncated prefix must be an error", short)
		}
	}
	// A non-canonical count (1 as fd0100) is an error, as in lightwalletd's ReadCompactSize.
	data, _ := hex.DecodeString(v4 + "fd0100" + null)
	if _, err := IsCoinbase(data); err == nil {
		t.Fatal("non-canonical tx_in_count accepted")
	}
}
