#!/usr/bin/env python3
"""Builds the synthetic containers the inspector tests run against.

The files are deliberately tiny and structurally valid but carry no real
Nintendo content: just enough header, entry table and payload to exercise the
PFS0/HFS0 walker, the truncation and overlap checks, and the three verdicts.
Nothing here is copied from a real game.
"""
import os
import struct
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "build/test-samples"

TITLE_BASE = "0100000000010000"
TITLE_UPDATE = "0100000000010800"
TITLE_DLC = "0100000000021000"


def pfs0(entries):
    """entries: [(name, payload_bytes)] -> bytes"""
    names = b""
    rows = b""
    payload = b""
    offset = 0
    for name, data in entries:
        name_bytes = name.encode() + b"\0"
        rows += struct.pack("<QQII", offset, len(data), len(names), 0)
        names += name_bytes
        payload += data
        offset += len(data)
    header = b"PFS0" + struct.pack("<II", len(entries), len(names)) + b"\0" * 4
    return header + rows + names + payload


def hfs0(entries):
    """entries: [(name, payload_bytes)] -> bytes"""
    names = b""
    rows = b""
    payload = b""
    offset = 0
    for name, data in entries:
        rows += struct.pack("<QQII", offset, len(data), len(names), 0) + b"\0" * 40
        names += name.encode() + b"\0"
        payload += data
        offset += len(data)
    header = b"HFS0" + struct.pack("<II", len(entries), len(names)) + b"\0" * 4
    return header + rows + names + payload


def xci(secure_entries):
    secure = hfs0(secure_entries)
    root = hfs0([("secure", secure)])
    head = bytearray(0x200)
    head[0x100:0x104] = b"HEAD"
    total = 0x200 + len(root)
    struct.pack_into("<Q", head, 0x118, total)          # declared cartridge size
    struct.pack_into("<Q", head, 0x130, 0x200)          # root HFS0 offset
    struct.pack_into("<Q", head, 0x138, len(root))      # root HFS0 size
    return bytes(head) + root


def nca(tag=b"NCAA"):
    return tag + b"\x01" * 60


def overlapping_pfs0(entries):
    """Both entries claim the same payload range."""
    names = b""
    rows = b""
    for index, (name, data) in enumerate(entries):
        rows += struct.pack("<QQII", 0, len(data), len(names), 0)
        names += name.encode() + b"\0"
    header = b"PFS0" + struct.pack("<II", len(entries), len(names)) + b"\0" * 4
    payload = b"".join(data for _, data in entries)
    return header + rows + names + payload


def write(name, data):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name)
    with open(path, "wb") as handle:
        handle.write(data)
    print(f"{name:24} {len(data):6} bytes")


def main():
    write("valid.nsp", pfs0([
        (f"{TITLE_BASE}.cnmt.nca", nca()),
        ("aaaaaaaaaaaaaaaa.nca", nca()),
        (f"{TITLE_BASE}.tik", b"TIK" + b"\x02" * 28),
    ]))
    write("update.nsp", pfs0([
        (f"{TITLE_UPDATE}.cnmt.nca", nca()),
        ("bbbbbbbbbbbbbbbb.nca", nca()),
        (f"{TITLE_UPDATE}.tik", b"TIK" + b"\x02" * 28),
    ]))
    write("dlc.nsp", pfs0([
        (f"{TITLE_DLC}.cnmt.nca", nca()),
        ("cccccccccccccccc.nca", nca()),
        (f"{TITLE_DLC}.tik", b"TIK" + b"\x02" * 28),
    ]))
    write("no_ticket.nsp", pfs0([
        (f"{TITLE_BASE}.cnmt.nca", nca()),
        ("aaaaaaaaaaaaaaaa.nca", nca()),
    ]))
    truncated = pfs0([
        (f"{TITLE_BASE}.cnmt.nca", nca()),
        ("dddddddddddddddd.nca", nca()),
    ])
    write("truncated.nsp", truncated[: len(truncated) - 40])
    write("fake.nsp", b"this is not a container at all")
    write("tiny.nsp", b"\x00\x01\x02\x03")
    write("compressed.nsp", pfs0([
        (f"{TITLE_BASE}.cnmt.nca", nca()),
        ("eeeeeeeeeeeeeeee.nca", b"NCZS" + b"\x03" * 60),
        (f"{TITLE_BASE}.tik", b"TIK" + b"\x02" * 28),
    ]))
    write("valid.xci", xci([
        (f"{TITLE_BASE}.cnmt.nca", nca()),
        ("aaaaaaaaaaaaaaaa.nca", nca()),
        (f"{TITLE_BASE}.tik", b"TIK" + b"\x02" * 28),
    ]))
    write("overlap.nsp", overlapping_pfs0([
        (f"{TITLE_BASE}.cnmt.nca", nca()),
        ("ffffffffffffffff.nca", nca()),
    ]))


if __name__ == "__main__":
    main()
