package single

import "testing"

func TestGreet(t *testing.T) {
	t.Parallel()

	if got := Greet("  world "); got != "hello, world" {
		t.Fatalf("Greet() = %q, want the trimmed greeting", got)
	}
	if got := Greet("   "); got != "" {
		t.Fatalf("Greet() = %q, want empty", got)
	}
}
