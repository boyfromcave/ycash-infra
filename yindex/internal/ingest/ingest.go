// Package ingest follows the node's best chain into the store: one block per transaction,
// a reorg detected by the previous-hash link and undone by rewinding to the fork point. One
// instance runs at a time (the chart's ingest Deployment is Recreate, replicas 1).
package ingest

import (
	"context"
	"log"
	"time"

	"github.com/boyfromcave/ycash-infra/yindex/internal/rpc"
	"github.com/boyfromcave/ycash-infra/yindex/internal/store"
)

const maxRewind = 100 // deeper than any reorg the light clients tolerate (they rewind 10)

// Node is what the ingester asks the node: the three read-only RPCs of rpc.Client.
type Node interface {
	BlockCount(ctx context.Context) (int64, error)
	BlockHash(ctx context.Context, h int64) (string, error)
	Block(ctx context.Context, hash string) (*rpc.Block, error)
}

// Index is what the ingester does to the store (store.Store; a fake in the tests).
type Index interface {
	Tip(ctx context.Context) (int64, string, error)
	HashAt(ctx context.Context, h int64) (string, error)
	Apply(ctx context.Context, b *rpc.Block) error
	Rewind(ctx context.Context, h int64) error
}

var (
	_ Node  = (*rpc.Client)(nil)
	_ Index = (*store.Store)(nil)
)

type Ingester struct {
	RPC   Node
	Store Index
	Poll  time.Duration
	// Height the index is at, for /ready and metrics.
	Height int64
}

func (g *Ingester) Run(ctx context.Context) error {
	for {
		if err := g.step(ctx); err != nil {
			log.Printf("ingest: %v", err)
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(5 * time.Second):
			}
			continue
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(g.Poll):
		}
	}
}

// step brings the index to the node's tip, or returns early when nothing changed.
func (g *Ingester) step(ctx context.Context) error {
	tipH, tipHash, err := g.Store.Tip(ctx)
	if err != nil {
		return err
	}
	nodeH, err := g.RPC.BlockCount(ctx)
	if err != nil {
		return err
	}
	// Reorg check: the node's hash at our tip must be ours. A node shorter than the index
	// (invalidateblock, or a pool member still catching up) is checked at its own tip: the
	// same hash there means our extra blocks are not yet contradicted (nothing to do until the
	// node passes us), a different one is a reorg whose fork point lies below.
	if tipH >= 0 {
		check := min(tipH, nodeH)
		ours := tipHash
		if check < tipH {
			if ours, err = g.Store.HashAt(ctx, check); err != nil {
				return err
			}
		}
		theirs, err := g.RPC.BlockHash(ctx, check)
		if err != nil {
			return err
		}
		if theirs != ours {
			fork, err := g.forkPoint(ctx, check)
			if err != nil {
				return err
			}
			log.Printf("ingest: reorg at %d (ours %s, node %s), rewinding %d -> %d", check, ours, theirs, tipH, fork)
			if err := g.Store.Rewind(ctx, fork); err != nil {
				return err
			}
			tipH = fork
		}
	}
	for h := tipH + 1; h <= nodeH; h++ {
		hash, err := g.RPC.BlockHash(ctx, h)
		if err != nil {
			return err
		}
		b, err := g.RPC.Block(ctx, hash)
		if err != nil {
			return err
		}
		if h > 0 {
			prev, err := g.Store.HashAt(ctx, h-1)
			if err != nil {
				return err
			}
			if prev != "" && prev != b.PreviousBlockHash {
				return nil // the chain moved under us; the next step rewinds
			}
		}
		if err := g.Store.Apply(ctx, b); err != nil {
			return err
		}
		g.Height = h
		if h%1000 == 0 || h == nodeH {
			log.Printf("ingest: at %d/%d %s", h, nodeH, b.Hash)
		}
	}
	return nil
}

func (g *Ingester) forkPoint(ctx context.Context, from int64) (int64, error) {
	for h := from - 1; h >= 0 && h > from-maxRewind; h-- {
		ours, err := g.Store.HashAt(ctx, h)
		if err != nil {
			return 0, err
		}
		theirs, err := g.RPC.BlockHash(ctx, h)
		if err != nil {
			return 0, err
		}
		if ours == theirs {
			return h, nil
		}
	}
	return max(from-maxRewind, -1), nil
}
