#!/usr/bin/env python3
"""verify_kmi_abi.py -- compare the KMI symbol CRCs of a freshly built kernel
against the official `android/abi_gki_aarch64.xml` in the ACK tree (Google's
source of truth for the android13-5.15 KMI, which carries a crc= for every
symbol).

This is an OFFLINE check and needs no device: if every symbol present on both
sides has a matching CRC, the stock vendor modules (built against that KMI)
will load.

Why this is needed: genksyms hashes structs TRANSITIVELY. One extra or missing
field in an internal struct (for instance `struct module` when
CONFIG_DEBUG_INFO_BTF is disabled) shifts the CRC of most KMI symbols ->
every vendor module is rejected -> BOOTLOOP.

Usage:
  python3 scripts/verify_kmi_abi.py [--kernel-src kernel-src/sm8550] [--json]
Exit code: 0 = everything matches, 1 = mismatched or missing mandatory KMI symbol.
"""
import argparse
import json
import os
import re
import sys

# Symbols provided by GKI modules (CONFIG_*=m) -- they are not present in the
# vmlinux.symvers of an Image-only build. Being absent is CORRECT, not an error.
MODULE_PROVIDED = {
    "zs_compact", "zs_create_pool", "zs_destroy_pool", "zs_free",
    "zs_get_total_pages", "zs_huge_class_size", "zs_malloc",
    "zs_map_object", "zs_pool_stats", "zs_unmap_object",
}


def parse_xml(path):
    if path.endswith(".xz"):
        import lzma
        text = lzma.decompress(open(path, "rb").read()).decode("utf-8", "replace")
    else:
        text = open(path, encoding="utf-8", errors="replace").read()
    out = {}
    for name, crc in re.findall(r"<elf-symbol name='([^']+)'[^>]*crc='(0x[0-9a-fA-F]+)'", text):
        out[name] = int(crc, 16)
    return out


def parse_symvers(path):
    out = {}
    for line in open(path, encoding="utf-8", errors="replace"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 2:
            try:
                out[parts[1]] = int(parts[0], 16)
            except ValueError:
                pass
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel-src", default=os.path.join(os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))), "kernel-src", "sm8550"))
    ap.add_argument("--symvers", default=None,
                    help="Path to a Module.symvers/vmlinux.symvers to use instead of out/ "
                         "(for example the copy saved in state/kmi/ once out/ was deleted)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--max-print", type=int, default=20)
    args = ap.parse_args()

    # Google's ABI corpus (CRC of every KMI symbol). Prefer the copy inside the
    # fetched kernel tree; fall back to the compressed snapshot shipped in
    # state/kmi/ so a release can be verified without the 1.4 GB source tree.
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    xml = os.path.join(args.kernel_src, "android", "abi_gki_aarch64.xml")
    if not os.path.exists(xml):
        xml = os.path.join(repo_root, "state", "kmi", "abi_gki_aarch64.xml.xz")
    # Prefer vmlinux.symvers (the direct product of the build). Module.symvers is
    # only a copy made by script 05, so it can be STALE when the kernel was just
    # rebuilt without re-running script 05 (a trap we already hit: the file still
    # held the CRCs of an older BTF-off build).
    candidates = [
        os.path.join(args.kernel_src, "out", "vmlinux.symvers"),
        os.path.join(args.kernel_src, "out", "Module.symvers"),
    ]
    if args.symvers:
        candidates.insert(0, args.symvers)
    symvers = next((p for p in candidates if os.path.exists(p)), None)
    if symvers is None:
        sys.exit("ERROR: both out/vmlinux.symvers and out/Module.symvers are missing -- build the kernel first.")
    for p in (xml, symvers):
        if not os.path.exists(p):
            sys.exit(f"ERROR: missing {p}")

    kmi = parse_xml(xml)
    build = parse_symvers(symvers)

    ok = bad = absent = 0
    bad_list = []
    absent_list = []
    for name, crc in kmi.items():
        if name not in build:
            absent += 1
            if name not in MODULE_PROVIDED:
                absent_list.append(name)
            continue
        if build[name] == crc:
            ok += 1
        else:
            bad += 1
            bad_list.append((name, crc, build[name]))

    # Ultimate guard: module_layout decides whether ANY module can load at all
    layout_expect = kmi.get("module_layout")
    layout_got = build.get("module_layout")
    layout_ok = layout_expect is not None and layout_got == layout_expect

    result = {
        "kmi_symbols": len(kmi),
        "matched": ok,
        "mismatched": bad,
        "absent_total": absent,
        "absent_unexpected": absent_list,
        "module_layout": {
            "expected": None if layout_expect is None else f"0x{layout_expect:08x}",
            "got": None if layout_got is None else f"0x{layout_got:08x}",
            "ok": layout_ok,
        },
        "mismatch_sample": [
            {"symbol": n, "kmi": f"0x{a:08x}", "build": f"0x{b:08x}"}
            for n, a, b in bad_list[: args.max_print]
        ],
    }

    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        print(f"==> ABI source: {xml}")
        print(f"==> KMI: {len(kmi)} symbols in abi_gki_aarch64.xml")
        print(f"    matched: {ok} | mismatched: {bad} | absent: {absent} "
              f"(absent because of CONFIG_*=m modules: {absent - len(absent_list)})")
        if layout_got is None:
            print("    module_layout: NOT present in Module.symvers -- is the build wrong?")
        else:
            print(f"    module_layout: build=0x{layout_got:08x} "
                  f"kmi=0x{layout_expect:08x} {'OK' if layout_ok else 'MISMATCH'}")
        for n, a, b in bad_list[: args.max_print]:
            print(f"    [MISMATCH] {n:50s} kmi=0x{a:08x} build=0x{b:08x}")
        if len(bad_list) > args.max_print:
            print(f"    ... {len(bad_list) - args.max_print} more mismatched symbols")
        if absent_list:
            print(f"    [WARNING] {len(absent_list)} KMI symbols are not exported from vmlinux "
                  f"(expected because of CONFIG_*=m): {', '.join(absent_list[:10])}")

    if bad or not layout_ok:
        print("ERROR: KMI does NOT match abi_gki_aarch64.xml -- do NOT flash this kernel.")
        sys.exit(1)
    if absent_list:
        # Absence is not an error: symbols provided by GKI modules (CONFIG_*=m)
        # are not in the vmlinux.symvers of an Image-only build. Report them only
        # so they can be inspected.
        print(f"[WARNING] {len(absent_list)} KMI symbols are not exported from vmlinux "
              f"(expected because of CONFIG_*=m): {', '.join(absent_list[:10])}")
    print("[OK] all KMI CRCs match abi_gki_aarch64.xml (vendor modules will load)")


if __name__ == "__main__":
    main()
