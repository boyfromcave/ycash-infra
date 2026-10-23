// yindex: `yindex ingest` follows the node into Postgres; `yindex serve` answers the address
// methods of CompactTxStreamer from it. Configuration by environment (the chart sets it).
package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"

	"github.com/boyfromcave/ycash-infra/yindex/internal/ingest"
	"github.com/boyfromcave/ycash-infra/yindex/internal/rpc"
	"github.com/boyfromcave/ycash-infra/yindex/internal/serve"
	"github.com/boyfromcave/ycash-infra/yindex/internal/store"
	"github.com/boyfromcave/ycash-infra/yindex/walletrpc"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: yindex ingest|serve")
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	st, err := store.Open(ctx, env("YINDEX_POSTGRES_URL", "postgres://yindex:yindex@localhost:5432/yindex?sslmode=disable"))
	if err != nil {
		log.Fatalf("postgres: %v", err)
	}
	defer st.Close()
	node := rpc.New(env("YINDEX_RPC_URL", "http://localhost:18832"), os.Getenv("YINDEX_RPC_USER"), os.Getenv("YINDEX_RPC_PASSWORD"))

	ready := func(context.Context) error { return st.Ping(ctx) }
	// /metrics (Prometheus text format, no client library): the index tip, the node tip and the lag
	// between them, for the kind demo's Grafana dashboard (plan §2 Demo). A failed read is left
	// out rather than reported as 0.
	metrics := func(c context.Context, w http.ResponseWriter) {
		c, cancel := context.WithTimeout(c, 3*time.Second)
		defer cancel()
		tip, _, errT := st.Tip(c)
		node, errN := node.BlockCount(c)
		if errT == nil {
			fmt.Fprintf(w, "# TYPE yindex_tip_height gauge\nyindex_tip_height %d\n", tip)
		}
		if errN == nil {
			fmt.Fprintf(w, "# TYPE yindex_node_height gauge\nyindex_node_height %d\n", node)
		}
		if errT == nil && errN == nil {
			fmt.Fprintf(w, "# TYPE yindex_lag_blocks gauge\nyindex_lag_blocks %d\n", node-tip)
		}
	}
	switch os.Args[1] {
	case "ingest":
		g := &ingest.Ingester{RPC: node, Store: st, Poll: 2 * time.Second}
		go health(env("YINDEX_HTTP_ADDR", ":9071"), ready, metrics)
		log.Fatal(g.Run(ctx))
	case "serve":
		lis, err := net.Listen("tcp", env("YINDEX_GRPC_ADDR", ":9070"))
		if err != nil {
			log.Fatal(err)
		}
		gs := grpc.NewServer()
		walletrpc.RegisterCompactTxStreamerServer(gs, &serve.Server{Store: st, Tip: func(c context.Context) (int64, error) {
			h, _, err := st.Tip(c)
			return h, err
		}})
		reflection.Register(gs)
		go health(env("YINDEX_HTTP_ADDR", ":9071"), ready, metrics)
		go func() { <-ctx.Done(); gs.GracefulStop() }()
		log.Printf("yindex serve on %s", lis.Addr())
		log.Fatal(gs.Serve(lis))
	default:
		fmt.Fprintln(os.Stderr, "usage: yindex ingest|serve")
		os.Exit(2)
	}
}

func health(addr string, ready func(context.Context) error, metrics func(context.Context, http.ResponseWriter)) {
	mux := http.NewServeMux()
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		metrics(r.Context(), w)
	})
	mux.HandleFunc("/live", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) })
	mux.HandleFunc("/ready", func(w http.ResponseWriter, r *http.Request) {
		if err := ready(r.Context()); err != nil {
			http.Error(w, err.Error(), 503)
			return
		}
		w.WriteHeader(200)
	})
	// Probe and metrics port: bounded header read so a slow client cannot hold connections open (gosec G114).
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	log.Fatal(srv.ListenAndServe())
}
