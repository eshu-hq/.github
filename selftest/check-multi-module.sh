#!/usr/bin/env bash
# Shape proof for .github/workflows/go-multi-module-ci.yml (eshu-hq/.github#1).
#
# Exercises the REAL classifier embedded in the reusable workflow (extracted
# from the CLASSIFY_EOF heredoc, never a copy) against seeded file lists, and
# asserts the org pins, GOWORK=off, go-version-file setup, lane gates, and the
# skip-aware ci-complete aggregator shape.
#
# Uses if/else (no A && B || C chains): the repo shell gate reports SC2015.
#
# Usage: selftest/check-multi-module.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="$REPO_ROOT/.github/workflows/go-multi-module-ci.yml"
failures=0

fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
pass() { printf 'PASS: %s\n' "$*"; }

if [ ! -f "$WF" ]; then
  fail "reusable workflow missing: $WF"
  exit 1
fi

# Extract the embedded classifier (heredoc body, dedented) into a temp file.
# (YAML strips the block indent before bash sees the script, so the extractor
# must strip the same 10 spaces or python sees an IndentationError.)
CLASSIFIER="$(mktemp /tmp/mm-classify-XXXXXX.py)"
trap 'rm -f "$CLASSIFIER"' EXIT
sed -n "/<<'CLASSIFY_EOF'/,/^ *CLASSIFY_EOF\$/p" "$WF" | sed '1d;$d' | sed 's/^          //' > "$CLASSIFIER"
if [ ! -s "$CLASSIFIER" ]; then
  fail "could not extract CLASSIFY_EOF block from $WF"
  exit 1
fi
if python3 -c "import ast; ast.parse(open('$CLASSIFIER').read())"; then
  pass "classifier extracts as valid python"
else
  fail "extracted classifier is not valid python"
  exit 1
fi

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

