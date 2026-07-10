# Maintenance & security policy (the load-bearing decision)

DisplayXR Browser is a **developer preview**, not a maintained daily-driver browser. This policy is what
keeps it a bounded demo/reference artifact instead of an open-ended browser-vendor commitment. It
mirrors §6 of the runtime packaging plan
([`displayxr-browser-preview.md`](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/roadmap/displayxr-browser-preview.md)),
which is the source of truth. **Locked.**

## Cadence — pin to Chrome stable, rebase ~monthly
- Track each new Chrome **stable milestone** (~4-week cadence) — **not** tip-of-tree, and **not** every
  mid-cycle security dot-release. The inline-3D patch is small and touches a known file set
  ([integration-points.md](integration-points.md)), so a milestone rebase is mechanical: a monthly
  `fetch → apply patches → resolve drift → build → verify weave → sign → release` pass
  ([rebase-runbook.md](rebase-runbook.md)).
- **Honest caveat (keeps the disclaimer mandatory):** monthly milestone rebases do **not** pick up
  Chrome's out-of-band security patches (shipped every ~1–2 weeks between milestones), so the build is
  always some days-to-weeks behind on security fixes.

## Security posture — the preview disclaimer (non-negotiable)
The download page and first-run state plainly:

> **Developer preview.** Rebased ~monthly onto Chrome stable, but **not** maintained to Chrome's
> mid-cycle security cadence — **don't use it for sensitive browsing**; use your primary browser for
> banking, etc.

It renders the whole web normally and *functionally* could be a daily driver — the preview label is
about the **security/maintenance commitment**, not missing capability. On a non-DisplayXR machine or a
2D monitor the weave silently no-ops and it is an ordinary Chromium browser.

## Updates — lightweight version check, not silent auto-update
On launch, check the GitHub Releases API for a newer preview and surface a "new version available →
download" prompt. **No** silent Omaha-style auto-update (heavier, and a stronger security promise than a
preview should make). A monthly release cadence makes the check meaningful.

## Explicitly out of scope (the treadmill)
Chrome's mid-cycle security cadence, Widevine DRM, Google Sync / Safe Browsing, and silent auto-update.
These are what make "run a browser" a dedicated-team commitment; the monthly-milestone + preview framing
captures the upside (dev adoption, demos, the evidence that drives the hardware + standards narrative)
without it.

## EOL clause
The preview may lag or pause between rebases; it is a showcase, not a supported product. If/when a
Chromium-derived browser (Edge/Brave) or upstream adopts the inline-3D module, this preview's job is done.

## Platform scope
Windows / D3D11 + DirectComposition only — that is where the weave path lives today. macOS (Metal) and
Linux (Vulkan) would each need a weave hook in their Chromium output path; out of scope for the preview.
