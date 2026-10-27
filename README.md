# eshu-hq/.github

Shared reusable Go CI for Eshu collectors and `eshu-sdk` (versioned, pinned).

- Reusable lanes: `.github/workflows/go-collector-ci.yml` (`workflow_call`).
- Org lint config: `.golangci.yml` (golangci-lint v2.12.2; govet,
  staticcheck — subsumes gosimple in v2 — ineffassign, unused, errcheck;
  formatter gofumpt).
- Stable job names (frozen): `lint`, `test`, `race`, `shell`, `image`,
  `govulncheck`, `gosec`, `ci-complete`. Only `ci-complete` is required.
- Rules: whole-repo lint to zero, no baselines; one exclusion = one reason +
  one linked issue; `COVERAGE_FLOOR` only rises; 500-line cap via `wc -l`.

Caller (each collector `ci.yml`): paths-filter `changes` job, then

```yaml
jobs:
  go-ci:
    uses: eshu-hq/.github/.github/workflows/go-collector-ci.yml@v1
    with:
      coverage-floor: 66.1
      run-image: true
```

SDK callers pass `working-directory` per module (`collector`, `factschema`).
