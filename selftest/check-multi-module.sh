#!/usr/bin/env bash
# Shape proof for .github/workflows/go-multi-module-ci.yml (eshu-hq/.github#1).
#
# Exercises the REAL classifier embedded in the reusable workflow (extracted
# from the CLASSIFY_EOF heredoc, never a copy) against seeded file lists, and
# asserts the org pins, GOWORK=off, go-version-file setup, lane gates, and the
# skip-aware ci-complete aggregator shape.
#
# Usage: selftest/check-multi-module.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="$REPO_ROOT/.github/workflows/go-multi-module-ci.yml"
failures=0

fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
pass() { printf 'PASS: %s\n' "$*"; }

[ -f "$WF" ] || { fail "reusable workflow missing: $WF"; exit 1; }

# Extract the embedded classifier (heredoc body, dedented) into a temp file.
# (YAML strips the block indent before bash sees the script, so the extractor
# must strip the same 10 spaces or python sees an IndentationError.)
CLASSIFIER="$(mktemp /tmp/mm-classify-XXXXXX.py)"
trap 'rm -f "$CLASSIFIER"' EXIT
sed -n "/<<'CLASSIFY_EOF'/,/^ *CLASSIFY_EOF\$/p" "$WF" | sed '1d;$d' | sed 's/^          //' > "$CLASSIFIER"
[ -s "$CLASSIFIER" ] || { fail "could not extract CLASSIFY_EOF block from $WF"; exit 1; }
python3 -c "import ast; ast.parse(open('$CLASSIFIER').read())" \
  || { fail "extracted classifier is not valid python"; exit 1; }
pass "classifier extracts as valid python"

# Run the classifier with canned env; prints KEY=VALUE lines.
run_case() {
  # $1=event $2=modules-json $3=gen-json $4=changed-files (newline separated)
  GITHUB_EVENT_NAME="$1" MODULES_JSON="$2" GEN_MODULES_JSON="$3" \
    FIXTURE_SUBPATHS="testdata,schema,fixturepack" CHANGED_FILES="$4" \
    python3 "$CLASSIFIER"
}

expect_contains() {
  # $1=case-output $2=key $3=expected-fragment $4=label
  line="$(printf '%s\n' "$1" | grep "^$2=" || true)"
  case "$line" in
    *"$3"*) pass "$4" ;;
    *) fail "$4 (got: $line)" ;;
  esac
}

SDK_MODS='["collector","factschema"]'
SDK_GEN='["factschema"]'

# --- 1. Go change selects lint/test/race/vuln/gosec/compat, not shell/docs. ---
out="$(run_case pull_request "$SDK_MODS" "$SDK_GEN" 'collector/store.go')"
expect_contains "$out" lint '"collector"' "go change selects lint-collector lane"
expect_contains "$out" test '"collector"' "go change selects test-collector lane"
expect_contains "$out" race '"collector"' "go change selects race-collector lane"
expect_contains "$out" vuln '"collector"' "go change selects govulncheck"
expect_contains "$out" sec '"collector"' "go change selects gosec"
expect_contains "$out" consumer_compat true "go change selects consumer-compat"
[ "$(printf '%s\n' "$out" | grep '^lint=')" = 'lint=["collector"]' ] \
  && pass "go change does not leak into factschema lint" \
  || fail "go change leaked: $(printf '%s\n' "$out" | grep '^lint=')"
[ "$(printf '%s\n' "$out" | grep '^shell=')" = 'shell=false' ] \
  && pass "go change does not select shell" \
  || fail "go change selected shell"

# --- 2. Fixture-only change selects test/race/compat/generate, not lint/vuln. ---
out="$(run_case pull_request "$SDK_MODS" "$SDK_GEN" 'factschema/schema/x.json')"
expect_contains "$out" test '"factschema"' "fixture change selects test-factschema"
expect_contains "$out" race '"collector"' "fixture change selects race-collector (cross-module)"
expect_contains "$out" race '"factschema"' "fixture change selects race-factschema"
expect_contains "$out" consumer_compat true "fixture change selects consumer-compat"
expect_contains "$out" generate true "fixture change selects generate-check"
[ "$(printf '%s\n' "$out" | grep '^lint=')" = 'lint=[]' ] \
  && pass "fixture change selects no lint lane" \
  || fail "fixture change selected lint: $(printf '%s\n' "$out" | grep '^lint=')"
[ "$(printf '%s\n' "$out" | grep '^vuln=')" = 'vuln=[]' ] \
  && pass "fixture change does not select govulncheck" \
  || fail "fixture change selected govulncheck"
[ "$(printf '%s\n' "$out" | grep '^sec=')" = 'sec=[]' ] \
  && pass "fixture change does not select gosec" \
  || fail "fixture change selected gosec"

