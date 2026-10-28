package alpha

import "testing"

func TestDouble(t *testing.T) {
	t.Parallel()

	if got := Double(21); got != 42 {
		t.Fatalf("Double(21) = %d, want 42", got)
	}
}
