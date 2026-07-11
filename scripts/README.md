# Build scripts

Bash scripts (run in git-bash, which ships with depot_tools). Every script sources `config.env` — the
single source of truth for the pinned Chromium tag + checkout paths. Override any value via env, e.g.
`CHROMIUM_TAG=151.0.xxxx.yy scripts/build.sh`.

| Script | Does |
|---|---|
| `config.env` | Pinned `CHROMIUM_TAG`, `CHROMIUM_SRC`, `DEPOT_TOOLS`, `OUT_DIR`. Bump the tag here on rebase. |
| `fetch.sh` | Provision / sync a pristine Chromium checkout to `$CHROMIUM_TAG` (`fetch` if absent, else `gclient sync` + runhooks). |
| `brand.sh` | Copy `branding/BRANDING` over `chrome/app/theme/chromium/BRANDING` (product strings). Icons/UA are TODO. |
| `build.sh` | `git am patches/*` onto the tag → `brand.sh` → write `args.official.gn` + `gn gen` → `autoninja chrome` in a box-kill retry loop. First official static build is multi-hour. |
| `package.sh` | Stage the runnable browser tree into `dist/DisplayXR-Browser/` (what the P2 installer packs). |
| `sign.sh` | EV-sign the staged tree via the signing provider (`$DXR_SIGN_REPO`, folder-sign path). Degrades to unsigned + warn if unreachable. |
| `release.sh` | `gh release create` a signed installer as a preview GitHub Release (`../docs/release-and-distribution.md`). |
| `remote-build.sh` | Dispatch the `build-browser` workflow on the remote build box (`$DXR_SIGN_REPO`) + download the tree — frees this machine (`../docs/remote-build.md`). |
| `args.official.gn` | The official static build args `build.sh` writes into `out/$OUT_DIR/args.gn`. |

Typical flow: `fetch.sh` → `build.sh` → verify the weave (see `../docs/rebase-runbook.md` §6) →
`package.sh` → `sign.sh`. Full rebase procedure: `../docs/rebase-runbook.md`.
