package store

import (
	"context"
	"fmt"
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/boyfromcave/ycash-infra/yindex/internal/rpc"
)

const (
	cbAddr = "smLnehwqrMSzBeBhChcnh6MDvaYJXFTuy13"
	v4     = "0400008085202f89"
)

// Raw transactions (only the prefix matters): a coinbase (null prevout) and an ordinary spend.
func coinbaseHex() string { return v4 + "01" + strings.Repeat("00", 32) + "ffffffff" + "00ffffffff" }
func spendHex(prev byte) string {
	return v4 + "01" + fmt.Sprintf("%02x", prev) + strings.Repeat("00", 31) + "00000000" + "00ffffffff"
}

func testBlock(height int64, txs ...rpc.Tx) *rpc.Block {
	return &rpc.Block{Hash: fmt.Sprintf("%064x", height), Height: height, Tx: txs}
}

func testTx(txid byte, hex string, vin string, outs int) rpc.Tx {
	t := rpc.Tx{Txid: fmt.Sprintf("%064x", txid), Hex: hex}
	t.Vin = append(t.Vin, struct {
		Txid     string `json:"txid"`
		Vout     int32  `json:"vout"`
		Coinbase string `json:"coinbase"`
	}{Txid: vin, Coinbase: map[bool]string{true: "51", false: ""}[vin == ""]})
	for i := 0; i < outs; i++ {
		t.Vout = append(t.Vout, struct {
			N            int32   `json:"n"`
			ValueZat     int64   `json:"valueZat"`
			ValueSat     int64   `json:"valueSat"`
			Value        float64 `json:"value"`
			ScriptPubKey struct {
				Hex       string   `json:"hex"`
				Addresses []string `json:"addresses"`
			} `json:"scriptPubKey"`
		}{N: int32(i), ValueZat: 1000 + int64(i)}) // #nosec G115 -- test loop index
		t.Vout[i].ScriptPubKey.Hex = "76a914" + strings.Repeat("11", 20) + "88ac"
		t.Vout[i].ScriptPubKey.Addresses = []string{cbAddr}
	}
	return t
}

func freshDB(t *testing.T) *pgx.Conn {
	url := os.Getenv("YINDEX_TEST_PG_URL")
	if url == "" {
		t.Skip("YINDEX_TEST_PG_URL not set")
	}
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close(ctx) })
	if _, err := conn.Exec(ctx, "DROP SCHEMA public CASCADE; CREATE SCHEMA public"); err != nil {
		t.Fatal(err)
	}
	return conn
}

