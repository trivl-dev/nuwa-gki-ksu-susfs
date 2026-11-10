#!/usr/bin/env python3
"""btf_diff.py -- compare struct layouts between the stock kernel (BTF embedded
in the Image) and the kit build (BTF generated from probe objects/DWARF). Used
to locate mismatched fields when the KMI CRC does not match.

Usage:
  python3 scripts/btf_diff.py <stock-image> <ours.btf> <struct> [<struct> ...]
"""
import struct
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from btf_dump import BTF, KIND_NAMES  # noqa: E402


def members(btf, idx):
    t = btf.types[idx]
    out = []
    extra = t["extra"]
    for i in range(t["vlen"]):
        name_off, type_id, offset = struct.unpack_from("<III", extra, i * 12)
        if t["kflag"]:
            bit_off = offset & 0xFFFFFF
            bit_sz = offset >> 24
        else:
            bit_off = offset
            bit_sz = 0
        out.append((btf.name(name_off) or "<anon>", bit_off, bit_sz,
                    btf.type_desc(type_id)))
    return t["size_or_type"], out


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        raise SystemExit(1)
    stock = BTF(sys.argv[1])
    ours = BTF(sys.argv[2])
    rc = 0
    for name in sys.argv[3:]:
        si = stock.find(4, name) or stock.find(5, name)
        oi = ours.find(4, name) or ours.find(5, name)
        if not si or not oi:
            print(f"!! {name}: not found in {'stock' if not si else 'ours'}")
            rc = 1
            continue
        ssize, smem = members(stock, si[0])
        osize, omem = members(ours, oi[0])
        if ssize == osize and smem == omem:
            print(f"[OK]   {name}: size {ssize} bytes, {len(smem)} members - identical")
            continue
        rc = 1
        print(f"[DIFF] {name}: stock size={ssize} ({len(smem)} mem) vs ours size={osize} ({len(omem)} mem)")
        for i in range(max(len(smem), len(omem))):
            s = smem[i] if i < len(smem) else None
            o = omem[i] if i < len(omem) else None
            if s != o:
                print(f"    idx {i}: stock={s}  ours={o}")
    raise SystemExit(rc)


if __name__ == "__main__":
    main()
