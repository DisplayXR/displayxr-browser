# DisplayXR Browser

**The web, in depth.** A Chromium-based browser for spatial displays. 3D models, movies, photos and
video calls appear right inside the page, with no "Enter VR" button, while every other website works
exactly as it does in Chrome. On a machine without a spatial display it is simply an ordinary browser.

Product page: **[displayxr.org/browser](https://displayxr.org/browser)** ·
Downloads: **[Releases](https://github.com/DisplayXR/displayxr-browser/releases/latest)** ·
Samples: **[displayxr.github.io/displayxr-web](https://displayxr.github.io/displayxr-web/)**

> **Security updates follow Chrome stable.** Every Chrome stable point release is rebuilt and
> published automatically when the browser's own code is untouched upstream, and verified on a
> DisplayXR display first when it is not. Not affiliated with Google; no Google account sign-in or
> sync. Full policy: [`docs/maintenance-policy.md`](docs/maintenance-policy.md).

## What it does

| | Windows | Android | Linux |
|---|:-:|:-:|:-:|
| Pages built with the [`@displayxr/inline3d`](https://www.npmjs.com/package/@displayxr/inline3d) SDK show their 3D in place; the rest of the page stays flat | ✓ | ✓ | ✓ |
| Flat page content (headers, menus, modals) layers correctly over 3D, with no page wiring | ✓ | ✓ | ✓ |
| Existing three.js / PlayCanvas / Spark pages render in 3D with no change to the page (on for popular 3D sites, offered on the rest) | ✓ | | ✓ |
| Right-click an image or video → **Convert to 3D**, in the page (live video needs a display with a conversion module) | ✓ | | |
| The display switches to 3D only while a 3D page is in front | ✓ | | ✓ |

macOS is coming soon. There is no iOS version.

The same pages render as ordinary 2D in every other browser, so a site can ship them to everyone.
The browser ships no Widevine DRM, so commercial streaming services do not play.

## Install

The browser needs the **DisplayXR runtime** and your display's plug-in to show 3D. Without them it runs
as a normal browser.

1. Install DisplayXR from [displayxr.org/download](https://displayxr.org/download) (the bundle installs
   the runtime and the display plug-in).
2. Install the browser from the [latest release](https://github.com/DisplayXR/displayxr-browser/releases/latest):
   - **Windows:** `DisplayXR-Browser-Setup-*.exe`. The installer checks the runtime version and tells
     you if it is too old.
   - **Android:** `DisplayXR-Browser-*-android-arm64.apk`.
   - **Linux (Ubuntu, x64):** `sudo apt install ./displayxr-browser_*_amd64.deb`. It needs
     `displayxr-runtime` installed; the minimum version is in each release's notes. A newer `.deb`
     upgrades in place; there is no apt repository.
3. Open the [live samples](https://displayxr.github.io/displayxr-web/), which are also the browser's
   start page.

## Build for it

Turn any `<canvas>` into a 3D window with the SDK:

```sh
npm install @displayxr/inline3d
```

```js
import { createInline3D } from '@displayxr/inline3d';

const wall = await createInline3D();      // 3D on a spatial display, 2D everywhere else
if (wall.supported) wall.addImage(canvas, 'photo-sbs.png');
```

Models, Gaussian splats, a 3D media player and a drop-in 3D video-call element are a line each.
Guides, API and samples: [`displayxr-web`](https://github.com/DisplayXR/displayxr-web) ·
[displayxr.org/browser#build](https://displayxr.org/browser#build).

## Reporting a bug

Open an [issue](https://github.com/DisplayXR/displayxr-browser/issues): issues are open and read.
Include the browser version (`chrome://version`), your OS, your display, and the page URL. If a 3D
element misbehaves, the browser log is the most useful attachment.

Questions and ideas: [GitHub Discussions](https://github.com/DisplayXR/displayxr-runtime/discussions).

## Where the source lives

**This repo holds releases, issues and the update feed, not source.** The Chromium patch series, build
lanes and release automation live in a private repo. This is the same split the DisplayXR Shell
uses, and it is about contribution economics rather than secrecy: building the fork needs a
multi-hour compile on a dedicated box and a 100+ patch series rebased onto every Chrome stable
release. The open, neutral infrastructure is the
[runtime](https://github.com/DisplayXR/displayxr-runtime), which display makers integrate against
and which takes outside contributions. The SDK and samples are open source too. Rationale:
[`docs/repo-split-plan.md`](docs/repo-split-plan.md).

This repo keeps its name deliberately: the version matrix, the install tooling and existing install
links all resolve assets against `DisplayXR/displayxr-browser`.

## Maintenance & security

A watcher polls for new Chrome stable releases twice daily. Each one is rebased and built
automatically, then one measurement decides what ships: if the files this browser patches and the
files Chrome changed upstream do **not** intersect, the build is tagged, published and promoted to the
update feed with no human in the loop; if they do, it is held until it has been verified on a real
DisplayXR display. Each release's notes state the Chromium version it is built on.

There is no silent auto-update: shipped browsers check the feed at
[`updates.displayxr.org`](https://updates.displayxr.org) (published from `feed/` in this repo), and
the start page offers the newer installer as a download
([#40](https://github.com/DisplayXR/displayxr-browser/issues/40) tracks a real updater). Full policy:
[`docs/maintenance-policy.md`](docs/maintenance-policy.md).

## Layout

```
feed/        the update feed published at updates.displayxr.org (pages.yml also assembles
             /services/ there from draft releases; see the workflow header)
docs/        maintenance policy + the repo-split rationale
```