# --- 3. Pure-docs change selects nothing. ---
out="$(run_case pull_request "$SDK_MODS" "$SDK_GEN" 'README.md')"
[ "$(printf '%s\n' "$out" | grep -c '=true')" = "0" ] \
  && [ "$(printf '%s\n' "$out" | grep -c '\["')" = "0" ] \
  && pass "docs change selects no lane" \
  || fail "docs change selected a lane: $out"

# --- 4. Agent-instruction file selects the shared lanes, not shell. ---
out="$(run_case pull_request "$SDK_MODS" "$SDK_GEN" 'collector/AGENTS.md')"
expect_contains "$out" lint '"collector"' "AGENTS.md selects shared lint lanes"
expect_contains "$out" actionlint true "AGENTS.md selects actionlint"
[ "$(printf '%s\n' "$out" | grep '^shell=')" = 'shell=false' ] \
  && pass "AGENTS.md does not select shell" \
  || fail "AGENTS.md selected shell"

# --- 5. Shell script selects shell plus shared lanes. ---
out="$(run_case pull_request "$SDK_MODS" "$SDK_GEN" 'scripts/ci/foo.sh')"
expect_contains "$out" shell true "script change selects shell"
expect_contains "$out" lint '"collector"' "script change selects shared lint lanes"

# --- 6. Unknown path fails closed (every lane). ---
out="$(run_case pull_request "$SDK_MODS" "$SDK_GEN" 'frobnicator/widget.xyz')"
[ "$(printf '%s\n' "$out" | grep '^lint=')" = 'lint=["collector", "factschema"]' ] \
  && pass "unknown path fails closed on lint" \
  || fail "unknown path missed lint: $(printf '%s\n' "$out" | grep '^lint=')"
expect_contains "$out" shell true "unknown path fails closed on shell"

# --- 7. Non-PR events fail closed. ---
out="$(GITHUB_EVENT_NAME=push MODULES_JSON="$SDK_MODS" GEN_MODULES_JSON="$SDK_GEN" \
  FIXTURE_SUBPATHS="testdata,schema,fixturepack" python3 "$CLASSIFIER")"
[ "$(printf '%s\n' "$out" | grep '^test=')" = 'test=["collector", "factschema"]' ] \
  && pass "push runs every test lane" \
  || fail "push missed lanes: $out"

# --- 8. Generic module paths work (selftest fixture layout). ---
MM_MODS='["selftest/modules/alpha", "selftest/modules/beta"]'
out="$(run_case pull_request "$MM_MODS" '[]' 'selftest/modules/alpha/alpha.go')"
[ "$(printf '%s\n' "$out" | grep '^lint=')" = 'lint=["selftest/modules/alpha"]' ] \
  && pass "module-dir path selects its own lint lane" \
  || fail "module-dir classification wrong: $out"

# --- 9. Org pins, hermetic Go, and setup shape. ---
grep -q "golangci-lint-version" "$WF" && grep -q "default: 'v2.12.2'" "$WF" \
  && pass "golangci-lint carries the org pin" \
  || fail "golangci-lint org pin missing"
grep -q "gosec-version" "$WF" && grep -q "default: 'v2.27.1'" "$WF" \
  && pass "gosec carries the org pin" \
  || fail "gosec org pin missing"
grep -q "govulncheck-version" "$WF" && grep -q "default: 'v1.9.0'" "$WF" \
  && pass "govulncheck carries an exact pin (no floating @latest)" \
  || fail "govulncheck exact pin missing"
grep -q 'govulncheck@latest' "$WF" \
  && fail "govulncheck still floats @latest" \
  || pass "govulncheck has no floating @latest"
grep -q "default: '1.7.12'" "$WF" && grep -q 'sha256sum' "$WF" \
  && pass "actionlint carries version + checksum" \
  || fail "actionlint version/checksum missing"
grep -q '8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8' "$WF" \
  && pass "actionlint checksum matches the SDK value" \
  || fail "actionlint checksum diverges from SDK"
[ "$(grep -c 'GOWORK=off' "$WF")" -ge 5 ] \
  && pass "GOWORK=off is set across go steps" \
  || fail "GOWORK=off missing from go steps"
grep -q 'go-version-file' "$WF" \
  && pass "setup-go uses per-module go-version-file" \
  || fail "go-version-file setup missing"

# --- 10. Matrix lanes expand from the changes outputs (dynamic matrix). ---
# (matrix context is illegal in job-level `if:`, so selection lives in the
# matrix itself; actionlint enforces the context rule on every PR.)
for lane in "lint:lint" "test:test" "race:race" "vuln:govulncheck" "sec:gosec"; do
  out="${lane%%:*}"; job="${lane##*:}"
  block="$(awk -v job="^  $job:" '$0 ~ job{injob=1; next} injob && /^  (changes|lint|test|race|generate-check|shell|govulncheck|gosec|consumer-compat|actionlint|ci-complete):/{exit} injob' "$WF")"
  if printf '%s\n' "$block" | grep -q "fromJSON(needs.changes.outputs.$out)"; then
    pass "$job matrix expands from changes.$out"
  else
    fail "$job matrix misses changes.$out lookup"
  fi
done
if grep -q 'if:.*matrix\.module' "$WF"; then
  fail "job-level if references matrix (illegal context)"
else
  pass "no job-level if references matrix"
fi

# --- 11. ci-complete stays skip-aware (v["result"] shape, seeded RED/GREEN). ---
grep -q 'v.get("result")' "$WF" \
  && pass "aggregator compares v[result], not whole job objects" \
  || fail "aggregator lost the v[result] shape"
AGG="$(awk "/<<'EOF'/{flag=1; next} flag && /^ *EOF\$/{flag=0} flag" "$WF" | sed 's/^          //')"
[ -n "$AGG" ] || fail "could not extract aggregator block"
RED_JSON='{"lint":{"result":"failure"},"test":{"result":"success"},"race":{"result":"skipped"}}'
if NEEDS_JSON="$RED_JSON" python3 -c "$AGG" >/dev/null 2>&1; then
  fail "aggregator passed a red payload"
else
  pass "aggregator fails a red payload"
fi
GREEN_JSON='{"lint":{"result":"success"},"test":{"result":"success"},"race":{"result":"skipped"},"shell":{"result":"skipped"}}'
NEEDS_JSON="$GREEN_JSON" python3 -c "$AGG" 2>/dev/null \
  && pass "aggregator passes green-with-skips" \
  || fail "aggregator failed green-with-skips"

if [ "$failures" -gt 0 ]; then
  printf '%d shape assertion(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'multi-module shape proof: all green\n'
