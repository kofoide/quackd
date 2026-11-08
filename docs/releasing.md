# Releasing quackd

This is the checklist for the maintainer when publishing a new version.

## 1. Prepare

1. Update `QUACKD_VERSION` in [`bin/quackd`](../bin/quackd). It's the only place the version is set: the app, `make version`, and the release workflow all read it from there.
2. Move the `unreleased` entries in [`CHANGELOG.md`](../CHANGELOG.md) under the new version and today's date.
3. Run `make lint test install-app`, and try the menu app by hand: Start, Stop, Copy Connect Command, and Open Log.
4. Commit: `git commit -am "Release vX.Y.Z"`.

## 2. Tag and publish

```sh
git tag vX.Y.Z
git push origin main vX.Y.Z
```

Pushing the tag runs [`.github/workflows/release.yml`](../.github/workflows/release.yml). It:
- checks that the tag matches `QUACKD_VERSION`
- runs the lint and tests
- builds `quackd`, `Quackd-X.Y.Z.zip` (a universal, ad-hoc-signed app), and `SHA256SUMS`
- publishes them as a GitHub Release, with instructions for opening the unsigned app

## 3. Update the Homebrew tap

The CLI formula lives in a separate repository, **`kofoide/homebrew-tap`**, at `Formula/quackd.rb`. The template is [`packaging/homebrew/quackd.rb`](../packaging/homebrew/quackd.rb).

1. Get the checksum of GitHub's source tarball for the tag:
   ```sh
   curl -sL https://github.com/kofoide/quackd/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256
   ```
2. In the tap repository, update `url` (the version in the tag) and `sha256`, then commit and push.
3. Check it:
   ```sh
   brew update && brew upgrade quackd    # or: brew install kofoide/tap/quackd
   brew test quackd && brew audit --strict kofoide/tap/quackd
   ```

### One-time tap setup

1. Create a public GitHub repository named **`homebrew-tap`** under `kofoide`. Homebrew requires the `homebrew-` prefix.
2. Copy `packaging/homebrew/quackd.rb` to `Formula/quackd.rb` in that repository, and fill in `sha256` as above.
3. Users can now run `brew install kofoide/tap/quackd`.

## Signing and notarization (optional, later)

Release builds are ad-hoc signed, so macOS asks users to click **Open Anyway** the first time. To remove that step:
1. Join the Apple Developer Program, which costs $99 a year.
2. Create a **Developer ID Application** certificate.
3. In the release workflow, sign with `codesign --options runtime --sign "Developer ID Application: …"`.
4. Notarize the zip with `xcrun notarytool submit --wait`, then staple the result with `xcrun stapler staple`.

The certificate and the App Store Connect API key go in GitHub Actions secrets. With a notarized build, you could also offer a Homebrew **cask** for the app.
