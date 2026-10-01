# git-credential-code-storage

A [git credential helper](https://git-scm.com/docs/gitcredentials) for macOS that signs in to
[Pierre Code Storage](https://code.storage) with a private key that **cannot be copied out of the
macOS Keychain**.

Code Storage is a hosted Git service. Each Git request carries a short-lived JWT, signed with a
private key that you register with your organization
([authentication docs](https://code.storage/docs/platform/authentication)). This helper mints a
new ES256 token for each Git operation, scoped to the one repository in the URL. It signs the token
with a key in your login keychain. The key is stored as non-extractable, so the private key
material never enters the helper process after import, and other programs cannot read it.

## Install

You need macOS 13 or later. The helper is a single universal (arm64 + x86_64) binary. Install it
anywhere on your `PATH`; these instructions use `~/.local/bin`.

### From a release

```sh
NAME=git-credential-code-storage-macos-universal
cd "$(mktemp -d)"
curl -fLO https://github.com/sj26/git-credential-code-storage-macos/releases/latest/download/$NAME.tar.gz
curl -fLO https://github.com/sj26/git-credential-code-storage-macos/releases/latest/download/$NAME.tar.gz.sha256
shasum -a 256 -c $NAME.tar.gz.sha256
tar -xzf $NAME.tar.gz
install -d ~/.local/bin
install -m 0755 $NAME/git-credential-code-storage ~/.local/bin/
```

The release binary is signed with a Developer ID (`Samuel Cochran (9C4D79M493)`) and notarized
by Apple, so Gatekeeper allows it even if you download the tarball with a browser.

### From source

You need the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/sj26/git-credential-code-storage-macos.git
cd git-credential-code-storage-macos
make install                  # installs to ~/.local/bin
make install PREFIX=/usr/local  # or somewhere else
```

## Setup

1. In the Code Storage dashboard, open **Keys** and select **Create key**. Copy the private key
   (a PKCS8 PEM). Note your organization name.

2. Import the key into your login keychain. Replace `your-org` with your organization name:

   ```sh
   pbpaste | git-credential-code-storage import your-org
   ```

   Then clear the key from your clipboard, and delete any copy that you saved to disk. To replace
   the key for an organization, run `import` again.

3. Configure git to use the helper for Code Storage hosts, and to send the repository path to it:

   ```sh
   git config --global "credential.https://*.code.storage.helper" ""
   git config --global --add "credential.https://*.code.storage.helper" code-storage
   git config --global "credential.https://*.code.storage.useHttpPath" true
   ```

   The empty `helper` entry stops other helpers (such as `osxkeychain`) from storing or supplying
   Code Storage credentials. `useHttpPath` is required, because each token covers one repository.

4. Use remote URLs **without a username**:

   ```sh
   git clone https://your-org.code.storage/your-repo.git
   ```

   Do not use `https://t@your-org.code.storage/...`. With a username in the URL, git sends it with
   an empty password. Code Storage responds with 403 (not 401), so git never asks the helper.

## Commands

| Command | Effect |
| --- | --- |
| `get` | Reads git credential attributes on stdin. For `https://<org>.code.storage/<repo>`, prints `username=t` and `password=<JWT>`. Ignores all other hosts. |
| `store`, `erase` | Do nothing. Tokens are minted for each request. |
| `import <org>` | Reads a P-256 PKCS8 PEM on stdin and stores it in the login keychain as a non-extractable key. Replaces the existing key for the org. |
| `delete <org>` | Deletes the key for the org from the keychain. |

The token has the header `{"alg":"ES256","typ":"JWT"}` and these claims:

| Claim | Value |
| --- | --- |
| `iss` | The org: the host without `.code.storage` |
| `sub` | `git-$USER` |
| `repo` | The URL path without `.git` |
| `scopes` | `["git:read","git:write"]` |
| `iat` | Now |
| `exp` | Now + 1 hour |

The token always asks for `git:read` and `git:write`. A
[restricted key](https://code.storage/docs/platform/authentication#restricted-keys) must allow
both.

## Security model

- **The key cannot be exported.** `import` stores the key in the login keychain, labelled
  `code.storage:<org>`. It is marked sensitive and not extractable. `SecKeyCopyExternalRepresentation`
  and `SecItemExport` (which `security export` uses) cannot get the private key back, even when
  the helper itself asks.
- **Signing happens in the keychain.** The helper calls `SecKeyCreateSignature` with
  `ecdsaSignatureMessageX962SHA256`, and converts the DER signature to the raw `r||s` form that JWS
  uses. The private key is in the helper's memory only once: while `import` parses the PEM.
- **Only the helper can use the key.** The key's access control list trusts only the helper binary
  that imported it, like `security import -x -T <helper>`. Other programs that try to sign with the
  key get a Keychain prompt, or `errSecAuthFailed` when they cannot show one.
- **The helper can still be used.** Any program that runs as you can run the helper and get tokens
  from it. The keychain stops the key from being copied, not from being used through the helper.
  Tokens expire after an hour and cover one repository.
- **Why the legacy keychain?** The import uses `SecItemImport`, `SecAccessCreate`, and
  `SecTrustedApplicationCreateFromPath`. Apple has deprecated these APIs, but they are the only
  public way to store a non-extractable, app-restricted key in the login (file-based) keychain. The
  newer data protection keychain needs a keychain-access-groups entitlement and a provisioning
  profile, which a plain command-line tool cannot have. The Secure Enclave is not an option, because
  Code Storage creates the key in your browser and the Secure Enclave cannot import keys.

## Rebuilds and upgrades

The key's access control list refers to the signature of the helper binary that imported it.
Releases are signed with a Developer ID, so the keychain checks the identifier
(`com.sj26.git-credential-code-storage`) and Team ID (`9C4D79M493`). Later releases match, so
upgrades do not cause a Keychain prompt.

Builds from source are signed ad hoc. The keychain then refers to the exact binary (its code
directory hash, or cdhash), so each rebuild is a different program to the keychain.

The first time a build that does not match signs with an existing key, macOS shows a Keychain
prompt that asks for your login keychain password. This happens after each rebuild from source,
and when you change between a source build and a release. Select **Always Allow** to trust the new
build. Before you approve, make sure that you just installed or rebuilt the helper. Or, if you
still have the PEM, run `import` again with the new build.

To avoid the prompt on each rebuild from source, sign with a stable identity, such as an Apple
Development certificate. Then the keychain checks the signing identity, not the cdhash:

```sh
make install CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
```

## Uninstall

```sh
git-credential-code-storage delete your-org   # for each org
rm ~/.local/bin/git-credential-code-storage   # or: make uninstall
git config --global --unset-all "credential.https://*.code.storage.helper"
git config --global --unset "credential.https://*.code.storage.useHttpPath"
```

## Development

```sh
make build   # universal release build, ad hoc signed, in .build/
make dist    # tarball and SHA-256 checksum in dist/
```

To make a signed, notarized release, store notary credentials once, then build:

```sh
xcrun notarytool store-credentials code-storage --apple-id you@example.com --team-id TEAMID
make dist CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

## License

[MIT](LICENSE)
