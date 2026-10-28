# eshu-hq/.github

Shared reusable Go CI for Eshu collectors and `eshu-sdk` (versioned, pinned).

- Reusable lanes: `.github/workflows/go-collector-ci.yml` (`workflow_call`).
- Org lint config: `.golangci.yml` (golangci-lint v2.12.2; govet,
  staticcheck — subsumes gosimple in v2 — ineffassign, unused, errcheck;
  formatter gofumpt).
- Stable job names (frozen): `lint`, `test`, `race`, `shell`, `image`,
  `boundary`, `govulncheck`, `gosec`, `actionlint`, `ci-complete`.
  Only `ci-complete` is required.
- Rules: whole-repo lint to zero, no baselines; one exclusion = one reason +
  one linked issue; `COVERAGE_FLOOR` only rises; 500-line cap via `wc -l`.

Caller (each collector `ci.yml`): paths-filter `changes` job, then

```yaml
jobs:
  go-ci:
    uses: eshu-hq/.github/.github/workflows/go-collector-ci.yml@<peeled-SHA> # v2
    with:
      coverage-floor: 90.5
      go-version-file: go.mod
      run-image: true
      image-tag: my-collector:ci
```

v2 inputs over v1: `go-version-file` (replaces the `go-version`
default); `run-govulncheck`, `run-gosec`, `run-actionlint`,
`run-boundary` path gates; `boundary-command` hook (empty skips);
`image-tag`, `image-context`, `image-command` hooks;
`gosec-fail-on-findings` (scheduled runs only); exact tool pins
(`golangci-lint-version`, `govulncheck-version`, `gosec-version`,
`actionlint-version` + `actionlint-sha256`). Callers pin the peeled
commit SHA with a version comment, never the mutable tag.

SDK callers pass `working-directory` per module (`collector`, `factschema`).

- Multi-module matrix entrypoint:
  `.github/workflows/go-multi-module-ci.yml` (`workflow_call`, tag `v2`).
  One call gates N modules with per-module `lint`/`test`/`race` matrix lanes
  plus `generate-check`, `shell`, `govulncheck`, `gosec`, `consumer-compat`,
  `actionlint`, and skip-aware `ci-complete`. Reference semantics: the SDK
  inline `ci.yml` (path-filter skip behavior, `GOWORK=off`, per-module
  `go-version-file` setup, org tool pins). Repo-specific hooks:
  `generate-check-command`, `consumer-compat-command` + `satellite-ref`,
  `tidy-check-command`, `file-cap-command`, `coverage-floors`.

```yaml
jobs:
  go-ci:
    uses: eshu-hq/.github/.github/workflows/go-multi-module-ci.yml@v2
    with:
      modules: '["collector", "factschema"]'
      coverage-floors: '{"collector": "85.0", "factschema": "48.3"}'
      generate-check-modules: '["factschema"]'
      satellite-repository: eshu-hq/eshu-collector-kubernetes-live
      satellite-ref: 2ec5ade94f2ccee4401e6c7767b1b5bc4347469d
```

- Selftest: `selftest/check-multi-module.sh` seeds the real embedded
  classifier with RED/GREEN file lists (wired as `multimodule-shape` in
  `selftest.yml`); `selftest-multimodule-caller.yml` executes the reusable
  against `selftest/modules/{alpha,beta}` on every PR and push.
