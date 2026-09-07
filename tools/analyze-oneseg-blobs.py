#!/usr/bin/env python3
"""
analyze-oneseg-blobs.py - report what the SC-06D 1seg libraries need in order
to load, so you can tell in advance how much of Jelly Bean has to come along.

Run it on the directory that tools/oneseg-probe.sh produced:

    ./tools/analyze-oneseg-blobs.py oneseg-report/

For every ELF that looks 1seg-related it prints the SONAME, the DT_NEEDED
list, and which of those dependencies are missing from the pull. Anything
listed as missing is a library the port has to supply on Android 9 - and each
one is a place the linker can refuse to load the stack.

Pure standard library on purpose: this has to run on whatever machine happens
to have the phone plugged into it, without pip.
"""

import os
import re
import struct
import sys
from collections import OrderedDict

# --- ELF constants we care about -------------------------------------------

PT_LOAD = 1
PT_DYNAMIC = 2

DT_NULL = 0
DT_NEEDED = 1
DT_STRTAB = 5
DT_STRSZ = 10
DT_SONAME = 14
DT_RPATH = 15
DT_RUNPATH = 29

EM_ARM = 40
EM_AARCH64 = 183

MACHINES = {3: "x86", 40: "ARM", 62: "x86-64", 183: "AArch64"}

# Strings worth flagging inside a 1seg binary. Each one answers a question
# that decides whether the port is possible at all.
MARKERS = OrderedDict([
    ("device node", [rb"/dev/isdbt"]),
    ("tuner", [rb"nmi326", rb"NMI326", rb"isdbt", rb"ISDBT"]),
    ("firmware load", [rb"\.fw\b", rb"firmware", rb"/system/etc/firmware"]),
    ("content protection", [rb"MULTI2", rb"multi2", rb"\bRMP\b", rb"descramble",
                            rb"B-CAS", rb"BCAS", rb"\bECM\b", rb"\bEMM\b"]),
    ("key material", [rb"key", rb"Key", rb"/efs/", rb"secret"]),
    ("broadcast", [rb"ISDB", rb"1seg", rb"oneseg", rb"OneSeg", rb"\bEPG\b",
                   rb"segment"]),
])

NAME_HINTS = re.compile(
    r"(isdb|1seg|oneseg|nmi|dtv|dmb|tuner|broadcast|_tv|tv_)", re.IGNORECASE
)


class ElfError(Exception):
    pass


