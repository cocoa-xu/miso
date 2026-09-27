# miso

Native tools for offline macOS system images. Swift 6, Apple silicon, macOS 15 or later.

The runtime does not require the third-party `ipsw` executable, Python, Homebrew,
or separately installed command-line helpers. ArgumentParser and ZIPFoundation
are pinned source dependencies compiled into the executable. Cryptography,
compression and encrypted archives use macOS libraries directly; HTTPS uses
URLSession. System image attachment and APFS administration currently use
`hdiutil`, `diskutil` and Apple's APFS checker at fixed system paths. Restore APFS
tools come from the verified IPSW and require valid Apple signatures before use.
Each construction stage creates locally signed copies without private entitlements
so OS launch constraints do not require executing the tools from a protected system
location. Journals retain the original and derived hashes; execution rechecks the
derived hash and signature. Original inputs and host security settings are unchanged.
CLT staging
uses Apple's `pkgutil`, `lsbom`, `ditto` and `makewhatis`; CLT package scripts are not
executed. Base provisioning uses the target's package-manager runtime, not a host
Homebrew installation. This is not a fully static binary.

Data template audits compare file content, ownership, modes, ACLs and extended
attributes. Host-generated `com.apple.provenance` tracking is retained and counted
separately in the template receipt; it is not copied from the source or required
to match across volumes. Other unexpected extended attributes remain errors.

`xcode prepare-archive` verifies a checksum-bound XIP with Apple's `xip`, checks
the extracted application signature, and records its exact version, build,
minimum macOS version and configured SDKs. Expansion has a bounded execution
time and a separate working directory. The default standard configuration
selects Xcode 27.0 (27A266a), all four arm64 simulator platforms and MetalToolchain;
it never selects the host's Xcode version.

`xcode prepare-metal` fetches the exact configured build from Apple's signed asset
catalog, authenticates the Pallas signature and Apple certificate chain, checks the
archive hash, decrypts it with AppleArchive and expands it with Apple's `aa patch`.
It verifies the arm64 restore identity, disk-image digest and Metal executable's
Apple signature on a read-only mount. It does not install a host component.
For offline replay, pass the saved `catalog.jwt` and `asset.aar` using `--catalog`
and `--archive`. Both are required together. The receipt records input preparation
separately from Xcode image construction and runtime acceptance.

`xcode prepare-runtime --platform iOS --runtime-version 27.0 --runtime-build 24A434
--output <runtime>` authenticates the exact arm64 simulator asset, decrypts it,
checks the restore image digest and inspects the runtime's platform and OS identity
on a read-only mount. Pass `--catalog` and `--archive` for offline replay. The full
asset digest binds the runtime contents, including bundles with legacy resource
omission rules. Preparation never installs a host runtime or starts a simulator.

`xcode prepare-packages --prepared <prepared-xcode> --output <packages>` verifies
the four reviewed first-launch packages and records their payload inventories,
relocation policies and unexecuted scripts. CoreTypes is restricted to its writable
firmlink subtree; MobileDevice payloads relocate under `/Library/Apple`. Package
links are checked lexically without resolving paths through the host filesystem.
`xcode install-packages --source <xcode-bundle> --prepared <prepared-xcode>
--output <stage>` installs those payloads and BOM receipts into a new image clone,
validates receipt lookup with `pkgutil`, and records the license and rvictl PATH.
It still leaves first-launch completion false pending certificate and device-image
effects and independent runtime checks.

```sh
miso xcode defaults > xcode.json
miso xcode prepare-archive --archive Xcode_27.0_Apple_silicon.xip \
  --sha256 <archive-sha256> --target-version 27.0.1 --target-build 26A434 \
  --config xcode.json --output prepared-xcode
```

`xcode install-application --source <base-bundle> --prepared <prepared-xcode>
--output <stage>` clones a completed, never-booted Base bundle, verifies and copies
the signed application with filesystem compression, audits every file and selects
the target developer directory. Its manifest preserves Base completion and records
Xcode stages separately, with Xcode completion and runtime verification still false.
First-launch packages, simulator and component installation, complete Xcode image
construction and independent guest acceptance remain incomplete. These commands
do not start a VM or install Xcode on the host.

