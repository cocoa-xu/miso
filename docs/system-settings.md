# Optional system settings

MISO configures the offline guest, never the host. It preserves Apple executables
and signatures. Missing services are reported as `not-present` and skipped.
Other errors fail the stage with the affected service or setting.

Use `miso xcode defaults --config xcode.json --profile profile.yaml`:

```yaml
preset: slim
system:
  features:
    messages: unchanged
  services:
    com.apple.photoanalysisd: unchanged
  settings:
    sessionRestore: true
    reduceMotion: false
    reduceTransparency: false
```

`preset: slim` inherits the complete Slim profile, including iOS/watchOS runtimes,
Intel trimming, compression, cleanup and sparse disk reclamation. Without a preset,
only the supplied system options change. Per-service entries override their group.

Service states are `disabled`, `enabled`, or `unchanged`. The last preserves the
parent image's state; it does not undo an earlier disable. Run
`miso bundle system-services` to list every group and service label. Custom service
labels can also be configured individually; MISO discovers their domains from the
target image's launchd definitions rather than using the host's service list.

| Feature group | Slim |
| --- | --- |
| `advertising` | Disabled: advertisements, Tips and promotions |
| `siri`, `appleIntelligence` | Disabled: personal assistant and generative features |
| `telemetryUpload` | Disabled: diagnostic submission; local crash reporting retained |
| `photoAnalysis` | Disabled: background photo/media analysis |
| `cloudSync`, `messages`, `continuity` | Disabled: personal cloud sync, messaging and device handoff |
| `home`, `personalApps` | Disabled: HomeKit, personal app sync and subscription services |

| Boolean setting | Slim |
| --- | --- |
| `automaticOSUpdates`, `automaticAppUpdates` | `false`: automatic downloads/installations |
| `securityDataUpdates` | `true`: security configuration and system data updates |
| `spotlightIndexing`, `automaticBackups` | `false` |
| `sessionRestore` | `false`: reopen applications/windows after login |
| `reduceMotion`, `reduceTransparency` | Unchanged |

Authentication, code-signing trust, networking, SSH/VNC, local crash reports,
development automation, WebKit debugging and shared asset services are retained
by the Slim preset. Disabling optional features can affect apps that use them.

To apply settings to an existing native bundle, put only `features`, `services`
and `settings` in `system.yaml`, then run:

```sh
sudo miso bundle optimize bundle --system-profile system.yaml --output optimized
```

This creates a separate offline clone. Spotlight configuration requires a prepared
Base image. A construction receipt is stored inside the guest at
`/Library/Application Support/MISO/system-policy.json`.

After booting a disposable acceptance clone, run inside that guest:

```sh
sudo miso bundle verify-system-policy --output /tmp/system-policy-verification
```

Repeat after reboot and alongside real compiler, simulator and remote-access
checks. The command checks launchd overrides/running services, retained preference
values and Spotlight status; it does not replace application-level acceptance.

Service selection draws on [mac-os-debloat](https://github.com/OleksandrKrupko/mac-os-debloat)
([MIT notice](../ThirdPartyLicenses/mac-os-debloat.txt)); VM settings were informed
by [osx-optimizer](https://github.com/sickcodes/osx-optimizer). Execution is implemented
independently in Swift; neither tool is installed or run.
