# Install And Update

The first Nudge install path is the hosted native installer:

```sh
curl -fsSL https://nudgecode.dev/install.sh | sh
```

The installer detects macOS/Linux and `aarch64`/`x86_64`, downloads the matching release archive from `https://nudgecode.dev/releases`, verifies its `.sha256` checksum, and installs `nudge` to `~/.local/bin` unless `NUDGE_INSTALL_DIR` is set.

For signed releases, require signature verification and point the installer at the published release public key:

```sh
curl -fsSL https://nudgecode.dev/install.sh | \
  NUDGE_REQUIRE_SIGNATURE=1 \
  NUDGE_PUBLIC_KEY_URL=https://nudgecode.dev/releases/nudge-release-public.pem \
  sh
```

The same verification policy can be used through `nudge update`:

```sh
nudge update \
  --require-signature \
  --public-key-url https://nudgecode.dev/releases/nudge-release-public.pem
```

Useful installer overrides:

- `NUDGE_VERSION`: release version path; defaults to `latest`.
- `NUDGE_RELEASE_BASE_URL`: release base URL; defaults to `https://nudgecode.dev/releases`.
- `NUDGE_INSTALL_DIR`: install directory; defaults to `~/.local/bin`.
- `NUDGE_SKIP_CHECKSUM=1`: skip checksum verification for local testing.
- `NUDGE_PUBLIC_KEY_FILE`, `NUDGE_PUBLIC_KEY`, or `NUDGE_PUBLIC_KEY_URL`: enable RSA/SHA-256 signature verification.
- `NUDGE_REQUIRE_SIGNATURE=1`: fail if no public key source is configured.

Current production gap: the repository supports the hosted install URL and public-key URL flow, but the actual `nudgecode.dev` static hosting and production public key publication still need to be deployed.
