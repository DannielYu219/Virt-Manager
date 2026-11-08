# Virtualization.framework VM Manager

A macOS virtual-machine manager built with SwiftUI, AppKit, and Apple Virtualization.framework. Minimum macOS 14, Apple Silicon target.

## Build

```sh
bash scripts/build.sh
open "artifacts/Virt Manager.app"
```

The Guest Tools ISO (`Resources/WoA/utm-guest-tools-0.1.275.iso`, 143,935,488 bytes) is not stored in git because it exceeds GitHub's 100 MB file limit. Download it from the matching GitHub Release assets into `Resources/WoA/` before building. `build.sh` checks its size and SHA-256 against `Resources/WoA/SHA256SUMS`.

The build requires Xcode's Swift toolchain and **UTM 5.0.8 installed at `/Applications/UTM.app` as a build-time source only**. The build copies the UTM ARM64 QEMU engine, its SPICE/GL/Vulkan/DirectX runtime dependencies, TPM executable library, UEFI firmware, and render helper into `Virt Manager.app`. It then rewrites rpaths and signs every embedded executable/framework. **The installed app has no runtime dependency on UTM.app**; this was verified by temporarily renaming UTM.app while running self-check and WoA probes.

The resulting app is ad-hoc signed locally and has the Hypervisor entitlement. Before distributing, use the developer's Developer ID identity and notarize. UTM's QEMU is Apache-2.0; the license is included under `Contents/Resources/WoA/UTM-APACHE-2.0.txt`. Other bundled UTM components retain their respective licenses in their framework Resources folders. Review and preserve third-party notices for distribution.

## Included features

- Local VM library; create, edit, open, relocate and trash `.virtvm` packages.
- Linux: EFI, virtio display/storage, NAT, audio, directory sharing, Rosetta, SPICE-agent clipboard.
- macOS: Virtualization.framework IPSW installation with persistent machine identity.
- Windows ARM64: bundled UTM 5.0.8 QEMU/HVF, secure UEFI, swtpm TPM 2.0, NVMe, USB, SPICE display/input/clipboard, Venus and DirectX paths, bundled Guest Tools 0.1.275.
- Start, pause where safe, resume, guest power-button shutdown and confirmed force stop.
- Independent guest windows and a single-window borderless immersive mode. The library stays windowed; multiple guests may run simultaneously.
- Emergency WoA stop sends SIGKILL directly, without waiting for QMP; native AVF guests use Virtualization.framework stop().

## Windows on ARM

Choose **Windows ARM64**, select a Windows 11 ARM64 ISO, and create the VM. The complete guest runtime is embedded in this app; UTM does not need to be installed on the user's Mac. Guest Tools 0.1.275 is bundled and attached by default; no network download is required. The build verifies its 143,935,488-byte size and publisher SHA-256 from Resources/WoA/SHA256SUMS. On Windows, run `utm-guest-tools.exe` from the attached optical drive to install network/storage, SPICE agent and display drivers. This enables guest clipboard and dynamic resize. Eject the Windows installer ISO after installation and shutdown.

Graphics modes:
- **2D compatibility**: virtio-ramfb / viogpudo.
- **Venus Vulkan (experimental)**: virtio-ramfb-gl with Venus and the bundled MoltenVK/KosmicKrisp host path.
- **DirectX (experimental)**: Neptune virtio-gpu driver with the bundled DXMT/D3DMetal path. D3DMetal is required for DirectX 12.

The VM pauses only in 2D mode. 3D acceleration is experimental and compatibility varies by guest driver and application. The build's bundled UTM 5.0.8 runtime supports Venus and Neptune. The built app was tested with `/Applications/UTM.app` temporarily renamed: self-check and Kali arm64 ISO probes passed in 2D, Venus and DirectX configurations. This establishes that UTM is not needed at runtime and the embedded QEMU/SPICE/GPU options initialize. It does **not** establish real Windows installation or DirectX rendering: those early tests used Kali and did not establish Windows compatibility. The 2026-11-07 recovery session subsequently booted the existing Windows guest in disposable snapshot mode; see RECOVERY-STATUS.md for current evidence. Guest Tools, Windows SPICE clipboard/resize, 3D games, audio and full input mappings remain unverified.

## Linux clipboard

Enable **Bidirectional clipboard** and install/run `spice-vdagent` in the guest. Debian/Ubuntu: `sudo apt install spice-vdagent`, then log out and back in. Uses the Virtualization.framework SPICE agent port, without host clipboard polling.

## Package format

VM packages are `.virtvm` directories containing an XML `config.plist`, disk, firmware state and guest identity. A package can be moved or opened on another host. Installer ISOs and shared folders remain external references. Windows TPM state is inside the package because it contains guest security data.

## Verify

```sh
"artifacts/Virt Manager.app/Contents/MacOS/VirtManager" --self-check
codesign --verify --deep --strict "artifacts/Virt Manager.app"
```

A developer probe can boot a local test ISO and save SPICE frames:

```sh
"artifacts/Virt Manager.app/Contents/MacOS/VirtManager" \
  --woa-probe /path/to/arm64.iso /tmp/woa-probe venus
```

The probe does not install Windows. It checks only the selected UTM/QEMU runtime and supplied ISO.

## Windows, fullscreen and concurrency

Each VM has a separate display window. Its green button or ⌘⌥Return enters borderless immersive mode on the current screen. The library remains an ordinary window on the original desktop. Multiple guests can run in separate windows. Closing a display hides the window; it does not stop the guest.

