# macapp Distribution — Operator Setup Runbook

Everything in the release pipeline is **code-complete and committed**. What is
left is the part only the repo owner can do: Apple enrollment, injecting the
signing secrets, and one-time GitHub setup. Once those are in place, publishing
a GitHub Release lights up all three distribution channels automatically.

- **Plan / phase status**: `docs/superpowers/plans/2026-06-29-macapp-distribution-and-onboarding.md`
- **Pipeline**: `.github/workflows/release.yml` (channels ① DMG, ② Release, ③ Homebrew)
- **Local Phase 2 entry point**: `macapp/scripts/sign-and-notarize.sh`

The whole chain hinges on **notarization** — an un-notarized `.app` is blocked
by Gatekeeper on every channel. That is why Part A is a hard blocker.

---

## Part A — Apple Developer (Phase 0, ~$99/yr, human-only)

1. **Enroll** in the Apple Developer Program (https://developer.apple.com/programs/).
2. **Create a "Developer ID Application" certificate**
   (developer.apple.com → Certificates → +). Download and double-click it to
   import into your login Keychain.
   - Note the identity string. Find it with:
     ```
     security find-identity -v -p codesigning
     ```
     It looks like `Developer ID Application: Your Name (TEAMID)`. The
     10-char `TEAMID` is your Team ID.
3. **Export the certificate + private key as a `.p12`** (Keychain Access →
   right-click the "Developer ID Application" identity → Export → .p12). Set a
   password when prompted — that becomes `DEVELOPER_ID_P12_PASSWORD`.
4. **Create a notary API key** (App Store Connect → Users and Access →
   Integrations → App Store Connect API → **Team Keys** → generate a key with
   the **Developer** role). Download the `AuthKey_XXXXXXXXXX.p8` **once** (you
   cannot re-download it). Record:
   - **Key ID** (the `XXXXXXXXXX` in the filename) → `NOTARY_KEY_ID`
   - **Issuer ID** (UUID shown at the top of the Keys page) → `NOTARY_ISSUER_ID`

**Deliverables from Part A**: `Developer ID Application: … (TEAMID)` string,
the `.p12` + its password, the `AuthKey_*.p8` + Key ID + Issuer ID.

---

## Part B — GitHub secrets (8)

Set them on this repo. `gh secret set NAME` reads the value from stdin, so no
secret is ever echoed on the command line or stored in shell history.

| Secret | Value |
|---|---|
| `DEVELOPER_ID_APP` | the identity string, e.g. `Developer ID Application: Your Name (TEAMID)` |
| `DEVELOPER_ID_P12` | **base64** of the exported `.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | the password you set when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | any random string (temp CI keychain password) |
| `NOTARY_KEY_P8` | **base64** of `AuthKey_*.p8` |
| `NOTARY_KEY_ID` | the key id |
| `NOTARY_ISSUER_ID` | the issuer uuid |
| `HOMEBREW_TAP_TOKEN` | a PAT that can push to the tap repo (Part C) |

```sh
# text secrets (typed/pasted at the prompt, then Ctrl-D):
gh secret set DEVELOPER_ID_APP
gh secret set DEVELOPER_ID_P12_PASSWORD
gh secret set NOTARY_KEY_ID
gh secret set NOTARY_ISSUER_ID
gh secret set KEYCHAIN_PASSWORD --body "$(uuidgen)"

# binary secrets (base64 piped straight from the file):
base64 -i /path/to/DeveloperID.p12        | gh secret set DEVELOPER_ID_P12
base64 -i /path/to/AuthKey_XXXXXXXXXX.p8  | gh secret set NOTARY_KEY_P8
```

`HOMEBREW_TAP_TOKEN`: create a fine-grained PAT scoped to the `homebrew-tap`
repo with **Contents: Read and write**, then
`gh secret set HOMEBREW_TAP_TOKEN`.

Sanity check afterwards: `gh secret list` should show all 8.

---

## Part C — one-time repo setup

1. **Create the Homebrew tap repo** (channel ③):
   ```sh
   gh repo create sohei56/homebrew-tap --public \
     --description "Homebrew tap for ScrumTeam.app"
   ```
   `bump-tap.sh` creates `Casks/scrum-team.rb` on the first Release; the repo
   can start empty. (Override the target with `TAP_REPO=owner/repo` if you rename it.)

2. **Enable GitHub Pages** for the landing page (channel ⓪, already deployed by
   `.github/workflows/pages.yml` on push to `main` touching `site/**`):
   repo **Settings → Pages → Build and deployment → Source: GitHub Actions**.

---

## Part D — local Phase 2 verification (do this before trusting CI)

Once the certificate is in your Keychain, verify the full sign→notarize→staple
loop on your own machine — this is the real Phase 2 gate.

```sh
# One-time: store the notary key as a keychain profile for notarytool.
xcrun notarytool store-credentials scrum-notary \
  --key /path/to/AuthKey_XXXXXXXXXX.p8 \
  --key-id  XXXXXXXXXX \
  --issuer  <issuer-uuid>

# Build a signed release, then notarize+staple the app AND the dmg:
export DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)"
sh macapp/scripts/make-app.sh release
NOTARY_PROFILE=scrum-notary sh macapp/scripts/sign-and-notarize.sh all
```

`sign-and-notarize.sh all` notarizes the `.app`, rebuilds the DMG from the
stapled app, notarizes the DMG, and runs `spctl`/`stapler validate` on both.
Expect `spctl` to print **"accepted … source=Notarized Developer ID"**.

**Clean-environment check** (the honest test): copy the `.dmg` to a *different*
Mac (or a fresh user account), download it through a browser so it carries the
`com.apple.quarantine` xattr, mount, drag to Applications, and launch. It must
open with **no Gatekeeper warning**. Test on both Apple Silicon and Intel.

---

## Part E — shipping a release

Publishing a GitHub Release is the single trigger (a bare `git push --tags`
does **not** fire the pipeline):

```sh
gh release create v1.4.3 --title "v1.4.3" --notes "…"
```

`release.yml` then: builds universal2 → notarizes+staples the app → packages +
signs + notarizes+staples the DMG → uploads `ScrumTeam-1.4.3.dmg` + `.sha256`
to the Release (channels ①②) → renders and pushes the cask to the tap
(channel ③). End users install via any of:

- **① Direct**: download the `.dmg` from the Release page.
- **② Release**: same asset, linked from the landing page / README.
- **③ Homebrew**: `brew tap sohei56/homebrew-tap && brew install --cask scrum-team`.

Until the secrets exist, the pipeline still runs and produces an **unsigned**
dmg (useful for testing; Gatekeeper warns end users) — signing/notarization and
the tap bump activate automatically the moment their secrets are present.

---

## Residual verification (not yet done)

- `release.yml` has **never been executed on GitHub Actions** — first real run
  is the true integration test. `actionlint` was not available locally to
  statically check it.
- The bundled framework launching the SM pane from the extracted copy was
  confirmed to *extract*, but the SM pane starting from it was not visually
  observed.
