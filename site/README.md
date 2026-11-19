# The website

[agneta.dahlbom.io](https://agneta.dahlbom.io): a static site built from this repository, with no dependencies beyond Python 3's standard library.

## What's generated, and from where

| On the site | Comes from |
| --- | --- |
| Developer guide | README.md, its "For app developers" section |
| App protocol, Diagnostics, Architecture, Engines, Containment, Privacy and threat model, Accounts and terms | The files of the same name in `docs/` |
| Changelog | CHANGELOG.md |
| The documentation index | README.md's Documentation table |
| On the start page: How it works, Providers and engines, What it is not, the status note, the pairing example | The README sections of those names |
| The install steps | packaging/release-page.md |
| The install page, `/get/`, which apps open to help their users get Agneta: both downloads, the steps, Homebrew and **Open Agneta** | `src/get.html`, with the install steps and the latest release's DMGs as above. An app may add the Mac's architecture as the fragment (`#arm64`, `#x86_64`) to put that download first |
| The version, its date and each DMG's link and size | The latest published release, read from GitHub when the site is built |
| Screenshots | docs/images/ and examples/project-chat/preview.png; on the start page they sit on a copy of the showcase backdrop they were captured over (Sources/Agneta/Snapshots.swift) |

The start page's own prose is in `src/index.html`; everything it says is taken from the README and docs/PRIVACY.md, so change it when they change. The rest of `src/` is the layout, the stylesheet, a small script (the screenshots' light and dark switch, copy buttons, the current section in a page's contents) and the icons, made from packaging/AppIcon.png by `site/icons` (run it after the app icon changes, then `site/social/render` for the social preview).

**`/get/` is a promise.** Apps send their users to `https://agneta.dahlbom.io/get/` ([APP_PROTOCOL.md](../docs/APP_PROTOCOL.md#getting-agneta)), so the address stays, and the build fails without it. Like every page, it loads nothing from elsewhere and the script reads nothing of its address but the fragment (no query string, no referrer) and sends nothing: the build fails otherwise. The start page's and the header's Download buttons go there too.

Links between documents become links between pages, and links to anything else go to the file on GitHub. The build fails on a link to a file or heading that doesn't exist, and on Markdown it doesn't render (raw HTML, images), so it can't publish something broken.

## Build and look at it

```bash
python3 site/build.py                                     # into site/_build, linking the releases list
gh api repos/olofd/agneta/releases/latest > /tmp/release.json
python3 site/build.py --release /tmp/release.json         # as published: the version and direct DMG links
python3 -m http.server 8642 --bind 127.0.0.1 --directory site/_build
```

Then open http://127.0.0.1:8642. Pages are served at `/<path>/`, as on GitHub Pages; http://127.0.0.1:8642/get/#x86_64 shows the install page as an app on an Intel Mac opens it.

## Publishing

`.github/workflows/pages.yml` builds the site and publishes it with GitHub Pages:

- on a push to `main` that changes the site, `docs/`, the README, the changelog, the release page text or the screenshots;
- after each run of "Homebrew and update feeds", which a published release starts, so the download links follow the release;
- by hand: **Actions → Website → Run workflow**.

It runs from `main` only, which the `github-pages` environment requires.

## The demo video

Put a short recording at `docs/images/demo.mp4` (H.264, muted, about 20 seconds: an app pairs, its task runs in the panel, Stop ends it), and optionally its first frame at `docs/images/demo-poster.png`. The build then shows it above the screenshots, with controls and without autoplay. Until it exists, the screenshots stand alone. The README has a marked spot for the same video, uploaded through GitHub's editor.

## The social preview

`docs/images/social-preview.png` (1280 × 640) is the image GitHub shows when the repository is shared, and the site's `og:image`. It's `social/social-preview.html` rendered with the Google Chrome on your Mac:

```bash
site/social/render
```

Then upload it in the repository's **Settings → General → Social preview**; GitHub doesn't read it from the repository.