The management window provides the confirmed force-stop action; guest display windows do not contain it. WoA force-stop kills the QEMU and TPM processes directly even when QMP is unresponsive; it remains available while another VM operation is pending. Linux/macOS guests are owned by Virtualization.framework and use its force-stop API; the app cannot safely SIGKILL an individual AVF VM process using public APIs.

The SPICE client uses a single dedicated GLib event thread for all guests, with per-session teardown. Software damage is sampled at the configured 60/120 Hz; GL copies are event-driven and retain the last frame while hidden. GPU capability probing runs off the UI thread.

## Display handover corrections (2026-11-07)

The software primary and IOSurface GL scanout now have separate lifetimes: destroying a software primary cannot erase a live GL frame, and disabling GL restores a surviving software primary. The single guest window uses one GPU output (`max_outputs=1`). RAMFB ROM data is bundled, the relocated render-server runpath is corrected, and the D3DMetal framework path is explicitly passed to Neptune. These fixes address concrete host-display defects; verification with an installed Windows guest is still required.

Installed-Windows verification: using copied UEFI/TPM and QEMU `-snapshot` temporary disk writes, the existing Windows 11 guest with Guest Tools reached its lock/login screen through SPICE in DirectX mode. The old Venus-only configuration reproduced failure; enabling Neptune alongside Venus restored the Windows lock screen, because viogpu3d uses the Direct3D path for DWM desktop composition. This does not establish application/game compatibility.

## USB and display timing

WoA settings list eligible host USB devices and save assignments. Selected devices attach through QMP `usb-host` after startup; an opt-in policy attaches eligible devices inserted while this VM is running. macOS may reject devices still owned by a host driver. Attachment errors are reported on the management page. Multiple guests cannot claim the same enumerated device. Physical passthrough has not yet been tested on an external USB device.

The single immersive entry uses the same NSWindow with borderless screen-sized geometry; the management window retains `.fullScreenNone` on its desktop. The guest toolbar is hidden in fullscreen and the exit chord is Command+Option+Shift+Q. Mouse capture releases on loss of focus or Space change.

UTM 5.0.8's QEMU defaults its custom EDID detailed timing to 75000 mHz and exposes no refresh-rate property in that release. The build applies a narrowly guarded ARM64 instruction patch in `qemu_edid_generate` to use 60000 mHz, then re-signs the copied framework. The installed UTM app is untouched. The generated 3024×1964 preferred EDID mode was executed and measured at 59.9991 Hz. Presentation sampling is now 60 Hz; 120 Hz is not claimed.

## High-refresh and color-depth boundary

WoA settings now persist 60 or 120 Hz separately from the GPU mode. The build packages two pinned ARM64 QEMU engines; the selected engine supplies that preferred EDID timing. Direct execution of their EDID generators produced 3024×1964 at 59.9991 Hz and 119.9994 Hz. This establishes timing advertisement, not sustained application frame rate.

10-bit guest output is not currently offered: the Neptune guest driver's `viogpu_vidpn.cpp` enumerates 8-bit channel dynamic ranges and ARGB/ABGR 8-bit source modes. Changing only the host layer or EDID would not produce end-to-end 10-bit output. Driver reference: https://github.com/osy/kvm-guest-drivers-windows/blob/neptune/viogpu/viogpu3d/viogpu_vidpn.cpp .

## Native Metal GL presentation

GL scanouts are now delivered as retained IOSurfaces to an MTKView. A Metal blit copies the shared surface into a private GPU texture; only after that GPU command completes is SPICE gl-draw-done acknowledged. Normal GL presentation does not call IOSurfaceLock, memcpy pixels into CPU memory, create CGImages or poll on a frame timer. A small private-texture ring and event-driven drawing avoid per-frame texture allocation. Software 2D remains a changed-frame 60 Hz fallback; explicit diagnostic screenshots alone read the private GPU texture back via Core Image.

Do not bind the mutable QEMU surface directly to CALayer and acknowledge immediately: Core Animation composition is asynchronous, so the server could overwrite the surface before it is consumed. The private GPU copy provides a completion fence without CPU pixel readback.

Installed Windows snapshot boot through the Metal path reached the login screen at 3024×1964. This verifies real GPU handover, not a measured five-second startup-delay reduction or sustained 120 fps. The confirmed borderless fullscreen controller was not modified by this rendering change.


## Recovery validation (2026-11-07)

See [RECOVERY-STATUS.md](RECOVERY-STATUS.md) for the current repair ledger and explicit interaction-test boundaries. Windows folder sharing is disabled: legacy paths are retained but no 9p/virtiofs device is emitted. SPICE WebDAV is not implemented. Network and EDID refresh-rate changes require shutdown. Live resolution changes require the SPICE guest agent.

The GPU diagnostic runs offscreen on the actual Metal device and does not boot a VM:

```sh
"artifacts/Virt Manager.app/Contents/MacOS/VirtManager" --display-self-check
xcrun clang -std=c11 -Wall -Wextra -Werror -g -fsanitize=address,undefined -I Sources/CSpiceBridge/include Tools/test-spice-bridge.c -framework IOSurface -framework CoreFoundation -o /tmp/test-spice-bridge
/tmp/test-spice-bridge
```

Installed-guest probes use a temporary QEMU snapshot plus copied firmware/TPM, preserve hardware identity, disable network/audio/USB auto-connect and host clipboard integration, and run without foreground windows unless explicitly passed `window`. Lock-screen display is not proof of game compatibility, clipboard round-trip or interactive fullscreen correctness.
