# Maintenance & security policy

This is the public statement of what the DisplayXR Browser promises and what it does not. The
release notes link here, and so do the download page and the packaging plan
([`displayxr-browser-preview.md`](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/roadmap/displayxr-browser-preview.md)
in the runtime repo, which carries the design history behind these decisions).

## What it is

A Chromium-based browser that renders the whole web normally **and** weaves glasses-free inline-3D
for [`inline-3d` WebXR](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/roadmap/webxr-displayxr-explainer.md)
pages on DisplayXR hardware. The only delta from upstream Chromium is that inline-3D surface — the
session mode, `XRDisplayLayer` bound to a DOM element, and the GPU-resident weave path. On a machine
with no DisplayXR display, or on a 2D monitor, the weave silently no-ops and it is an ordinary
Chromium browser.

## Release channel

- Releases are tagged **`vX.Y.Z`** (from `v1.0.0`; builds up to `preview-0.1.35` used
  `preview-X.Y.Z`) and published as ordinary GitHub Releases on
  [`DisplayXR/displayxr-browser`](https://github.com/DisplayXR/displayxr-browser/releases), with the
  newest marked **Latest** — so `/releases/latest` always resolves to the current build.
- The same release is announced in the update feed published from `feed/` at
  [`updates.displayxr.org/feed.json`](https://updates.displayxr.org), on channel **`stable`**. The
  feed carries the version, the Chromium pin it was built from, the installer URL, its SHA-256 and
  size, and whether the release was driven by a security fix.
- Windows installers are signed; Android APKs are release-signed (every build since 0.1.25).

## Security cadence — Chrome stable, automatic where it is safe to be

Security updates follow **Chrome stable**. A watcher polls for new Chrome stable releases twice
daily; when one appears, the build pipeline rebases the patch series onto it and builds **both**
lanes (Windows and Android arm64) unprompted. What happens to the result depends on one measurement,
the **weave gate**:

| Gate | Meaning | What ships |
|---|---|---|
| **PASS** | The files this browser patches and the files Chrome changed upstream do not intersect — the weave code is untouched by this Chrome release. | Tagged, published and promoted to the feed **automatically**, with no human in the loop. |
| **HOLD** | The two sets intersect: Chrome changed something the weave sits on top of. | Held until the build has been **verified on a real DisplayXR display**, then published by hand. |

So: every Chrome stable point release is rebuilt and published automatically when the browser's own
code is untouched upstream, and verified on a DisplayXR display first when it is not. The gate is a
measurement, not a judgement call — which is what makes the automatic half of it trustworthy.

A build is only as current as the Chromium pin it was built from; the feed publishes that pin so you
can check it against Chrome's own release notes.

## Updates — the start page offers the download; nothing installs itself

There is **no silent auto-update**. The browser's default start page compares the running build
against the feed and offers the newer installer as a download; installing it is your action. An
in-browser updater is tracked as
[browser#40](https://github.com/DisplayXR/displayxr-browser/issues/40) and is not shipped.

## What it is not

- **No Google account.** There is no Google sign-in and no Chrome Sync — bookmarks, history,
  passwords and tabs stay on the machine. Nothing is synced to a DisplayXR service either.
- **Not affiliated with, or endorsed by, Google.** It is an independent build of the open-source
  Chromium project with an inline-3D patch series applied.
- **No Widevine DRM.** Streaming services that require it will not play protected video. Ordinary
  media, including the inline-3D samples, plays normally.
- **No Google Safe Browsing** and none of the other Google-proprietary services a Chrome-branded
  build carries.

## Platform scope

**Windows** (D3D11 + DirectComposition) and **Android arm64** — that is where the weave path lives.
macOS (Metal) and desktop Linux (Vulkan) would each need a weave hook in their Chromium output path
and are not in scope today.

## Support & end of life

This browser exists to make the inline-3D web real on DisplayXR hardware; it is not a browser-vendor
product with a support contract behind it. If and when a Chromium-derived browser (Edge, Brave) or
Chromium upstream adopts the inline-3D module, this build's job is done and it will be retired in
favour of that. Bug reports are open and read on
[this repo's issues](https://github.com/DisplayXR/displayxr-browser/issues).
