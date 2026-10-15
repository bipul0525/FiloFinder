# Launch kit (for the maintainer)

## GitHub repo settings
- **Name:** FiloFinder
- **Description:** Fast, free, open-source Finder alternative for macOS — cut & paste, split view, tabs, folder tree. Native Swift + Rust.
- **Website:** https://github.com/bipul0525/FiloFinder/releases/latest
- **Topics:** finder-alternative, finder-replacement, file-manager, file-explorer, macos, mac, macos-app, dual-pane, swift, appkit, rust, open-source
- **Social preview:** Settings → General → Social preview → upload `docs/social-preview.png`
- Enable **Issues** and **Discussions**; disable Wiki and Projects.

## First release
1. `scripts/release.sh` → upload the 4 files in `build/release/v0.1.0/` to a GitHub Release tagged `v0.1.0`.
2. Homebrew: create repo `bipul0525/homebrew-tap`, copy `packaging/homebrew/filofinder.rb` to `Casks/filofinder.rb`, put the DMG hash from `SHA256SUMS` in `sha256`.

## Where to post
- **Reddit r/macapps** — title: *I built a free, open-source Finder alternative with real Cut & Paste and split view*
- **Hacker News** — *Show HN: FiloFinder – a fast open-source Finder alternative (Swift + Rust)*
- **Product Hunt** — tagline: *The fast, free Finder alternative for Mac*
- PRs to lists: [serhii-londar/open-source-mac-os-apps](https://github.com/serhii-londar/open-source-mac-os-apps), [jaywcjlove/awesome-mac](https://github.com/jaywcjlove/awesome-mac), [iCHAIT/awesome-macOS](https://github.com/iCHAIT/awesome-macOS) (section: File Management)

### Short post text
> FiloFinder is a free, open-source file manager for macOS: real ⌘X/⌘V cut & paste, split view, tabs, an expandable folder tree with image previews, Quick Look, tags and clean ZIP extraction. Native AppKit + a Rust core — lists 100k-file folders in ~0.1 s. One-line install, no account, no telemetry.
