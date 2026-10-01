# git-credential-code-storage

A [git credential helper](https://git-scm.com/docs/gitcredentials) for macOS that signs you in to
[Pierre Code Storage](https://code.storage) with a private key that **cannot be copied out of your
Keychain**.

Code Storage authenticates each Git request with a short-lived token, signed by a private key that
you register with your organization
([docs](https://code.storage/docs/platform/authentication)). This helper keeps that key in your
macOS login keychain and makes a new token for each Git operation. Each token is valid for one hour
and one repository.

## Install

You need macOS 13 or later, on Apple silicon or Intel.

```sh
cd "$(mktemp -d)"
curl -fLO https://github.com/sj26/git-credential-code-storage-macos/releases/latest/download/git-credential-code-storage-macos-universal.tar.gz
curl -fLO https://github.com/sj26/git-credential-code-storage-macos/releases/latest/download/git-credential-code-storage-macos-universal.tar.gz.sha256
shasum -a 256 -c git-credential-code-storage-macos-universal.tar.gz.sha256
tar -xzf git-credential-code-storage-macos-universal.tar.gz
install -d ~/.local/bin
install -m 0755 git-credential-code-storage-macos-universal/git-credential-code-storage ~/.local/bin/
```

Make sure `~/.local/bin` is on your `PATH`, or install somewhere else that is. Releases are signed
with a Developer ID and notarized by Apple.

To build from source instead, install the Xcode command line tools (`xcode-select --install`),
clone this repository, and run `make install`.

## Setup

1. In the Code Storage dashboard, open **Keys** and select **Create key**. Copy the private key.

2. Import the key into your Keychain. Replace `your-org` with your organization name:

   ```sh
   pbpaste | git-credential-code-storage import your-org
   ```

   Then clear your clipboard, and delete any copy of the key that you saved. To replace the key
   later, run `import` again.

3. Tell git to use the helper for Code Storage:

   ```sh
   git config --global "credential.https://*.code.storage.helper" ""
   git config --global --add "credential.https://*.code.storage.helper" code-storage
   git config --global "credential.https://*.code.storage.useHttpPath" true
   ```

   The empty entry stops other helpers, such as the macOS Keychain helper, from saving Code Storage
   passwords. `useHttpPath` sends the repository name to the helper.

4. Use remote URLs **without a username**:

   ```sh
   git clone https://your-org.code.storage/your-repo.git
   ```

   Not `https://t@your-org.code.storage/...`. With a username in the URL, git never asks the helper,
   and Code Storage refuses the request with a 403 error.

## Commands

| Command | What it does |
| --- | --- |
| `import <org>` | Stores the private key from stdin in your Keychain. Replaces the existing key for the org. |
| `delete <org>` | Deletes the key for the org from your Keychain. |
| `get`, `store`, `erase` | Called by git. You don't run these. |

Tokens have the scopes `git:read` and `git:write`. If you use a
[restricted key](https://code.storage/docs/platform/authentication#restricted-keys), it must allow
both.

## Security

- **The key can't be copied.** The Keychain stores it as non-extractable. No program, including
  this helper, can read the key back out. The Keychain does the signing.
- **Only this helper can use the key.** Other programs that try get a Keychain prompt.
- **Anything running as you can run the helper.** So any program on your account can get tokens,
  but each token is valid for one hour and one repository. To stop all access, delete the key in
  the Code Storage dashboard.

## Keychain prompts

The Keychain trusts the helper that imported the key. Later releases are signed with the same
identity, so upgrades don't cause a prompt.

You see a Keychain prompt that asks for your login password when a different build uses the key.
For example, after you build from source, or when you change between a source build and a
release. If you just installed or built the helper, select **Always Allow**. Otherwise, select
**Deny**.

## Uninstall

```sh
git-credential-code-storage delete your-org
rm ~/.local/bin/git-credential-code-storage
git config --global --unset-all "credential.https://*.code.storage.helper"
git config --global --unset "credential.https://*.code.storage.useHttpPath"
```

## Development

`make build` makes an ad hoc signed universal binary in `.build/`, and `make install` installs it.
To make a signed, notarized release tarball in `dist/`:

```sh
xcrun notarytool store-credentials code-storage --apple-id you@example.com --team-id TEAMID
make dist CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

## License

[MIT](LICENSE)
