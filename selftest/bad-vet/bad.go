package badvet

import "fmt"

// Mismatched verb trips go vet (printf check).
func Speak() {
	fmt.Printf("%d", "not-a-number")
}
