/*
 * oneseg-api-probe.c - call libonesegdmxdriver.so directly and find out how
 * the SC-06D tuner is actually driven.
 *
 * The library exports 141 symbols with C linkage - no C++ mangling - so every
 * one of them is reachable with dlsym. That is the whole opportunity here: the
 * tuner API is not hidden, only undocumented. What the symbols do not carry is
 * argument types, and this program is how you find those out.
 *
 * Run it on the STOCK ROM. The stack is intact there, so a working sequence
 * discovered now is ground truth to reproduce later - and you learn whether
 * the fourteen-year-old tuner still works before committing to a flash.
 *
 * The interesting names, from the survey:
 *
 *   OneSegDrv_Initailze        (Samsung's typo, kept verbatim)
 *   OneSegDrv_SetChannel       tune
 *   OneSegDrv_CheckChannelLock did it lock on
 *   OneSegDrv_ReadData         TS out
 *   OneSegDrv_ReleaseChannel / OneSegDrv_Finalize
 *   OneSegDrv_GetRSSI / GetCN / GetBerPer / GetSingalStatistics
 *
 * CALLING UNKNOWN SIGNATURES SAFELY
 *
 * Under the ARM procedure call standard the first four integer arguments go
 * in r0-r3 and the caller cleans up, so calling a function with MORE integer
 * arguments than it takes is harmless - the extra registers are ignored.
 * Calling with FEWER is not: the callee reads whatever was left in the
 * register. So every unknown function here is called through a four-argument
 * prototype, with the guesses in the leading slots and zeros after.
 *
 * A wrong guess can still fault. Each call runs under a SIGSEGV/SIGBUS/SIGILL
 * handler that longjmps back, so one bad guess reports "crashed" instead of
 * killing the run. That is a probe, not a safety net - the library may be
 * left in an odd state afterwards, so re-run rather than continuing past a
 * crash.
 *
 * BUILD - this one needs the NDK, because it dlopens a Bionic library and so
 * must itself be a dynamically linked Bionic binary. (isdbt-dump.c has no
 * such constraint and builds with a plain apt cross-compiler.)
 *
 *   export ANDROID_NDK=/path/to/android-ndk-r21e
 *   "$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi16-clang" \
 *       -O2 -o oneseg-api-probe tools/oneseg-api-probe.c -ldl
 *
 * Use r21e or older: later NDKs dropped the API levels this device needs.
 *
 * RUN
 *
 *   adb push oneseg-api-probe /data/local/tmp/
 *   adb shell chmod 755 /data/local/tmp/oneseg-api-probe
 *
 *   # 1. safe: load the library, resolve symbols, read build info. No tuner.
 *   adb shell su -c '/data/local/tmp/oneseg-api-probe'
 *
 *   # 2. attempt a real tune on physical channel 27, 10 seconds of TS
 *   adb shell su -c '/data/local/tmp/oneseg-api-probe -t 27 -s 10 -o /sdcard/ch27.ts'
 *
 * Japanese terrestrial physical channels are 13-52. Find a local one from a
 * channel list for your area; trying every channel blind takes a while.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define LIB_DEFAULT "/system/lib/libonesegdmxdriver.so"
#define TS_PACKET   188
#define TS_SYNC     0x47
#define TSBUF       (TS_PACKET * 64)

/* Everything unknown is called through this. See the header. */
typedef long (*fn4_t)(long, long, long, long);

static void *g_lib;
static sigjmp_buf g_jmp;
static volatile sig_atomic_t g_faulted;

static void fault_handler(int sig)
{
    g_faulted = sig;
    siglongjmp(g_jmp, 1);
}

/* Resolve a symbol, reporting whether it was there. */
static void *sym(const char *name, int quiet)
{
    void *p;
    dlerror();
    p = dlsym(g_lib, name);
    if (!p && !quiet)
        printf("  %-32s MISSING\n", name);
    else if (!quiet)
        printf("  %-32s %p\n", name, p);
    return p;
}

/*
 * Call an unknown function under a fault handler.
 * Returns 0 on a clean call (result in *out), -1 if it faulted.
 */
