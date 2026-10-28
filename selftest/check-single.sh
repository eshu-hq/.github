#!/bin/sh
# Shape proof for go-collector-ci v2: every v2 contract point asserted by
# grep, so a regression turns this script (and the selftest lane) red.
# Run: bash selftest/check-single.sh (from the repo root).
set -eu
wf=".github/workflows/go-collector-ci.yml"
pass=0
fail=0
check() { # $1 = description, $2... = grep -E pattern (must match)
	desc="$1"; shift
	if grep -Eq "$@" "$wf"; then
		echo "PASS: $desc"
		pass=$((pass + 1))
	else
		echo "FAIL: $desc"
		fail=$((fail + 1))
	fi
}
check_absent() { # $1 = description, $2... = grep -E pattern (must NOT match)
	desc="$1"; shift
	if grep -Eq "$@" "$wf"; then
		echo "FAIL: $desc"
		fail=$((fail + 1))
	else
		echo "PASS: $desc"
		pass=$((pass + 1))
	fi
}

# v2 path-gating inputs.
check "run-govulncheck input" "^      run-govulncheck:"
check "run-gosec input" "^      run-gosec:"
check "run-actionlint input" "^      run-actionlint:"
check "run-boundary input" "^      run-boundary:"
check "boundary-command input" "^      boundary-command:"
check "image-tag input" "^      image-tag:"
check "image-context input" "^      image-context:"
check "image-command input" "^      image-command:"
check "gosec-fail-on-findings input" "^      gosec-fail-on-findings:"
check "go-version-file input" "^      go-version-file:"
check_absent "go-version input removed" "^      go-version:"
check "golangci-lint-version input" "^      golangci-lint-version:"
check "govulncheck-version input" "^      govulncheck-version:"
check "gosec-version input" "^      gosec-version:"
check "actionlint-version input" "^      actionlint-version:"
check "actionlint-sha256 input" "^      actionlint-sha256:"

# No floating installs.
check_absent "no @latest installs" "@latest"

# govulncheck: pinned install, package scan.
check "govulncheck pinned install" 'go install golang.org/x/vuln/cmd/govulncheck@\$\{\{ inputs.govulncheck-version \}\}'
check "govulncheck package scan" 'govulncheck -scan package \./\.\.\.'

# gosec: pinned install, never blocking, artifact upload, no Security-tab upload.
check "gosec pinned install" 'go install github.com/securego/gosec/v2/cmd/gosec@\$\{\{ inputs.gosec-version \}\}'
check "gosec never blocks the lane" '\|\| true'
check "gosec artifact upload" 'name: gosec-'
check_absent "no codeql SARIF upload" 'codeql-action/upload-sarif'

# boundary + actionlint lanes exist and gate.
check "boundary job" '^  boundary:'
check "boundary hook gate" "inputs.boundary-command != ''"
check "actionlint job" '^  actionlint:'
check "actionlint sha256 gate" 'sha256sum -c'

# image hooks.
check "image tag plumbing" 'inputs.image-tag'
check "image context plumbing" 'inputs.image-context'
check "image command hook" 'inputs.image-command'

# Timeout parity: lint 15, image 15, gosec 30.
check "lint timeout 15" 'timeout-minutes: 15'
check "image timeout 15" 'timeout-minutes: 15'
check "gosec timeout 30" 'timeout-minutes: 30'

# v7 action pins throughout; old pins gone.
check "checkout v7 pin" 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'
check "setup-go v7 pin" 'actions/setup-go@b7ad1dad31e06c5925ef5d2fc7ad053ef454303e'
check "upload-artifact v7 pin" 'actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9'
check "shellcheck 2.0.0 pin" 'action-shellcheck@00cae500b08a931fb5698e11e79bfbd38e612a38'
check_absent "old checkout pin gone" 'actions/checkout@11d5960a326750d5838078e36cf38b85af677262'
check_absent "old setup-go pin gone" 'actions/setup-go@40f1582b2485089dde7abd97c1529aa768e1baff'
check_absent "old upload-artifact pin gone" 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02'
check_absent "old shellcheck pin gone" 'action-shellcheck@00b27aa7cb85167568cb48a3838b75f4265f2bca'

# ci-complete covers the new lanes.
check "ci-complete needs boundary" 'boundary, govulncheck, gosec, actionlint'

echo "single shape proof: $pass PASS, $fail FAIL"
test "$fail" -eq 0