func mustTxid(t *testing.T, h string) []byte {
	t.Helper()
	b, err := txidBytes(h)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func utxoFlags(t *testing.T, s *Store) map[string]bool {
	t.Helper()
	got := map[string]bool{}
	err := s.Utxos(context.Background(), []string{cbAddr}, 0, 0, func(u Utxo) error {
		got[fmt.Sprintf("%02x:%d", u.Txid[0], u.Vout)] = u.Coinbase
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return got
}

// TestCoinbaseFlag: Apply stores the flag (from the raw prefix, as lightwalletd-dd reads it) and
// Utxos serves it; a row without the flag (written before the column) is answered from txs.raw;
// BackfillCoinbase fills such rows and is a no-op when nothing is left.
func TestCoinbaseFlag(t *testing.T) {
	conn := freshDB(t)
	ctx := context.Background()
	s, err := Open(ctx, os.Getenv("YINDEX_TEST_PG_URL"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	cb := testTx(0xc0, coinbaseHex(), "", 2)
	spend := testTx(0x0d, spendHex(0xab), fmt.Sprintf("%064x", 0xab), 1)
	if err := s.Apply(ctx, testBlock(0, cb, spend)); err != nil {
		t.Fatal(err)
	}
	want := map[string]bool{"c0:0": true, "c0:1": true, "0d:0": false}
	check := func(stage string) {
		t.Helper()
		got := utxoFlags(t, s)
		if fmt.Sprint(got) != fmt.Sprint(want) {
			t.Fatalf("%s: %v, want %v", stage, got, want)
		}
	}
	check("applied")

	// The rows an older yindex wrote: no flag.
	if _, err := conn.Exec(ctx, "UPDATE outputs SET coinbase = NULL"); err != nil {
		t.Fatal(err)
	}
	check("NULL flags, answered from txs.raw")
	n, missing, err := s.BackfillCoinbase(ctx, 1) // batch of one: the keyset walk crosses batches
	if err != nil || n != 3 || missing != 0 {
		t.Fatalf("backfill: %d %d %v", n, missing, err)
	}
	var nulls int
	if err := conn.QueryRow(ctx, "SELECT count(*) FROM outputs WHERE coinbase IS NULL").Scan(&nulls); err != nil || nulls != 0 {
		t.Fatalf("after backfill: %d NULL, %v", nulls, err)
	}
	check("backfilled")
	if n, missing, err := s.BackfillCoinbase(ctx, 5000); err != nil || n != 0 || missing != 0 {
		t.Fatalf("second backfill: %d %d %v", n, missing, err)
	}

	// A NULL row whose transaction is not stored fails the call (no guess), and the backfill
	// leaves it and counts it.
	for _, q := range []string{"UPDATE outputs SET coinbase = NULL WHERE txid = $1", "DELETE FROM txs WHERE txid = $1"} {
		if _, err := conn.Exec(ctx, q, mustTxid(t, cb.Txid)); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.Utxos(ctx, []string{cbAddr}, 0, 0, func(Utxo) error { return nil }); err == nil || !strings.Contains(err.Error(), "coinbase lookup") {
		t.Fatalf("an unknown flag must fail the call, got %v", err)
	}
	if n, missing, err := s.BackfillCoinbase(ctx, 5000); err != nil || n != 0 || missing != 1 {
		t.Fatalf("backfill with a missing transaction: %d %d %v", n, missing, err)
	}
}

// TestCoinbaseMigration: an index created by the previous schema (outputs without the column)
// gains it at Open, NULL on its rows, and the backfill sets them.
func TestCoinbaseMigration(t *testing.T) {
	conn := freshDB(t)
	ctx := context.Background()
	old := regexp.MustCompile(`(?m)^  coinbase .*\n`).ReplaceAllString(schema, "")
	old = old[:strings.Index(old, "-- Migration (beta4)")] + old[strings.Index(old, "END $$;")+len("END $$;"):]
	if strings.Contains(old, "coinbase") {
		t.Fatal("could not derive the previous schema")
	}
	if _, err := conn.Exec(ctx, old); err != nil {
		t.Fatal(err)
	}
	cb, spend := []byte{0xc0}, []byte{0x0d}
	cbID := append(cb, make([]byte, 31)...)
	spID := append(spend, make([]byte, 31)...)
	if _, err := conn.Exec(ctx, `INSERT INTO outputs(address,txid,vout,script,value_zat,height) VALUES ($1,$2,0,'\x00',5,1),($1,$3,0,'\x00',6,2)`,
		cbAddr, cbID, spID); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `INSERT INTO txs(txid,height,raw) VALUES ($1,1,decode($3,'hex')),($2,2,decode($4,'hex'))`,
		cbID, spID, coinbaseHex(), spendHex(0xab)); err != nil {
		t.Fatal(err)
	}
	s, err := Open(ctx, os.Getenv("YINDEX_TEST_PG_URL"))
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	s, err = Open(ctx, os.Getenv("YINDEX_TEST_PG_URL")) // a second start: the guarded ALTER is a no-op
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	var nulls int
	if err := conn.QueryRow(ctx, "SELECT count(*) FROM outputs WHERE coinbase IS NULL").Scan(&nulls); err != nil || nulls != 2 {
		t.Fatalf("migrated rows: %d NULL, %v", nulls, err)
	}
	if got := utxoFlags(t, s); !got["c0:0"] || got["0d:0"] || len(got) != 2 {
		t.Fatalf("before backfill: %v", got)
	}
	if n, missing, err := s.BackfillCoinbase(ctx, 5000); err != nil || n != 2 || missing != 0 {
		t.Fatalf("backfill: %d %d %v", n, missing, err)
	}
	var cbFlag, spFlag bool
	if err := conn.QueryRow(ctx, "SELECT (SELECT coinbase FROM outputs WHERE txid=$1), (SELECT coinbase FROM outputs WHERE txid=$2)",
		cbID, spID).Scan(&cbFlag, &spFlag); err != nil || !cbFlag || spFlag {
		t.Fatalf("backfilled flags: %v %v %v", cbFlag, spFlag, err)
	}
}
