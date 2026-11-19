package serve

import (
	"context"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/boyfromcave/ycash-infra/yindex/internal/store"
	"github.com/boyfromcave/ycash-infra/yindex/walletrpc"
)

// TestGetAddressUtxosCoinbase: GetAddressUtxos carries field 7 `coinbase` as lightwalletd-dd
// does: true on a coinbase transaction's outputs, false on the others. Needs a disposable
// Postgres (YINDEX_TEST_PG_URL, the schema is dropped and recreated).
func TestGetAddressUtxosCoinbase(t *testing.T) {
	url := os.Getenv("YINDEX_TEST_PG_URL")
	if url == "" {
		t.Skip("YINDEX_TEST_PG_URL not set")
	}
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)
	if _, err := conn.Exec(ctx, "DROP SCHEMA public CASCADE; CREATE SCHEMA public"); err != nil {
		t.Fatal(err)
	}
	st, err := store.Open(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	const a = "smLnehwqrMSzBeBhChcnh6MDvaYJXFTuy13"
	v4 := "0400008085202f8901"
	cbID, spID := append([]byte{0xc0}, make([]byte, 31)...), append([]byte{0x0d}, make([]byte, 31)...)
	if _, err := conn.Exec(ctx, `INSERT INTO outputs(address,txid,vout,script,value_zat,height,coinbase) VALUES ($1,$2,0,'\x00',125,1,true),($1,$3,1,'\x00',5,2,false)`,
		a, cbID, spID); err != nil {
		t.Fatal(err)
	}
	// The stored transactions disagree with nothing: the flag column is what is served.
	if _, err := conn.Exec(ctx, `INSERT INTO txs(txid,height,raw) VALUES ($1,1,decode($3,'hex')),($2,2,decode($4,'hex'))`,
		cbID, spID, v4+strings.Repeat("00", 32)+"ffffffff", v4+"ab"+strings.Repeat("00", 31)+"00000000"); err != nil {
		t.Fatal(err)
	}
	s := &Server{Store: st}
	r, err := s.GetAddressUtxos(ctx, &walletrpc.GetAddressUtxosArg{Addresses: []string{a}})
	if err != nil {
		t.Fatal(err)
	}
	u := r.AddressUtxos
	if len(u) != 2 || !u[0].Coinbase || u[0].ValueZat != 125 || u[1].Coinbase || u[1].Index != 1 {
		t.Fatalf("%v", u)
	}
}
