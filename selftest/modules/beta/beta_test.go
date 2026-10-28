package beta

import "testing"

func TestGreet(t *testing.T) {
	t.Parallel()

	if got := Greet("eshu"); got != "hello eshu" {
		t.Fatalf("Greet(eshu) = %q, want %q", got, "hello eshu")
	}
}