This is an in-progress native migration. The commands below work without starting
a virtual machine. The experimental `restore` and `base build` commands have
single-command offline acceptance on macOS 15.6.1 (24G90), 26.6.2 (25G83) and
27.0 (26A428). Their Base outputs also passed separate automated boot, SSH,
Safari automation and VNC input checks on disposable copies; construction still
never starts a VM. The 15.6.1 acceptance retains reviewed first-boot diagnostic
warnings; it is not a zero-diagnostics claim. Upgrade execution is not yet exposed.
A recognized profile is not a claim of native end-to-end validation. Write stages
fail closed on unvalidated host ABIs.

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

`base prepare` combines software resolution, downloads and checksum-bound plans
without root or a VM. It selects target-compatible versions and pins a matching
core snapshot. Runtime constraints come from the selected archives, not host tools.

```sh
miso base prepare --target-version 15.6.1 --target-build 24G90 \
  --sources examples/homebrew-mirrors.json --output prepared-software
miso base prepare --target-version 15.6.1 --target-build 24G90 \
  --sources examples/homebrew-mirrors.json --cache prepared-software --output replayed-software
```

The source mapping is optional. Use `--config` for package selections and
`--bundler-version` for an exact Bundler release. Cache replay requires the same
configuration and never falls back to network access. `--resolved-formulae` and
`--resolved-bottles` together import previously resolved core inputs; other software
is still resolved online. Keep the whole output directory for replay.
`preparation.json` records selected versions and stage receipts. This prepares
software only: target security/settings/CA inputs, trusted known-host keys and a
complete build recipe are still required for `base build`. No installation or
runtime verification is implied.

`base recipe --software prepared-software --template previous-recipe.json
--inputs input-root --output new-recipe` replaces a prior recipe's software stages
while preserving its username, trusted known-host keys and target-specific
security/settings/CA inputs. Both old platform inputs and prepared software must
remain under `input-root`. Preflight rejects target, runtime or guest-agent version
mismatches; it does not read privileged boot policy material or verify a VM.
Unreadable inputs fail without producing a completed recipe. Build with
`base build --source vanilla-bundle --recipe new-recipe/recipe.json --inputs input-root
--output base-bundle` after administrator authorization.

Resolution does not install software or prove runtime compatibility. `base resolve`
resolves core formula requests. `base packages resolve` separately resolves Bundler,
yarn and pnpm against explicit target Ruby, RubyGems, Node and npm versions:

```sh
miso base packages resolve --config base.json --target-version 26.6.2 \
  --target-build 25G83 --ruby-version 4.0.7 --rubygems-version 4.0.20 \
  --node-formula node@24 --node-version 24.21.0 --npm-version 11.19.0 \
  --output resolved-packages
```

Omit npm request versions to follow the upstream stable channel with compatibility
fallback. `--bundler-version` selects an exact Bundler release. Payloads, registry
metadata and `plan.json` are retained; repeating the command with
`--cache resolved-packages` and a new output directory replays without network
access. Missing cached inputs fail instead of falling back to the network. Install
with `base packages install --plan resolved-packages/plan.json --inputs resolved-packages`
and the usual `--source` and `--output` options; installation checks actual target
runtime versions before invoking package managers.

Resolve Homebrew bootstrap sources and portable Ruby with:

```sh
miso base bootstrap resolve --target-version 15.6.1 --target-build 24G90 \
  --sources examples/homebrew-mirrors.json --output bootstrap-inputs
```

Omit `--sources` to use upstream repositories. `--homebrew-version` selects an exact stable
tag; otherwise candidates are checked newest first against both Homebrew's macOS
minimum and its portable Ruby executable. Compatibility probes and payloads are
preserved for replay; searches are bounded to 256 tags and eight distinct Ruby payloads.
Source mappings change transport repositories, not upstream identities or versions.
Forks need not advertise every tag: pinned objects are verified before checkout.
`--core-revision` pins the core checkout when pairing it with preserved bottle
inputs. A full Base recipe rejects mismatched formula sources before construction.
Use `--cache bootstrap-inputs` with a new output directory for network-free replay.
The resulting directory is accepted by `base bootstrap --archive`; input resolution
does not prove installation or runtime compatibility.