expect_line() {
  # $1=case-output $2=expected-line $3=label (fixed-string match)
  if printf '%s\n' "$1" | grep -Fxq -- "$2"; then
    pass "$3"
  else
    fail "$3 (got: $(printf '%s\n' "$1" | grep -F -- "${2%%=*}=" || true))"
  fi
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
expect_line "$out" 'lint=["collector"]' "go change does not leak into factschema lint"
expect_line "$out" 'shell=false' "go change does not select shell"

# --- 2. Fixture-only change selects test/race/compat/generate, not lint/vuln. ---
out="$(run_case pull_request "$SDK_MODS" "$SDK_GEN" 'factschema/schema/x.json')"
expect_contains "$out" test '"factschema"' "fixture change selects test-factschema"
expect_contains "$out" race '"collector"' "fixture change selects race-collector (cross-module)"
expect_contains "$out" race '"factschema"' "fixture change selects race-factschema"
expect_contains "$out" consumer_compat true "fixture change selects consumer-compat"
expect_contains "$out" generate true "fixture change selects generate-check"
expect_line "$out" 'lint=[]' "fixture change selects no lint lane"
expect_line "$out" 'vuln=[]' "fixture change does not select govulncheck"
expect_line "$out" 'sec=[]' "fixture change does not select gosec"

# --- 3. Pure-docs change selects nothing. ---
out="$(run_case pull_request "$SDK_MODS" "$SDK_GEN" 'README.md')"
if [ "$(printf '%s\n' "$out" | grep -c '=true' || true)" = "0" ]; then
  if [ "$(printf '%s\n' "$out" | grep -c '\["' || true)" = "0" ]; then
    pass "docs change selects no lane"
  else
    fail "docs change selected a lane: $out"
  fi
else
  fail "docs change selected a lane: $out"
fi

# --- 4. Agent-instruction file selects the shared lanes, not shell. ---
out="$(run_case pull_request "$SDK_MODS" "$SDK_GEN" 'collector/AGENTS.md')"
expect_contains "$out" lint '"collector"' "AGENTS.md selects shared lint lanes"
expect_contains "$out" actionlint true "AGENTS.md selects actionlint"
expect_line "$out" 'shell=false' "AGENTS.md does not select shell"

# --- 5. Shell script selects shell plus shared lanes. ---
out="$(run_case pull_request "$SDK_MODS" "$SDK_GEN" 'scripts/ci/foo.sh')"
expect_contains "$out" shell true "script change selects shared shell"
expect_contains "$out" lint '"collector"' "script change selects shared lint lanes"

# --- 6. Unknown path fails closed (every lane). ---
out="$(run_case pull_request "$SDK_MODS" "$SDK_GEN" 'frobnicator/widget.xyz')"
expect_line "$out" 'lint=["collector", "factschema"]' "unknown path fails closed on lint"
expect_contains "$out" shell true "unknown path fails closed on shell"

# --- 6b. Empty or invalid modules input fails closed, never zero lanes. ---
for badmods in '[]' 'not-json' ''; do
  if GITHUB_EVENT_NAME=pull_request MODULES_JSON="$badmods" GEN_MODULES_JSON="$SDK_GEN" \
    FIXTURE_SUBPATHS="testdata,schema,fixturepack" CHANGED_FILES='collector/store.go' \
    python3 "$CLASSIFIER" >/dev/null 2>&1; then
    fail "modules input '$badmods' should fail closed"
  else
    pass "modules input '$badmods' fails closed"
  fi
done

# --- 6c. Gosec SARIF uses absolute workspace paths (nested modules safe). ---
if grep -q 'GITHUB_WORKSPACE/gosec-' "$WF"; then
  if grep -q 'github.workspace }}/gosec-' "$WF"; then
    pass "gosec scan and upload share absolute workspace paths"
  else
    fail "gosec upload path is not absolute"
  fi
else
  fail "gosec scan path is not absolute"
fi

# --- 7. Non-PR events fail closed. ---
out="$(GITHUB_EVENT_NAME=push MODULES_JSON="$SDK_MODS" GEN_MODULES_JSON="$SDK_GEN" \
  FIXTURE_SUBPATHS="testdata,schema,fixturepack" python3 "$CLASSIFIER")"
expect_line "$out" 'test=["collector", "factschema"]' "push runs every test lane"

# --- 8. Generic module paths work (selftest fixture layout). ---
MM_MODS='["selftest/modules/alpha", "selftest/modules/beta"]'
out="$(run_case pull_request "$MM_MODS" '[]' 'selftest/modules/alpha/alpha.go')"
expect_line "$out" 'lint=["selftest/modules/alpha"]' "module-dir path selects its own lint lane"

# --- 9. Org pins, hermetic Go, and setup shape. ---
if grep -q "golangci-lint-version" "$WF"; then
  if grep -q "default: 'v2.12.2'" "$WF"; then
    pass "golangci-lint carries the org pin"
  else
    fail "golangci-lint org pin missing"
  fi
else
  fail "golangci-lint org pin missing"
fi
if grep -q "gosec-version" "$WF"; then
  if grep -q "default: 'v2.27.1'" "$WF"; then
    pass "gosec carries the org pin"
  else
    fail "gosec org pin missing"
  fi
else
  fail "gosec org pin missing"
fi
if grep -q "govulncheck-version" "$WF"; then
  if grep -q "default: 'v1.9.0'" "$WF"; then
    pass "govulncheck carries an exact pin (no floating @latest)"
  else
    fail "govulncheck exact pin missing"
  fi
else
  fail "govulncheck exact pin missing"
fi
if grep -q 'govulncheck@latest' "$WF"; then
  fail "govulncheck still floats @latest"
else
  pass "govulncheck has no floating @latest"
fi
if grep -q "default: '1.7.12'" "$WF"; then
  if grep -q 'sha256sum' "$WF"; then
    pass "actionlint carries version + checksum"
  else
    fail "actionlint version/checksum missing"
  fi
else
  fail "actionlint version/checksum missing"
fi
if grep -q '8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8' "$WF"; then
  pass "actionlint checksum matches the SDK value"
else
  fail "actionlint checksum diverges from SDK"
fi
if [ "$(grep -c 'GOWORK=off' "$WF")" -ge 5 ]; then
  pass "GOWORK=off is set across go steps"
else
  fail "GOWORK=off missing from go steps"
fi
if grep -q 'go-version-file' "$WF"; then
  pass "setup-go uses per-module go-version-file"
else
  fail "go-version-file setup missing"
fi

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

# --- 11b. Every action pin is 40-hex and recorded-verified (no dead pins). ---
# (guards the .github#3 class: a dead/truncated SHA must fail shape, not CI;
# extend VERIFIED_PINS with the API verification whenever a pin changes.)
VERIFIED_PINS='3d3c42e5aac5ba805825da76410c181273ba90b1
b7ad1dad31e06c5925ef5d2fc7ad053ef454303e
cf430e030ddbb5b0abf93d22962f4752f3646cd9
11d5960a326750d5838078e36cf38b85af677262
40f1582b2485089dde7abd97c1529aa768e1baff
ea165f8d65b6e75b540449e92b4886f43607fa02
9b3254085494b55a0f7c4c2b3d2d52cc712ce370
00b27aa7cb85167568cb48a3838b75f4265f2bca
22fd014b7bfcd88c892bfccea1784cade496cdef'
pin_fail=0
if refs="$(rg -No --no-filename 'uses: [^ ]+' "$REPO_ROOT"/.github/workflows/*.yml | sed 's/^uses: //')"; then
  if [ -z "$refs" ]; then
    fail "pin census: uses-ref extraction found nothing"
  else
    while IFS= read -r ref; do
      case "$ref" in
        '' | [!0-9a-zA-Z./-]*)
          fail "pin census: blank or malformed uses line among $(printf '%s' "$refs" | wc -l) extracted refs"
          pin_fail=1
          continue ;;
        ./*) continue ;; # local workflow ref, always allowed
      esac
      sha="${ref##*@}"
      if [ "${#sha}" -ne 40 ]; then
        fail "action pin is not 40-hex: $ref"
        pin_fail=1
      elif printf '%s' "$sha" | grep -q '[^0-9a-f]'; then
        fail "action pin has non-hex chars: $ref"
        pin_fail=1
      elif printf '%s\n' "$VERIFIED_PINS" | grep -Fxq -- "$sha"; then
        :
      else
        fail "action pin not in the recorded verified set: $ref"
        pin_fail=1
      fi
    done <<EOF
$refs
EOF
  fi
else
  fail "pin census: uses-ref extraction failed"
fi
if [ "$pin_fail" -eq 0 ]; then
  pass "all action pins 40-hex and recorded-verified (local refs allowed)"
fi

# --- 11. ci-complete stays skip-aware (v["result"] shape, seeded RED/GREEN). ---
if grep -q 'v.get("result")' "$WF"; then
  pass "aggregator compares v[result], not whole job objects"
else
  fail "aggregator lost the v[result] shape"
fi
AGG="$(awk "/<<'EOF'/{flag=1; next} flag && /^ *EOF\$/{flag=0} flag" "$WF" | sed 's/^          //')"
if [ -z "$AGG" ]; then
  fail "could not extract aggregator block"
fi
RED_JSON='{"lint":{"result":"failure"},"test":{"result":"success"},"race":{"result":"skipped"}}'
if NEEDS_JSON="$RED_JSON" python3 -c "$AGG" >/dev/null 2>&1; then
  fail "aggregator passed a red payload"
else
  pass "aggregator fails a red payload"
fi
GREEN_JSON='{"lint":{"result":"success"},"test":{"result":"success"},"race":{"result":"skipped"},"shell":{"result":"skipped"}}'
if NEEDS_JSON="$GREEN_JSON" python3 -c "$AGG" >/dev/null 2>&1; then
  pass "aggregator passes green-with-skips"
else
  fail "aggregator failed green-with-skips"
fi

if [ "$failures" -gt 0 ]; then
  printf '%d shape assertion(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'multi-module shape proof: all green\n'
