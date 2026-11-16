#!/usr/bin/env bash
# Behavior proof for the gosec lane in go-collector-ci.yml (issue #13).
# Extracts the real run scripts of the scan, count, and fail steps from the
# gosec job and replays them in order against a fake `gosec`, the way the
# runner would (bash -e, stop at the first failing step, skip the fail step
# when gosec-fail-on-findings is false). Also asserts the shape points that
# cannot be replayed: the artifact upload runs on a red lane, and the stale
# "scheduled runs only" wording is gone.
# Run: bash selftest/check-gosec.sh (from the repo root).
set -euo pipefail

wf="${GOSEC_WF:-.github/workflows/go-collector-ci.yml}"
scan_step="gosec scan (never blocking; findings ride the artifact)"
count_step="finding count to summary"
fail_step="fail on findings (when gosec-fail-on-findings is set)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0
fail=0

ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# extract STEP: print the run script of STEP inside the gosec job. Handles
# both `run: |` blocks and one-line `run: cmd` forms.
extract() {
	awk -v step="$1" '
		$0 == "  gosec:" { injob = 1; next }
		injob && /^  [a-z-]+:$/ { injob = 0 }
		injob && /^      - / { instep = (index($0, "- name: " step) > 0); inrun = 0; next }
		instep && /^        run: \|$/ { inrun = 1; next }
		instep && /^        run: / { sub(/^        run: /, ""); print; next }
		inrun && /^          / { sub(/^          /, ""); print; next }
		inrun && /^$/ { print ""; next }
		inrun { inrun = 0 }
	' "$wf"
}

# Pull the step bodies out once; a missing step is a failure, not a skip.
for s in scan count fail; do
	case "$s" in
	scan) name="$scan_step" ;;
	count) name="$count_step" ;;
	fail) name="$fail_step" ;;
	esac
	extract "$name" >"$work/$s.sh"
	if [ -s "$work/$s.sh" ]; then ok "gosec job carries a '$name' step"; else bad "gosec job carries a '$name' step"; fi
done

# Fake gosec: honors `-out PATH`, behavior chosen by FAKE_MODE.
#   findings:N  SARIF with N results, exit 1 (gosec exits non-zero on findings)
#   noloc       one result with no locations, exit 1
#   clean       SARIF with zero results, exit 1 (generics type-check quirk)
#   empty       zero-byte SARIF, exit 2 (killed mid-write)
#   none        no SARIF at all, exit 2
mkdir -p "$work/bin"
cat >"$work/bin/gosec" <<'EOF'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
	if [ "$1" = "-out" ]; then out="$2"; shift; fi
	shift
done
echo "fake gosec mode=$FAKE_MODE"
case "$FAKE_MODE" in
findings:*)
	n="${FAKE_MODE#findings:}"
	jq -n --argjson n "$n" '{version:"2.1.0",runs:[{results:[range($n)|{
		ruleId:("G" + (101 + (.%5) | tostring)),
		message:{text:"seeded finding"},
		locations:[{physicalLocation:{artifactLocation:{uri:("pkg/f\(.).go")},region:{startLine:(10 + .)}}}]}]}]}' >"$out"
	exit 1 ;;
noloc)
	echo '{"version":"2.1.0","runs":[{"results":[{"ruleId":"G999","message":{"text":"no location"}}]}]}' >"$out"
	exit 1 ;;
clean)
	echo '{"version":"2.1.0","runs":[{"results":[]}]}' >"$out"
	exit 1 ;;
empty)
	: >"$out"
	exit 2 ;;
none)
	exit 2 ;;
esac
EOF
chmod +x "$work/bin/gosec"

# replay MODE FAIL_INPUT: run scan, count, fail (when FAIL_INPUT=true) the way
# the runner chains steps. Echoes the first failing step name, or "green".
# Leaves $work/ws, $work/summary, and $work/out for the assertions.
replay() {
	local mode="$1" input="$2" step
	rm -rf "$work/ws" "$work/summary" "$work/out"
	mkdir -p "$work/ws/sub"
	: >"$work/summary"
	: >"$work/out"
	for step in scan count fail; do
		if [ "$step" = fail ] && [ "$input" != true ]; then continue; fi
		if ! (cd "$work/ws/sub" && env -i PATH="$work/bin:/usr/bin:/bin:/opt/homebrew/bin" \
			FAKE_MODE="$mode" GITHUB_WORKSPACE="$work/ws" GITHUB_STEP_SUMMARY="$work/summary" GOSEC_ARTIFACT=gosec-demo \
			bash -e "$work/$step.sh") >>"$work/out" 2>&1; then
			echo "$step"
			return
		fi
	done
	echo green
}

