# MISO

Build macOS Vanilla, Base and Xcode images on Apple silicon without starting a VM.

## Install

Download `miso.tar.gz` and `miso.tar.gz.sha256` from the
[latest release](https://github.com/cocoa-xu/miso/releases/latest), then:

```sh
shasum -a 256 -c miso.tar.gz.sha256
tar -xzf miso.tar.gz
mkdir -p "$HOME/.local/bin"
install -m 755 miso "$HOME/.local/bin/miso"
export PATH="$HOME/.local/bin:$PATH"
miso --version
```

Image construction requires Apple silicon macOS, an APFS workspace and administrator
privileges. Required host interfaces are checked at runtime; missing interfaces are
reported by name. Downloads and Apple personalization need network access.
No Python or third-party `ipsw` executable is required.

## Build an image

List supported targets and create a configuration:

```sh
miso profiles
miso config defaults > image.json
```

Edit `image.json` to set the account and image options. Default credentials are
`admin/admin`. Provide the target IPSW and matching Command Line Tools packages:

```sh
miso config check image.json
sudo "$(command -v miso)" restore restore.ipsw \
  --packages /path/to/clt-packages --config image.json --output vanilla
```

The image bundle is written to `vanilla/assembled/bundle`. Output directories must
be new, with enough free space for the image and its inputs.
You can also pass an Apple HTTPS IPSW URL. MISO removes its download after successful
input preparation; add `--keep-downloads` to retain it. Local IPSW files are always
preserved.

To build a Base image from a prepared recipe and its input directory:

```sh
sudo "$(command -v miso)" base build --source vanilla/assembled/bundle \
  --recipe base-recipe.json --inputs /path/to/inputs --output base
```

Use `miso base --help` for input preparation and `miso xcode --help` for Xcode,
SDK and Simulator installation. Each subcommand provides its own `--help`.

Final images automatically compress eligible installed files and reclaim unused
APFS blocks. To optimize an existing, trusted MISO bundle into a new clone:

```sh
sudo "$(command -v miso)" bundle optimize /path/to/bundle --output optimized
```

The result is `optimized/bundle`; the source is preserved. Add `--no-compress` to
only reclaim free blocks, or `--username NAME` for a different guest account.

## Upload and download

MISO transfers OCI VM images directly to GHCR. For uploads, set
`MISO_REGISTRY_USERNAME` and `MISO_REGISTRY_PASSWORD` using credentials with package
write access. In Actions, use `${{ github.actor }}` and `${{ github.token }}` with
`packages: write`.

```sh
miso bundle export-tart /path/to/bundle --output exported
miso bundle push exported/vm ghcr.io/owner/image:tag --output upload
miso bundle pull ghcr.io/owner/image:tag --output downloaded
```

Downloads produce `downloaded/vm` on an APFS workspace. Public images can be pulled
without credentials. Uploads use Zstd level 9; use `--compression lz4` for existing
Tart clients. Downloads accept both formats. Compression and transfers default to
four concurrent jobs; set `--concurrency 1` through `16` to adjust. Progress shows bytes and recent upload or
download speed. Temporary transfer data is removed automatically. No Tart executable
or VM is needed.

To reuse an exported parent, import it with its original MISO manifest. Optional
`--disk-bytes` expands the clone and its APFS container while preserving Recovery:

```sh
sudo miso bundle import-tart downloaded/vm --manifest parent-manifest.json \
  --output parent --disk-bytes 160000000000
```

## GitHub Actions

Use the Action in an Apple silicon macOS job:

```yaml
steps:
  - uses: cocoa-xu/miso@v0.4.4
    with:
      version: 0.4.4
      xcode-base-url: ${{ secrets.XCODE_BASE_URL }}
  - run: miso --version
```

`version` accepts a release number, `latest` (default), or `source` to build the
Action revision. Xcode mirror support requires MISO 0.2.3 or later.
Omit `xcode-base-url` when using local XIPs. The Action passes it to MISO through
`MISO_XCODE_BASE_URL` and masks it; MISO also masks the complete download URL.
Base preparation uses `GH_TOKEN` or `GITHUB_TOKEN` for GitHub metadata when available.

To download and prepare Xcode from that mirror:

```sh
miso xcode prepare-archive --config xcode.json \
  --target-version 27.0.1 --target-build 26A434 --output xcode-input
```

The configuration selects the Xcode version and build. MISO resolves the original
Apple filename from the public Xcode Releases catalog, verifies Apple signatures
and the selected version, then removes its downloaded XIP. Use `--keep-downloads`
to retain it. Local files supplied with `--archive` and `--sha256` are preserved.
Mirror URLs are excluded from receipts. Configure the base URL as a repository
secret; MISO provides no shared mirror.

For Slim, generate a configuration and use it throughout the Xcode stages:

```sh
miso xcode defaults --config xcode.json --slim > xcode-slim.json
```

Slim keeps macOS/iOS/watchOS SDKs and iOS/watchOS runtimes. It trims Intel code,
preserves ARM signatures, then compresses, cleans caches and sparsifies the image.
Use `--profile profile.yaml` instead for custom `platforms`, `trimIntel`,
`transparentCompression`, `cleanup` and `sparsify` settings. The last four are
independent booleans. Without a profile, the full installation remains the default.
Slim also disables optional personal services and automatic OS/App Store updates,
while retaining animations, local diagnostics, security-data updates and developer
services. Use `preset: slim` in YAML to override individual choices; see
[system settings](docs/system-settings.md).

Image construction needs an APFS workspace, administrator privileges and enough
free space for its inputs and output. The Action does not remove runner software.
