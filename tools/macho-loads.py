#!/usr/bin/env python3
"""List a Mach-O's dylib load commands without otool/xcrun (works with the Xcode license unaccepted).

usage: macho-loads.py BIN                -> "KIND path" per dylib load (fat: "# slice cpu=N" headers)
       macho-loads.py BIN --count NAME   -> number of loads matching NAME (every slice must agree)
       macho-loads.py BIN --uuid         -> LC_UUID per slice, space separated

NAME matches a load whose basename is NAME or NAME.dylib; a NAME containing '/' must equal the path.
KIND: LOAD, WEAK, REEXPORT, LAZY, UPWARD.
exit: 0 ok; 2 unreadable / not Mach-O / corrupt / usage. Callers must treat 2 as fatal, never as 'absent'.
"""
import struct
import sys

LC_REQ_DYLD = 0x80000000
KINDS = {0x0c: 'LOAD', 0x18 | LC_REQ_DYLD: 'WEAK', 0x1f | LC_REQ_DYLD: 'REEXPORT',
         0x20: 'LAZY', 0x23 | LC_REQ_DYLD: 'UPWARD'}
LC_UUID = 0x1b
FAT = {0xcafebabe: False, 0xcafebabf: True}  # value: 64-bit fat_arch entries
THIN = {0xfeedfacf: 32, 0xfeedface: 28}      # little-endian magic -> header size


class Bad(Exception):
    pass


def unpack(fmt, d, off):
    if off < 0 or off + struct.calcsize(fmt) > len(d):
        raise Bad(f'truncated at {off:#x}')
    return struct.unpack_from(fmt, d, off)


def slices(d):
    magic = unpack('>I', d, 0)[0]
    if magic not in FAT:
        return [0]
    wide = FAT[magic]
    n = unpack('>I', d, 4)[0]
    if not 0 < n <= 32:
        raise Bad(f'implausible fat arch count {n}')
    out = []
    for i in range(n):
        if wide:
            _, _, off, size, _, _ = unpack('>iiQQII', d, 8 + i * 32)
        else:
            _, _, off, size, _ = unpack('>iiIII', d, 8 + i * 20)
        if off + size > len(d):
            raise Bad('fat slice extends past EOF')
        out.append(off)
    return out


def parse(d, base):
    magic = unpack('<I', d, base)[0]
    if magic not in THIN:
        raise Bad(f'not a little-endian Mach-O (magic {magic:#x})')
    cpu = unpack('<i', d, base + 4)[0]
    ncmds, sizeofcmds = unpack('<II', d, base + 16)
    off = base + THIN[magic]
    end = off + sizeofcmds
    if end > len(d):
        raise Bad('load commands extend past EOF')
    loads, uuid = [], None
    for _ in range(ncmds):
        cmd, size = unpack('<II', d, off)
        if size < 8 or off + size > end:
            raise Bad('corrupt load command table')
        if cmd in KINDS:
            name_off = unpack('<I', d, off + 8)[0]
            if not 24 <= name_off < size:
                raise Bad('bad dylib name offset')
            raw = d[off + name_off:off + size].split(b'\0', 1)[0]
            loads.append((KINDS[cmd], raw.decode('utf-8', 'surrogateescape')))
        elif cmd == LC_UUID:
            if size < 24:
                raise Bad('short LC_UUID')
            uuid = d[off + 8:off + 24].hex().upper()
        off += size
    return cpu, loads, uuid


def matches(path, name):
    if '/' in name:
        return path == name
    base = path.rsplit('/', 1)[-1]
    return base in (name, name + '.dylib')


def main(argv):
    if len(argv) not in (2, 3, 4) or (len(argv) == 3 and argv[2] != '--uuid') \
            or (len(argv) == 4 and argv[2] != '--count'):
        print(__doc__.strip().split('\n\n')[1], file=sys.stderr)
        return 2
    try:
        with open(argv[1], 'rb') as f:
            data = f.read()
        parsed = [parse(data, base) for base in slices(data)]
    except (OSError, Bad, struct.error, UnicodeError) as e:
        print(f'macho-loads: {argv[1]}: {e}', file=sys.stderr)
        return 2
    if len(argv) == 4:
        counts = {sum(matches(p, argv[3]) for _, p in loads) for _, loads, _ in parsed}
        if len(counts) != 1:
            print(f'macho-loads: slices disagree on {argv[3]}: {sorted(counts)}', file=sys.stderr)
            return 2
        print(counts.pop())
    elif len(argv) == 3:
        if any(u is None for _, _, u in parsed):
            print(f'macho-loads: {argv[1]}: no LC_UUID', file=sys.stderr)
            return 2
        print(' '.join(u for _, _, u in parsed))
    else:
        for cpu, loads, _ in parsed:
            if len(parsed) > 1:
                print(f'# slice cpu={cpu}')
            for kind, path in loads:
                print(kind, path)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
