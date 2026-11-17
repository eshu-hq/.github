#!/usr/bin/env bash
# Behavior proof for the test-timeout and race-test-timeout inputs in
# go-collector-ci.yml (issue #15). Extracts the real validate and go test step
# scripts from the test and race jobs and replays them against a stub `go`,
# so the effective command line and the bad-value guard are exercised without
# a toolchain. Also asserts the shape points that cannot be replayed: inputs
# reach the shell only through env:, the job timeouts did not move, and the
# header comment names both inputs.
# Run: bash selftest/check-timeouts.sh (from the repo root).
set -euo pipefail

wf="${TIMEOUT_WF:-.github/workflows/go-collector-ci.yml}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0
fail=0

ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# extract JOB STEP: print the run script of STEP inside JOB. Handles both
# `run: |` blocks and one-line `run: cmd` forms.
extract() {
	awk -v job="$1" -v step="$2" '
		$0 == "  " job ":" { injob = 1; next }
		injob && /^  [a-z-]+:$/ { injob = 0; instep = 0; inrun = 0 }
		injob && /^      - / { instep = ($0 == "      - name: " step); inrun = 0; next }
		instep && /^        run: \|$/ { inrun = 1; next }
		instep && /^        run: / { sub(/^        run: /, ""); print; next }
		inrun && /^          / { sub(/^          /, ""); print; next }
		inrun && /^$/ { print ""; next }
		inrun { inrun = 0 }
	' "$wf"
}

# Stub go: records its argv on one line.
mkdir -p "$work/bin"
cat >"$work/bin/go" <<'STUB'
#!/usr/bin/env bash
echo "go $*" >>"$STUB_LOG"
STUB
chmod +x "$work/bin/go"

# run_script SCRIPT [VAR=value ...]: run like the runner does (bash -e), log
# the stub go calls to $work/log, leave the exit code in $got.
run_script() {
	local script="$1"
	shift
	: >"$work/log"
	got=0
	env -i PATH="$work/bin:/usr/bin:/bin" STUB_LOG="$work/log" "$@" \
		bash -e "$script" >"$work/out" 2>&1 || got=$?
}

for lane in test race; do
	if [ "$lane" = test ]; then
		job=test var=TEST_TIMEOUT input=test-timeout want_default=9m
		gostep="test"
		want_pre="go test ./... -count=1"
	else
		job=race var=RACE_TEST_TIMEOUT input=race-test-timeout want_default=13m
		gostep="race + coverprofile"
		want_pre="go test ./... -race -count=1 -covermode=atomic -coverprofile=coverage.out"
	fi
	vstep="validate $input"

	extract "$job" "$vstep" >"$work/$lane-validate.sh"
	extract "$job" "$gostep" >"$work/$lane-go.sh"
	for s in validate go; do
		if [ -s "$work/$lane-$s.sh" ]; then ok "$job job carries its $s step"; else bad "$job job carries its $s step"; fi
	done
	[ -s "$work/$lane-validate.sh" ] && [ -s "$work/$lane-go.sh" ] || continue

	# The input is declared as a string with the documented default.
	if awk -v n="$input" '
		$0 == "      " n ":" { inin = 1; next }
		inin && /^      [a-z]/ { exit }
		inin && /default: / { d = $0; sub(/.*default: /, "", d); gsub(/[\047"]/, "", d) }
		inin && /type: / { t = $0; sub(/.*type: /, "", t) }
		END { exit !(d == "'"$want_default"'" && t == "string") }' "$wf"; then
		ok "$input is a string input defaulting to $want_default"
	else
		bad "$input is a string input defaulting to $want_default"
	fi

	# The caller passes nothing: the workflow hands the default to env.
	run_script "$work/$lane-validate.sh" "$var=$want_default"
	if [ "$got" -eq 0 ]; then ok "$lane: default $want_default passes the guard"; else bad "$lane: default $want_default passes the guard"; cat "$work/out"; fi

	run_script "$work/$lane-go.sh" "$var=$want_default"
	if [ "$got" -eq 0 ] && grep -Fxq "$want_pre -timeout $want_default" "$work/log"; then
		ok "$lane: effective command is [$want_pre -timeout $want_default]"
	else
		bad "$lane: effective command is [$want_pre -timeout $want_default]"
		cat "$work/log" "$work/out"
	fi

	run_script "$work/$lane-go.sh" "$var=25m"
	if grep -Fxq "$want_pre -timeout 25m" "$work/log"; then ok "$lane: caller override 25m reaches go test"; else bad "$lane: caller override 25m reaches go test"; fi

	for good in 90s 13m 2h 1s; do
		run_script "$work/$lane-validate.sh" "$var=$good"
		if [ "$got" -eq 0 ]; then ok "$lane: guard accepts [$good]"; else bad "$lane: guard accepts [$good]"; fi
	done
	# shellcheck disable=SC2016 # literal shell metacharacters are the point
	for evil in '' 13 m 1.5m '13 m' ' 13m' '13m ' '-5m' '0s' '0m' '013m' '1d' '1M' '10ms' '1h30m' '13m;id' '13m"' '$(id)' '13m
id' '13m -run X' 'foo'; do
		run_script "$work/$lane-validate.sh" "$var=$evil"
		if [ "$got" -ne 0 ] && grep -Fq "::error::" "$work/out"; then
			ok "$lane: guard rejects [$(printf '%s' "$evil" | tr '\n' '~')] loudly"
		else
			bad "$lane: guard rejects [$(printf '%s' "$evil" | tr '\n' '~')] loudly"
			cat "$work/out"
		fi
	done

	# Guard order: validate runs before setup-go and the go test step.
	order=$(awk -v job="$job" '
		$0 == "  " job ":" { injob = 1; next }
		injob && /^  [a-z-]+:$/ { injob = 0 }
		injob && /^      - / { n++; if (index($0, "name: validate '"$input"'")) v = n; if (index($0, "uses: actions/setup-go")) s = n }
		END { print (v > 0 && s > 0 && v < s) ? "early" : "late" }' "$wf")
	if [ "$order" = early ]; then ok "$lane: guard runs before setup-go"; else bad "$lane: guard runs before setup-go"; fi
done

# Inputs reach the shell only through env: (no template text in a run script).
stray=$(grep -nE 'inputs\.(race-)?test-timeout' "$wf" | grep -vE '^[0-9]+: +(TEST_TIMEOUT|RACE_TEST_TIMEOUT): ' || true)
if [ -z "$stray" ]; then ok "timeout inputs only referenced via env:"; else bad "timeout input interpolated elsewhere:"; echo "$stray"; fi

# Job limits are untouched: the input default must stay under them.
for pair in test:10 race:15; do
	j="${pair%%:*}" m="${pair##*:}"
	if awk -v job="$j" -v m="$m" '
		$0 == "  " job ":" { injob = 1; next }
		injob && /^  [a-z-]+:$/ { injob = 0 }
		injob && $0 == "    timeout-minutes: " m { found = 1 }
		END { exit !found }' "$wf"; then ok "$j job timeout-minutes stays $m"; else bad "$j job timeout-minutes stays $m"; fi
done

# Header comment names both inputs.
for i in test-timeout race-test-timeout; do
	if sed -n '1,25p' "$wf" | grep -qE "^# .*(^|[^a-z-])$i([^a-z-]|$)"; then ok "header comment names $i"; else bad "header comment names $i"; fi
done

echo "timeout inputs proof: $pass PASS, $fail FAIL"
test "$fail" -eq 0