static int safe_call(void *fp, const char *name,
                     long a, long b, long c, long d, long *out)
{
    struct sigaction sa, old_segv, old_bus, old_ill;
    volatile long r = 0;
    int rc = 0;

    if (!fp) {
        printf("  %-28s -> not resolved, skipped\n", name);
        return -1;
    }

    memset(&sa, 0, sizeof sa);
    sa.sa_handler = fault_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &old_segv);
    sigaction(SIGBUS,  &sa, &old_bus);
    sigaction(SIGILL,  &sa, &old_ill);

    g_faulted = 0;
    if (sigsetjmp(g_jmp, 1) == 0) {
        r = ((fn4_t)fp)(a, b, c, d);
        /* These APIs return int, and errors are conventionally negative, so
         * show the low 32 bits signed as well as raw - a bare unsigned 0x...
         * hides the difference between "-5" and a huge success value. */
        printf("  %-28s -> %d  (raw 0x%lx)\n",
               name, (int)(r & 0xffffffffL), (unsigned long)r);
        if (out) *out = r;
    } else {
        printf("  %-28s -> CRASHED (signal %d)\n", name, (int)g_faulted);
        rc = -1;
    }

    sigaction(SIGSEGV, &old_segv, NULL);
    sigaction(SIGBUS,  &old_bus,  NULL);
    sigaction(SIGILL,  &old_ill,  NULL);
    return rc;
}

/* Print a data symbol as a string, without running off the end of memory. */
static void print_str_sym(const char *name)
{
    struct sigaction sa, old_segv;
    const char *p = (const char *)dlsym(g_lib, name);
    char safe[257];
    size_t i;

    if (!p) return;

    memset(&sa, 0, sizeof sa);
    sa.sa_handler = fault_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &old_segv);

    g_faulted = 0;
    if (sigsetjmp(g_jmp, 1) == 0) {
        for (i = 0; i < sizeof safe - 1; i++) {
            char ch = p[i];
            if (ch == '\0') break;
            safe[i] = (ch >= 0x20 && ch < 0x7f) ? ch : '.';
        }
        safe[i] = '\0';
        if (i) printf("  %-16s %s\n", name, safe);
    } else {
        printf("  %-16s <unreadable>\n", name);
    }

    sigaction(SIGSEGV, &old_segv, NULL);
}

static int looks_like_ts(const unsigned char *p, size_t n, size_t *off_out)
{
    size_t off, k;
    for (off = 0; off + TS_PACKET * 4 < n && off < TS_PACKET; off++) {
        if (p[off] != TS_SYNC) continue;
        for (k = 1; k < 4; k++)
            if (p[off + k * TS_PACKET] != TS_SYNC) break;
        if (k == 4) { if (off_out) *off_out = off; return 1; }
    }
    return 0;
}

static void show_last_error(void)
{
    void *f = dlsym(g_lib, "get_last_err_info");
    long r;
    if (!f) return;
    if (safe_call(f, "get_last_err_info", 0, 0, 0, 0, &r) == 0 && r) {
        /* The return may be a pointer to a message. Try to read it. */
        struct sigaction sa, old;
        const char *p = (const char *)r;
        char buf[129];
        size_t i;
        memset(&sa, 0, sizeof sa);
        sa.sa_handler = fault_handler;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGSEGV, &sa, &old);
        g_faulted = 0;
        if (sigsetjmp(g_jmp, 1) == 0) {
            for (i = 0; i < sizeof buf - 1 && p[i]; i++)
                buf[i] = (p[i] >= 0x20 && p[i] < 0x7f) ? p[i] : '.';
            buf[i] = '\0';
            if (i > 1) printf("      last error text: %s\n", buf);
        }
        sigaction(SIGSEGV, &old, NULL);
    }
}

static void usage(const char *a0)
{
    printf("usage: %s [-l LIB] [-t CHANNEL] [-s SECONDS] [-o OUTFILE]\n"
           "\n"
           "  -l LIB       library to probe (default " LIB_DEFAULT ")\n"
           "  -t CHANNEL   attempt a real tune on this physical channel\n"
           "               (Japanese terrestrial: 13-52). Without -t the\n"
           "               program only loads and inspects - it never\n"
           "               touches the tuner.\n"
           "  -s SECONDS   how long to read TS for after tuning (default 10)\n"
           "  -o OUTFILE   write the TS to this file\n"
           "  -m MAXMB     stop after this many MB (default 64). 1seg runs\n"
           "               about 400kbps, so a sane capture is well under 1MB\n"
           "               per 10s - the cap is here so a misread length\n"
           "               cannot fill the phone's storage.\n"
           "\n"
           "Run under su.\n", a0);
}

