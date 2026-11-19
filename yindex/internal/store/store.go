// Package store is the Postgres index: the ingester writes blocks atomically, the servers read.
package store

import (
	"context"
	_ "embed"
	"encoding/hex"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/boyfromcave/ycash-infra/yindex/internal/rpc"
	"github.com/boyfromcave/ycash-infra/yindex/internal/txparse"
)

//go:embed schema.sql
var schema string

type Store struct{ db *pgxpool.Pool }

func Open(ctx context.Context, url string) (*Store, error) {
	db, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, err
	}
	if err := applySchema(ctx, db); err != nil {
		db.Close()
		return nil, fmt.Errorf("schema: %w", err)
	}
	return &Store{db: db}, nil
}

// schemaLockKey is the advisory lock that serializes schema creation. The server and the
// ingester open the store at the same time on a fresh database, and two concurrent
// CREATE TABLE IF NOT EXISTS can both pass the existence check and fail on pg_type's unique
// index (SQLSTATE 23505), which restarted one of them once on every kind chain reset.
const schemaLockKey = 0x79696e646578 // "yindex"

func applySchema(ctx context.Context, db *pgxpool.Pool) error {
	return pgx.BeginFunc(ctx, db, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock($1)", int64(schemaLockKey)); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, schema)
		return err
	})
}

func (s *Store) Close() { s.db.Close() }

func (s *Store) Ping(ctx context.Context) error { return s.db.Ping(ctx) }

// Tip returns the indexed tip (height, hash); height -1 when empty.
func (s *Store) Tip(ctx context.Context) (int64, string, error) {
	var h int64
	var hash string
	err := s.db.QueryRow(ctx, `SELECT height, hash FROM blocks ORDER BY height DESC LIMIT 1`).Scan(&h, &hash)
	if errors.Is(err, pgx.ErrNoRows) {
		return -1, "", nil
	}
	return h, hash, err
}

func (s *Store) HashAt(ctx context.Context, h int64) (string, error) {
	var hash string
	err := s.db.QueryRow(ctx, `SELECT hash FROM blocks WHERE height=$1`, h).Scan(&hash)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return hash, err
}

// Apply writes one block in one transaction: outputs created, inputs spent, address_txs, txs.
func (s *Store) Apply(ctx context.Context, b *rpc.Block) error {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `INSERT INTO blocks(height,hash,time) VALUES($1,$2,$3)`, b.Height, b.Hash, b.Time); err != nil {
		return err
	}
	for _, t := range b.Tx {
		txid, err := txidBytes(t.Txid)
		if err != nil {
			return err
		}
		raw, err := hex.DecodeString(t.Hex)
		if err != nil {
			return fmt.Errorf("tx %s hex: %w", t.Txid, err)
		}
		// GetAddressUtxosReply.coinbase, from the bytes as lightwalletd-dd reads them. A prefix
		// that does not parse stops the ingest rather than store a guess.
		coinbase, err := txparse.IsCoinbase(raw)
		if err != nil {
			return fmt.Errorf("tx %s: coinbase: %w", t.Txid, err)
		}
		touched := map[string]struct{}{}
		for _, o := range t.Vout {
			if len(o.ScriptPubKey.Addresses) != 1 {
				continue // not a single-address standard output (OP_RETURN, bare multisig, the carrier payload)
			}
			a := o.ScriptPubKey.Addresses[0]
			script, _ := hex.DecodeString(o.ScriptPubKey.Hex)
			val := o.ValueZat
			if val == 0 {
				val = o.ValueSat
			}
			if _, err := tx.Exec(ctx, `INSERT INTO outputs(address,txid,vout,script,value_zat,height,coinbase) VALUES($1,$2,$3,$4,$5,$6,$7)
				ON CONFLICT (txid,vout) DO NOTHING`, a, txid, o.N, script, val, b.Height, coinbase); err != nil {
				return err
			}
			touched[a] = struct{}{}
		}
		for _, in := range t.Vin {
			if in.Coinbase != "" {
				continue
			}
			prev, err := txidBytes(in.Txid)
			if err != nil {
				return err
			}
			var a string
			err = tx.QueryRow(ctx, `UPDATE outputs SET spent_txid=$1, spent_height=$2 WHERE txid=$3 AND vout=$4 RETURNING address`,
				txid, b.Height, prev, in.Vout).Scan(&a)
			if errors.Is(err, pgx.ErrNoRows) {
				continue // spends a shielded-only or pre-index output
			}
			if err != nil {
				return err
			}
			touched[a] = struct{}{}
		}
		if len(touched) == 0 {
			continue
		}
		if _, err := tx.Exec(ctx, `INSERT INTO txs(txid,height,raw) VALUES($1,$2,$3) ON CONFLICT (txid) DO NOTHING`, txid, b.Height, raw); err != nil {
			return err
		}
		for a := range touched {
			if _, err := tx.Exec(ctx, `INSERT INTO address_txs(address,txid,height) VALUES($1,$2,$3) ON CONFLICT DO NOTHING`, a, txid, b.Height); err != nil {
				return err
			}
		}
	}
	return tx.Commit(ctx)
}