`base taps resolve` accepts the same target, source mapping, cache and output options,
plus `--config` for package requests. It preserves formula history and checks the
selected arm64 executable's minimum macOS version. Unknown formula layouts fail
closed. The resulting `plan.json` and directory are accepted by `base taps install
--plan ... --inputs ...`. Older targets may use the original `cirruslabs/cli` tap;
its source repository can also be mapped with `cirruslabs/homebrew-cli`.

`additionalRubyVersions` is an explicit compatibility list and can be changed or emptied.
Versioned formula names such as `node@24` constrain the release line; use `node`
to select the newest compatible upstream line instead.

Archive specifications contain `schemaVersion: 1`, a `target` with `version` and
`build`, and `resources`: objects with `name`, local `path`, and optional `origin`.
Archives copy the actual inputs and preserve modes, relative links and digests;
verification is network-free and works after moving the archive. An archive of
selected software inputs is not a complete macOS/Base reconstruction kit.
Keep private input archives separately from disposable build intermediates.

`base build` replays a verified recipe from a fresh, never-booted Vanilla bundle.
It runs bounded native stages, retains journals, validates each candidate, and
removes successful execution views and superseded images unless
`--keep-intermediates` is set. Failed stages are not resumed. Runtime and boot
validation remain separate from offline completion.

```sh
sudo miso base build --source vanilla/bundle --recipe base-recipe.json \
  --inputs /path/to/inputs --output new-base
```

Recipes contain `schemaVersion: 1`, `target`, `username`, and ordered `steps`:
`static`, `bootstrap`, `bottles`, `ruby`, `packages`, `taps`, `gcm`, `security`,
`settings`, `certificates`. Each step binds `files` with relative paths, byte counts
and SHA-256 hashes, and `directories` relative to `--inputs`. Bottle steps also
select `formulae`. Archive and resolution records name `archive.json` and
`resolution.json`. Final cleanup is derived from the verified package and CA plans.
This replay interface consumes supplied inputs; it does not run online resolvers.

The explicit Base security stage reduces SIP protections and configures automation
permissions. It is not applied by the Vanilla restore command. Security, settings,
CA installation and cleanup are also exposed as individual `base` subcommands.
On macOS 26, a security plan may include `captureReminder` with `schemaVersion: 1`,
the target `replaydSHA256`, and an ISO-8601 `expiresAt`. This defers capture reminders
for the already-authorized SSH client until that date; it does not grant access.
Other macOS families require separate validation before using this policy.

`base static` requires a completed never-booted bundle, the Actions Runner release
metadata and matching arm64 archive, and a GitHub known-hosts file. It clones the
bundle, writes the static user/service payloads, and verifies them after read-only
reattachment. Its output remains explicitly incomplete Base, without runtime
acceptance. All construction must use a local APFS workspace; slow external
volumes are suitable for input archives, not working images.

`base bootstrap --source bundle --archive archived-inputs --output new-stage`
installs the archive's `homebrew-sources` resource on a clone. It requires root and
includes bounded guest execution controls and detached payload verification.
On the validated 26A428 host, the 26A434 target also uses a temporary copied
execution view because launching its original System executables is rejected.
Each copied executable is authenticated against its Apple signature before its
signature is replaced locally without entitlements; both hashes are recorded.
The image's original executables and the host security settings remain unchanged.
The temporary execution view is not part of the exported bundle. This experimental
stage does not install the complete Base package set or prove VM bootability.
Use only trusted package inputs; a chroot is not a virtual-machine security boundary.

`base bottles download --resolution resolved --output bottle-directory` downloads
the resolved dependency closure and verifies its digests, OCI indexes and layouts.
`--cache bottle-directory` is strict offline replay. `--reuse stopped-download`
reuses verified completed files from the same resolution and downloads missing pairs;
it does not modify the previous output. Add `--formula name` to select a closure.

