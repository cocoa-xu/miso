# miso

Native tools for offline macOS system images. Swift 6, Apple silicon, macOS 15 or later.

The runtime does not require the third-party `ipsw` executable, Python, Homebrew,
or separately installed command-line helpers. ArgumentParser and ZIPFoundation
are pinned source dependencies compiled into the executable. Cryptography,
compression and encrypted archives use macOS libraries directly; HTTPS uses
URLSession. System image attachment and APFS administration currently use
`hdiutil`, `diskutil` and Apple's APFS checker at fixed system paths. Restore APFS
tools come from the verified IPSW and require valid Apple signatures. CLT staging
uses Apple's `pkgutil`, `lsbom`, `ditto` and `makewhatis`; CLT package scripts are not
executed. Base provisioning uses the target's package-manager runtime, not a host
Homebrew installation. This is not a fully static binary.

This is an in-progress native migration. The commands below work without starting
a virtual machine. The experimental `restore` command connects the native vanilla
stages, with single-command offline acceptance on macOS 26.6.2. Base currently
exposes input preparation, its static layer, bootstrap, and experimental bottle/lifecycle
stages, not a complete build. Upgrade execution is not yet exposed. A recognized profile is not a claim of
native end-to-end validation. Write stages fail closed on unvalidated host ABIs.

```sh
make build
swift test
swift run miso --help
swift run miso profiles
swift run miso config defaults
swift run miso config check image.json
swift run miso ipsw inspect restore.ipsw
swift run miso ipsw inspect restore.ipsw --verify-digest
```

`ipsw extract` copies one regular archive member to a new file and requires either
its `--sha256` or the complete `--archive-sha256`. `upgrade plan` performs a three-way Data-template comparison for an exact
recognized source/target pair. It rejects conflicts and never modifies an image.
Use each command's `--help` for arguments.

`base defaults` prints package requests. Omitted versions mean the newest stable
target-compatible upstream release, not the host's installed version. Explicit
versions must be available upstream; they are never silently substituted.
The core formula resolver supports current and upstream versioned formulae, not
arbitrary historical Homebrew revisions. It checks arm64 bottle availability,
runtime requirements and dependency closure, and verifies pinned formula sources.
Unknown installation hooks still require a compatible execution adapter.

```sh
miso base defaults > base.json
miso base resolve --config base.json --target-version 15.6.1 \
  --target-build 24G90 --output resolved
miso base resolve --config base.json --target-version 15.6.1 \
  --target-build 24G90 --metadata resolved/metadata --output replayed
miso base archive create --spec inputs.json --output archived-inputs
miso base archive verify archived-inputs
```

Resolution does not install software or prove runtime compatibility. Only core
formula requests are currently resolved; Homebrew itself, Ruby, npm and third-party
selectors are configuration for the remaining migration. `additionalRubyVersions`
is an explicit compatibility list and can be changed or emptied.
Versioned formula names such as `node@24` constrain the release line; use `node`
to select the newest compatible upstream line instead.

Archive specifications contain `schemaVersion: 1`, a `target` with `version` and
`build`, and `resources`: objects with `name`, local `path`, and optional `origin`.
Archives copy the actual inputs and preserve modes, relative links and digests;
verification is network-free and works after moving the archive. An archive of
selected software inputs is not a complete macOS/Base reconstruction kit.
Keep private input archives separately from disposable build intermediates.

`base static` requires a completed never-booted bundle, the Actions Runner release
metadata and matching arm64 archive, and a GitHub known-hosts file. It clones the
bundle, writes the static user/service payloads, and verifies them after read-only
reattachment. Its output remains explicitly incomplete Base, without runtime
acceptance. All construction must use a local APFS workspace; slow external
volumes are suitable for input archives, not working images.

`base bootstrap --source bundle --archive archived-inputs --output new-stage`
installs the archive's `homebrew-sources` resource on a clone. It requires root and
includes bounded guest execution controls and detached payload verification.
The temporary execution view is not part of the exported bundle. This experimental
stage does not install the complete Base package set or prove VM bootability.
Use only trusted package inputs; a chroot is not a virtual-machine security boundary.

`base bottles verify --resolution resolved --bottles bottle-directory` validates
resolved formula sources and local `<name>.tar.gz` / `<name>.tar.index.json` inputs
without administrator privileges. Add `--formula name` to select a dependency closure.
`base bottles install` accepts the same inputs plus `--source bundle --output new-stage`
and requires root. It installs local bottles with target Homebrew, denies network
access, audits exact versions and verifies the detached payload. Post-install hooks
are deferred unless `--post-install` is supplied. That experimental option invokes
upstream hook methods under the same guest restrictions, then checks target tools,
dependencies and linkage. This remains incomplete Base without VM runtime acceptance.

Configuration defaults use `admin/admin`, disable FileVault, and request SSH/VNC.
They are intended for isolated test systems; change credentials before exposing a
guest to an untrusted network. Rosetta and ARM Linux translation are opt-in.
Validating a configuration does not apply it to an image.

```sh
sudo .build/out/Products/Release/miso restore restore.ipsw \
  --packages /path/to/pinned-clt-packages --config image.json --output new-build
```

Outputs must be new directories. Stages retain private journals, host/target
versions, receipts and failure diagnostics. `prepare`, `disk seal`, `disk volumes`,
`disk populate`, `disk tools`, `personalize material`, `personalize boot` and
`bundle assemble` expose the same stages individually. Completed inputs are
digest-bound; failed stages are not resumable inputs. Disk mutations operate on
new, owned images or clones, not supplied device numbers. Keep intermediate
artifacts private: they contain configuration credentials and identity material.

The final bundle is under `assembled/bundle`. Offline validation is distinct from
runtime and cross-Mac acceptance; manifests do not mark either as verified.
Network access is required for Apple archive keys and personalization tickets.

`disk layout` calculates a GPT layout. `disk seed` copies a digest-checked raw APFS
System container into a new sparse GPT image with reserved iSC and Recovery
partitions. A seed is not a bootable or provisioned system. `decode pbze` decodes
bounded component payloads without invoking an external interpreter.

`disk inspect disk.img --output inspection` attaches a GPT image read-only without
mounting its volumes, reports only its owned APFS containers, and detaches before
completion. Device identifiers are discovered at runtime, never fixed disk numbers.

`decode aea component.aea --output decoded` decrypts in process and writes
`payload.bin` and an operation journal to a new directory. It supports the
symmetric-encryption profile used by supported restore components. Recipient keys
are fetched over bounded HTTPS from the component's Apple endpoint, or supplied
with `--private-key recipient.pem`. Redirects are bounded and restricted to
recognized Apple key endpoints with the same key path. Keys are not logged or
written to temporary files. `--maximum-bytes` bounds the decrypted size.
AEA authentication is not verification of an Apple restore ticket or system seal.

`identity` creates a new machine identifier, hardware model and empty auxiliary
storage after verifying the IPSW digest. `bundle verify` checks all four bundle
files against `manifest.json`. `bundle validate` checks a read-only
Virtualization.framework configuration and runs a negative CPU-count control;
it neither creates nor starts a VM. The latter two operations are independent:
configuration validation does not verify the image's seal or file manifest.
Use the signed executable produced by `make build` for Virtualization.framework
commands; `swift run` may replace that signature.

Metadata inspection is not payload authentication or boot validation. Commands
write JSON reports to standard output and diagnostics to standard error. Failed
extractions retain their partial output; existing files are never overwritten.
