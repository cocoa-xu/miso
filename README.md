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

## GitHub Actions

Install a release in an Apple silicon macOS job, then run MISO in later steps:

```yaml
name: MISO
on: workflow_dispatch

permissions:
  contents: read

jobs:
  miso:
    runs-on: xcode-27
    steps:
      - name: Install MISO
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          mkdir -p "$RUNNER_TEMP/miso"
          gh release download v0.2.1 --repo cocoa-xu/miso \
            --pattern 'miso.tar.gz*' --dir "$RUNNER_TEMP/miso"
          cd "$RUNNER_TEMP/miso"
          shasum -a 256 -c miso.tar.gz.sha256
          tar -xzf miso.tar.gz
          echo "$RUNNER_TEMP/miso" >> "$GITHUB_PATH"
      - run: miso --version
```

For image-building jobs, supply the inputs and APFS workspace described above.
The manual [image workflow](.github/workflows/image-test.yml) builds macOS 27.0.1
Vanilla on the official `xcode-27` runner, publishes to GHCR, and verifies a fresh
download without starting a VM. It removes unused runner software to provide at
least 89 GiB of free workspace. Base and Xcode builds on hosted runners are not yet
validated.
