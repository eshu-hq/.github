#!/usr/bin/env bash
# Behavior proof for the test-timeout and race-test-timeout inputs in
# go-collector-ci.yml (issue #15). Extracts the real validate and go test step
# scripts from the test and race jobs and replays them against a stub `go`,
# so the effective command line and the bad-value guard are exercised without
# a toolchain. Also asserts the shape points that cannot be replayed: inputs
# reach the shell only through env:, the race job limit is 25 minutes and
# matches the race validate step's job_limit_min, and the header comment names
# both inputs. The race validate step also bounds race-test-timeout under the
# job limit (issue #18).
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

# env_of JOB STEP: print the env: mapping lines of STEP inside JOB.
env_of() {
	awk -v job="$1" -v step="$2" '
		$0 == "  " job ":" { injob = 1; next }
		injob && /^  [a-z-]+:$/ { injob = 0; instep = 0; inenv = 0 }
		injob && /^      - / { instep = ($0 == "      - name: " step); inenv = 0; next }
		instep && /^        env:$/ { inenv = 1; next }
		instep && inenv && /^          / { print; next }
		instep && inenv { inenv = 0 }
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
		job=test var=TEST_TIMEOUT input=test-timeout want_default=9m want_override=8m
		gostep="test"
		want_pre="go test ./... -count=1"
	else
		job=race var=RACE_TEST_TIMEOUT input=race-test-timeout want_default=13m want_override=20m
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

	# The step's env: maps the variable to the matching input and nothing else.
	# The scripts above are fed the variable directly, so without this check a
	# swapped input or a constant in env: would pass every replay.
	for step in "$vstep" "$gostep"; do
		got_env="$(env_of "$job" "$step")"
		if [ "$got_env" = "          $var: \${{ inputs.$input }}" ]; then
			ok "$job job step [$step] maps $var from inputs.$input"
		else
			bad "$job job step [$step] maps $var from inputs.$input (env was: ${got_env:-none})"
		fi
	done

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

	run_script "$work/$lane-go.sh" "$var=$want_override"
	if grep -Fxq "$want_pre -timeout $want_override" "$work/log"; then ok "$lane: caller override $want_override reaches go test"; else bad "$lane: caller override $want_override reaches go test"; fi

	# The test lane's validate step is format-only. The race lane's also bounds
	# the value under its job limit: 25m job minus 4m of room is 21m (1260s).
	if [ "$lane" = test ]; then
		goods="90s 9m 13m 2h 1s"
	else
		goods="90s 13m 20m 21m 1260s 1s"
	fi
	for good in $goods; do
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

	if [ "$lane" = race ]; then
		# Over the bound: well-formed values that leave under 4 minutes of the
		# 25 minute job. The last two are past 64-bit range, so they must be
		# rejected on length before any arithmetic can wrap them under the bound.
		for over in 22m 1261s 25m 26m 1500s 1h 2h 1000000s 99999999999999999999s 9999999999999999999h; do
			run_script "$work/$lane-validate.sh" "$var=$over"
			if [ "$got" -ne 0 ] && grep -Fq "::error::race-test-timeout" "$work/out" && grep -Fq "25 minute race job limit" "$work/out" && grep -Fq "largest accepted value is 21m" "$work/out"; then
				ok "$lane: guard rejects [$over] as over the job limit"
			else
				bad "$lane: guard rejects [$over] as over the job limit"
				cat "$work/out"
			fi
		done

		# The limit in the validate step must be the race job's timeout-minutes,
		# or the bound protects a different ceiling than the one that cancels.
		jobmin=$(awk '
			$0 == "  race:" { injob = 1; next }
			injob && /^  [a-z-]+:$/ { injob = 0 }
			injob && /^    timeout-minutes: / { sub(/.*: /, ""); print; exit }' "$wf")
		scriptmin=$(sed -n 's/^job_limit_min=\([0-9][0-9]*\)$/\1/p' "$work/race-validate.sh")
		if [ -n "$jobmin" ] && [ "$jobmin" = "$scriptmin" ]; then
			ok "race validate step job_limit_min ($scriptmin) equals the race job timeout-minutes ($jobmin)"
		else
			bad "race validate step job_limit_min (${scriptmin:-none}) equals the race job timeout-minutes (${jobmin:-none})"
		fi
	fi

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

# Job limits: test stays 10; race is 25 (issue #18) so race-test-timeout can
# reach 21m with 4m of room. Both defaults stay under them.
for pair in test:10 race:25; do
	j="${pair%%:*}" m="${pair##*:}"
	if awk -v job="$j" -v m="$m" '
		$0 == "  " job ":" { injob = 1; next }
		injob && /^  [a-z-]+:$/ { injob = 0 }
		injob && $0 == "    timeout-minutes: " m { found = 1 }
		END { exit !found }' "$wf"; then ok "$j job timeout-minutes stays $m"; else bad "$j job timeout-minutes stays $m"; fi
done

# Header comment names both inputs.
for i in test-timeout race-test-timeout; do
	if sed -n '1,/^name:/p' "$wf" | grep -qE "^# .*(^|[^a-z-])$i([^a-z-]|$)"; then ok "header comment names $i"; else bad "header comment names $i"; fi
done

# Header comment states the race job limit and the 21m bound.
for phrase in 'race lane.s is 25m' 'above 21m' 'job_limit_min'; do
	if sed -n '1,/^name:/p' "$wf" | grep -qE "^# .*$phrase"; then ok "header comment says [$phrase]"; else bad "header comment says [$phrase]"; fi
done

echo "timeout inputs proof: $pass PASS, $fail FAIL"
test "$fail" -eq 0
