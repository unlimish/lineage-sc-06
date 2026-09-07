/*
 * isdbt-dump.c - poke /dev/isdbt on an SC-06D and see what comes back.
 *
 * Two jobs:
 *
 *   1. Prove the plumbing works: the node opens, the ioctls succeed, the
 *      driver's GPIO power sequence runs, poll() behaves. On a fourteen-
 *      year-old handset this is worth establishing before anything else -
 *      if the tuner is dead, everything downstream is wasted effort.
 *
 *   2. Be the skeleton of TsSource (docs/08-アプリ設計.md): open, power on,
 *      poll, read, tee to a file. The app's read loop is this loop.
 *
 * WHAT THIS WILL NOT DO: produce a watchable stream. The GPL driver is a
 * pass-through - it moves bytes over SPI and knows nothing about tuning. The
 * NMI326 needs firmware and a channel before it emits transport stream, and
 * that sequence lives in libonesegdmxdriver.so, not here. So expect either
 * nothing at all, or bytes that are not TS. Both are useful results: they
 * tell you the path to the chip is open.
 *
 * Build. Two routes; the first needs no Android SDK at all.
 *
 *   A. Debian/Ubuntu cross-compiler (easiest - this program only uses POSIX,
 *      and a fully static binary does not care that the target runs Bionic):
 *
 *        sudo apt install gcc-arm-linux-gnueabihf
 *        arm-linux-gnueabihf-gcc -static -O2 -o isdbt-dump tools/isdbt-dump.c
 *
 *      If that binary will not run on the phone, try the soft-float variant:
 *        sudo apt install gcc-arm-linux-gnueabi
 *        arm-linux-gnueabi-gcc -static -O2 -o isdbt-dump tools/isdbt-dump.c
 *
 *   B. Android NDK (needed only if you later link against Bionic libraries):
 *
 *        export ANDROID_NDK=/path/to/android-ndk-r21e
 *        "$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi16-clang" \
 *            -static -O2 -o isdbt-dump tools/isdbt-dump.c
 *
 *      Set ANDROID_NDK to the real directory - there is no "..." in the path.
 *      Use r21e or older: newer NDKs dropped the API levels this device needs.
 *
 * Either way, -static matters. A dynamically linked binary built against a
 * modern toolchain will not start on Android 4.0.4.
 *
 * Run:
 *
 *   adb push isdbt-dump /data/local/tmp/
 *   adb shell chmod 755 /data/local/tmp/isdbt-dump
 *   adb shell su -c '/data/local/tmp/isdbt-dump -s 10 -o /sdcard/isdbt.bin'
 *   adb shell su -c 'dmesg | tail -40'      # look for isdbt_gpio_on
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* From drivers/media/nmi326/nmi326.h in the LineageOS d2 kernel. These are
 * the entire userspace interface: power, and interrupt bookkeeping. There is
 * deliberately no tune ioctl - see the file header. */
#define IOCTL_MAGIC 't'
#define IOCTL_ISDBT_POWER_ON                 _IO(IOCTL_MAGIC, 0)
#define IOCTL_ISDBT_POWER_OFF                _IO(IOCTL_MAGIC, 1)
#define IOCTL_ISDBT_INTERRUPT_REGISTER       _IO(IOCTL_MAGIC, 2)
#define IOCTL_ISDBT_INTERRUPT_UNREGISTER     _IO(IOCTL_MAGIC, 3)
#define IOCTL_ISDBT_INTERRUPT_ENABLE         _IO(IOCTL_MAGIC, 4)
#define IOCTL_ISDBT_INTERRUPT_DISABLE        _IO(IOCTL_MAGIC, 5)
#define IOCTL_ISDBT_INTERRUPT_DONE           _IO(IOCTL_MAGIC, 6)
#define IOCTL_ISDBT_INTERRUPT_HANDLER_START  _IO(IOCTL_MAGIC, 7)

