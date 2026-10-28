// Package single is a minimal fixture module exercised by the
// selftest-single-caller workflow through the reusable single-module CI.
package single

import "strings"

// Greet returns a bounded greeting; empty names stay empty.
func Greet(name string) string {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" {
		return ""
	}
	return "hello, " + trimmed
}
