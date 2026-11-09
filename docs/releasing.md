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
- updates the Homebrew tap (next section)

Follow it on the repository's **Actions** tab, or with `gh run watch`.

## 3. The Homebrew tap (automatic)

The formula (`Formula/quackd.rb`, the CLI) and the cask (`Casks/quackd-menu.rb`, the app) live only in the separate repository **`kofoide/homebrew-tap`**. After publishing, the release workflow runs [`scripts/update-tap.sh`](../scripts/update-tap.sh), which sets the new version and both checksums, then commits `quackd X.Y.Z` to the tap and pushes. You don't edit anything.

Once the workflow finishes, check it:
```sh
brew update
brew upgrade quackd && brew upgrade --cask quackd-menu
quackd version
```

### If the tap step fails or was skipped
The release itself is already published. Look at the **Update Homebrew tap** step in the run's log. Usually the token has expired; see below. To update the tap by hand instead:
```sh
cd ~/projects/homebrew-tap && git pull
~/projects/quack/scripts/update-tap.sh . X.Y.Z
git diff                                  # check the version and two sha256 lines
git commit -am "quackd X.Y.Z" && git push
```

### The token
The workflow pushes to the tap with the repository secret **`HOMEBREW_TAP_TOKEN`**. The workflow's built-in token can only write to `quackd` itself.
- **What it is:** a fine-grained personal access token from GitHub → Settings → Developer settings → Fine-grained tokens. It has access to **only `homebrew-tap`**, with **Contents: Read and write**.
- **Where it goes:** `quackd` → Settings → Secrets and variables → Actions → **`HOMEBREW_TAP_TOKEN`**.
- **Renewing it:** fine-grained tokens expire, a year at most. When it does, the step fails with an authentication error. Generate a new token, replace the secret's value, and update the tap by hand for that release.

If the secret isn't set at all, the step is skipped with a warning.

### Setting up a tap from scratch
1. Create a public GitHub repository named **`homebrew-tap`** under `kofoide`. Homebrew requires the `homebrew-` prefix.
2. Add `Formula/quackd.rb` and `Casks/quackd-menu.rb`. Copy them from the current tap, since that's the only copy.
3. Create the token and secret as above.

## Signing and notarization (optional, later)

Release builds are ad-hoc signed, so macOS asks users to click **Open Anyway** the first time. To remove that step:
1. Join the Apple Developer Program, which costs $99 a year.
2. Create a **Developer ID Application** certificate.
3. In the release workflow, sign with `codesign --options runtime --sign "Developer ID Application: …"`.
4. Notarize the zip with `xcrun notarytool submit --wait`, then staple the result with `xcrun stapler staple`.

The certificate and the App Store Connect API key go in GitHub Actions secrets. With a notarized build, the `quackd-menu` cask could drop its **Open Anyway** caveat.
