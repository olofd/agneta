# Release setup

The one-time setup a release needs ([RELEASING.md](RELEASING.md), part 0). Each key goes from the maintainer's Mac straight into GitHub through `scripts/dev/release-secrets`, which the maintainer runs. Nobody else, Claude included, ever handles a key. It takes about 15 minutes, **at the Mac itself**: Keychain may ask to let Sparkle's tool save its key.

## Done already (2026-11-18)

- **The `release` environment** on olofd/agneta. Every run waits for the maintainer's approval (Review deployments → Approve). It can be used only from `v*` tags (releases) and `main` (dry runs).
- **The "Release tags" ruleset:** only repository admins can create, move or delete `v*` tags.
- **The tap,** [olofd/homebrew-tap](https://github.com/olofd/homebrew-tap), which the publish workflow writes `Casks/agneta.rb` into.

## What the maintainer does

### 1. Make the signing request

```bash
scripts/dev/release-secrets request
```

This makes Agneta's own Developer ID key, so revoking it never affects Klang or Hemma. It also makes `agneta.certSigningRequest` and shows it in Finder.

### 2. Get the certificate from Apple

On [developer.apple.com → Certificates](https://developer.apple.com/account/resources/certificates/list):
1. Click **+** and choose **Developer ID Application**, then the **G2 Sub-CA** profile.
2. Upload `agneta.certSigningRequest`.
3. Download the certificate (`developerID_application.cer`).

### 3. Make the notarization key

On [App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api), under **Team Keys**:
1. Click **+**. Name it `Agneta notarization` and give it **Developer** access, which is enough to notarize and nothing more.
2. Download `AuthKey_<KEY ID>.p8`. Apple offers the download only once.
3. Keep this page open: step 5 asks for the **Issuer ID**, shown above the table.

### 4. Make the tap token

At [github.com/settings/personal-access-tokens/new](https://github.com/settings/personal-access-tokens/new):
- Name: `agneta-homebrew-tap`; expiration: one year.
- Repository access: **Only select repositories** → `olofd/homebrew-tap`.
- Permissions: **Contents: Read and write**, and nothing else.

Copy the token; step 5 asks for it.

### 5. Put it all in GitHub

```bash
scripts/dev/release-secrets finish ~/Downloads/developerID_application.cer ~/Downloads/AuthKey_XXXXXXXXXX.p8
```

It asks for the Issuer ID and, at a hidden prompt, the tap token. Then it:

- checks the certificate was made from step 1's request, and imports it with its key into the login keychain (the backup, and what signs a release built on this Mac);
- stores the certificate as a `.p12` with a random password, and the notarization key with its IDs;
- makes Sparkle's update key in the login keychain (account `agneta`) and stores it;
- stores the tap token;
- ends by checking that the environment has all 7 secrets and 2 variables.

### 6. Keep two things safe, delete the downloads

- **The `.p8` file** goes in your password manager, since Apple won't offer it again. Then delete it and the `.cer`.
- **Sparkle's private key** is in Keychain Access → login, "Private key for signing Sparkle updates" (account `agneta`). Save it in your password manager too:
  ```bash
  ~/Library/Caches/agneta-build/sparkle-2.10.1/bin/generate_keys --account agneta -x ~/Desktop/agneta-sparkle-key.txt
  ```
  Then delete that file. **Without this key, installed copies of Agneta can never be updated again.**

### 7. Hand back

Say it's done. Claude then starts the dry run (`gh workflow run release.yml -f version=0.1.0-rc.1`), and you approve it on GitHub when it waits on the `release` environment. It builds, signs and notarizes both architectures and keeps the files as a workflow artifact, without publishing anything. If Apple refuses something, the run prints Apple's notarization log.

## Notes

- **Two certificates, one name.** The new certificate has the same name as Klang's (`Developer ID Application: <name> (<team>)`). On GitHub's runner it's the only one, so the name works. On this Mac, `codesign` needs the certificate's SHA-1 instead (`security find-identity -v -p codesigning` lists both).
- **Your email on GitHub.** "Keep my email addresses private" is off in GitHub's [email settings](https://github.com/settings/emails), so commits GitHub makes for you (a repository's first commit, edits on the web) carry your personal address. Turning it on, together with "Block command line pushes that expose my email", makes GitHub use the noreply address instead.
- **Redoing a step.** `release-secrets request` keeps a waiting request until `finish` succeeds. Delete `~/Library/Caches/agneta-build/release-request` to start over. Running `finish` again replaces the secrets and reuses Sparkle's key, so installed copies keep updating.
