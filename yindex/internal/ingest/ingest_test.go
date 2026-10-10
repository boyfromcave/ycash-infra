package ingest

import (
	"context"
	"fmt"
	"testing"

	"github.com/boyfromcave/ycash-infra/yindex/internal/rpc"
)

// fakeNode is a chain of blocks the test rewrites to stage a reorg; the hashes name the branch.
type fakeNode struct{ chain []*rpc.Block }

func (n *fakeNode) BlockCount(context.Context) (int64, error) { return int64(len(n.chain) - 1), nil }
func (n *fakeNode) BlockHash(_ context.Context, h int64) (string, error) {
	if h < 0 || h >= int64(len(n.chain)) {
		return "", fmt.Errorf("getblockhash: rpc error -8: Block height out of range")
	}
	return n.chain[h].Hash, nil
}
func (n *fakeNode) Block(_ context.Context, hash string) (*rpc.Block, error) {
	for _, b := range n.chain {
		if b.Hash == hash {
			return b, nil
		}
	}
	return nil, fmt.Errorf("getblock: unknown %s", hash)
}

// extend appends blocks on branch tag from height `from` (dropping anything above from-1).
func (n *fakeNode) extend(from int64, tag string, count int) {
	n.chain = n.chain[:from]
	for i := 0; i < count; i++ {
		h := from + int64(i)
		n.chain = append(n.chain, &rpc.Block{Hash: fmt.Sprintf("%s%d", tag, h), Height: h, PreviousBlockHash: n.chain[h-1].Hash})
	}
}

// fakeIndex records every Apply and Rewind, and keeps the hash chain the store would hold.
type fakeIndex struct {
	hashes []string
	log    []string
}

func (s *fakeIndex) Tip(context.Context) (int64, string, error) {
	if len(s.hashes) == 0 {
		return -1, "", nil
	}
	return int64(len(s.hashes) - 1), s.hashes[len(s.hashes)-1], nil
}
func (s *fakeIndex) HashAt(_ context.Context, h int64) (string, error) {
	if h < 0 || h >= int64(len(s.hashes)) {
		return "", nil
	}
	return s.hashes[h], nil
}
func (s *fakeIndex) Apply(_ context.Context, b *rpc.Block) error {
	if b.Height != int64(len(s.hashes)) {
		return fmt.Errorf("apply %d onto tip %d", b.Height, len(s.hashes)-1)
	}
	if b.Height > 0 && s.hashes[b.Height-1] != b.PreviousBlockHash {
		return fmt.Errorf("apply %s: prev %s is not our %d", b.Hash, b.PreviousBlockHash, b.Height-1)
	}
	s.hashes = append(s.hashes, b.Hash)
	s.log = append(s.log, "apply "+b.Hash)
	return nil
}
func (s *fakeIndex) Rewind(_ context.Context, h int64) error {
	s.hashes = s.hashes[:h+1]
	s.log = append(s.log, fmt.Sprintf("rewind %d", h))
	return nil
}

func newChain(n int) *fakeNode {
	node := &fakeNode{chain: []*rpc.Block{{Hash: "genesis", Height: 0}}}
	node.extend(1, "a", n)
	return node
}

func sameChain(t *testing.T, node *fakeNode, idx *fakeIndex) {
	t.Helper()
	if len(idx.hashes) != len(node.chain) {
		t.Fatalf("index has %d blocks, node %d", len(idx.hashes), len(node.chain))
	}
	for h, b := range node.chain {
		if idx.hashes[h] != b.Hash {
			t.Fatalf("height %d: index %s, node %s", h, idx.hashes[h], b.Hash)
		}
	}
}

// A 3-deep reorg: the node replaces a4..a6 by b4..b7; the index rewinds to 3 (the fork point)
// once and applies the new branch, ending on the node's chain.
func TestReorgThreeDeep(t *testing.T) {
	node, idx := newChain(6), &fakeIndex{}
	g := &Ingester{RPC: node, Store: idx}
	if err := g.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	sameChain(t, node, idx)
	idx.log = nil

	node.extend(4, "b", 4) // b4 b5 b6 b7 on top of a3
	if err := g.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	sameChain(t, node, idx)
	want := []string{"rewind 3", "apply b4", "apply b5", "apply b6", "apply b7"}
	if fmt.Sprint(idx.log) != fmt.Sprint(want) {
		t.Fatalf("log %v, want %v", idx.log, want)
	}
	if g.Height != 7 {
		t.Fatalf("height %d", g.Height)
	}
}

// invalidateblock on the node: it drops to a3 (shorter than the index, same prefix) and the
// miner then extends it by two blocks only. The shorter node is not a reorg yet (the index
// keeps a4..a6 until contradicted); the two new blocks are, with the fork point found below
// the node's tip.
func TestReorgNodeShorter(t *testing.T) {
	node, idx := newChain(6), &fakeIndex{}
	g := &Ingester{RPC: node, Store: idx}
	if err := g.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	idx.log = nil

	node.extend(4, "a", 0) // invalidateblock a4: the node is at a3
	if err := g.step(context.Background()); err != nil {
		t.Fatalf("a shorter node with our prefix is not an error: %v", err)
	}
	if len(idx.log) != 0 || len(idx.hashes) != 7 {
		t.Fatalf("nothing should change: log %v, %d blocks", idx.log, len(idx.hashes))
	}

	node.extend(4, "b", 2) // b4 b5: still shorter than our a6
	if err := g.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	sameChain(t, node, idx)
	want := []string{"rewind 3", "apply b4", "apply b5"}
	if fmt.Sprint(idx.log) != fmt.Sprint(want) {
		t.Fatalf("log %v, want %v", idx.log, want)
	}
}

// A block whose previous hash is not our tip (the chain moved between getblockcount and
// getblock) is not applied: the step returns and the next one rewinds.
func TestMovedUnderUs(t *testing.T) {
	node, idx := newChain(6), &fakeIndex{}
	g := &Ingester{RPC: node, Store: idx}
	if err := g.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	idx.log = nil
	// The node's hash at our tip still matches, but height 7 claims another parent.
	node.chain = append(node.chain, &rpc.Block{Hash: "b7", Height: 7, PreviousBlockHash: "b6"})
	if err := g.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(idx.log) != 0 {
		t.Fatalf("applied %v", idx.log)
	}
}
