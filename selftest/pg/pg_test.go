package pgfixture

import (
	"context"
	"net"
	"testing"
	"time"
)

// The values below mirror the `with:` block in
// .github/workflows/selftest-postgres-caller.yml.
const dsnFormat = "postgresql://claimplane_test:claimplane_test@localhost:5432/"

func TestBootstrappedDatabasesAnswer(t *testing.T) {
	t.Parallel()

	conn, err := net.DialTimeout("tcp", "localhost:5432", 5*time.Second)
	if err != nil {
		t.Fatalf("postgres is not listening on localhost:5432: %v", err)
	}
	_ = conn.Close()

	for _, db := range []string{"claimplane_test_store", "claimplane_test_server", "claimplane_test_coordinator"} {
		got, err := SelectOne(context.Background(), dsnFormat+db)
		if err != nil || got != "1" {
			t.Fatalf("SelectOne(%s) = %q, %v; want \"1\", nil", db, got, err)
		}
	}
}

func TestSelectOneReportsFailure(t *testing.T) {
	t.Parallel()

	if _, err := SelectOne(context.Background(), "postgresql://nobody@127.0.0.1:1/none"); err == nil {
		t.Fatal("SelectOne against a closed port returned nil error")
	}
}
