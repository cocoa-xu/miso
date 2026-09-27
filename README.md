# miso

Native tools for offline macOS system images. Swift 6, Apple silicon, macOS 15 or later.

This is an in-progress native migration. The commands below work without starting
a virtual machine. Complete restore, Base provisioning and upgrade execution are
not yet exposed by this package. A recognized profile is not a claim of native
end-to-end validation.

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

`ipsw extract` copies one regular archive member to a new file and requires its
SHA-256. `upgrade plan` performs a three-way Data-template comparison for an exact
recognized source/target pair. It rejects conflicts and never modifies an image.
Use each command's `--help` for arguments.

Configuration defaults use `admin/admin`, disable FileVault, and request SSH/VNC.
They are intended for isolated test systems; change credentials before exposing a
guest to an untrusted network. Rosetta and ARM Linux translation are opt-in.
Validating a configuration does not apply it to an image.

`disk layout` calculates a GPT layout. `disk seed` copies a digest-checked raw APFS
System container into a new sparse GPT image with reserved iSC and Recovery
partitions. A seed is not a bootable or provisioned system. `decode pbze` decodes
bounded component payloads without invoking an external interpreter.

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
