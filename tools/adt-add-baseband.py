#!/usr/bin/env python3
"""Add a minimal /device-tree/baseband node to a device tree blob (ADT).

  python3 tools/adt-add-baseband.py IN.adt OUT.adt

launchd starts the cellular CommCenter only when the device tree has a node named "baseband"
(com.apple.CommCenter _LimitLoadToDeviceTree = baseband; the -noncellular job is limited FROM it).
The node only carries name, device_type, compatible and a phandle; no IMEI, no wiring.
The root node's children end exactly at the end of the file (checked), so the new node is appended
and the root's child count is raised by one.
"""
import struct, sys

def prop(name, data):
    pad = (-len(data)) & 3
    return name.encode().ljust(32, b'\0') + struct.pack('<I', len(data)) + data + b'\0' * pad

def cstr(s):
    return s.encode() + b'\0'

def skip(d, off):
    n, c = struct.unpack_from('<II', d, off)
    off += 8
    for _ in range(n):
        ln = struct.unpack_from('<I', d, off + 32)[0] & 0x7fffffff
        off += 36 + ((ln + 3) & ~3)
    for _ in range(c):
        off = skip(d, off)
    return off

def main():
    d = bytearray(open(sys.argv[1], 'rb').read())
    if skip(bytes(d), 0) != len(d):
        sys.exit('device tree does not end where the root node ends; refusing')
    n, c = struct.unpack_from('<II', d, 0)
    node = struct.pack('<II', 4, 0)
    for k, v in (('AAPL,phandle', struct.pack('<I', 0x7f10)), ('name', cstr('baseband')),
                 ('device_type', cstr('baseband')), ('compatible', cstr('baseband,n41'))):
        node += prop(k, v)
    node = struct.pack('<II', 4, 0) + node[8:]
    struct.pack_into('<I', d, 4, c + 1)
    d += node
    open(sys.argv[2], 'wb').write(d)
    assert skip(bytes(d), 0) == len(d)
    print('added baseband node;', len(d), 'bytes')

main()
