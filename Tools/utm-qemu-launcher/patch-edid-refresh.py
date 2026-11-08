#!/usr/bin/env python3
"""Pinned UTM 5.0.8 ARM64 EDID default: 75000 -> 60000 or 120000 mHz.

UTM's binary has no refresh_rate QOM property. Patch only the two verified
instructions inside qemu_edid_generate, retaining the upstream binary elsewhere.
Fail closed on a different release/layout. Re-signing is done by build.sh.
"""
import argparse
import pathlib
import struct
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary', type=pathlib.Path)
parser.add_argument('refresh_hz', nargs='?', type=int, choices=(60, 120))
parser.add_argument('--hz', type=int, choices=(60, 120))
args = parser.parse_args()
if args.hz is not None and args.refresh_hz is not None and args.hz != args.refresh_hz:
    parser.error('positional refresh rate and --hz disagree')
hz = args.hz if args.hz is not None else (args.refresh_hz or 60)
binary = args.binary.resolve()
# Extract Apple Silicon slice; this app only targets Apple Silicon.
arches = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
if len(arches) > 1:
    subprocess.run(['lipo', str(binary), '-thin', 'arm64', '-output', str(binary) + '.arm64'], check=True)
    pathlib.Path(str(binary) + '.arm64').replace(binary)
data = bytearray(binary.read_bytes())
symbols = subprocess.check_output(['nm', '-arch', 'arm64', str(binary)], text=True)
address = next(int(line.split()[0], 16) for line in symbols.splitlines() if line.endswith(' _qemu_edid_generate'))
# Resolve virtual symbol address to Mach-O file offset using LC_SEGMENT_64.
assert struct.unpack_from('<I', data)[0] == 0xFEEDFACF
ncmds = struct.unpack_from('<I', data, 16)[0]
pos = 32
file_offset = None
for _ in range(ncmds):
    cmd, size = struct.unpack_from('<II', data, pos)
    if cmd == 0x19:
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', data, pos + 24)
        if vmaddr <= address < vmaddr + filesize:
            file_offset = fileoff + address - vmaddr
    pos += size
assert file_offset is not None
old = bytes.fromhex('099f84522900a072')  # mov w9,#0x24f8; movk w9,#1,lsl#16 = 75000
# MOVZ writes bits 0..15; MOVK writes bits 16..31. 120000 needs both halves.
refresh_millihz = hz * 1000
new = struct.pack('<II', 0x52800009 | ((refresh_millihz & 0xFFFF) << 5),
                  0x72A00009 | (((refresh_millihz >> 16) & 0xFFFF) << 5))
start, end = file_offset, file_offset + 160
assert data[start:end].count(old) == 1, 'Unexpected UTM EDID code: refusing patch'
offset = data.index(old, start, end)
data[offset:offset + 8] = new
binary.write_bytes(data)
print(f'Applied pinned ARM64 EDID default: {hz} Hz ({refresh_millihz} mHz)')
