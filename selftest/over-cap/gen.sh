#!/bin/sh
# Generate a 501-line .go fixture to prove the wc -l cap trips.
set -eu
out="$(dirname "$0")/gen.go"
{ echo "package overcap"; echo ""; echo "// Padding below is intentional fixture data."; i=0; while [ "$i" -lt 498 ]; do echo "// pad $i"; i=$((i+1)); done; } > "$out"
wc -l "$out"