class Elf:
    """Just enough ELF to read the dynamic section."""

    def __init__(self, path):
        self.path = path
        with open(path, "rb") as fh:
            self.data = fh.read()
        self._parse_header()

    def _parse_header(self):
        d = self.data
        if len(d) < 64 or d[:4] != b"\x7fELF":
            raise ElfError("not an ELF file")

        ei_class = d[4]
        ei_data = d[5]
        if ei_class not in (1, 2):
            raise ElfError("bad EI_CLASS %d" % ei_class)
        if ei_data not in (1, 2):
            raise ElfError("bad EI_DATA %d" % ei_data)

        self.is64 = ei_class == 2
        self.end = "<" if ei_data == 1 else ">"

        if self.is64:
            # e_type, e_machine, e_version, e_entry, e_phoff, ...
            (self.e_type, self.e_machine, _, _entry, self.e_phoff, _shoff,
             _flags, _ehsize, self.e_phentsize, self.e_phnum) = struct.unpack_from(
                self.end + "HHIQQQIHHH", d, 16)
        else:
            (self.e_type, self.e_machine, _, _entry, self.e_phoff, _shoff,
             _flags, _ehsize, self.e_phentsize, self.e_phnum) = struct.unpack_from(
                self.end + "HHIIIIIHHH", d, 16)

        self.machine = MACHINES.get(self.e_machine, "machine-%d" % self.e_machine)

    def _phdrs(self):
        d = self.data
        for i in range(self.e_phnum):
            off = self.e_phoff + i * self.e_phentsize
            if off + self.e_phentsize > len(d):
                break
            if self.is64:
                p_type, _flags, p_offset, p_vaddr, _paddr, p_filesz, _memsz, _align = \
                    struct.unpack_from(self.end + "IIQQQQQQ", d, off)
            else:
                p_type, p_offset, p_vaddr, _paddr, p_filesz, _memsz, _flags, _align = \
                    struct.unpack_from(self.end + "IIIIIIII", d, off)
            yield p_type, p_offset, p_vaddr, p_filesz

    def _vaddr_to_off(self, vaddr):
        """Map a virtual address back to a file offset via the PT_LOAD segments."""
        for p_type, p_offset, p_vaddr, p_filesz in self._phdrs():
            if p_type == PT_LOAD and p_vaddr <= vaddr < p_vaddr + p_filesz:
                return p_offset + (vaddr - p_vaddr)
        return None

    def dynamic(self):
        """Return (soname, [needed], [rpath])."""
        dyn_off = dyn_size = None
        for p_type, p_offset, _p_vaddr, p_filesz in self._phdrs():
            if p_type == PT_DYNAMIC:
                dyn_off, dyn_size = p_offset, p_filesz
                break
        if dyn_off is None:
            return None, [], []

        entsize = 16 if self.is64 else 8
        # d_tag is signed in the spec, but every tag read here is a small
        # positive constant and DT_NULL(0) ends the walk, so unpacking both
        # fields unsigned avoids turning a high d_ptr into a negative number.
        fmt = self.end + ("QQ" if self.is64 else "II")

        entries = []
        strtab_va = strsz = None
        off = dyn_off
        d = self.data
        while off + entsize <= min(dyn_off + dyn_size, len(d)):
            tag, val = struct.unpack_from(fmt, d, off)
            off += entsize
            if tag == DT_NULL:
                break
            entries.append((tag, val))
            if tag == DT_STRTAB:
                strtab_va = val
            elif tag == DT_STRSZ:
                strsz = val

        if strtab_va is None:
            return None, [], []

        strtab_off = self._vaddr_to_off(strtab_va)
        if strtab_off is None:
            # Some prebuilts store an offset here rather than an address.
            strtab_off = strtab_va
        if strtab_off is None or strtab_off >= len(d):
            return None, [], []

        limit = len(d) if strsz is None else min(len(d), strtab_off + strsz)

        def s(idx):
            p = strtab_off + idx
            if p < 0 or p >= limit:
                return None
            e = d.find(b"\x00", p, limit)
            if e < 0:
                return None
            try:
                return d[p:e].decode("utf-8", "replace")
            except Exception:
                return None

        soname = None
        needed = []
        rpath = []
        for tag, val in entries:
            if tag == DT_NEEDED:
                n = s(val)
                if n:
                    needed.append(n)
            elif tag == DT_SONAME:
                soname = s(val)
            elif tag in (DT_RPATH, DT_RUNPATH):
                r = s(val)
                if r:
                    rpath.append(r)
        return soname, needed, rpath

    def markers(self):
        """Which interesting strings appear in this binary."""
        found = OrderedDict()
        for label, pats in MARKERS.items():
            hits = []
            for p in pats:
                m = re.search(p, self.data)
                if m:
                    hits.append(m.group(0).decode("ascii", "replace"))
            if hits:
                found[label] = sorted(set(hits))
        return found


