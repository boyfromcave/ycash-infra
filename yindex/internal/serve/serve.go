// Package serve implements the five address methods of CompactTxStreamer from the index. Every
// other method returns Unimplemented: the gateway never routes them here (they are
// lightwalletd-dd's), and a client that reaches yindex directly gets a clear answer.
package serve

import (
	"context"
	"errors"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/boyfromcave/ycash-infra/yindex/internal/addr"
	"github.com/boyfromcave/ycash-infra/yindex/internal/store"
	"github.com/boyfromcave/ycash-infra/yindex/walletrpc"
)

type Server struct {
	walletrpc.UnimplementedCompactTxStreamerServer
	Store *store.Store
	Tip   func(context.Context) (int64, error)
}

func normalise(in []string) ([]string, error) {
	out := make([]string, 0, len(in))
	for _, a := range in {
		t, err := addr.Transparent(a)
		if err != nil {
			return nil, status.Errorf(codes.InvalidArgument, "Invalid address: %s", a)
		}
		out = append(out, t)
	}
	return out, nil
}

func (s *Server) GetAddressUtxos(ctx context.Context, arg *walletrpc.GetAddressUtxosArg) (*walletrpc.GetAddressUtxosReplyList, error) {
	var out walletrpc.GetAddressUtxosReplyList
	err := s.GetAddressUtxosStream(arg, &collect{ctx: ctx, f: func(r *walletrpc.GetAddressUtxosReply) error {
		out.AddressUtxos = append(out.AddressUtxos, r)
		return nil
	}})
	return &out, err
}

func (s *Server) GetAddressUtxosStream(arg *walletrpc.GetAddressUtxosArg, srv walletrpc.CompactTxStreamer_GetAddressUtxosStreamServer) error {
	addrs, err := normalise(arg.Addresses)
	if err != nil {
		return err
	}
	return s.Store.Utxos(srv.Context(), addrs, int64(arg.StartHeight), int(arg.MaxEntries), func(u store.Utxo) error {
		return srv.Send(&walletrpc.GetAddressUtxosReply{
			Address: u.Address, Txid: u.Txid, Index: u.Vout, Script: u.Script, ValueZat: u.ValueZat, Height: uint64(u.Height),
		})
	})
}

func (s *Server) GetTaddressBalance(ctx context.Context, list *walletrpc.AddressList) (*walletrpc.Balance, error) {
	addrs, err := normalise(list.Addresses)
	if err != nil {
		return nil, err
	}
	v, err := s.Store.Balance(ctx, addrs)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "%v", err)
	}
	return &walletrpc.Balance{ValueZat: v}, nil
}

func (s *Server) GetTaddressBalanceStream(srv walletrpc.CompactTxStreamer_GetTaddressBalanceStreamServer) error {
	var addrs []string
	for {
		a, err := srv.Recv()
		if err != nil {
			break
		}
		addrs = append(addrs, a.Address)
	}
	b, err := s.GetTaddressBalance(srv.Context(), &walletrpc.AddressList{Addresses: addrs})
	if err != nil {
		return err
	}
	return srv.SendAndClose(b)
}

func (s *Server) GetTaddressTxids(f *walletrpc.TransparentAddressBlockFilter, srv walletrpc.CompactTxStreamer_GetTaddressTxidsServer) error {
	a, err := addr.Transparent(f.Address)
	if err != nil {
		return status.Errorf(codes.InvalidArgument, "Invalid address: %s", f.Address)
	}
	start, end := int64(0), int64(0)
	if f.Range != nil && f.Range.Start != nil {
		start = int64(f.Range.Start.Height)
	}
	if f.Range != nil && f.Range.End != nil {
		end = int64(f.Range.End.Height)
	}
	if end == 0 {
		tip, err := s.Tip(srv.Context())
		if err != nil {
			return status.Errorf(codes.Internal, "%v", err)
		}
		end = tip
	}
	return s.Store.AddressTxs(srv.Context(), a, start, end, func(r store.RawTx) error {
		return srv.Send(&walletrpc.RawTransaction{Data: r.Raw, Height: uint64(r.Height)})
	})
}

// collect adapts the unary call onto the streaming implementation.
type collect struct {
	walletrpc.CompactTxStreamer_GetAddressUtxosStreamServer
	ctx context.Context
	f   func(*walletrpc.GetAddressUtxosReply) error
}

func (c *collect) Send(r *walletrpc.GetAddressUtxosReply) error { return c.f(r) }
func (c *collect) Context() context.Context                     { return c.ctx }

var _ = errors.New
