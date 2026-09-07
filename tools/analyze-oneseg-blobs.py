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

To see the API a library actually offers - which is what you need in order to
call it yourself instead of shipping the stock app:

    ./tools/analyze-oneseg-blobs.py oneseg-report/ --symbols libonesegdmxdriver

To find out whether those libraries will load on the Android version you are
porting to, without building it first - point --against at that build's
system/lib and every DT_NEEDED and undefined symbol is resolved against it:

    ./tools/analyze-oneseg-blobs.py oneseg-report/ --against /tmp/los16/system/lib

Pure standard library on purpose: this has to run on whatever machine happens
to have the phone plugged into it, without pip. C++ names are demangled with
c++filt when it is installed, and shown mangled when it is not.
"""

import os
import re
import struct
import subprocess
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
            (self.e_type, self.e_machine, _, _entry, self.e_phoff, self.e_shoff,
             _flags, _ehsize, self.e_phentsize, self.e_phnum,
             self.e_shentsize, self.e_shnum, _shstrndx) = struct.unpack_from(
                self.end + "HHIQQQIHHHHHH", d, 16)
        else:
            (self.e_type, self.e_machine, _, _entry, self.e_phoff, self.e_shoff,
             _flags, _ehsize, self.e_phentsize, self.e_phnum,
             self.e_shentsize, self.e_shnum, _shstrndx) = struct.unpack_from(
                self.end + "HHIIIIIHHHHHH", d, 16)

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

    def _shdrs(self):
        """Yield (sh_type, sh_offset, sh_size, sh_link, sh_entsize)."""
        d = self.data
        if not self.e_shoff or not self.e_shnum:
            return
        for i in range(self.e_shnum):
            off = self.e_shoff + i * self.e_shentsize
            if off + self.e_shentsize > len(d):
                return
            if self.is64:
                (_name, sh_type, _flags, _addr, sh_offset, sh_size,
                 sh_link, _info, _align, sh_entsize) = struct.unpack_from(
                    self.end + "IIQQQQIIQQ", d, off)
            else:
                (_name, sh_type, _flags, _addr, sh_offset, sh_size,
                 sh_link, _info, _align, sh_entsize) = struct.unpack_from(
                    self.end + "IIIIIIIIII", d, off)
            yield sh_type, sh_offset, sh_size, sh_link, sh_entsize

    def undefined_symbols(self):
        """Names this object imports - what it needs someone else to provide.

        These are the .dynsym entries with st_shndx == SHN_UNDEF. Whether a
        library loads on a different Android version comes down to whether
        every one of these resolves there, so this is the list that decides
        a port - and it can be checked without building anything.
        """
        return [n for n, _b in self._syms(want_undef=True)]

    def undefined_required(self):
        """Undefined symbols that MUST resolve, i.e. the strong ones.

        A weak undefined symbol is optional by definition - the linker binds
        it to zero when nothing provides it, and the object still loads. Only
        strong ones can fail a load, so only these belong in a verdict.
        """
        return [n for n, b in self._syms(want_undef=True) if b == 1]

    def undefined_weak(self):
        return [n for n, b in self._syms(want_undef=True) if b == 2]

    def exported_symbols(self):
        """Names defined and exported by this object.

        Section headers are used rather than walking DT_HASH, because Android
        .so files keep them and this stays readable. A fully stripped object
        returns nothing, which the caller reports rather than hiding.
        """
        return [n for n, _b in self._syms(want_undef=False)]

    def _syms(self, want_undef):
        d = self.data
        sections = list(self._shdrs())
        if not sections:
            return []

        SHT_DYNSYM = 11
        dynsym = next((x for x in sections if x[0] == SHT_DYNSYM), None)
        if dynsym is None:
            return []

        _t, sym_off, sym_size, sym_link, sym_entsize = dynsym
        if not sym_entsize:
            sym_entsize = 24 if self.is64 else 16
        if sym_link >= len(sections):
            return []
        _t2, str_off, str_size, _l, _e = sections[sym_link]

        def s(idx):
            p = str_off + idx
            if p < str_off or p >= str_off + str_size or p >= len(d):
                return None
            e = d.find(b"\x00", p, str_off + str_size)
            if e < 0:
                return None
            return d[p:e].decode("utf-8", "replace")

        out = []
        n = sym_size // sym_entsize
        for i in range(n):
            off = sym_off + i * sym_entsize
            if off + sym_entsize > len(d):
                break
            if self.is64:
                st_name, st_info, _other, st_shndx, _val, _sz = struct.unpack_from(
                    self.end + "IBBHQQ", d, off)
            else:
                st_name, _val, _sz, st_info, _other, st_shndx = struct.unpack_from(
                    self.end + "IIIBBH", d, off)
            if (st_shndx == 0) != want_undef:
                continue
            bind = st_info >> 4          # 0 LOCAL, 1 GLOBAL, 2 WEAK
            if bind not in (1, 2):
                continue
            name = s(st_name)
            if name:
                out.append((name, bind))
        return sorted(set(out))

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


def demangle(names):
    """Run names through c++filt if it exists; otherwise return them as-is."""
    if not names:
        return {}
    try:
        p = subprocess.run(["c++filt"], input="\n".join(names),
                           capture_output=True, text=True, timeout=30)
        if p.returncode == 0:
            out = p.stdout.splitlines()
            if len(out) == len(names):
                return dict(zip(names, out))
    except (OSError, subprocess.SubprocessError):
        pass
    return {n: n for n in names}


def show_symbols(sysroot, pattern):
    """Print the exported API of every library whose name matches pattern."""
    hits = [p for p in walk_elfs(sysroot)
            if pattern.lower() in os.path.basename(p).lower()]
    if not hits:
        print("no ELF object under %s matches %r" % (sysroot, pattern))
        return 1

    for path in sorted(hits):
        rel = os.path.relpath(path, sysroot)
        try:
            elf = Elf(path)
            syms = elf.exported_symbols()
        except (ElfError, struct.error, OSError) as e:
            print("%s: cannot read (%s)" % (rel, e))
            continue

        print("=" * 72)
        print("%s  [%s]  %d exported symbol(s)" % (rel, elf.machine, len(syms)))
        print("=" * 72)

        if not syms:
            print("  none - the object is stripped of section headers, or")
            print("  exports nothing (a plugin loaded only by dlsym).")
            print()
            continue

        dm = demangle(syms)
        # C++ entry points first: those carry the argument types, which is the
        # part you cannot guess.
        cpp = [n for n in syms if n.startswith("_Z")]
        plain = [n for n in syms if not n.startswith("_Z")]

        if cpp:
            print("  C++ (demangled):")
            for n in cpp:
                print("    %s" % dm.get(n, n))
            print()
        if plain:
            print("  C / extern \"C\":")
            for n in plain:
                print("    %s" % n)
            print()

    print("-" * 72)
    print("These are the functions the port can call directly. Look for a")
    print("power/open call, a tune-by-channel or by-frequency call, and a read")
    print("that hands back TS. Those three are the whole minimum API.")
    print()
    print("Cross-check against the ioctls in the GPL driver")
    print("(drivers/media/nmi326/nmi326.h) - the library is the only thing that")
    print("knows what bytes to push through them.")
    return 0


# The three proprietary libraries the port ships. Everything else the stack
# had - the demuxer, CPRM, the service layer, the app - was ruled out earlier.
PORT_LIBS = ["libonesegdmxdriver.so", "libonesegutils.so", "libPGL.so"]


def find_ndk_arm_sysroot():
    """Locate the NDK's 32-bit ARM stub libraries for API 28.

    The NDK ships, per API level, a stub .so for each library it exposes.
    A stub carries no code - only the exported symbol list - which is
    exactly what a link-time and load-time check needs, and that list is
    generated from the platform, so API 28's stubs are Android 9's symbols.

    Printing "$NDK/toolchains/..." and leaving the reader to substitute is
    how this project already lost two attempts to a literal path, so find
    the real one and print that.
    """
    import glob
    roots = []
    for var in ("ANDROID_NDK_HOME", "ANDROID_NDK_ROOT", "ANDROID_NDK", "NDK"):
        v = os.environ.get(var)
        if v:
            roots.append(v)
    roots += sorted(glob.glob(os.path.expanduser("~/android-ndk-*")))
    roots += sorted(glob.glob(os.path.expanduser("~/Android/Sdk/ndk/*")))
    roots += sorted(glob.glob("/opt/android-ndk-*"))
    roots += sorted(glob.glob("/usr/lib/android-ndk"))

    for r in roots:
        for host in ("linux-x86_64", "darwin-x86_64"):
            for api in ("28", "27", "26"):
                d = os.path.join(r, "toolchains", "llvm", "prebuilt", host,
                                 "sysroot", "usr", "lib",
                                 "arm-linux-androideabi", api)
                if os.path.isdir(d) and os.path.exists(os.path.join(d, "libc.so")):
                    return d
    return None


def check_port(sysroot, target_dirs):
    """Will the three shipped libraries load on another Android version?

    That question is answerable without building anything. A library loads if
    every DT_NEEDED is present and every undefined symbol resolves; both are
    readable straight out of the ELF. Point --against at the system/lib of the
    Android version you are porting to and this says yes or names what is
    missing.
    """
    # "ndk" resolves to the NDK's ARM stub libraries for API 28, whose
    # exported symbols are Android 9's. It saves typing a path six
    # directories deep that differs on every machine.
    resolved = []
    for d in target_dirs:
        if d == "ndk":
            found = find_ndk_arm_sysroot()
            if not found:
                print("no NDK found in $ANDROID_NDK_HOME, $ANDROID_NDK_ROOT,",
                      file=sys.stderr)
                print("~/android-ndk-*, ~/Android/Sdk/ndk/* or /opt/android-ndk-*.",
                      file=sys.stderr)
                return 1
            print("ndk -> %s" % found)
            resolved.append(found)
        else:
            resolved.append(d)
    target_dirs = resolved

    for d in target_dirs:
        if not os.path.isdir(d):
            print("error: %s is not a directory" % d, file=sys.stderr)
            print(file=sys.stderr)
            print("--against wants the target Android's own libraries:",
                  file=sys.stderr)
            print("  out/target/product/d2dcm/system/lib      after a build",
                  file=sys.stderr)
            print("  <extracted LineageOS 16.0 zip>/system/lib", file=sys.stderr)
            print("  ndk    the NDK's API 28 stubs, found automatically",
                  file=sys.stderr)
            return 1

    # What we intend to ship, found in the survey.
    ours = {}
    for path in walk_elfs(sysroot):
        base = os.path.basename(path)
        if base in PORT_LIBS and base not in ours:
            ours[base] = path
    missing_ours = [n for n in PORT_LIBS if n not in ours]

    # What the target Android provides.
    print("=" * 72)
    print("Port check: the 1seg libraries against")
    for d in target_dirs:
        print("  %s" % d)
    print("=" * 72)
    print()

    if missing_ours:
        print("Not in the survey (run tools/oneseg-probe.sh first):")
        for n in missing_ours:
            print("  %s" % n)
        print()
        if not ours:
            return 1

    provided = {}          # symbol -> library that defines it
    target_libs = set()
    n_scanned = 0
    for path in (q for d in target_dirs for q in walk_elfs(d)):
        try:
            elf = Elf(path)
        except (ElfError, struct.error, OSError):
            continue
        n_scanned += 1
        base = os.path.basename(path)
        target_libs.add(base)
        so, _n, _r = elf.dynamic()
        if so:
            target_libs.add(so)
        for sym_name in elf.exported_symbols():
            provided.setdefault(sym_name, base)

    print("target: %d ELF objects, %d distinct symbols" % (n_scanned, len(provided)))
    if n_scanned == 0:
        print()
        print("Nothing readable there. --against wants the system/lib directory")
        print("of the target build - e.g. the system/lib/ inside an extracted")
        print("LineageOS 16.0 zip for a d2 device.")
        return 1

    # Is this actually an Android system/lib?
    #
    # Point --against at the wrong directory and this tool will happily
    # report that every libc symbol is unresolved and every DT_NEEDED is
    # missing. That reads like a devastating verdict on the port and means
    # nothing at all - the target simply had no libc in it. Everything these
    # three libraries import comes from the C library and Android's core
    # utility libraries, so a target without libc.so cannot answer the
    # question and must not pretend to.
    base_absent = [n for n in ("libc.so", "libm.so", "libdl.so")
                   if n not in target_libs]
    if "libc.so" in base_absent:
        print()
        print("=" * 72)
        print("STOP - that is not an Android system/lib.")
        print("=" * 72)
        print()
        print("No libc.so among the %d objects scanned. Every symbol these"
              % n_scanned)
        print("libraries import comes from libc and Android's core utility")
        print("libraries, so against this target everything would come back")
        print("'unresolved' and none of it would mean anything.")
        print()
        print("A common mistake is pointing --against at the extracted blobs")
        print("themselves (vendor/samsung/d2dcm/proprietary/lib). That is the")
        print("thing being checked, not the thing to check it against.")
        print()
        print("What --against wants is the target Android's own libraries:")
        print()
        print("  out/target/product/d2dcm/system/lib      after a build")
        print("  <extracted LineageOS 16.0 zip>/system/lib")
        print()
        print("If you have neither yet, the NDK ships stub libraries whose")
        print("exported symbols are exactly Android 9's, which settles most of")
        print("the question today.")
        print()
        ndk = find_ndk_arm_sysroot()
        if ndk:
            print("Found one on this machine. This command runs as written:")
            print()
            print("  %s \\" % sys.argv[0])
            print("      %s \\" % sysroot)
            print("      --against %s" % ndk)
        else:
            print("No NDK found in $ANDROID_NDK_HOME, ~/android-ndk-*, or")
            print("~/Android/Sdk/ndk/*. With one installed, the directory to")
            print("pass is:")
            print()
            print("  <ndk>/toolchains/llvm/prebuilt/linux-x86_64/sysroot/\\")
            print("      usr/lib/arm-linux-androideabi/28")
        print()
        print("That covers libc, libm, libdl and liblog. It does not carry")
        print("libcutils, libutils or libstdc++, so pass those directories as")
        print("well - --against may be given more than once - or read whatever")
        print("they would have provided as still-unknown, not as missing.")
        return 1
    if base_absent:
        print("note: the target has no %s. Symbols that would come from"
              % ", ".join(base_absent))
        print("      %s are reported as unresolved but are not proven missing."
              % " or ".join(base_absent))
    print()

    # The libraries we ship also satisfy each other.
    for name, path in ours.items():
        try:
            for sym_name in Elf(path).exported_symbols():
                provided.setdefault(sym_name, name)
            target_libs.add(name)
        except (ElfError, struct.error, OSError):
            pass

    verdict_ok = True
    for name in PORT_LIBS:
        if name not in ours:
            continue
        print("-" * 72)
        print(name)
        try:
            elf = Elf(ours[name])
            _so, needed, _r = elf.dynamic()
            imports = elf.undefined_required()
            weak = elf.undefined_weak()
        except (ElfError, struct.error, OSError) as e:
            print("  cannot read: %s" % e)
            verdict_ok = False
            continue

        miss_lib = [n for n in needed if n not in target_libs]
        if miss_lib:
            verdict_ok = False
            print("  MISSING LIBRARIES:")
            for n in miss_lib:
                print("    %s" % n)
        else:
            print("  all %d DT_NEEDED present" % len(needed))

        unresolved = [x for x in imports if x not in provided]
        if unresolved:
            verdict_ok = False
            print("  UNRESOLVED SYMBOLS (%d of %d required):"
                  % (len(unresolved), len(imports)))
            for x in unresolved[:40]:
                print("    %s" % x)
            if len(unresolved) > 40:
                print("    ... and %d more" % (len(unresolved) - 40))
        else:
            print("  all %d required symbols resolve" % len(imports))

        weak_missing = [x for x in weak if x not in provided]
        if weak_missing:
            print("  weak and absent (harmless - bound to zero): %s"
                  % ", ".join(weak_missing[:8]))
        print()

    print("=" * 72)
    if verdict_ok:
        print("Every dependency and symbol resolves against that target.")
        print()
        print("That is the static half of the question answered: the linker has")
        print("no reason to refuse these. What it does not prove is behaviour -")
        print("a symbol can exist with different semantics, and libutils in")
        print("particular is C++ whose object layout changed between releases.")
        print("But there is nothing here to fix before trying it.")
    else:
        print("Something is missing. Each unresolved name is a symbol the port")
        print("has to supply - by shipping the old library alongside, or by")
        print("adding it to a shim. hardware/samsung/libsamsung_symbols in the")
        print("d2att tree already does this for other blobs; extend it rather")
        print("than starting a new one.")
    return 0 if verdict_ok else 2


def main(argv):
    args = argv[1:]
    # --against may be repeated, and each may be a comma-separated list. An
    # Android 9 system/lib is often assembled from more than one place - NDK
    # stubs for libc and friends, a build tree for libcutils and libutils.
    against = []
    while "--against" in args:
        i = args.index("--against")
        if i + 1 >= len(args):
            print("--against needs a directory", file=sys.stderr)
            return 2
        against.extend(d for d in args[i + 1].split(",") if d)
        del args[i:i + 2]

    symbols_of = None
    if "--symbols" in args:
        i = args.index("--symbols")
        if i + 1 >= len(args):
            print("--symbols needs a library name, e.g. --symbols libonesegdmxdriver",
                  file=sys.stderr)
            return 2
        symbols_of = args[i + 1]
        del args[i:i + 2]

    if len(args) != 1:
        print(__doc__.strip())
        print("\nusage: %s <oneseg-report dir> [--symbols <libname>]"
              % os.path.basename(argv[0]))
        print("       %s <oneseg-report dir> --against <target system/lib dir>"
              % os.path.basename(argv[0]))
        print("       %s <oneseg-report dir> --against ndk"
              % os.path.basename(argv[0]))
        return 2

    report = args[0]
    if not os.path.isdir(report):
        print("error: %s is not a directory" % report, file=sys.stderr)
        return 1

    # The probe pulls into <report>/system; accept either that or a bare tree.
    sysroot = os.path.join(report, "system")
    if not os.path.isdir(sysroot):
        sysroot = report

    if against:
        return check_port(sysroot, against)

    if symbols_of:
        return show_symbols(sysroot, symbols_of)

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
