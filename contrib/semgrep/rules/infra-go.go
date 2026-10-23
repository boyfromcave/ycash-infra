// Test file for infra-go.yaml (semgrep --test).
package main

func main() {
	gs := grpc.NewServer()
	// ok: ycash-infra.yindex.no-yellowback-streamer
	walletrpc.RegisterCompactTxStreamerServer(gs, srv)
	// ruleid: ycash-infra.yindex.no-yellowback-streamer
	walletrpc.RegisterYellowbackStreamerServer(gs, srv)
}