#define DEV_PATH   "/dev/isdbt"
#define TS_PACKET  188
#define TS_SYNC    0x47
#define CHUNK      (TS_PACKET * 32)   /* keep reads a multiple of 188 */

static volatile sig_atomic_t g_stop = 0;

static void on_signal(int sig) { (void)sig; g_stop = 1; }

static void hexdump(const unsigned char *p, size_t n)
{
    size_t i, j;
    for (i = 0; i < n; i += 16) {
        printf("  %04zx  ", i);
        for (j = 0; j < 16; j++) {
            if (i + j < n) printf("%02x ", p[i + j]);
            else           printf("   ");
        }
        printf(" |");
        for (j = 0; j < 16 && i + j < n; j++) {
            unsigned char c = p[i + j];
            putchar((c >= 0x20 && c < 0x7f) ? c : '.');
        }
        printf("|\n");
    }
}

/* Does this look like MPEG-2 TS? Sync bytes land every 188 bytes, so check
 * several in a row rather than trusting one 0x47 - random data hits 0x47
 * about once every 256 bytes by chance. */
static int looks_like_ts(const unsigned char *p, size_t n, size_t *offset_out)
{
    size_t off, k;
    for (off = 0; off + TS_PACKET * 4 < n && off < TS_PACKET; off++) {
        if (p[off] != TS_SYNC) continue;
        for (k = 1; k < 4; k++)
            if (p[off + k * TS_PACKET] != TS_SYNC) break;
        if (k == 4) { if (offset_out) *offset_out = off; return 1; }
    }
    return 0;
}

static int try_ioctl(int fd, unsigned long req, const char *name)
{
    if (ioctl(fd, req) < 0) {
        printf("  %-34s FAILED (%s)\n", name, strerror(errno));
        return -1;
    }
    printf("  %-34s ok\n", name);
    return 0;
}

static void usage(const char *argv0)
{
    printf("usage: %s [-s SECONDS] [-o OUTFILE] [-d DEVICE] [-n] [-q]\n"
           "\n"
           "  -s SECONDS   how long to read for (default 10)\n"
           "  -o OUTFILE   write everything read to this file\n"
           "  -d DEVICE    read from this path instead of " DEV_PATH "\n"
           "               (a captured .ts file works, which is how the TS\n"
           "                detection here was checked without hardware)\n"
           "  -n           skip poll() and read() blindly.\n"
           "               The driver only reports POLLIN after its interrupt\n"
           "               handler fires, and the handler only fires once the\n"
           "               tuner has something to say - so before tuning, poll\n"
           "               times out forever. This reads the SPI bus anyway,\n"
           "               which tells you whether the chip answers at all.\n"
           "  -q           no hexdump of the first bytes\n"
           "\n"
           "Run as root: /dev/isdbt is system:system on stock.\n",
           argv0);
}

