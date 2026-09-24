#!/usr/bin/env python3
"""List a Mach-O's dylib load commands without otool/xcrun (works while the Xcode license is unaccepted).

usage: macho-loads.py BIN               -> "KIND path" per dylib load command
       macho-loads.py BIN --count NAME  -> number of loads whose basename is NAME or NAME.dylib
exit 2: unreadable / not a thin 64-bit Mach-O / corrupt. Callers must treat it as fatal, never as 'absent'.
"""
import struct
import sys

KINDS = {0x0c: 'LOAD', 0x80000018: 'WEAK', 0x8000001f: 'REEXPORT', 0x20: 'LAZY', 0x80000023: 'UPWARD'}


def loads(d):
    magic, _, _, _, ncmds, sizeofcmds = struct.unpack_from('<IiiIII', d, 0)
    if magic != 0xfeedfacf:
        raise ValueError(f'not a thin 64-bit Mach-O (magic {magic:#x})')
    off, end = 32, 32 + sizeofcmds
    if end > len(d):
        raise ValueError('load commands extend past EOF')
    out = []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', d, off)
        if size < 8 or off + size > end:
            raise ValueError('corrupt load command table')
        if cmd in KINDS:
            name_off = struct.unpack_from('<I', d, off + 8)[0]
            if not 24 <= name_off < size:
                raise ValueError('bad dylib name offset')
            name = d[off + name_off:off + size].split(b'\0', 1)[0]
            out.append((KINDS[cmd], name.decode('utf-8', 'surrogateescape')))
        off += size
    return out


def main(argv):
    if len(argv) not in (2, 4) or (len(argv) == 4 and argv[2] != '--count'):
        print(__doc__.strip().split('\n\n')[1], file=sys.stderr)
        return 2
    try:
        with open(argv[1], 'rb') as f:
            found = loads(f.read())
    except (OSError, ValueError, struct.error) as e:
        print(f'macho-loads: {argv[1]}: {e}', file=sys.stderr)
        return 2
    if len(argv) == 4:
        name = argv[3]
        print(sum(p.rsplit('/', 1)[-1] in (name, name + '.dylib') for _, p in found))
    else:
        for kind, path in found:
            print(kind, path)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
