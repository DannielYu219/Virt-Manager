#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
TOOLS_ISO="$PROJECT_DIR/Resources/WoA/utm-guest-tools-0.1.275.iso"
[[ -f "$TOOLS_ISO" ]] || { echo "Missing bundled Guest Tools ISO: $TOOLS_ISO" >&2; exit 1; }
[[ "$(stat -f %z "$TOOLS_ISO")" == 143935488 ]] || { echo "Invalid Guest Tools ISO size" >&2; exit 1; }
(cd "$PROJECT_DIR/Resources/WoA" && shasum -a 256 -c SHA256SUMS)
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PROJECT_DIR/artifacts/Virt Manager.app"
UTM_APP="${UTM_APP:-/Applications/UTM.app}"
UTM_CONTENTS="$UTM_APP/Contents"
UTM_FRAMEWORKS="$UTM_CONTENTS/Frameworks"
UTM_RESOURCES="$UTM_CONTENTS/Resources"

[[ -d "$UTM_FRAMEWORKS" ]] || { echo "UTM.app not found at $UTM_APP; install UTM 5.0.8 to build the bundled WoA runtime." >&2; exit 1; }
UTM_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$UTM_CONTENTS/Info.plist")
[[ "$UTM_VERSION" == "5.0.8" ]] || { echo "Expected UTM 5.0.8 runtime, found $UTM_VERSION." >&2; exit 1; }

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/WoA/qemu" \
  "$APP/Contents/Resources/WoA/vulkan/icd.d" "$APP/Contents/Frameworks" "$APP/Contents/Helpers"
cp "$BIN_DIR/VirtManager" "$APP/Contents/MacOS/VirtManager"
/usr/libexec/PlistBuddy -c 'Print' "$PROJECT_DIR/Resources/Info.plist" >/dev/null
cp "$PROJECT_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/VirtManager.icns" "$APP/Contents/Resources/VirtManager.icns"

# UTM's published QEMU is Apache-2.0; keep its license and preserve framework directory layouts.
FRAMEWORKS=(
  qemu-aarch64-softmmu qemu-img swtpm.0 spice-client-glib-2.0.8
  epoxy.0 gio-2.0.0 glib-2.0.0 gmodule-2.0.0 gobject-2.0.0
  jpeg.62 pixman-1.0 slirp.0 spice-server.1 usb-1.0.0 usbredirparser.1 usbredirhost.1
  virglrenderer.1 zstd.1 crypto.1.1 ssl.1.1 intl.8 iconv.2 ffi.8
  json-glib-1.0.0 soup-3.0.0 phodav-3.0.0
  gstreamer-1.0.0 gstapp-1.0.0 gstaudio-1.0.0 gstbase-1.0.0 gstvideo-1.0.0 gsttag-1.0.0 opus.0
  vulkan.1 vulkan_kosmickrisp MoltenVK EGL GLESv2
  D3DMetal d3dmetal-native dxmt-native
)
for name in "${FRAMEWORKS[@]}"; do
  source="$UTM_FRAMEWORKS/$name.framework"
  [[ -d "$source" ]] || { echo "UTM framework missing: $source" >&2; exit 1; }
  ditto "$source" "$APP/Contents/Frameworks/$name.framework"
done

# Pinned UTM 5.0.8 defaults custom EDID timings to 75 Hz; ship selectable 60/120 Hz binaries.
QEMU_BINARY="$APP/Contents/Frameworks/qemu-aarch64-softmmu.framework/Versions/A/qemu-aarch64-softmmu"
QEMU_BINARY_120="${QEMU_BINARY}-120"
cp "$QEMU_BINARY" "$QEMU_BINARY_120"
python3 "$PROJECT_DIR/Tools/utm-qemu-launcher/patch-edid-refresh.py" "$QEMU_BINARY" --hz 60
python3 "$PROJECT_DIR/Tools/utm-qemu-launcher/patch-edid-refresh.py" "$QEMU_BINARY_120" --hz 120
cp "$PROJECT_DIR/Tools/utm-qemu-launcher/patch-edid-refresh.py" "$APP/Contents/Resources/WoA/patch-edid-refresh.py"
# QEMU ROM/UEFI data (only ARM firmware and device ROMs needed by the WoA machine).
for name in edk2-aarch64-code.fd edk2-aarch64-secure-code.fd edk2-arm-vars.fd edk2-arm-secure-vars.fd edk2-licenses.txt efi-virtio.rom vgabios-ramfb.bin; do
  [[ -f "$UTM_RESOURCES/qemu/$name" ]] || { echo "UTM QEMU resource missing: $name" >&2; exit 1; }
  cp "$UTM_RESOURCES/qemu/$name" "$APP/Contents/Resources/WoA/qemu/$name"
done
cp "$UTM_RESOURCES/vulkan/icd.d/MoltenVK_icd.json" "$APP/Contents/Resources/WoA/vulkan/icd.d/MoltenVK_icd.json"
cp "$UTM_RESOURCES/../Frameworks/../XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMURenderServer.app/Contents/MacOS/QEMURenderServer" \
  "$APP/Contents/Helpers/QEMURenderServer"
cp "$PROJECT_DIR/Tools/utm-qemu-launcher/UTM-APACHE-2.0.txt" "$APP/Contents/Resources/WoA/UTM-APACHE-2.0.txt"
cp "$TOOLS_ISO" "$APP/Contents/Resources/WoA/utm-guest-tools-0.1.275.iso"
cp "$PROJECT_DIR/Resources/WoA/SHA256SUMS" "$APP/Contents/Resources/WoA/SHA256SUMS"
cp "$PROJECT_DIR/Resources/WoA/SOURCE.md" "$APP/Contents/Resources/WoA/GuestTools-SOURCE.md"
cp "$PROJECT_DIR/Tools/utm-qemu-launcher/main.c" "$APP/Contents/Resources/WoA/utm-qemu-launcher.c"

HELPER="$APP/Contents/Helpers/utm-qemu-launcher"
sh "$PROJECT_DIR/Tools/utm-qemu-launcher/build.sh" "$HELPER" >/dev/null
codesign --force --sign - --entitlements "$PROJECT_DIR/helper-entitlements.plist" "$HELPER"
# Render server moved out of UTM's nested helper bundle: replace its old relative loader path.
install_name_tool -rpath '@executable_path/../../../../../../../Frameworks' '@executable_path/../Frameworks' "$APP/Contents/Helpers/QEMURenderServer"
# Render server uses the same UTM graphics helper code, but our own app signature.
codesign --force --sign - --entitlements "$PROJECT_DIR/helper-entitlements.plist" "$APP/Contents/Helpers/QEMURenderServer"
# Sign the additional standalone Mach-O before sealing its containing framework.
codesign --force --sign - "$QEMU_BINARY_120"
# Re-sign nested frameworks deepest-first, then the app. The user-facing bundle owns every executable.
find "$APP/Contents/Frameworks" -depth -name '*.framework' -type d -exec codesign --force --sign - {} \;
codesign --force --sign - --entitlements "$PROJECT_DIR/entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"
printf '\nBuilt: %s\nBundled WoA runtime: UTM %s, %s\n' "$APP" "$UTM_VERSION" "$(du -sh "$APP/Contents/Frameworks" | awk '{print $1}') frameworks"