int main(int argc, char **argv)
{
    int seconds = 10, quiet = 0, opt, blind = 0, blind_tried = 0;
    const char *outpath = NULL;
    const char *devpath = DEV_PATH;
    int fd = -1, out = -1, rc = 1;
    unsigned char buf[CHUNK];
    unsigned long long total = 0;
    int reads = 0, timeouts = 0, first = 1;
    time_t deadline;

    while ((opt = getopt(argc, argv, "s:o:d:nqh")) != -1) {
        switch (opt) {
        case 's': seconds = atoi(optarg); break;
        case 'o': outpath = optarg;       break;
        case 'd': devpath = optarg;       break;
        case 'q': quiet = 1;              break;
        case 'n': blind = 1;              break;
        default:  usage(argv[0]); return (opt == 'h') ? 0 : 2;
        }
    }
    if (seconds <= 0) seconds = 10;

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    /* Unbuffered: piped through "adb shell su -c", stdout is fully buffered,
     * so anything printed before a crash is lost with the buffer. That is how
     * a segfault inside dlopen came back as a bare "Segmentation fault" with
     * no output at all. */
    setvbuf(stdout, NULL, _IONBF, 0);

    printf("isdbt-dump - SC-06D tuner path check\n");
    printf("====================================\n\n");

    if (geteuid() != 0)
        printf("note: not running as root. Stock leaves %s mode 0666, so this\n"
               "      may still work - but if open fails, that is why.\n\n",
               DEV_PATH);

    int is_tuner = (strcmp(devpath, DEV_PATH) == 0);

    printf("opening %s ...\n", devpath);
    fd = open(devpath, is_tuner ? O_RDWR : O_RDONLY);
    if (fd < 0) {
        printf("  FAILED: %s\n\n", strerror(errno));
        if (errno == ENOENT)
            printf("The node does not exist. Either the kernel has no\n"
                   "CONFIG_ISDBT_NMI, or the driver did not probe. Check:\n"
                   "  cat /proc/devices | grep 225\n"
                   "  dmesg | grep -i isdbt\n");
        else if (errno == EACCES)
            printf("Permission denied - run this under su.\n");
        return 1;
    }
    printf("  ok (fd %d)\n\n", fd);

    if (!is_tuner) {
        printf("(-d given: skipping the tuner ioctls and just reading)\n\n");
        goto read_loop;
    }

    printf("ioctls:\n");
    if (try_ioctl(fd, IOCTL_ISDBT_POWER_ON, "POWER_ON") < 0) {
        printf("\nPower-on failed. The driver could not drive the PMIC GPIOs\n"
               "(ISDBT_EN / ISDBT_RST). Look for 'Failed to request gpio' in\n"
               "dmesg. Without this nothing else can work.\n");
        goto out;
    }

    /* The power sequence in board-m2_dcm.c takes ~62ms: enable, 50ms, reset
     * low, 2ms, reset high, 10ms. Give it room before touching the chip. */
    usleep(150 * 1000);

    try_ioctl(fd, IOCTL_ISDBT_INTERRUPT_REGISTER, "INTERRUPT_REGISTER");
    try_ioctl(fd, IOCTL_ISDBT_INTERRUPT_ENABLE,   "INTERRUPT_ENABLE");
    try_ioctl(fd, IOCTL_ISDBT_INTERRUPT_HANDLER_START, "INTERRUPT_HANDLER_START");

    printf("\ncheck dmesg now - you should see 'isdbt_gpio_on'.\n");
    printf("That line means the tuner was actually powered. It is the first\n");
    printf("real evidence the hardware is alive.\n\n");

read_loop:
    if (outpath) {
        out = open(outpath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (out < 0)
            printf("warning: cannot write %s (%s) - continuing without\n\n",
                   outpath, strerror(errno));
        else
            printf("writing to %s\n\n", outpath);
    }

    printf("reading for %d second(s)  (Ctrl-C to stop early) ...\n\n", seconds);
    deadline = time(NULL) + seconds;

    while (!g_stop && time(NULL) < deadline) {
        struct pollfd pfd;
        ssize_t n;

        pfd.fd = fd;
        pfd.events = POLLIN;
        pfd.revents = 0;

        if (!blind) {
            int pr = poll(&pfd, 1, 500);
            if (pr < 0) {
                if (errno == EINTR) continue;
                printf("poll: %s\n", strerror(errno));
                break;
            }
            if (pr == 0) {
                timeouts++;
                /*
                 * isdbt_poll() only sets POLLIN after isdbt_irq_handler() has
                 * run, and that only happens when the tuner asserts its
                 * interrupt line - which an untuned chip never does. So poll
                 * timing out here is the expected state, not a fault. Try one
                 * blind read anyway: whatever the SPI bus returns says
                 * something about whether the chip is answering.
                 */
                if (timeouts == 3 && !blind_tried) {
                    blind_tried = 1;
                    printf("poll has timed out 3 times - the driver's interrupt\n"
                           "handler has not fired, which is expected before tuning.\n"
                           "Trying one blind read to see if the SPI bus answers ...\n");
                    {
                        ssize_t bn = read(fd, buf, sizeof buf);
                        if (bn > 0) {
                            printf("  blind read returned %zd bytes:\n", bn);
                            if (!quiet) hexdump(buf, (size_t)bn < 64 ? (size_t)bn : 64);
                        } else if (bn == 0) {
                            printf("  blind read returned 0 (nothing queued)\n");
                        } else {
                            printf("  blind read failed: %s\n", strerror(errno));
                        }
                    }
                    printf("\n");
                }
                continue;
            }
        }

        if (blind) usleep(50 * 1000);

        n = read(fd, buf, sizeof buf);
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN) continue;
            printf("read: %s\n", strerror(errno));
            break;
        }
        if (n == 0) continue;

        reads++;
        total += (unsigned long long)n;

        if (first) {
            size_t off = 0;
            first = 0;
            printf("first read: %zd bytes\n", n);
            if (!quiet) {
                hexdump(buf, (size_t)n < 96 ? (size_t)n : 96);
                printf("\n");
            }
            if (looks_like_ts(buf, (size_t)n, &off))
                printf("  *** looks like MPEG-2 TS (sync at offset %zu) ***\n\n", off);
            else
                printf("  not TS yet - expected, since nothing has tuned the\n"
                       "  chip. See docs/08-アプリ設計.md section 6.\n\n");
        }

        if (out >= 0) {
            ssize_t off2 = 0;
            while (off2 < n) {
                ssize_t w = write(out, buf + off2, (size_t)(n - off2));
                if (w <= 0) {
                    printf("write to output failed: %s\n", strerror(errno));
                    close(out);
                    out = -1;
                    break;
                }
                off2 += w;
            }
        }

        /* IOCTL_ISDBT_INTERRUPT_DONE tells the driver the handler is finished
         * so it can re-arm. Harmless if this build of the driver ignores it. */
        if (is_tuner)
            ioctl(fd, IOCTL_ISDBT_INTERRUPT_DONE);
        else if (n < (ssize_t)sizeof buf)
            break;   /* -d on a regular file: stop at EOF instead of spinning */
    }

    printf("\n--- result ---\n");
    printf("reads          : %d\n", reads);
    printf("poll timeouts  : %d\n", timeouts);
    printf("bytes read     : %llu\n", total);
    if (outpath && out >= 0) printf("written to     : %s\n", outpath);

    printf("\n");
    if (total == 0) {
        printf("Nothing came back. That is the expected result at this stage:\n"
               "the chip has had no firmware and no channel, so it has nothing\n"
               "to send, and the driver's interrupt never fires - which is why\n"
               "poll only ever times out.\n\n"
               "What matters is that open and POWER_ON succeeded and that dmesg\n"
               "shows isdbt_gpio_on. The path to the tuner is open and the\n"
               "hardware responds.\n\n"
               "Next: drive the tuner through the stock library.\n"
               "  tools/oneseg-api-probe.c  (see docs/07 section 5)\n");
    } else {
        printf("Bytes came back. Check %s with:\n",
               outpath ? outpath : "the output (re-run with -o FILE)");
        printf("  xxd FILE | head\n");
        printf("  ffprobe FILE       # if it is TS, this will say so\n");
    }

    rc = 0;

out:
    if (out >= 0) { fsync(out); close(out); }
    if (fd >= 0) {
        if (is_tuner) {
            ioctl(fd, IOCTL_ISDBT_INTERRUPT_DISABLE);
            ioctl(fd, IOCTL_ISDBT_INTERRUPT_UNREGISTER);
            ioctl(fd, IOCTL_ISDBT_POWER_OFF);  /* else the tuner keeps draining the battery */
        }
        close(fd);
    }
    return rc;
}
