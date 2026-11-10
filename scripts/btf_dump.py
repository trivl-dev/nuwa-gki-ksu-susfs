#!/usr/bin/env python3
"""btf_dump.py -- read the .BTF section embedded in a kernel Image (raw binary)
and print the layout of a struct/union by name. Used to compare the struct
layout of the stock kernel against the kit build (the KMI CRCs depend on that
layout).

Usage:
  python3 scripts/btf_dump.py <kernel-image> <struct-name> [--members]
  python3 scripts/btf_dump.py <kernel-image> --list-structs

BTF header (little-endian):
  u16 magic=0xeb9f, u8 version, u8 flags, u32 hdr_len,
  u32 type_off, u32 type_len, u32 str_off, u32 str_len
Type entry: u32 name_off, u32 info (vlen:16, unused:8, kind:5, kind_flag:1), u32 size_or_type
"""
import struct
import sys

KIND_NAMES = {
    0: "VOID", 1: "INT", 2: "PTR", 3: "ARRAY", 4: "STRUCT", 5: "UNION",
    6: "ENUM", 7: "FWD", 8: "TYPEDEF", 9: "VOLATILE", 10: "CONST",
    11: "RESTRICT", 12: "FUNC", 13: "FUNC_PROTO", 14: "VAR", 15: "DATASEC",
    16: "FLOAT", 17: "DECL_TAG", 18: "TYPE_TAG", 19: "ENUM64",
}


def find_btf(data):
    magic = b"\x9f\xeb\x01\x00"
    start = 0
    while True:
        i = data.find(magic, start)
        if i < 0:
            return None
        hdr_len, type_off, type_len, str_off, str_len = struct.unpack_from("<IIIII", data, i + 4)
        if hdr_len == 24 and 0 < type_len < len(data) - i and 0 < str_len < len(data) - i:
            return i, type_off, type_len, str_off, str_len
        start = i + 1


class BTF:
    def __init__(self, path):
        data = open(path, "rb").read()
        loc = find_btf(data)
        if not loc:
            raise SystemExit("ERROR: no BTF found in the file.")
        base, type_off, type_len, str_off, str_len = loc
        # BTF: type id 0 is the implicit void; the FIRST record in the section is
        # id 1. The list therefore needs a placeholder at index 0 so that the
        # index equals the type id.
        self.types = [{"name_off": 0, "kind": 0, "kflag": 0, "vlen": 0,
                       "size_or_type": 0, "extra": b""}]
        # type_off/str_off are counted from AFTER the header (base + 24), not from base
        self.strs = data[base + 24 + str_off: base + 24 + str_off + str_len]
        pos = base + 24 + type_off
        end = pos + type_len
        while pos < end:
            name_off, info, size_or_type = struct.unpack_from("<III", data, pos)
            pos += 12
            vlen = info & 0xFFFF
            kind = (info >> 24) & 0x1F
            kflag = (info >> 31) & 1
            extra = b""
            if kind in (4, 5):      # STRUCT/UNION: vlen * 12 bytes
                extra = data[pos:pos + vlen * 12]
                pos += vlen * 12
            elif kind == 1:         # INT: 4 bytes
                extra = data[pos:pos + 4]
                pos += 4
            elif kind == 3:         # ARRAY: 12 bytes (type, index_type, nelems)
                extra = data[pos:pos + 12]
                pos += 12
            elif kind == 6:         # ENUM: vlen * 8
                extra = data[pos:pos + vlen * 8]
                pos += vlen * 8
            elif kind == 13:        # FUNC_PROTO: vlen * 8
                extra = data[pos:pos + vlen * 8]
                pos += vlen * 8
            elif kind == 14:        # VAR: 4
                extra = data[pos:pos + 4]
                pos += 4
            elif kind == 15:        # DATASEC: vlen * 12
                extra = data[pos:pos + vlen * 12]
                pos += vlen * 12
            elif kind == 17:        # DECL_TAG: 4
                extra = data[pos:pos + 4]
                pos += 4
            elif kind == 19:        # ENUM64: vlen * 12
                extra = data[pos:pos + vlen * 12]
                pos += vlen * 12
            self.types.append({
                "name_off": name_off, "kind": kind, "kflag": kflag,
                "vlen": vlen, "size_or_type": size_or_type, "extra": extra,
            })

    def name(self, off):
        if off == 0:
            return ""
        e = self.strs.find(b"\0", off)
        return self.strs[off:e].decode("utf-8", "replace")

    def type_desc(self, tid, depth=0):
        if tid == 0:
            return "void"
        t = self.types[tid]
        k = t["kind"]
        if k == 2:
            return self.type_desc(t["size_or_type"], depth) + " *"
        if k in (8, 18, 9, 10, 11):
            base = self.type_desc(t["size_or_type"], depth)
            return base if k != 8 else (self.name(t["name_off"]) or base)
        if k in (4, 5):
            return ("struct " if k == 4 else "union ") + (self.name(t["name_off"]) or "<anon>")
        if k == 1:
            return self.name(t["name_off"])
        if k == 3:
            return f"{self.type_desc(t['size_or_type'])}[{t['size_or_type']}]"
        if k == 6:
            return "enum " + (self.name(t["name_off"]) or "<anon>")
        if k == 7:
            return ("struct " if t["kflag"] == 0 else "union ") + self.name(t["name_off"])
        if k == 16:
            return self.name(t["name_off"])
        return KIND_NAMES.get(k, str(k))

    def find(self, kind, name):
        out = []
        for i, t in enumerate(self.types):
            if t["kind"] == kind and self.name(t["name_off"]) == name:
                out.append(i)
        return out

    def dump_struct(self, idx):
        t = self.types[idx]
        print(f"{KIND_NAMES[t['kind']]} {self.name(t['name_off'])} (size {t['size_or_type']})")
        extra = t["extra"]
        for i in range(t["vlen"]):
            name_off, type_id, offset = struct.unpack_from("<III", extra, i * 12)
            if t["kflag"]:
                bit_off = offset & 0xFFFFFF
                bit_sz = offset >> 24
                byte_off = bit_off // 8
                bits = f", bit {bit_off}" + (f"..{bit_off + bit_sz - 1}" if bit_sz else "")
            else:
                byte_off = offset // 8
                bits = f", bit {offset}"
            print(f"  +{byte_off:5d} {self.name(name_off) or '<anon>':32s} {self.type_desc(type_id)}{bits}")


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        raise SystemExit(1)
    btf = BTF(sys.argv[1])
    if sys.argv[2] == "--list-structs":
        names = sorted({btf.name(t["name_off"]) for t in btf.types if t["kind"] == 4 and btf.name(t["name_off"])})
        print("\n".join(names[:200]))
        print(f"... total {len(names)} structs")
        return
    target = sys.argv[2]
    found = False
    for kind in (4, 5):
        for idx in btf.find(kind, target):
            btf.dump_struct(idx)
            found = True
    if not found:
        raise SystemExit(f"ERROR: struct/union '{target}' not found")


if __name__ == "__main__":
    main()
