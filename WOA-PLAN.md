# WoA implementation status

The app now embeds the WoA runtime from UTM 5.0.8 at **build time**; the installed app does not need a separate UTM.app. See the README for the build, UI workflow and GPU modes.

## Embedded runtime

- `qemu-aarch64-softmmu.framework`, `qemu-img.framework`, `swtpm.0.framework`, `spice-client-glib-2.0.8.framework` and their transitive runtime dependencies are copied into the app.
- `utm-qemu-launcher` provides process entry points for QEMU, swtpm and qemu-img. The framework binaries are dynamic libraries rather than standalone executables.
- UEFI code/variable images, Vulkan ICD manifest, QEMURenderServer and the UTM framework set are embedded. `install_name_tool` adds app-relative `@executable_path/../Frameworks` paths, then binaries are re-signed.
- The framework dependency list is in `scripts/build.sh`. The UTM 5.0.8 build source must be at `/Applications/UTM.app`; only the build machine needs it. No UTM path is consulted at runtime.
- Third-party licenses are kept inside the copied frameworks; the QEMU Apache-2.0 license is included at `Contents/Resources/WoA/UTM-APACHE-2.0.txt`.

## Code map

- `Core/WoAConfiguration.swift`: persisted VM options.
- `Core/WoABackend.swift`: app-local runtime discovery, GPU capability probe and launch arguments.
- `Core/WoAPackage.swift`: package-local firmware and TPM state.
- `Core/WoARuntime.swift`: QEMU/swtpm lifecycle, QMP guest power and pause/resume.
- Guest Tools 0.1.275 is included in `Resources/WoA` and copied into the app at build time; the downloader UI and network downloader have been removed. QEMU attaches the bundled ISO by default.
- `Display/WoASpiceDisplay.swift`: SPICE display client and AppKit guest view.
- `Sources/CSpiceBridge`: runtime-loaded spice-glib API, 2D surface, IOSurface GL scanout, input and clipboard bridge.
- `Tools/utm-qemu-launcher`: small process host for framework QEMU/swtpm entry points.

## Verification boundary

Current UTM-compatible runtime: 5.0.8 is embedded in the app. The installed app does not need UTM.app. Verified with `/Applications/UTM.app` temporarily renamed: self-check passed; Kali arm64 ISO booted to GRUB under both software and Venus modes, QMP/SPICE connected, frame capture/input/force stop completed; Venus/Neptune options were accepted without GL timeout warnings. The DirectX probe used a non-Windows guest and only verifies that QEMU accepts the Neptune configuration and SPICE remains responsive; it does not verify DirectX rendering.

- Tests ran on macOS 27.0 / Apple Silicon. Windows guest, drivers, 3D rendering, clipboard agent, audio and complete Windows input mapping remain unverified.

Build uses a development ad-hoc signature. Distribution requires a valid developer signing identity and notarization, plus a complete audit of bundled UTM/transitive framework licensing.


## Recovery update — 2026-11-07

Current repair details and evidence are maintained in RECOVERY-STATUS.md. Real installed Windows snapshot boots have now been performed separately for DirectX and Venus, reaching 3024×1964 lock-screen output with agent connection. The previous statement that no Windows guest had been tested describes the earlier baseline only. Full interactive acceptance remains pending.

The repair includes Metal pipeline/uniform correction, retained-frame GL/software handoff, bounded C frame copies and token lifetimes, absolute/relative input separation, window chrome restoration, and clipboard signal ABI fixes. Windows folder sharing remains explicitly unavailable until SPICE WebDAV exists end-to-end; legacy 9p launch arguments have been removed. Unsafe live network replacement is disabled. Host GPU tests and ASan/UBSan bridge regressions are available, alongside package self-checks.