int main(int argc, char **argv)
{
    const char *libpath = LIB_DEFAULT;
    const char *outpath = NULL;
    int channel = -1, seconds = 10, opt;
    long max_mb = 64;
    void *f_init, *f_fin, *f_set, *f_rel, *f_read, *f_lock, *f_state, *f_rssi, *f_cn;
    long r;

    while ((opt = getopt(argc, argv, "l:t:s:o:m:h")) != -1) {
        switch (opt) {
        case 'l': libpath = optarg;        break;
        case 't': channel = atoi(optarg);  break;
        case 's': seconds = atoi(optarg);  break;
        case 'o': outpath = optarg;        break;
        case 'm': max_mb = atol(optarg);   break;
        default:  usage(argv[0]); return (opt == 'h') ? 0 : 2;
        }
    }
    if (seconds <= 0) seconds = 10;

    printf("oneseg-api-probe\n================\n\n");

    /* ---- 1. load ---- */
    printf("dlopen %s\n", libpath);
    g_lib = dlopen(libpath, RTLD_NOW);
    if (!g_lib) {
        printf("  FAILED: %s\n\n", dlerror());
        printf("On stock this should just work. On a ported system this is\n"
               "the first real test: the message above names the missing\n"
               "dependency or the symbol the Pie linker would not provide.\n"
               "See docs/05 step 5.\n");
        return 1;
    }
    printf("  ok\n\n");

    /* ---- 2. build provenance ---- */
    printf("build info:\n");
    print_str_sym("___Date");
    print_str_sym("___Revision");
    print_str_sym("___URL");
    printf("\n");

    /* ---- 3. resolve the API ---- */
    printf("high-level API:\n");
    f_init  = sym("OneSegDrv_Initailze", 0);     /* sic */
    f_fin   = sym("OneSegDrv_Finalize", 0);
    f_set   = sym("OneSegDrv_SetChannel", 0);
    f_rel   = sym("OneSegDrv_ReleaseChannel", 0);
    f_read  = sym("OneSegDrv_ReadData", 0);
    f_lock  = sym("OneSegDrv_CheckChannelLock", 0);
    f_state = sym("OneSegDrv_CheckChipState", 0);
    f_rssi  = sym("OneSegDrv_GetRSSI", 0);
    f_cn    = sym("OneSegDrv_GetCN", 0);
    printf("\n");

    printf("lower layers (informational):\n");
    sym("oneseg_drv_open", 0);
    sym("oneseg_power_on", 0);
    sym("oneseg_set_channel", 0);
    sym("BBM_TUNER_SET_FREQ", 0);
    sym("oem_init_spi", 0);
    sym("queue_read", 0);
    printf("\n");

    if (channel < 0) {
        printf("No -t given, so nothing was called. The tuner is untouched.\n\n");
        printf("Next: pick a physical channel that broadcasts where you are\n");
        printf("(13-52) and run, as root:\n\n");
        printf("  %s -t 27 -s 10 -o /sdcard/ch27.ts\n\n", argv[0]);
        printf("Then check the capture on a PC:\n");
        printf("  adb pull /sdcard/ch27.ts && ffprobe ch27.ts\n");
        dlclose(g_lib);
        return 0;
    }

    /* ---- 4. attempt the sequence ---- */
    printf("=== attempting tune on physical channel %d ===\n\n", channel);
    printf("Argument types are unknown, so each call goes through a\n");
    printf("four-argument prototype. A return of 0 usually means success in\n");
    printf("this style of API; nonzero is often an error code.\n\n");

    if (safe_call(f_init, "OneSegDrv_Initailze", 0, 0, 0, 0, &r) < 0)
        goto done;
    show_last_error();

    safe_call(f_state, "OneSegDrv_CheckChipState", 0, 0, 0, 0, &r);

    /*
     * SetChannel almost certainly takes the physical channel number, but it
     * could want a frequency in kHz. Japanese UHF physical channel N has its
     * centre at 473143 + (N-13)*6000 kHz. Try the channel number first, and
     * only fall back if that is rejected - a tuner told to go to 27 kHz will
     * simply fail to lock rather than do anything harmful.
     */
    if (safe_call(f_set, "OneSegDrv_SetChannel(ch)", channel, 0, 0, 0, &r) == 0 && r != 0) {
        long khz = 473143L + (long)(channel - 13) * 6000L;
        printf("      nonzero - retrying as a frequency (%ld kHz)\n", khz);
        safe_call(f_set, "OneSegDrv_SetChannel(kHz)", khz, 0, 0, 0, &r);
    }
    show_last_error();

    printf("\nwaiting for lock ...\n");
    {
        int i;
        for (i = 0; i < 10; i++) {
            sleep(1);
            if (safe_call(f_lock, "OneSegDrv_CheckChannelLock", 0, 0, 0, 0, &r) < 0)
                break;
            if (r) { printf("      locked after %ds\n", i + 1); break; }
        }
    }
    safe_call(f_rssi, "OneSegDrv_GetRSSI", 0, 0, 0, 0, &r);
    safe_call(f_cn,   "OneSegDrv_GetCN",   0, 0, 0, 0, &r);

    /* ---- 5. read ---- */
    printf("\nreading for %d second(s) ...\n", seconds);
    {
        unsigned char *buf = malloc(TSBUF);
        int out = -1, first = 1, calls = 0;
        unsigned long long total = 0;
        time_t deadline = time(NULL) + seconds;
        unsigned long long cap = (max_mb > 0)
            ? (unsigned long long)max_mb * 1024ULL * 1024ULL : 0ULL;

        if (!buf) { printf("  out of memory\n"); goto done; }
        if (outpath) {
            out = open(outpath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (out < 0) printf("  cannot write %s: %s\n", outpath, strerror(errno));
        }

        while (time(NULL) < deadline) {
            memset(buf, 0, TSBUF);
            if (safe_call(f_read, "OneSegDrv_ReadData", (long)buf, TSBUF, 0, 0, &r) < 0)
                break;
            calls++;

            if (r <= 0) { usleep(100 * 1000); continue; }
            if (r > TSBUF) {                       /* not a byte count */
                printf("      return %ld exceeds the buffer - it is a status,\n"
                       "      not a length. The data may arrive by the callback\n"
                       "      in g_pfdtvtscb instead.\n", r);
                break;
            }
            total += (unsigned long long)r;
            if (cap && total > cap) {
                printf("      hit the %ld MB cap - stopping. If this is real TS,\n"
                       "      raise it with -m; if it filled up instantly, the\n"
                       "      return value is not a byte count.\n", max_mb);
                break;
            }

            if (first) {
                size_t off = 0;
                first = 0;
                if (looks_like_ts(buf, (size_t)r, &off))
                    printf("\n  *** MPEG-2 TS, sync at offset %zu ***\n\n", off);
                else
                    printf("\n  data, but not TS-shaped. First bytes:"
                           " %02x %02x %02x %02x\n\n",
                           buf[0], buf[1], buf[2], buf[3]);
            }
            if (out >= 0) {
                long off2 = 0;
                while (off2 < r) {
                    ssize_t w = write(out, buf + off2, (size_t)(r - off2));
                    if (w <= 0) break;
                    off2 += w;
                }
            }
        }

        if (out >= 0) { fsync(out); close(out); }
        free(buf);

        printf("\n  ReadData calls : %d\n", calls);
        printf("  bytes          : %llu\n", total);
        if (outpath) printf("  written to     : %s\n", outpath);

        if (total > 0) {
            printf("\n  *** This is the result the whole port was waiting for. ***\n");
            printf("  Pull it and confirm on a PC:\n");
            printf("    adb pull %s\n", outpath ? outpath : "/sdcard/out.ts");
            printf("    ffprobe FILE\n");
        } else {
            printf("\n  Nothing read. Either the channel does not broadcast here,\n");
            printf("  the antenna is retracted, SetChannel wants different\n");
            printf("  arguments, or TS arrives through the g_pfdtvtscb callback\n");
            printf("  rather than by return. Try another channel first - that is\n");
            printf("  the cheapest thing to rule out.\n");
        }
    }

done:
    printf("\ncleaning up ...\n");
    safe_call(f_rel, "OneSegDrv_ReleaseChannel", 0, 0, 0, 0, &r);
    safe_call(f_fin, "OneSegDrv_Finalize", 0, 0, 0, 0, &r);
    dlclose(g_lib);
    printf("\nExtend the antenna before blaming the software.\n");
    return 0;
}