// Rewind drops everything above height h (a reorg): blocks, outputs created, txs, and the
// spends recorded above h are undone.
func (s *Store) Rewind(ctx context.Context, h int64) error {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	for _, q := range []string{
		`UPDATE outputs SET spent_txid=NULL, spent_height=NULL WHERE spent_height > $1`,
		`DELETE FROM outputs WHERE height > $1`,
		`DELETE FROM address_txs WHERE height > $1`,
		`DELETE FROM txs WHERE height > $1`,
		`DELETE FROM blocks WHERE height > $1`,
	} {
		if _, err := tx.Exec(ctx, q, h); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

type Utxo struct {
	Address  string
	Txid     []byte
	Vout     int32
	Script   []byte
	ValueZat int64
	Height   int64
	Coinbase bool
}

// Utxos lists unspent outputs. A row written before the coinbase column (NULL until the
// ingester's backfill reaches it) is answered from the stored transaction's prefix; a row with
// neither fails the call, as lightwalletd-dd fails it when its lookup fails: a coinbase output
// reported as an ordinary coin would be offered to an ordinary send, which consensus refuses.
func (s *Store) Utxos(ctx context.Context, addresses []string, start int64, max int, f func(Utxo) error) error {
	rows, err := s.db.Query(ctx, `SELECT o.address,o.txid,o.vout,o.script,o.value_zat,o.height,o.coinbase,
			CASE WHEN o.coinbase IS NULL THEN substring(t.raw FROM 1 FOR $4) END
		FROM outputs o LEFT JOIN txs t ON o.coinbase IS NULL AND t.txid = o.txid
		WHERE o.address = ANY($1) AND o.spent_height IS NULL AND o.height >= $2 ORDER BY o.height, o.txid, o.vout LIMIT $3`,
		addresses, start, nullIfZero(max), txparse.PrefixLen)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var u Utxo
		var coinbase *bool
		var prefix []byte
		if err := rows.Scan(&u.Address, &u.Txid, &u.Vout, &u.Script, &u.ValueZat, &u.Height, &coinbase, &prefix); err != nil {
			return err
		}
		if coinbase != nil {
			u.Coinbase = *coinbase
		} else {
			if prefix == nil {
				return fmt.Errorf("coinbase lookup: no stored transaction for output %x:%d", u.Txid, u.Vout)
			}
			v, err := txparse.IsCoinbase(prefix)
			if err != nil {
				return fmt.Errorf("coinbase lookup: %x: %w", u.Txid, err)
			}
			u.Coinbase = v
		}
		if err := f(u); err != nil {
			return err
		}
	}
	return rows.Err()
}

func (s *Store) Balance(ctx context.Context, addresses []string) (int64, error) {
	var v int64
	err := s.db.QueryRow(ctx, `SELECT COALESCE(SUM(value_zat),0) FROM outputs WHERE address = ANY($1) AND spent_height IS NULL`, addresses).Scan(&v)
	return v, err
}

type RawTx struct {
	Txid   []byte
	Height int64
	Raw    []byte
}

func (s *Store) AddressTxs(ctx context.Context, address string, start, end int64, f func(RawTx) error) error {
	rows, err := s.db.Query(ctx, `SELECT t.txid, t.height, t.raw FROM address_txs a JOIN txs t USING (txid)
		WHERE a.address=$1 AND a.height BETWEEN $2 AND $3 ORDER BY a.height, t.txid`, address, start, end)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var r RawTx
		if err := rows.Scan(&r.Txid, &r.Height, &r.Raw); err != nil {
			return err
		}
		if err := f(r); err != nil {
			return err
		}
	}
	return rows.Err()
}

// BackfillCoinbase sets the coinbase flag on every output written before the column existed,
// from the creating transaction's stored prefix (txs.raw), batch by batch in txid order; the
// ingester runs it once at start, before it ingests, and it returns at once on an index with
// nothing to backfill. An output whose transaction is not stored (none should exist: Apply stores
// every transaction that creates an indexed output) is left NULL and counted in `missing`.
func (s *Store) BackfillCoinbase(ctx context.Context, batch int) (updated, missing int64, err error) {
	after := []byte{}
	for {
		rows, err := s.db.Query(ctx, `SELECT o.txid, substring(t.raw FROM 1 FOR $3)
			FROM (SELECT DISTINCT txid FROM outputs WHERE coinbase IS NULL AND txid > $1 ORDER BY txid LIMIT $2) o
			LEFT JOIN txs t USING (txid) ORDER BY o.txid`, after, batch, txparse.PrefixLen)
		if err != nil {
			return updated, missing, err
		}
		var txids [][]byte
		var flags []bool
		n := 0
		for rows.Next() {
			var txid, prefix []byte
			if err := rows.Scan(&txid, &prefix); err != nil {
				rows.Close()
				return updated, missing, err
			}
			n++
			after = txid
			if prefix == nil {
				missing++
				continue
			}
			v, err := txparse.IsCoinbase(prefix)
			if err != nil {
				rows.Close()
				return updated, missing, fmt.Errorf("backfill coinbase: %x: %w", txid, err)
			}
			txids = append(txids, txid)
			flags = append(flags, v)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return updated, missing, err
		}
		if len(txids) > 0 {
			tag, err := s.db.Exec(ctx, `UPDATE outputs o SET coinbase = v.cb
				FROM unnest($1::bytea[], $2::boolean[]) AS v(txid, cb)
				WHERE o.txid = v.txid AND o.coinbase IS NULL`, txids, flags)
			if err != nil {
				return updated, missing, err
			}
			updated += tag.RowsAffected()
		}
		if n < batch {
			return updated, missing, nil
		}
	}
}

func nullIfZero(n int) any {
	if n <= 0 {
		return nil
	}
	return n
}

// txidBytes: the proto carries txids in internal (little-endian) byte order, the RPC prints
// them big-endian hex; the index stores the proto's order so the servers copy bytes through.
func txidBytes(h string) ([]byte, error) {
	b, err := hex.DecodeString(h)
	if err != nil || len(b) != 32 {
		return nil, fmt.Errorf("bad txid %q", h)
	}
	for i, j := 0, 31; i < j; i, j = i+1, j-1 {
		b[i], b[j] = b[j], b[i]
	}
	return b, nil
}
