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

## Part B — GitHub secrets (9)

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
| `SPARKLE_ED_PRIVATE_KEY` | **optional** — Sparkle EdDSA private key for the in-app auto-update appcast (Part C.3). Absent = releases still ship, appcast is skipped. |

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

Sanity check afterwards: `gh secret list` should show the 8 signing/tap
secrets above, plus `SPARKLE_ED_PRIVATE_KEY` once you complete Part C.3 (9 in
total). The Sparkle key is the only optional one — the other 8 gate
signing/notarization and the tap bump.

---

## Part C — one-time repo setup

1. **Create the Homebrew tap repo** (channel ③):
   ```sh
   gh repo create sohei56/homebrew-tap --public \
     --description "Homebrew tap for MaulTeam.app"
   ```
   `bump-tap.sh` creates `Casks/maul-team.rb` on the first Release; the repo
   can start empty. (Override the target with `TAP_REPO=owner/repo` if you rename it.)

2. **Enable GitHub Pages** for the landing page (channel ⓪, already deployed by
   `.github/workflows/pages.yml` on push to `main` touching `site/**`):
   repo **Settings → Pages → Build and deployment → Source: GitHub Actions**.

3. **Generate the Sparkle EdDSA key pair** (channel ④, in-app auto-update).
   Sparkle signs every appcast entry with an EdDSA private key; the app
   verifies it with the matching **public** key baked into the bundle. Do this
   once:

   ```sh
   # Download the pinned Sparkle 2.9.4 tooling and verify its checksum before
   # running anything from it (same tarball release.yml uses):
   curl -fL -o Sparkle-2.9.4.tar.xz \
     https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-2.9.4.tar.xz
   echo "ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9  Sparkle-2.9.4.tar.xz" \
     | shasum -a 256 -c -
   mkdir -p sparkle && tar -xf Sparkle-2.9.4.tar.xz -C sparkle

   # Create the key pair. The PRIVATE key is stored in your login Keychain;
   # this prints the PUBLIC key (single-line base64) to stdout — copy it.
   ./sparkle/bin/generate_keys

   # Export the private key to a file so it can be pushed as a repo secret,
   # then hand it to GitHub and DELETE the local copy immediately:
   ./sparkle/bin/generate_keys -x sparkle_private_key.txt
   gh secret set SPARKLE_ED_PRIVATE_KEY --repo sohei56/maul-team < sparkle_private_key.txt
   rm -f sparkle_private_key.txt
   ```

   Then commit the **public** key so the build embeds it:

   ```sh
   # Paste the single-line base64 public key printed by generate_keys:
   printf '%s\n' "<public-key-base64>" > macapp/sparkle-public-key.txt
   git add macapp/sparkle-public-key.txt && git commit -m "chore(macapp): add Sparkle public key"
   ```

   `make-app.sh` reads `macapp/sparkle-public-key.txt` — a release build
   **fails without it**. The private key never leaves your Keychain / the repo
   secret; only the public key is committed. Losing the private key means you
   must ship a new public key and every existing installed app can no longer
   verify updates, so back up the Keychain item.

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
signs + notarizes+staples the DMG → uploads `MaulTeam-1.4.3.dmg` + `.sha256`
to the Release (channels ①②) → renders and pushes the cask to the tap
(channel ③). End users install via any of:

- **① Direct**: download the `.dmg` from the Release page.
- **② Release**: same asset, linked from the landing page / README.
- **③ Homebrew**: `brew tap sohei56/homebrew-tap && brew install --cask maul-team`.

When `SPARKLE_ED_PRIVATE_KEY` is present, the run also drives **channel ④
(in-app auto-update)**: it generates `appcast.xml` over the versioned dmg,
attaches it to the Release as an asset, and force-pushes it to a dedicated
single-file **`appcast` branch**. That branch is created automatically by the
first release run with the secret configured — you do not seed it by hand (it
mirrors how `.github/workflows/download-stats.yml` maintains the `metrics`
branch). The app's `SUFeedURL` points at the stable raw URL served from that
branch:

```
https://raw.githubusercontent.com/sohei56/maul-team/appcast/appcast.xml
```

Alongside the versioned asset, the upload step publishes a **version-less
alias** — `MaulTeam.dmg` + `MaulTeam.dmg.sha256` (byte-identical copy) — so
the stable direct-download URL
`https://github.com/sohei56/maul-team/releases/latest/download/MaulTeam.dmg`
never rots on version bumps. The landing page's and README's download buttons
point at this alias; the cask keeps using the versioned asset (its `url`
embeds `#{version}`).

Until the secrets exist, the pipeline still runs and produces an **unsigned**
dmg (useful for testing; Gatekeeper warns end users) — signing/notarization and
the tap bump activate automatically the moment their secrets are present.

---

## Part F — verifying a shipped release

After the run finishes, confirm all channels landed:

1. **DMG + checksum** on the Release page (channels ①②), and the version-less
   `MaulTeam.dmg` alias present.
2. **Homebrew** (channel ③): the tap's `Casks/maul-team.rb` bumped to the new
   version.
3. **Appcast** (channel ④), when `SPARKLE_ED_PRIVATE_KEY` is set:
   - the `appcast.xml` **asset** exists on the Release;
   - the **`appcast` branch** advanced (its commit message names this tag),
     and `https://raw.githubusercontent.com/sohei56/maul-team/appcast/appcast.xml`
     serves the new `<item>`;
   - **in-app update works from the PREVIOUS app version**: install version
     N, publish N+1, and confirm N offers and applies the update via Sparkle.

   **First-release caveat**: the very first Sparkle-enabled release cannot be
   delivered through Sparkle to anyone — there is no prior in-app updater to
   pull it. In-app auto-update only works from N→N+1 onward. Users on older
   (pre-Sparkle) builds still upgrade through the dmg funnel (channels ①②③),
   not the appcast.

---

## Residual verification (not yet done)

- `release.yml` has **never been executed on GitHub Actions** — first real run
  is the true integration test. `actionlint` was not available locally to
  statically check it.
- The bundled framework launching the SM pane from the extracted copy was
  confirmed to *extract*, but the SM pane starting from it was not visually
  observed.
