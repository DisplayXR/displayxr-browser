# Docs

- **[maintenance-policy.md](maintenance-policy.md)** — the load-bearing decision: monthly-milestone
  rebase cadence + the (mandatory) preview/security disclaimer + version-check-not-auto-update. Mirrors
  §6 of the runtime packaging plan (source of truth).
- **[rebase-runbook.md](rebase-runbook.md)** — the step-by-step monthly rebase: fetch → apply → resolve
  drift → build → **verify weave** → sign → release, with the gotchas.
- **[integration-points.md](integration-points.md)** — the enumerated file set the patch touches
  (grouped by subsystem), so a rebase conflict can only land in a known, documented hook. The reason a
  rebase is mechanical.

Design/rationale for every hook lives in the runtime repo:
[`docs/roadmap/webxr-step-b-design.md`](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/roadmap/webxr-step-b-design.md)
§13 and
[`displayxr-browser-preview.md`](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/roadmap/displayxr-browser-preview.md).
