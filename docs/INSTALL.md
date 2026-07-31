# Installing Disker

## Requirements

- **macOS 26 (Tahoe) or later.** Disker uses the Liquid Glass APIs directly and has no
  fallback path on older systems.
- **Apple Silicon.** The release build is `arm64` only.

## Install

1. Download `Disker-1.0.0-macos-arm64.zip` from the
   [latest release](https://github.com/mohammad-malik/disker/releases/latest).
2. Unzip it and drag `Disker.app` to `/Applications`.
3. **The first launch needs an extra step** — see below.

## First launch: "Disker cannot be opened"

The release is ad-hoc signed, not notarised by Apple, so Gatekeeper blocks it the first time.
This is expected for any app distributed outside the App Store without a paid Developer ID.

Either of these clears it:

**From Finder** — right-click (or Control-click) `Disker.app`, choose **Open**, then **Open**
again in the dialog. macOS remembers the choice, so later launches are normal double-clicks.

**From Terminal** — remove the quarantine flag:

```sh
xattr -d com.apple.quarantine /Applications/Disker.app
```

If you would rather not trust a prebuilt binary — a reasonable position for something that
reads your whole disk — [build it yourself](../README.md#building). It takes two commands and
no Apple developer account.

## Full Disk Access

Without it, Disker cannot read protected directories. It does not fail silently: the scan
still runs and the app tells you the total is a lower bound and how many folders it could not
read.

To grant it: **System Settings → Privacy & Security → Full Disk Access**, then add
`Disker.app` and restart the app.

### If you are building from source

macOS keys this permission to code signing identity. A plain `swift build` produces an ad-hoc
signature that changes on every build, so the grant is revoked each time you rebuild. Run this
once:

```sh
./Tools/create-signing-identity.sh
```

It creates a self-signed certificate in your login keychain, and `Tools/bundle.sh` signs with
it from then on, so the grant survives rebuilds. That certificate is local to your machine —
release builds are deliberately signed ad-hoc instead, because a bundle signed with a
certificate nobody else trusts fails validation on other Macs and Finder reports the app as
damaged.

## Mole

Cleanup is handed to [Mole](https://github.com/tw93/mole):

```sh
brew install mole
```

It is optional. Without it, scanning, the sunburst, recommendations, and in-app deletion all
work normally; the Mole panel reports that it is not installed.

## Uninstalling

```sh
rm -rf /Applications/Disker.app
rm -rf ~/Library/Application\ Support/Disker    # cached scans
```

Also remove Disker from the Full Disk Access list in System Settings.