# expect NAME MODE INPUT WANT: WANT is green or the failing step (count|fail).
expect() {
	local got
	got="$(replay "$2" "$3")"
	if [ "$got" = "$4" ]; then ok "$1 -> $4"; else bad "$1 -> $4 (got $got)"; cat "$work/out"; fi
}
contains() { # NAME FILE PATTERN
	if grep -Eq -- "$3" "$2"; then ok "$1"; else bad "$1"; echo "--- $2"; cat "$2"; fi
}
lacks() { # NAME FILE PATTERN
	if grep -Eq -- "$3" "$2"; then bad "$1"; grep -En -- "$3" "$2"; else ok "$1"; fi
}

# Seeded finding, input true: red, SARIF kept, findings readable in log+summary.
expect "finding, input true" findings:1 true fail
if [ -s "$work/ws/gosec.sarif" ]; then ok "SARIF kept on a red lane"; else bad "SARIF kept on a red lane"; fi
contains "log names rule and file:line" "$work/out" 'G101 pkg/f0\.go:10'
contains "summary names rule and file:line" "$work/summary" 'G101 pkg/f0\.go:10'
contains "summary keeps the count heading" "$work/summary" '## gosec findings: 1'

# Many findings: only the first 20 are listed, with the total stated.
expect "25 findings, input true" findings:25 true fail
if [ "$(grep -Ec '^G[0-9]+ pkg/f[0-9]+\.go:[0-9]+$' "$work/summary")" -eq 20 ]; then ok "summary lists exactly 20 findings"; else bad "summary lists exactly 20 findings"; fi
if [ "$(grep -Ec '^G[0-9]+ pkg/f[0-9]+\.go:[0-9]+$' "$work/out")" -eq 20 ]; then ok "log lists exactly 20 findings"; else bad "log lists exactly 20 findings"; fi
contains "summary states first 20 of 25" "$work/summary" '20 of 25'

# A finding without locations must not crash the listing.
expect "finding without locations, input true" noloc true fail
contains "missing location is shown as unknown" "$work/summary" 'G999 unknown'

# Empty SARIF is a crash for every caller, input or not.
expect "empty SARIF, input true" empty true count
expect "empty SARIF, input false" empty false count
expect "missing SARIF, input true" none true count
expect "missing SARIF, input false" none false count

# Clean SARIF is green whatever the input says (gosec itself exits non-zero).
expect "clean SARIF, input true" clean true green
expect "clean SARIF, input false" clean false green

# Callers that leave the input false: findings stay advisory.
expect "finding, input false" findings:3 false green
contains "advisory run still reports the count" "$work/out" 'gosec findings: 3'
lacks "advisory run does not claim to fail" "$work/out" 'failing'

# Shape points that cannot be replayed.
check_in_gosec() { # NAME ERE
	if awk -v pat="$2" '
		$0 == "  gosec:" { injob = 1; next }
		injob && /^  [a-z-]+:$/ { injob = 0 }
		injob && ($0 ~ pat) { found = 1 }
		END { exit !found }' "$wf"; then ok "$1"; else bad "$1"; fi
}
check_in_gosec "upload step runs on a red lane" '^        if: always[(][)]$'
check_in_gosec "upload tolerates a missing SARIF" '^          if-no-files-found: warn$'
check_in_gosec "fail step gated on the input" '^        if: inputs[.]gosec-fail-on-findings$'
check_in_gosec "scan step still never blocks" '[|][|] true$'
lacks "no stale scheduled-only wording" "$wf" 'scheduled runs only|to file the issue|PRs stay advisory|scheduled runs opt into'

echo "gosec lane proof: $pass PASS, $fail FAIL"
test "$fail" -eq 0
