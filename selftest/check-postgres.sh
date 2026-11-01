#!/usr/bin/env bash
# Behavior proof for the opt-in Postgres bootstrap in go-collector-ci.yml.
# Extracts the real step script from both the test and race jobs and runs it
# against a stub `docker`, so validation, command shape, and failure paths are
# exercised without a daemon. Live proof is selftest-postgres-caller.yml.
# Run: bash selftest/check-postgres.sh (from the repo root).
set -euo pipefail

wf=".github/workflows/go-collector-ci.yml"
step="postgres bootstrap (opt-in)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0
fail=0

ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# extract JOB: print the run script of the bootstrap step inside JOB.
extract() {
	awk -v job="$1" -v step="$step" '
		$0 == "  " job ":" { injob = 1; next }
		injob && /^  [a-z-]+:$/ { injob = 0 }
		injob && index($0, "- name: " step) { instep = 1; next }
		instep && /^        run: \|$/ { inrun = 1; next }
		inrun && /^          / { sub(/^          /, ""); print; next }
		inrun && /^$/ { print ""; next }
		inrun { exit }
	' "$wf"
}

# Stub docker: records every call; `exec ... pg_isready` obeys STUB_READY.
mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >>"$STUB_LOG"
case "$*" in
*pg_isready*) [ "${STUB_READY:-1}" = 1 ] ;;
*) exit 0 ;;
esac
EOF
chmod +x "$work/bin/docker"

# run_case NAME EXPECT_EXIT SCRIPT [VAR=value ...]
run_case() {
	local name="$1" want="$2" script="$3" got=0
	shift 3
	: >"$work/log"
	env -i PATH="$work/bin:/usr/bin:/bin" STUB_LOG="$work/log" PG_READY_TIMEOUT=2 "$@" \
		bash "$script" >"$work/out" 2>&1 || got=$?
	if [ "$want" = zero ] && [ "$got" -eq 0 ]; then ok "$name"; return; fi
	if [ "$want" = nonzero ] && [ "$got" -ne 0 ]; then ok "$name"; return; fi
	bad "$name (exit $got)"
	cat "$work/out"
}

for job in test race; do
	script="$work/$job.sh"
	extract "$job" >"$script"
	if [ ! -s "$script" ]; then
		bad "$job job carries a '$step' step"
		continue
	fi
	ok "$job job carries a '$step' step"

	run_case "$job: happy path creates every extra database" zero "$script" \
		PG_IMAGE=postgres:18 PG_USER=u PG_DB=d POSTGRES_PASSWORD=p PG_EXTRA_DBS="a_one, b2 ,,_c"
	for db in a_one b2 _c; do
		if grep -Eq "CREATE DATABASE \"$db\"" "$work/log"; then ok "$job: CREATE DATABASE $db"; else bad "$job: CREATE DATABASE $db"; fi
	done
	if grep -Eq '^docker run -d --name ci-postgres -p 5432:5432 ' "$work/log"; then ok "$job: docker run shape"; else bad "$job: docker run shape"; fi

	run_case "$job: no extra databases is fine" zero "$script" \
		PG_IMAGE=postgres:18 PG_USER=u PG_DB=d POSTGRES_PASSWORD=p PG_EXTRA_DBS=
	run_case "$job: user defaults and db defaults to user" zero "$script" \
		PG_IMAGE=postgres:18 PG_USER= PG_DB= POSTGRES_PASSWORD=p PG_EXTRA_DBS=

	for evil in 'x;DROP DATABASE d' 'a"b' '1abc' 'a-b' "a'b" 'a b'; do
		run_case "$job: rejects database name [$evil]" nonzero "$script" \
			PG_IMAGE=postgres:18 PG_USER=u PG_DB=d POSTGRES_PASSWORD=p "PG_EXTRA_DBS=ok,$evil"
		if grep -Eq '^docker run' "$work/log"; then bad "$job: [$evil] rejected before docker run"; else ok "$job: [$evil] rejected before docker run"; fi
	done
	run_case "$job: rejects bad user" nonzero "$script" \
		PG_IMAGE=postgres:18 'PG_USER=u;x' PG_DB=d POSTGRES_PASSWORD=p PG_EXTRA_DBS=
	run_case "$job: rejects bad db" nonzero "$script" \
		PG_IMAGE=postgres:18 PG_USER=u 'PG_DB=d d' POSTGRES_PASSWORD=p PG_EXTRA_DBS=
	run_case "$job: requires a password" nonzero "$script" \
		PG_IMAGE=postgres:18 PG_USER=u PG_DB=d POSTGRES_PASSWORD= PG_EXTRA_DBS=

	run_case "$job: never-ready server fails the step and dumps logs" nonzero "$script" \
		PG_IMAGE=postgres:18 PG_USER=u PG_DB=d POSTGRES_PASSWORD=p PG_EXTRA_DBS=a STUB_READY=0
	if grep -Eq '^docker logs ci-postgres' "$work/log"; then ok "$job: logs dumped on timeout"; else bad "$job: logs dumped on timeout"; fi
done

if cmp -s "$work/test.sh" "$work/race.sh"; then ok "test and race bootstrap scripts identical"; else bad "test and race bootstrap scripts identical"; fi

echo "postgres bootstrap proof: $pass PASS, $fail FAIL"
test "$fail" -eq 0