For developer formulae that require Xcode, `base resolve --xcode-config xcode.json`
records an explicit target prerequisite and retains it during bottle validation.
`xcode install-bottles` verifies that the installed, selected Xcode matches it before
using the existing offline bottle installer. It preserves the completed Base layer
and runs post-install methods only for newly installed formulae, preserving existing
Base configuration such as its certificate bundle. CLT-only resolution remains the
default and rejects runtime Xcode requirements.

`base bottles verify --resolution resolved --bottles bottle-directory` validates
resolved formula sources and local `<name>.tar.gz` / `<name>.tar.index.json` inputs
without administrator privileges. Add `--formula name` to select a dependency closure.
`base bottles install` accepts the same inputs plus `--source bundle --output new-stage`
and requires root. It installs local bottles with target Homebrew, denies network
access, audits exact versions and verifies the detached payload. The verified core
snapshot is explicitly trusted inside the target, including when sourced from a fork.
Post-install hooks
are deferred unless `--post-install` is supplied. That experimental option invokes
upstream hook methods under the same guest restrictions, then checks target tools,
dependencies and linkage. This remains incomplete Base without VM runtime acceptance.

`base ruby resolve --resolution resolved --bottles bottle-directory --output ruby-sources`
selects the newest stable Ruby known to the target's verified ruby-build bottle,
or `rubyVersion` from `--config`. It resolves `additionalRubyVersions` too,
selects a compatible resolved OpenSSL formula or a vendored source, and downloads
checksum-bound source archives. Unsupported definition syntax fails closed.
`--cache ruby-sources` replays without network access; retain the core resolution,
bottles and source directory for reproducibility. Source selection does not prove
compiler, SDK or runtime compatibility; the target build must still pass.

`base ruby verify --plan ruby-sources/plan.json --inputs ruby-sources` verifies a resolved
Ruby build plan and local source digests. `base ruby install` adds `--source bundle
--output new-stage` and requires root. The plan selects exact Ruby versions,
source file records, an OpenSSL formula (or vendored source), a default version and
1–8 compilation jobs. Builds use the target CLT/SDK with explicit target parameters
and no network access. Extension, default-shim and detached payload checks do not
replace a VM boot test.

`base packages runtimes --resolution resolved --bottles bottle-directory
--node-formula node@24 --ruby-plan ruby-sources/plan.json --ruby-inputs ruby-sources
--output runtime-inputs` inspects Node, npm and RubyGems versions without executing
archive contents. This inspection is included in `base prepare`.

`base packages verify --plan packages.json --inputs source-directory` validates
resolved Bundler/npm metadata and local payloads. `base packages install` adds
`--source bundle --output new-stage`, requires root and a matching installed Ruby,
and uses offline package-manager execution. It checks installed versions, yarn/pnpm
offline controls and detached payloads. Package selection is explicit at this stage.

`base gcm resolve --target-version 27.0 --target-build 26A428 --output gcm-sources`
downloads the current ARM64 credential manager cask snapshot, immutable recipe and
checksum-bound package. Declared macOS minimums are checked; unknown requirements
fail closed. `--package-version` must match the snapshot; `--cache gcm-sources`
replays a retained snapshot offline, including an older release. This does not
discover arbitrary historical versions or prove runtime compatibility. Use
`base gcm inspect --plan gcm-sources/plan.json --inputs gcm-sources --output inspection`
for package/binary signature and payload checks without executing package scripts.

`base runner resolve --target-version 15.6.1 --target-build 24G90 --output runner-sources`
preserves the latest stable Actions Runner release, or `--package-version`, with
its ARM64 archive and upstream checksum. Runner and bundled Node executable
deployment targets must support the target macOS. `--cache runner-sources` replays
offline. Unsupported releases fail closed; historical fallback is explicit.
This does not register a runner or prove runtime compatibility. The preserved
archive and `release.json` are inputs to `base static`.

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
