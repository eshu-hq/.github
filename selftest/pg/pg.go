// Package pgfixture is a minimal fixture proving the reusable workflow's
// opt-in Postgres bootstrap: its tests need a live server on localhost:5432.
package pgfixture

import (
	"context"
	"os/exec"
	"strings"
)

// SelectOne runs "select 1" against dsn through psql and returns the trimmed
// output. psql keeps the fixture free of third-party Go dependencies.
func SelectOne(ctx context.Context, dsn string) (string, error) {
	out, err := exec.CommandContext(ctx, "psql", dsn, "-v", "ON_ERROR_STOP=1", "-tAc", "select 1").CombinedOutput()
	return strings.TrimSpace(string(out)), err
}
