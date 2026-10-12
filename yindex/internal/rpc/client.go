// Package rpc is the smallest JSON-RPC client the ingester needs against ycashd: no
// third-party RPC library, no wallet calls, read-only.
package rpc

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

type Client struct {
	url, user, pass string
	http            *http.Client
}

func New(url, user, pass string) *Client {
	return &Client{url: url, user: user, pass: pass, http: &http.Client{Timeout: 120 * time.Second}}
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (c *Client) Call(ctx context.Context, method string, out any, params ...any) error {
	body, _ := json.Marshal(map[string]any{"jsonrpc": "1.0", "id": "yindex", "method": method, "params": params})
	req, err := http.NewRequestWithContext(ctx, "POST", c.url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.SetBasicAuth(c.user, c.pass)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	var env struct {
		Result json.RawMessage `json:"result"`
		Error  *rpcError       `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&env); err != nil {
		return fmt.Errorf("%s: %w", method, err)
	}
	if env.Error != nil {
		return fmt.Errorf("%s: rpc error %d: %s", method, env.Error.Code, env.Error.Message)
	}
	if out != nil {
		return json.Unmarshal(env.Result, out)
	}
	return nil
}

// Block is getblock <hash> 2: the transactions decoded, scriptPubKey.addresses present when the
// node runs with -insightexplorer (the address index) or for any standard P2PKH/P2SH output, and,
// on the post-quantum line, for a TX_PQPKH output as its plain PQ address (sq…/tq…/rq…, D-Q-20).
type Block struct {
	Hash              string `json:"hash"`
	Height            int64  `json:"height"`
	Time              int64  `json:"time"`
	PreviousBlockHash string `json:"previousblockhash"`
	Tx                []Tx   `json:"tx"`
}

type Tx struct {
	Txid string `json:"txid"`
	Hex  string `json:"hex"`
	Vin  []struct {
		Txid     string `json:"txid"`
		Vout     int32  `json:"vout"`
		Coinbase string `json:"coinbase"`
	} `json:"vin"`
	Vout []struct {
		N            int32   `json:"n"`
		ValueZat     int64   `json:"valueZat"`
		ValueSat     int64   `json:"valueSat"`
		Value        float64 `json:"value"`
		ScriptPubKey struct {
			Hex       string   `json:"hex"`
			Addresses []string `json:"addresses"`
		} `json:"scriptPubKey"`
	} `json:"vout"`
}

func (c *Client) BlockCount(ctx context.Context) (int64, error) {
	var n int64
	return n, c.Call(ctx, "getblockcount", &n)
}

func (c *Client) BlockHash(ctx context.Context, h int64) (string, error) {
	var s string
	return s, c.Call(ctx, "getblockhash", &s, h)
}

func (c *Client) Block(ctx context.Context, hash string) (*Block, error) {
	var b Block
	return &b, c.Call(ctx, "getblock", &b, hash, 2)
}