def walk_elfs(root):
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            path = os.path.join(dirpath, fn)
            try:
                if os.path.getsize(path) < 64:
                    continue
                with open(path, "rb") as fh:
                    if fh.read(4) != b"\x7fELF":
                        continue
            except OSError:
                continue
            yield path


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip())
        print("\nusage: %s <oneseg-report dir>" % os.path.basename(argv[0]))
        return 2

    report = argv[1]
    if not os.path.isdir(report):
        print("error: %s is not a directory" % report, file=sys.stderr)
        return 1

    # The probe pulls into <report>/system; accept either that or a bare tree.
    sysroot = os.path.join(report, "system")
    if not os.path.isdir(sysroot):
        sysroot = report

    print("=" * 72)
    print("SC-06D 1seg blob analysis")
    print("  tree: %s" % sysroot)
    print("=" * 72)

    # Everything present, so we can tell "missing" from "elsewhere in the pull".
    present = {}
    all_elfs = list(walk_elfs(sysroot))
    for path in all_elfs:
        present[os.path.basename(path)] = path
        try:
            so, _n, _r = Elf(path).dynamic()
            if so:
                present.setdefault(so, path)
        except (ElfError, struct.error, OSError):
            pass

    print("\nscanned %d ELF objects\n" % len(all_elfs))

    # Candidates: named like 1seg, or containing a marker string.
    candidates = []
    for path in all_elfs:
        rel = os.path.relpath(path, sysroot)
        try:
            elf = Elf(path)
        except (ElfError, struct.error, OSError):
            continue
        marks = elf.markers()
        by_name = bool(NAME_HINTS.search(os.path.basename(path)))
        # A hit on the device node or the tuner name is decisive; the softer
        # markers (key/broadcast) only count when the file name agrees, or
        # every libc in the tree would qualify.
        decisive = "device node" in marks or "tuner" in marks
        if decisive or (by_name and marks):
            candidates.append((path, rel, elf, marks, decisive))

    if not candidates:
        print("No 1seg-related ELF objects found.")
        print()
        print("That is a real result, not necessarily a failure. It can mean:")
        print("  - the pull did not include /system/lib (check probe.log)")
        print("  - the device is already running a custom ROM")
        print("  - the stack is driven from Java/apk rather than a native lib")
        print("    (unpack the candidate apks and look at their lib/armeabi*/)")
        return 0

    # Decisive hits first.
    candidates.sort(key=lambda c: (not c[4], c[1]))

    missing_total = set()

    for path, rel, elf, marks, decisive in candidates:
        print("-" * 72)
        print("%s  [%s]" % (rel, elf.machine))
        if decisive:
            print("  ** references the tuner directly **")

        try:
            soname, needed, rpath = elf.dynamic()
        except (ElfError, struct.error):
            soname, needed, rpath = None, [], []

        if soname:
            print("  SONAME : %s" % soname)
        if rpath:
            print("  RPATH  : %s" % ", ".join(rpath))

        if needed:
            print("  NEEDED :")
            for n in needed:
                if n in present:
                    print("    [have]    %s" % n)
                else:
                    print("    [MISSING] %s" % n)
                    missing_total.add(n)
        else:
            print("  NEEDED : (none - static or not dynamic)")

        if marks:
            print("  markers:")
            for label, hits in marks.items():
                print("    %-20s %s" % (label + ":", ", ".join(hits[:6])))
        print()

    print("=" * 72)
    print("what this means for the port")
    print("=" * 72)

    if missing_total:
        print()
        print("These dependencies are referenced but were not in the pull:")
        for n in sorted(missing_total):
            print("  - %s" % n)
        print()
        print("Each one has to exist on Android 9 with a compatible ABI. Where")
        print("the name is an AOSP library (libutils, libbinder, libcutils,")
        print("libstdc++...) the Jelly Bean version is NOT interface-compatible")
        print("with Pie - you need either the stock copy alongside a private")
        print("linker namespace, or a shim. d2att-unified already carries")
        print("libsamsung_symbols for exactly this class of problem; extend it")
        print("rather than starting a new one.")
    else:
        print()
        print("Every dependency was found inside the pull. That is the best")
        print("case: the stack may be self-contained enough to move as a unit.")

    print()
    print("Next: check whether the decisive library also carries content")
    print("protection markers. If RMP/MULTI2 code lives in the same .so that")
    print("talks to /dev/isdbt, the key is probably fetched from the chip and")
    print("the port has a chance. If it lives in a separate library that reads")
    print("a file, that file has to be found and carried across too.")
    print()
    print("See docs/05-ワンセグ移植の手順.md step 4.")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
