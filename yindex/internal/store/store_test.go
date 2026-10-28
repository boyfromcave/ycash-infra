package store

import (
	"context"
	"os"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5"
)

// TestOpenConcurrentFreshDatabase opens the store from several connections at once on an empty
// database, as the server and the ingester do after a chain reset. Needs a disposable Postgres:
// YINDEX_TEST_PG_URL=postgres://user@host/db (the test drops and recreates the schema's tables).
func TestOpenConcurrentFreshDatabase(t *testing.T) {
	url := os.Getenv("YINDEX_TEST_PG_URL")
	if url == "" {
		t.Skip("YINDEX_TEST_PG_URL not set")
	}
	ctx := context.Background()
	for round := 0; round < 20; round++ {
		conn, err := pgx.Connect(ctx, url)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := conn.Exec(ctx, "DROP SCHEMA public CASCADE; CREATE SCHEMA public"); err != nil {
			t.Fatal(err)
		}
		conn.Close(ctx)
		var wg sync.WaitGroup
		errs := make(chan error, 8)
		for i := 0; i < 8; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				s, err := Open(ctx, url)
				if err != nil {
					errs <- err
					return
				}
				s.Close()
			}()
		}
		wg.Wait()
		close(errs)
		for err := range errs {
			t.Fatalf("round %d: %v", round, err)
		}
	}
}
