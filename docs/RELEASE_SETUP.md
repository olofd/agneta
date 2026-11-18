# Release setup

The one-time setup a release needs ([RELEASING.md](RELEASING.md), part 0), step by step. It takes about 30 minutes. Every secret goes from your Mac straight into GitHub: nobody else, Claude included, ever sees one. When you're done, the release workflow can sign and notarize Agneta, and a dry run proves it.

You need: the Apple Developer account (as its Account Holder), Keychain Access, and `gh` signed in to GitHub (`gh auth status`).

## 1. A Developer ID certificate for Agneta

Agneta gets a certificate of its own, so revoking it never affects Klang or Hemma. It has the same team, and so the same name, as theirs; only the date tells them apart.

1. **Make a signing request.** Open Keychain Access, then Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority…
   - User Email Address: your Apple ID's email. Common Name: `Agneta Developer ID`. CA Email Address: leave empty.
   - Choose **Saved to disk**, and save `CertificateSigningRequest.certSigningRequest`. This also puts a new private key in your login keychain.
2. **Ask Apple for the certificate.** On [developer.apple.com → Certificates](https://developer.apple.com/account/resources/certificates/list), click **+**, choose **Developer ID Application**, then the **G2 Sub-CA** profile, and upload the request. Download the `.cer` file and double-click it: it joins its private key in your login keychain.
3. **Check it's there:**
   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
   You'll see the new one beside Klang's, with the same name: `Developer ID Application: <your name> (<team ID>)`. Copy that name for step 4.
4. **Export it.** In Keychain Access, open the login keychain's **My Certificates**, and find the Developer ID Application certificate that expires five years from today (the newest). Expand it to check that a private key is under it. Right-click the certificate → Export…, choose **Personal Information Exchange (.p12)**, save it as `agneta-developer-id.p12`, and give it a strong password. Keychain Access writes the format a CI keychain can import, which newer `openssl` doesn't by default.

Keep the `.p12` and its password in your password manager. Delete the file from the disk once it's in GitHub (step 4).

## 2. An App Store Connect API key for notarization

1. On [App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api), open **Team Keys**. If you've never made one, click Request Access first.
2. Click **+** (Generate API Key). Name: `Agneta notarization`. Access: **Developer**, which is enough to notarize and nothing more.
3. **Download** the key, `AuthKey_<KEY ID>.p8`. Apple offers the download only once.
4. Note the **Key ID** (in the key's row) and the **Issuer ID** (above the table).

Keep the `.p8` in your password manager too, and delete the file once it's in GitHub.

## 3. The `release` environment on GitHub

On [github.com/olofd/agneta → Settings → Environments](https://github.com/olofd/agneta/settings/environments), click **New environment** and name it `release`.

- **Required reviewers:** add yourself. Leave "Prevent self-review" off, since you're the only reviewer. Every release run then waits for your approval before it touches a key.
- **Deployment branches and tags:** choose **Selected branches and tags**, then add a tag rule `v*` (releases) and a branch rule `main` (dry runs).

Then, under Settings → Rules → **Rulesets**, choose New ruleset → **New tag ruleset**. Name it `Release tags`, set Enforcement to Active, add the target `v*`, tick **Restrict creations**, **Restrict updates** and **Restrict deletions**, and add **Repository admin** to the bypass list. Now only you can make a release tag.

## 4. Put the keys in the environment

Run these in a terminal, in the folder that holds the files. The `.p12` password is typed at a prompt, so it stays out of your shell history.

```bash
base64 -i agneta-developer-id.p12 | gh secret set DEVELOPER_ID_P12 --env release --repo olofd/agneta
```

```bash
gh secret set DEVELOPER_ID_P12_PASSWORD --env release --repo olofd/agneta
```

```bash
gh secret set ASC_KEY_P8 --env release --repo olofd/agneta < AuthKey_XXXXXXXXXX.p8
```

```bash
gh secret set ASC_KEY_ID --env release --repo olofd/agneta --body XXXXXXXXXX
```

```bash
gh secret set ASC_ISSUER_ID --env release --repo olofd/agneta --body xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

```bash
gh variable set AGNETA_SIGN_IDENTITY --env release --repo olofd/agneta --body "Developer ID Application: <your name> (<team ID>)"
```

Then delete the `.p12` and `.p8` files from the disk.

## 5. Sparkle's update key

This one isn't Apple's, but the release needs it as well. Updates are verified with it, so **losing the private key means installed copies can never be updated again**: keep it in your password manager.

Sparkle's tools are already on this Mac, in `~/Library/Caches/agneta-build/sparkle-2.10.1/bin/`.

1. **Make the key.** It goes into your login keychain, and the tool prints the public key:
   ```bash
   ~/Library/Caches/agneta-build/sparkle-2.10.1/bin/generate_keys --account agneta
   ```
2. **Export the private key** and store it in GitHub:
   ```bash
   ~/Library/Caches/agneta-build/sparkle-2.10.1/bin/generate_keys --account agneta -x agneta-sparkle-private-key.txt
   ```
   ```bash
   gh secret set SPARKLE_ED_PRIVATE_KEY --env release --repo olofd/agneta < agneta-sparkle-private-key.txt
   ```
3. **Store the public key** (the base64 text from step 1) in GitHub:
   ```bash
   gh variable set AGNETA_SPARKLE_PUBLIC_KEY --env release --repo olofd/agneta --body "<public key>"
   ```
4. Put the exported file's contents in your password manager, then delete the file.

## 6. The Homebrew tap

1. **Make the tap repository.** It's public, and Homebrew finds it by its name:
   ```bash
   gh repo create olofd/homebrew-tap --public --description "Homebrew casks for Agneta"
   ```
2. **Make a token.** Open [github.com/settings/personal-access-tokens/new](https://github.com/settings/personal-access-tokens/new) and fill it in:
   - Name: `agneta-homebrew-tap`; expiration: one year.
   - Repository access: **Only select repositories** → `olofd/homebrew-tap`.
   - Permissions: **Contents: Read and write**, and nothing else.
3. **Store the token** in GitHub. Paste it at the prompt:
   ```bash
   gh secret set HOMEBREW_TAP_TOKEN --env release --repo olofd/agneta
   ```

## Done: check and hand back

This lists the names only; it can't show values.

```bash
gh secret list --env release --repo olofd/agneta && gh variable list --env release --repo olofd/agneta
```

You should see:
- seven secrets: `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `ASC_KEY_P8`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `SPARKLE_ED_PRIVATE_KEY` and `HOMEBREW_TAP_TOKEN`;
- two variables: `AGNETA_SIGN_IDENTITY` and `AGNETA_SPARKLE_PUBLIC_KEY`.

Then say so, and Claude starts the dry run (`gh workflow run release.yml -f version=0.1.0-rc.1`). It needs your approval on GitHub: the run waits on the `release` environment until you click **Review deployments** → Approve. It builds, signs and notarizes both architectures and keeps the files as a workflow artifact, without publishing anything. If Apple refuses something, the run prints Apple's notarization log.
