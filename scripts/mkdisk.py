#!/usr/bin/env python3
"""Create an empty DOS hard disk image: MBR + one FAT16 partition.

    scripts/mkdisk.py IMAGE [SIZE_MB]

The partition starts at sector 63 (byte offset 32256) with a 16-head,
63-sector geometry, which DOS, FreeDOS and QEMU all agree on. The FAT16 file
system is created with mtools (mformat), so no root is needed. Default size
is 32 MB (rounded to whole cylinders).

Use the image with mtools via the partition offset, e.g.
    mdir  -i IMAGE@@32256 ::/
    mcopy -i IMAGE@@32256 file.txt ::/
"""
import struct
import subprocess
import sys

HEADS, SPT, START = 16, 63, 63          # geometry and first partition sector
OFFSET = START * 512                    # 32256


def chs(lba):
    cyl, rem = divmod(lba, HEADS * SPT)
    head, sect = divmod(rem, SPT)
    return bytes([head, ((cyl >> 2) & 0xC0) | (sect + 1), cyl & 0xFF])


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if len(sys.argv) > 1 else 2
    image = sys.argv[1]
    size_mb = int(sys.argv[2]) if len(sys.argv) > 2 else 32
    cyls = min(1024, (size_mb * 1024 * 1024) // (HEADS * SPT * 512))
    total = cyls * HEADS * SPT
    count = total - START
    if count * 512 > 2047 * 1024 * 1024:
        sys.exit("too big for FAT16")

    mbr = bytearray(512)
    entry = (bytes([0x80]) + chs(START) +
             bytes([0x06 if count * 512 >= 32 * 1024 * 1024 else 0x04]) +
             chs(total - 1) + struct.pack("<II", START, count))
    mbr[446:462] = entry
    mbr[510:512] = b"\x55\xaa"
    with open(image, "wb") as f:
        f.write(mbr)
        f.truncate(total * 512)

    subprocess.run(["mformat", "-i", f"{image}@@{OFFSET}", "-T", str(count),
                    "-h", str(HEADS), "-s", str(SPT), "-H", str(START),
                    "-v", "WWIVFOSS", "::"], check=True)
    print(f"{image}: {total * 512 // (1024 * 1024)} MB, FAT16 partition at offset {OFFSET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
