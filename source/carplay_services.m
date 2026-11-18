/*
 * carplay_services.m - Wireless CarPlay protocol service for Showcase
 *
 * Provides mDNS, AirPlay RTSP, pairing, BAA authentication, timing, video,
 * audio, event commands, and HID transport.
 */

#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <errno.h>
#include <dns_sd.h>
#include <dispatch/dispatch.h>
#include <net/if.h>
#include <ifaddrs.h>
#include <sys/time.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdbool.h>
#include <dlfcn.h>
#include <CommonCrypto/CommonCrypto.h>
#include <Security/Security.h>
#include <sys/un.h>
#include <sys/sysctl.h>
#include <sys/ioctl.h>
#include <signal.h>
#include <time.h>
#include <float.h>
#include <stdarg.h>
#include <pthread.h>
#include <poll.h>
#include <stdatomic.h>
#include <limits.h>
#include <mach/mach_time.h>
#include "carplay_pair.h"
#include "baa_broker.h"
#include "video_in_car.h"
#include "vendor/monocypher/monocypher.h"

/*
 * Prefix every service log line with a monotonic timestamp.  The line-state
 * tracking matters because several packet dumps are emitted by many short
 * printf calls.
 */
static pthread_mutex_t g_service_log_lock = PTHREAD_MUTEX_INITIALIZER;
static bool g_service_log_at_line_start = true;

/*
 * The app truncates carplay_services.log only when it spawns the daemon, and
 * the daemon can wait in AwaitingPhone for days while LAN peers reach port
 * 7000. Bound the file in place: once it passes the cap, keep the head
 * (launch arguments and the first negotiation) and drop the rest. stdout is
 * opened O_APPEND by spawn_daemon, so later writes continue at the new end.
 * Checked every SERVICE_LOG_CHECK_BYTES so normal logging stays cheap; fstat
 * also accounts for stderr and direct fwrite output sharing the file.
 */
#define SERVICE_LOG_MAX_BYTES   (8 * 1024 * 1024)
#define SERVICE_LOG_KEEP_BYTES  (1024 * 1024)
#define SERVICE_LOG_CHECK_BYTES (64 * 1024)
static size_t g_service_log_unchecked_bytes = 0;

/* Caller holds g_service_log_lock. */
static void service_log_enforce_cap_locked(void) {
    if (g_service_log_unchecked_bytes < SERVICE_LOG_CHECK_BYTES) return;
    g_service_log_unchecked_bytes = 0;
    fflush(stdout);
    struct stat st;
    int fd = fileno(stdout);
    if (fd < 0 || fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) return;
    if (st.st_size <= SERVICE_LOG_MAX_BYTES) return;
    if (ftruncate(fd, SERVICE_LOG_KEEP_BYTES) != 0) return;
    fseeko(stdout, 0, SEEK_END);
    fprintf(stdout, "\n[LOG] carplay_services.log reached %lld bytes; "
                    "dropped everything after the first %d bytes\n",
            (long long)st.st_size, SERVICE_LOG_KEEP_BYTES);
    g_service_log_at_line_start = true;
}

int showcase_service_log_printf(const char *format, ...) {
    va_list args;
    va_start(args, format);
    va_list copied;
    va_copy(copied, args);
    int length = vsnprintf(NULL, 0, format, copied);
    va_end(copied);
    if (length < 0) {
        va_end(args);
        return length;
    }

    char *rendered = malloc((size_t)length + 1);
    if (!rendered) {
        va_end(args);
        return -1;
    }
    vsnprintf(rendered, (size_t)length + 1, format, args);
    va_end(args);

    pthread_mutex_lock(&g_service_log_lock);
    const char *cursor = rendered;
    const char *end = rendered + length;
    while (cursor < end) {
        if (g_service_log_at_line_start) {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            fprintf(stdout, "[%lld.%06lld] ",
                    (long long)now.tv_sec,
                    (long long)(now.tv_nsec / 1000));
            g_service_log_at_line_start = false;
        }
        const char *newline = memchr(cursor, '\n', (size_t)(end - cursor));
        size_t chunk = newline ? (size_t)(newline - cursor + 1)
                               : (size_t)(end - cursor);
        fwrite(cursor, 1, chunk, stdout);
        cursor += chunk;
        if (newline) g_service_log_at_line_start = true;
    }
    g_service_log_unchecked_bytes += (size_t)length;
    service_log_enforce_cap_locked();
    pthread_mutex_unlock(&g_service_log_lock);
    free(rendered);
    return length;
}

#define printf showcase_service_log_printf

/* ── Forward declarations for IPC status events
 * (defined fully below near the IPC machinery, but used earlier in
 * pair-setup / pair-verify handlers). ── */
#define STATUS_IPHONE_CONNECTED     0x01
#define STATUS_PAIR_SETUP_COMPLETE  0x02
#define STATUS_PAIR_VERIFY_COMPLETE 0x03
#define STATUS_STREAM_SETUP         0x04
#define STATUS_PAIR_SETUP_STARTED   0x05   /* first pairing with this iPhone */
#define STATUS_AUTH_COMPLETE        0x06   /* accessory certificate accepted */
#define STATUS_SESSION_SETUP        0x07   /* control session negotiated     */
#define STATUS_HOST_UI_REQUESTED    0x08   /* CarPlay OEM icon selected       */
static void app_send_status(uint8_t code);

/* Explicit test builds can negotiate playback without a vehicle-state source. */
#ifndef SHOWCASE_VIDEO_IN_CAR_BENCH
#define SHOWCASE_VIDEO_IN_CAR_BENCH 0
#endif
#ifndef SHOWCASE_MIRROR_BENCH
#define SHOWCASE_MIRROR_BENCH 0
#endif
static atomic_bool g_car_video_negotiated;
static void send_car_video_availability(void);

static NSDictionary *car_video_capabilities(uint64_t legacyFeatures) {
    uint8_t bits[9] = {0};
    legacyFeatures |= 1;
    for (size_t i = 0; i < 8; i++)
        bits[i] = (uint8_t)(legacyFeatures >> (i * 8));
    bits[8] = 1; /* Extended AirPlay feature 64. */
    NSData *featureData = [NSData dataWithBytes:bits length:sizeof(bits)];
    return @{
        @"videoPlaybackAllowed": @YES,
        @"featuresEx": [featureData base64EncodedStringWithOptions:0],
        @"playbackCapabilities": @{
            @"supportsOfflineHLS": @NO,
            @"supportsAirPlayVideoWithSharePlay": @NO,
            @"supportsInterstitials": @NO,
            @"supportsIntegratedTimeline": @NO,
            @"supportsAVMetrics": @NO,
            @"supportsUIForAudioOnlyContent": @YES,
            @"supportsFPSSecureStop": @NO
        }
    };
}

#define MSG_AUDIO_CONFIG 0x08
#define MSG_AUDIO_PACKET 0x09
#define MSG_BT_HANDOFF 0x0A
#define MSG_AUDIO_RENDER 0x0B
#define MSG_AUDIO_CONTROL 0x0C

#define AUDIO_CONTROL_PAUSE  0
#define AUDIO_CONTROL_RESUME 1
#define AUDIO_CONTROL_FLUSH  2
#define AUDIO_CONTROL_STOP   3

/* ── Configuration ── */
#define AIRPLAY_PORT 7000
#define DEVICE_ID    "90:B9:31:AC:86:A0"
#define DEVICE_ID_RAW "90B931AC86A0"        /* no colons, for _raop._tcp name */
#define DEVICE_ID_INT "159125076739744"     /* 0x90B931AC86A0 as decimal — for HTTP headers */
#define MODEL_NAME   "AirPlayGeneric1,1"    /* Apple SDK default for CarPlay receivers */

/* Runtime-configurable display name (the "car name" — what shows up in
 * Settings → General → CarPlay on the iPhone). Set via --name argv. */
static char g_instance_name[32] = "RoadLink";
static char g_raop_name[64]     = DEVICE_ID_RAW "@" "RoadLink";
static uint16_t g_display_width = 800;
static uint16_t g_display_height = 480;
static uint16_t g_display_fps = 60;
static int g_screen_receive_buffer = 176 * 1024;
static bool g_baa_broker_mode = false;
/* false: leave CarPlay audio on the sender (its speaker or its own car
 * Bluetooth), which is the Showcase default. true: claim MainAudio and play
 * the negotiated buffered/low-latency streams on this receiver. */
static bool g_receiver_audio = false;
/* When true, the receiver and sender are both on an existing Wi-Fi LAN
 * (for example a portable router).  Personal Hotspot's bridge100 is not
 * present in this mode, so mDNS and the wire announcement must use the
 * normal Wi-Fi interface instead. */
static bool g_shared_wifi = false;
static char g_wifi_interface[IFNAMSIZ] = "bridge100";
/* Places CarPlay's dock on the right edge, for right-hand-drive cars and for
 * displays mounted to the driver's right. */
static bool g_right_hand_drive = false;

/* A byte-limited copy may split a multi-byte UTF-8 sequence; drop the
 * incomplete trailing sequence so the name stays valid UTF-8 (otherwise
 * NSString stringWithUTF8String: returns nil and mDNS names are corrupt). */
static void truncate_utf8_tail(char *s) {
    size_t len = strlen(s);
    if (len == 0) return;
    size_t start = len;
    /* Walk back over at most 3 continuation bytes to the lead byte. */
    while (start > 0 && len - start < 4 &&
           ((unsigned char)s[start - 1] & 0xC0) == 0x80)
        start--;
    if (start == 0) { s[0] = '\0'; return; }
    unsigned char lead = (unsigned char)s[start - 1];
    size_t need;
    if (lead < 0x80) return;                 /* ASCII: complete */
    else if ((lead & 0xE0) == 0xC0) need = 2;
    else if ((lead & 0xF0) == 0xE0) need = 3;
    else if ((lead & 0xF8) == 0xF0) need = 4;
    else need = 0;                           /* invalid lead byte */
    if (need == 0 || len - (start - 1) < need)
        s[start - 1] = '\0';
}

static NSString *instance_name_string(void) {
    NSString *name = [NSString stringWithUTF8String:g_instance_name];
    return name.length > 0 ? name : @"RoadLink";
}

static void parse_args(int argc, char *argv[]) {
    for (int i = 1; i < argc; i++) {
        if ((!strcmp(argv[i], "--name") || !strcmp(argv[i], "-n")) &&
            i + 1 < argc) {
            strncpy(g_instance_name, argv[i+1], sizeof(g_instance_name) - 1);
            g_instance_name[sizeof(g_instance_name) - 1] = '\0';
            truncate_utf8_tail(g_instance_name);
            if (g_instance_name[0] == '\0')
                strlcpy(g_instance_name, "RoadLink", sizeof(g_instance_name));
            snprintf(g_raop_name, sizeof(g_raop_name),
                     "%s@%s", DEVICE_ID_RAW, g_instance_name);
            i++;
        } else if (!strcmp(argv[i], "--width") && i + 1 < argc) {
            long value = strtol(argv[++i], NULL, 10);
            if (value >= 640 && value <= UINT16_MAX)
                g_display_width = (uint16_t)value;
        } else if (!strcmp(argv[i], "--height") && i + 1 < argc) {
            long value = strtol(argv[++i], NULL, 10);
            if (value >= 360 && value <= UINT16_MAX)
                g_display_height = (uint16_t)value;
        } else if (!strcmp(argv[i], "--fps") && i + 1 < argc) {
            long value = strtol(argv[++i], NULL, 10);
            if (value >= 30 && value <= 60)
                g_display_fps = (uint16_t)value;
        } else if (!strcmp(argv[i], "--screen-rcvbuf") && i + 1 < argc) {
            long value = strtol(argv[++i], NULL, 10);
            if (value >= 64 * 1024 && value <= 4 * 1024 * 1024)
                g_screen_receive_buffer = (int)value;
        } else if (!strcmp(argv[i], "--right-hand-drive")) {
            g_right_hand_drive = true;
        } else if (!strcmp(argv[i], "--audio") && i + 1 < argc) {
            g_receiver_audio = strcmp(argv[++i], "receiver") == 0;
        } else if (!strcmp(argv[i], "--shared-wifi")) {
            g_shared_wifi = true;
        } else if (!strcmp(argv[i], "--wifi-interface") && i + 1 < argc) {
            g_shared_wifi = true;
            snprintf(g_wifi_interface, sizeof(g_wifi_interface), "%s", argv[++i]);
        } else if (!strcmp(argv[i], "--baa-broker")) {
            g_baa_broker_mode = true;
        }
    }
}
/* SRV hostname: NULL = use iPad's real hostname (RoadLink-CarPlay.local.)
 * which already has A/AAAA records. Using a custom hostname like
 * "RoadLink.local." fails because mDNSResponder doesn't auto-create
 * A/AAAA records for it, so the iPhone can't resolve it. */
#define SRV_HOSTNAME  NULL
#define SOURCE_VERSION "509.0"
#define CTRL_CONNECT_ATTEMPTS 3   /* attempts per resolved port */
#define CTRL_RESOLVE_ROUNDS   10  /* how many times to re-resolve */
#define CTRL_RETRY_SEC 2
#define MDNS_REANNOUNCE_SECONDS 300
#define MDNS_REANNOUNCE_INTERVAL 3

/* Accessory long-term Ed25519 identity — REAL key generated via PyNaCl.
 * It is shared by every installation (it is in the public source). A
 * per-device key would stop already-paired iPhones from pair-verifying (the
 * iPhone would see a known deviceid with a different key and ask to pair the
 * car again), so changing it is a product decision and stays parked.
 * pk = 32-byte Ed25519 public key, hex-encoded for TXT record.
 * sk = 32-byte Ed25519 private seed, stored for pair-setup/verify. */
#define ACCESSORY_STATE_DIR  "/var/root/Library/ShowcaseCarPlay"
#define HK_PK "1b15f0ad62c894721c4097651801e62845451a183c8df8af7d6b20430823586f"
#define HK_PI "29f0a5dc-2c2a-4b3e-9e5d-1a6c85f201a3"   /* UUID format, not MAC */
static const uint8_t ed25519_sk[32] = {
    0x95, 0x74, 0xdb, 0x39, 0x5b, 0x64, 0x5e, 0xae,
    0x89, 0xd1, 0xfa, 0x7d, 0x01, 0xb7, 0xa4, 0x6b,
    0x20, 0xa4, 0x45, 0x80, 0x19, 0xd7, 0x8e, 0x56,
    0x69, 0x25, 0xe5, 0x42, 0xed, 0x6a, 0xf3, 0x06
};
static const uint8_t ed25519_pk[32] = {
    0x1b, 0x15, 0xf0, 0xad, 0x62, 0xc8, 0x94, 0x72,
    0x1c, 0x40, 0x97, 0x65, 0x18, 0x01, 0xe6, 0x28,
    0x45, 0x45, 0x1a, 0x18, 0x3c, 0x8d, 0xf8, 0xaf,
    0x7d, 0x6b, 0x20, 0x43, 0x08, 0x23, 0x58, 0x6f
};
static const char g_hk_pk_hex[] = HK_PK;
static const char g_hk_pi[] = HK_PI;

/* Features bitmask — UxPlay base + MFi bit 26 restored for CarPlay:
 * Lower 32 = 0x5E7FFEE6:
 *   Bits 1-2:  Video/Photo
 *   Bit 5:     VideoFairPlayFP
 *   Bits 6-13: Volume/HTTP/Screen/ScreenRotate/Audio/etc.
 *   Bit 14:    FPSAPv2pt5_AES_GCM (FairPlay software auth)
 *   Bits 15-25: various audio/video capabilities
 *   Bit 26:    MFi-SAP auth (REQUIRED for CarPlay — iPhone won't connect without it)
 *              TomSignalius has it, wiomoc has it. Auth will need stubbing later.
 *   Bit 27,29-30: other capabilities
 * Upper 32 with HK = 0x61:
 *   Bit 0: Car (CarPlay capability)
 *   Bit 5: CarPlayControl
 *   Bit 6: HKPairingAndEncrypt
 * Upper 32 without HK = 0x21:
 *   Bit 0: Car
 *   Bit 5: CarPlayControl
 *
 * Bit 26 (0x04000000) = MFi-SAP v1 auth (auth-setup with raw 33-byte format).
 * Bit 22 (0x00400000) = AudioUnencrypted. */
/*
 * Match Apple's CarPlay Simulator advertisement exactly. Codec support is
 * negotiated through /info audioFormats; bit 20 is not an AAC-LC flag.
 */
#define FEATURES_WITH_HK   "0x4040280,0x61"
#define FEATURES_NO_HK     "0x4040280,0x21"

/* HK ON — bit 38 (HKPairingAndEncrypt). The newer Apple SDK unconditionally
 * sets this bit. iOS 18 may require it for CarPlay connections.
 * Without it, the iPhone may refuse to connect to port 7000. */
static bool g_useHK = true;

/* Global pairing context — initialized in main(), used by pair handlers */
static pair_ctx_t *g_pair = NULL;
/* g_pair holds one SRP / pair-verify state machine for the whole process, but
 * every control connection runs on its own thread. All calls into it (and
 * reads of its results) are serialized here. Lock order: g_pair_lock, then
 * g_control_owner_lock. */
static pthread_mutex_t g_pair_lock = PTHREAD_MUTEX_INITIALIZER;
/* The controller registry is this root daemon's authorization store: every
 * entry may pair-verify without the PIN. It therefore lives in the root-only
 * state directory, never in a mobile-writable location. */
#define PAIRING_STORE_PATH ACCESSORY_STATE_DIR "/paired-controllers.plist"
/* Former mobile-owned location. It is imported once into the root-only store
 * and then removed, so iPhones paired before the move keep pair-verifying
 * without asking to pair the car again. */
#define LEGACY_PAIRING_STORE_PATH \
    "/var/mobile/Library/Showcase/paired-controllers.plist"
/* The same location, walked one component at a time (see
 * open_legacy_showcase_dir) so no mobile-controlled symlink is followed. */
#define LEGACY_PAIRING_STORE_NAME "paired-controllers.plist"
#define MOBILE_UID 501
#define BT_ID_PATH "/tmp/showcase_bt_id"
/* /tmp is emptied at boot; the Bluetooth helper keeps a persistent copy so the
 * iPhone keeps seeing the same car identity even before BT re-reads its MAC. */
#define BT_ID_PERSIST_PATH "/var/mobile/Library/Showcase/bt-id"

/* Creates the root-only state directory and refuses one that is a symlink,
 * owned by another user, or reachable by group/other. */
static bool ensure_accessory_state_dir(void) {
    mkdir("/var/root/Library", 0755);
    if (mkdir(ACCESSORY_STATE_DIR, 0700) != 0 && errno != EEXIST) {
        printf("[PAIR] ERROR: cannot create %s: %s\n",
               ACCESSORY_STATE_DIR, strerror(errno));
        return false;
    }
    struct stat st;
    if (lstat(ACCESSORY_STATE_DIR, &st) != 0 || !S_ISDIR(st.st_mode) ||
        st.st_uid != 0) {
        printf("[PAIR] ERROR: %s is not a root-owned directory\n",
               ACCESSORY_STATE_DIR);
        return false;
    }
    if ((st.st_mode & 0077) != 0 && chmod(ACCESSORY_STATE_DIR, 0700) != 0) {
        printf("[PAIR] ERROR: cannot restrict %s: %s\n",
               ACCESSORY_STATE_DIR, strerror(errno));
        return false;
    }
    return true;
}

/* Reads a file only when it is a regular, root-owned, root-only file (the
 * final component is not followed if it is a symlink). */
static NSData *read_root_private_file(const char *path, size_t maxLength) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != 0 ||
        (st.st_mode & 0077) != 0 || st.st_size < 0 ||
        (uint64_t)st.st_size > maxLength) {
        printf("[PAIR] WARN: ignoring %s (not a root-only regular file)\n",
               path);
        close(fd);
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    uint8_t *bytes = data.mutableBytes;
    size_t got = 0;
    while (got < (size_t)st.st_size) {
        ssize_t n = read(fd, bytes + got, (size_t)st.st_size - got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        got += (size_t)n;
    }
    close(fd);
    return got == (size_t)st.st_size ? data : nil;
}

/* Atomically replaces path with a root-owned 0600 file. */
static bool write_root_private_file(const char *path, const void *bytes,
                                    size_t length) {
    char tmp[PATH_MAX];
    if (snprintf(tmp, sizeof(tmp), "%s.tmp", path) >= (int)sizeof(tmp))
        return false;
    unlink(tmp);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                  0600);
    if (fd < 0) return false;
    size_t written = 0;
    while (written < length) {
        ssize_t n = write(fd, (const uint8_t *)bytes + written,
                          length - written);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        written += (size_t)n;
    }
    bool ok = written == length && fchown(fd, 0, 0) == 0 &&
              fchmod(fd, 0600) == 0 && fsync(fd) == 0;
    if (close(fd) != 0) ok = false;
    if (ok && rename(tmp, path) != 0) ok = false;
    if (!ok) unlink(tmp);
    return ok;
}

/* Written once the legacy location has been dealt with, whether or not
 * there was anything to import. Without it, any process able to write the
 * mobile-owned legacy path could plant a controller key that a later start
 * would import into the root authorization store. */
#define LEGACY_PAIRING_MIGRATED_PATH \
    ACCESSORY_STATE_DIR "/legacy-pairing-migrated"

/* Copies the legacy registry into the root-only store. Returns true when the
 * legacy file may be removed: it was copied, the root store already exists,
 * or the legacy entry is not an importable regular file. Returns false when
 * it must be kept for a later attempt. */
static bool import_legacy_pairing_registry(int legacyDir) {
    struct stat st;
    if (lstat(PAIRING_STORE_PATH, &st) == 0) return true;
    if (errno != ENOENT) {
        printf("[PAIR] WARN: cannot inspect %s: %s\n",
               PAIRING_STORE_PATH, strerror(errno));
        return false;
    }
    /* O_NONBLOCK: a FIFO planted in the mobile-owned directory must not hang
     * the open (and with it every pair-setup/verify); S_ISREG rejects it. */
    int fd = openat(legacyDir, LEGACY_PAIRING_STORE_NAME,
                    O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        if (errno == ELOOP) return true;  /* a symlink: never imported */
        printf("[PAIR] WARN: cannot open the legacy controller registry: %s\n",
               strerror(errno));
        return false;
    }
    struct stat lst;
    if (fstat(fd, &lst) != 0) {
        close(fd);
        return false;
    }
    if (!S_ISREG(lst.st_mode) || lst.st_size <= 0 ||
        lst.st_size > 1024 * 1024) {
        close(fd);
        return true;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)lst.st_size];
    size_t got = 0;
    while (got < (size_t)lst.st_size) {
        ssize_t n = read(fd, (uint8_t *)data.mutableBytes + got,
                         (size_t)lst.st_size - got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        got += (size_t)n;
    }
    close(fd);
    if (got == (size_t)lst.st_size &&
        write_root_private_file(PAIRING_STORE_PATH, data.bytes, got)) {
        printf("[PAIR] Moved controller registry to the root-only store\n");
        return true;
    }
    printf("[PAIR] WARN: could not move the legacy controller registry\n");
    return false;
}

/* Reads the Bluetooth identity published by the Bluetooth helper. Both copies
 * live in locations other users can write, so the read must never block (a
 * FIFO), follow a symlink in the final component (/dev/zero), or read more
 * than a short regular file. Returns nil unless it holds XX:XX:XX:XX:XX:XX. */
static NSString *read_bt_id_at(int dirFd, const char *path) {
    int fd = openat(dirFd, path,
                    O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return nil;
    enum { BT_ID_MAX_FILE = 64 };
    char buf[BT_ID_MAX_FILE + 1];
    struct stat st;
    size_t got = 0;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size >= 0 &&
        st.st_size <= BT_ID_MAX_FILE) {
        while (got < (size_t)st.st_size) {
            ssize_t n = read(fd, buf + got, (size_t)st.st_size - got);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) break;
            got += (size_t)n;
        }
    }
    close(fd);
    while (got > 0 && (buf[got - 1] == '\n' || buf[got - 1] == '\r' ||
                       buf[got - 1] == ' ' || buf[got - 1] == '\t'))
        got--;
    if (got != 17) return nil;
    for (size_t i = 0; i < 17; i++) {
        bool ok = (i % 3 == 2) ? buf[i] == ':' : isxdigit((unsigned char)buf[i]);
        if (!ok) return nil;
    }
    buf[got] = '\0';
    return [NSString stringWithUTF8String:buf];
}

/* Opens the legacy mobile-owned directory without following a symlink in any
 * mobile-writable component: O_NOFOLLOW on the full path would protect only
 * the file name, and a mobile process could otherwise point "Showcase" at the
 * root-only state directory so the migration deletes the root registry.
 * Returns -1 with errno ENOENT when it does not exist, or another errno when
 * it is not a plain directory owned by mobile (or root). */
static int open_legacy_showcase_dir(void) {
    static const char *const components[] = { "mobile", "Library",
                                              "Showcase" };
    /* /var itself is a root-owned symlink to /private/var. */
    int dirFd = open("/var", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    for (size_t i = 0;
         dirFd >= 0 && i < sizeof(components) / sizeof(components[0]); i++) {
        int next = openat(dirFd, components[i],
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        int openErrno = errno;
        close(dirFd);
        dirFd = next;
        errno = openErrno;
    }
    if (dirFd < 0) return -1;
    struct stat st;
    if (fstat(dirFd, &st) != 0 || !S_ISDIR(st.st_mode) ||
        (st.st_uid != MOBILE_UID && st.st_uid != 0)) {
        close(dirFd);
        errno = EPERM;
        return -1;
    }
    return dirFd;
}

/* One-time move of the registry from the former mobile-owned location. The
 * legacy file is imported at most once (on the first start of this version)
 * and is removed only once it is safe to lose: a failure to create the root
 * store keeps it so paired iPhones are not forgotten. */
static void migrate_legacy_pairing_registry(void) {
    if (!ensure_accessory_state_dir()) return;
    struct stat st;
    bool migrated = lstat(LEGACY_PAIRING_MIGRATED_PATH, &st) == 0;
    int legacyDir = open_legacy_showcase_dir();
    if (legacyDir < 0 && errno != ENOENT) {
        /* A symlinked or foreign directory is never imported from or
         * cleaned up; record the migration so nothing planted later is. */
        printf("[PAIR] WARN: skipping the legacy controller registry: "
               "unexpected /var/mobile/Library/Showcase (%s)\n",
               strerror(errno));
    }
    bool legacyExists = legacyDir >= 0 &&
        fstatat(legacyDir, LEGACY_PAIRING_STORE_NAME, &st,
                AT_SYMLINK_NOFOLLOW) == 0;
    if (!migrated) {
        /* Only a regular file is ever opened for import; anything else (a
         * FIFO, a device node) is just cleaned up below. */
        if (legacyExists && S_ISREG(st.st_mode) &&
            !import_legacy_pairing_registry(legacyDir)) {
            close(legacyDir);
            return;
        }
        static const char marker[] = "1\n";
        if (!write_root_private_file(LEGACY_PAIRING_MIGRATED_PATH, marker,
                                     sizeof(marker) - 1))
            printf("[PAIR] WARN: could not record the registry migration\n");
    } else if (legacyExists) {
        printf("[PAIR] Ignoring a legacy controller registry written after "
               "the one-time migration\n");
    }
    if (legacyExists) unlinkat(legacyDir, LEGACY_PAIRING_STORE_NAME, 0);
    if (legacyDir >= 0) close(legacyDir);
}

static bool ensure_pair_context(void) {
    if (g_pair) return true;
    g_pair = pair_ctx_create(ed25519_sk, ed25519_pk, NULL);
    if (!g_pair) return false;

    @autoreleasepool { migrate_legacy_pairing_registry(); }

    @autoreleasepool {
        NSData *data = read_root_private_file(PAIRING_STORE_PATH,
                                              1024 * 1024);
        if (!data) {
            printf("[PAIR] No saved controller registry yet\n");
            return true;
        }
        NSError *error = nil;
        id value = [NSPropertyListSerialization
            propertyListWithData:data
                         options:NSPropertyListImmutable
                          format:NULL
                           error:&error];
        if (![value isKindOfClass:[NSArray class]]) {
            printf("[PAIR] Saved controller registry is invalid: %s\n",
                   error.localizedDescription.UTF8String ?: "unexpected root");
            return true;
        }
        for (id entry in (NSArray *)value) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            NSData *identifier = entry[@"identifier"];
            NSData *publicKey = entry[@"publicKey"];
            if (![identifier isKindOfClass:[NSData class]] ||
                ![publicKey isKindOfClass:[NSData class]] ||
                publicKey.length != 32)
                continue;
            pair_ctx_add_peer(g_pair, identifier.bytes, identifier.length,
                              publicKey.bytes);
        }
        printf("[PAIR] Restored %zu paired controller(s)\n",
               pair_ctx_peer_count(g_pair));
    }
    return true;
}

static void save_pairing_registry(void) {
    if (!g_pair) return;
    @autoreleasepool {
        NSMutableArray *entries = [NSMutableArray array];
        size_t count = pair_ctx_peer_count(g_pair);
        for (size_t i = 0; i < count; i++) {
            uint8_t identifier[128], publicKey[32];
            size_t identifierLength = 0;
            if (pair_ctx_get_peer(g_pair, i, identifier, sizeof(identifier),
                                  &identifierLength, publicKey) != 0)
                continue;
            [entries addObject:@{
                @"identifier": [NSData dataWithBytes:identifier
                                               length:identifierLength],
                @"publicKey": [NSData dataWithBytes:publicKey length:32]
            }];
        }
        NSError *error = nil;
        NSData *plist = [NSPropertyListSerialization
            dataWithPropertyList:entries
                          format:NSPropertyListBinaryFormat_v1_0
                         options:0
                           error:&error];
        if (!plist || !ensure_accessory_state_dir() ||
            !write_root_private_file(PAIRING_STORE_PATH, plist.bytes,
                                     plist.length)) {
            printf("[PAIR] ERROR: Could not persist controller registry: %s\n",
                   error.localizedDescription.UTF8String ?: "write failed");
            return;
        }
        printf("[PAIR] Persisted %zu paired controller(s)\n", entries.count);
    }
}

/* ═══════════════════════════════════════════════════════════════
 * BAA Certificate (for auth-setup MFi-SAP response)
 * ═══════════════════════════════════════════════════════════════ */
static uint8_t   *g_baa_leaf_der = NULL;
static int        g_baa_leaf_len = 0;
static uint8_t   *g_baa_inter_der = NULL;
static int        g_baa_inter_len = 0;
static bool       g_baa_ready = false;
static SecKeyRef  g_baa_broker_key = NULL;

/* g_baa_lock guards the certificate globals above in this process; once
 * g_baa_ready is set they are never replaced. g_baa_load_lock serializes
 * broker loads so concurrent auth-setup handlers (one detached thread per
 * control connection) cannot both fetch and race on the globals. */
static pthread_mutex_t g_baa_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_baa_load_lock = PTHREAD_MUTEX_INITIALIZER;

static void load_baa_from_broker(void) {
    pthread_mutex_lock(&g_baa_load_lock);
    pthread_mutex_lock(&g_baa_lock);
    bool alreadyReady = g_baa_ready;
    pthread_mutex_unlock(&g_baa_lock);
    if (alreadyReady) {
        pthread_mutex_unlock(&g_baa_load_lock);
        return;
    }

    printf("[BAA] Loading preheated certificate from Showcase...\n");
    uint8_t *leaf = NULL;
    uint8_t *intermediate = NULL;
    int leafLength = 0;
    int intermediateLength = 0;
    int rc = -1;
    for (int attempt = 0; attempt < 30 && rc != 0; attempt++) {
        rc = baa_broker_get_certs(&leaf, &leafLength,
                                  &intermediate, &intermediateLength);
        if (rc != 0) usleep(100000);
    }
    if (rc == 0) {
        /* Publish only a complete pair; ready is set last. */
        pthread_mutex_lock(&g_baa_lock);
        g_baa_leaf_der = leaf;
        g_baa_leaf_len = leafLength;
        g_baa_inter_der = intermediate;
        g_baa_inter_len = intermediateLength;
        g_baa_ready = true;
        pthread_mutex_unlock(&g_baa_lock);
        printf("[BAA] Leaf=%d Inter=%d — preheated and ready\n",
               leafLength, intermediateLength);
    } else {
        printf("[BAA] Could not retrieve preheated certificate (rc=%d)\n", rc);
    }
    pthread_mutex_unlock(&g_baa_load_lock);
}

static bool issue_baa_for_broker(void) {
    printf("[BAA] Preheating DeviceIdentity certificate before hotspot...\n");
    void *framework = dlopen(
        "/System/Library/PrivateFrameworks/DeviceIdentity.framework/DeviceIdentity",
        RTLD_NOW);
    if (!framework) {
        framework = dlopen(
            "/System/Library/PrivateFrameworks/MobileActivation.framework/MobileActivation",
            RTLD_NOW);
    }
    if (!framework) {
        printf("[BAA] Cannot load DeviceIdentity framework\n");
        return false;
    }

    typedef void (^DIBlock)(id, id, id);
    typedef void (*DIFunc)(id, id, DIBlock);
    DIFunc issue = (DIFunc)dlsym(
        framework, "DeviceIdentityIssueClientCertificateWithCompletion");
    if (!issue) {
        printf("[BAA] DeviceIdentity issuance function unavailable\n");
        return false;
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    issue(nil, [NSDictionary dictionary], ^(id key, id certificates, id error) {
        if (error) {
            NSLog(@"[BAA] Preheat error: %@", error);
            dispatch_semaphore_signal(semaphore);
            return;
        }
        NSArray *chain = (NSArray *)certificates;
        if (!key || [chain count] < 2) {
            printf("[BAA] Preheat returned an incomplete certificate chain\n");
            dispatch_semaphore_signal(semaphore);
            return;
        }

        g_baa_broker_key = (SecKeyRef)CFRetain((__bridge CFTypeRef)key);
        CFDataRef leaf = SecCertificateCopyData(
            (__bridge SecCertificateRef)chain[0]);
        CFDataRef intermediate = SecCertificateCopyData(
            (__bridge SecCertificateRef)chain[1]);
        g_baa_leaf_len = (int)CFDataGetLength(leaf);
        g_baa_inter_len = (int)CFDataGetLength(intermediate);
        g_baa_leaf_der = malloc(g_baa_leaf_len);
        g_baa_inter_der = malloc(g_baa_inter_len);
        if (g_baa_leaf_der && g_baa_inter_der) {
            memcpy(g_baa_leaf_der, CFDataGetBytePtr(leaf), g_baa_leaf_len);
            memcpy(g_baa_inter_der, CFDataGetBytePtr(intermediate),
                   g_baa_inter_len);
            g_baa_ready = true;
        }
        CFRelease(leaf);
        CFRelease(intermediate);
        dispatch_semaphore_signal(semaphore);
    });

    if (dispatch_semaphore_wait(
            semaphore,
            dispatch_time(DISPATCH_TIME_NOW, 45LL * NSEC_PER_SEC)) != 0) {
        printf("[BAA] Preheat timed out\n");
        return false;
    }
    if (g_baa_ready) {
        printf("[BAA] Preheated: leaf=%d intermediate=%d\n",
               g_baa_leaf_len, g_baa_inter_len);
    }
    return g_baa_ready && g_baa_broker_key;
}

static void baa_broker_handle_client(int client) {
    if (!baa_peer_is_root(client) || !baa_prepare_socket(client)) return;
    uint64_t deadline = baa_now_ms() + 3000;
    uint8_t header[BAA_BROKER_HEADER_SIZE];
    if (!baa_read_exact(client, header, sizeof(header), deadline) ||
        memcmp(header, BAA_BROKER_MAGIC, 4) != 0) return;
    uint8_t opcode = header[4];
    uint32_t requestLength = baa_read_le32(header + 8);
    if (requestLength > BAA_BROKER_MAX_PAYLOAD) return;

    uint8_t *request = NULL;
    if (requestLength > 0) {
        request = malloc(requestLength);
        if (!request || !baa_read_exact(client, request, requestLength, deadline)) {
            free(request);
            return;
        }
    }

    uint8_t status = BAA_STATUS_BAD_REQUEST;
    uint8_t *response = NULL;
    uint32_t responseLength = 0;
    if (!g_baa_ready || !g_baa_broker_key) {
        status = BAA_STATUS_NOT_READY;
    } else if (opcode == BAA_OP_GET_CERTS && requestLength == 0) {
        responseLength = 8U + (uint32_t)g_baa_leaf_len +
                         (uint32_t)g_baa_inter_len;
        response = malloc(responseLength);
        if (response) {
            baa_write_le32(response, (uint32_t)g_baa_leaf_len);
            baa_write_le32(response + 4, (uint32_t)g_baa_inter_len);
            memcpy(response + 8, g_baa_leaf_der, g_baa_leaf_len);
            memcpy(response + 8 + g_baa_leaf_len,
                   g_baa_inter_der, g_baa_inter_len);
            status = BAA_STATUS_OK;
        }
    } else if (opcode == BAA_OP_SIGN &&
               requestLength > 0 && requestLength <= 4096) {
        NSData *message = [NSData dataWithBytes:request length:requestLength];
        CFErrorRef error = NULL;
        CFDataRef signature = SecKeyCreateSignature(
            g_baa_broker_key,
            kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
            (__bridge CFDataRef)message, &error);
        if (signature) {
            responseLength = (uint32_t)CFDataGetLength(signature);
            response = malloc(responseLength);
            if (response) {
                memcpy(response, CFDataGetBytePtr(signature), responseLength);
                status = BAA_STATUS_OK;
            }
            CFRelease(signature);
        } else {
            status = BAA_STATUS_SIGN_FAILED;
            if (error) {
                NSLog(@"[BAA] Broker sign failed: %@", error);
                CFRelease(error);
            }
        }
    }
    free(request);

    baa_make_header(header, opcode, status, responseLength);
    baa_write_exact(client, header, sizeof(header), deadline);
    if (responseLength > 0)
        baa_write_exact(client, response, responseLength, deadline);
    free(response);
}

/* The key lives behind a token daemon connection that iOS drops when it sits
 * idle, after which signing fails. Signing every 30 s keeps it open; a broker
 * that can no longer sign exits so Showcase starts a fresh one. */
static bool baa_broker_key_usable(void) {
    static const uint8_t probe[] = "Showcase BAA keepalive";
    CFErrorRef error = NULL;
    CFDataRef signature = SecKeyCreateSignature(
        g_baa_broker_key, kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
        (__bridge CFDataRef)[NSData dataWithBytes:probe length:sizeof(probe) - 1], &error);
    if (signature) CFRelease(signature);
    if (error) {
        NSLog(@"[BAA] Broker keepalive failed: %@", error);
        CFRelease(error);
    }
    return signature != NULL;
}

static int run_baa_broker(void) {
    if (!issue_baa_for_broker()) return 1;

    unlink(BAA_BROKER_PATH);
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server < 0) return 1;
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, BAA_BROKER_PATH,
            sizeof(address.sun_path) - 1);
    if (bind(server, (struct sockaddr *)&address, sizeof(address)) < 0) {
        printf("[BAA] Broker socket failed: %s\n", strerror(errno));
        close(server);
        return 1;
    }
    /* Never accept signing requests on a socket whose permissions could not
     * be restricted. Set permissions before listen to avoid an open window. */
    if (chmod(BAA_BROKER_PATH, 0600) < 0 || listen(server, 4) < 0) {
        printf("[BAA] Broker socket protection/listen failed: %s\n", strerror(errno));
        close(server);
        unlink(BAA_BROKER_PATH);
        return 1;
    }
    printf("[BAA] Broker ready on %s\n", BAA_BROKER_PATH);

    while (1) {
        fd_set ready;
        FD_ZERO(&ready);
        FD_SET(server, &ready);
        struct timeval wait = { .tv_sec = 30, .tv_usec = 0 };
        int count = select(server + 1, &ready, NULL, NULL, &wait);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) break;
        if (count == 0) {
            bool usable;
            @autoreleasepool { usable = baa_broker_key_usable(); }
            if (!usable) break;
            continue;
        }
        int client = accept(server, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) continue;
            break;
        }
        @autoreleasepool {
            baa_broker_handle_client(client);
        }
        close(client);
    }
    close(server);
    unlink(BAA_BROKER_PATH);
    printf("[BAA] Broker exiting\n");
    return 0;
}

/* ═══════════════════════════════════════════════════════════════
 * Encrypted Transport (ChaCha20-Poly1305) after pair-verify
 *
 * Frame format: [2-byte LE length][ciphertext][16-byte auth tag]
 * - The 2-byte length header is used as AAD
 * - 8-byte nonce counter (LE), starts at 0, increments per message
 * - Apple's transport reads records up to 16 KiB but emits 1 KiB records
 * ═══════════════════════════════════════════════════════════════ */

#define ENCRYPTED_MAX_READ_SIZE  (16 * 1024)
#define ENCRYPTED_MAX_WRITE_SIZE 1024

typedef struct {
    uint8_t readKey[32];
    uint8_t writeKey[32];
    uint64_t readNonce;
    uint64_t writeNonce;
    bool active;
} encrypted_ctx_t;

static encrypted_ctx_t g_enc = {0};
static encrypted_ctx_t g_event_enc = {0};
/* The pairing and session implementation is process-wide. Only its owner may
 * mutate it; unrelated discovery connections must not inherit its cipher. */
static pthread_mutex_t g_control_owner_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_control_owner = -1;
static bool control_is_encrypted(int sock) {
    pthread_mutex_lock(&g_control_owner_lock);
    bool active = g_control_owner == sock && g_enc.active;
    pthread_mutex_unlock(&g_control_owner_lock);
    return active;
}
/* An owner that has not completed pair-verify within this window can be
 * displaced by another connection that starts pairing, so a LAN peer that
 * opens a pairing request and then idles cannot lock the iPhone out. */
#define CONTROL_UNVERIFIED_CLAIM_SECONDS 60
#define CONTROL_NANOS_PER_SECOND 1000000000ULL
/* Idle limits. A connection that has not started pairing only needs to
 * answer discovery probes; the verified pairing owner gets the long limit so
 * the iPhone can send SETUP Phase 2 well after RECORD. */
#define CONTROL_IDLE_SECONDS_UNCLAIMED 30
#define CONTROL_IDLE_SECONDS_OWNER     600
/* Until pair-verify succeeds the owner only gets the takeover window: an
 * owner silent for that long has stalled and must not hold the session for
 * the full owner limit. */
#define CONTROL_IDLE_SECONDS_UNVERIFIED_OWNER CONTROL_UNVERIFIED_CLAIM_SECONDS
static uint64_t g_control_claim_nanos = 0;
static uint64_t control_monotonic_nanos(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * CONTROL_NANOS_PER_SECOND +
           (uint64_t)now.tv_nsec;
}
/* Caller holds g_control_owner_lock. Drops an owner that has not completed
 * pair-verify within CONTROL_UNVERIFIED_CLAIM_SECONDS. The displaced handler
 * sees EOF, closes its own descriptor and, because it no longer owns the
 * session, does not end it. Returns true when an owner was dropped. */
static bool control_expire_unverified_owner_locked(uint64_t now) {
    if (g_control_owner < 0 || g_enc.active ||
        now - g_control_claim_nanos <
            (uint64_t)CONTROL_UNVERIFIED_CLAIM_SECONDS *
                CONTROL_NANOS_PER_SECOND)
        return false;
    shutdown(g_control_owner, SHUT_RDWR);
    g_control_owner = -1;
    return true;
}
static bool control_has_owner(void) {
    pthread_mutex_lock(&g_control_owner_lock);
    bool owned = g_control_owner >= 0;
    pthread_mutex_unlock(&g_control_owner_lock);
    return owned;
}
/* Like control_has_owner, but an owner stuck before pair-verify past the
 * takeover window is dropped instead of counted, so the ctrl-int retry is
 * not blocked by a peer that never finishes pairing. */
static bool control_has_live_owner(void) {
    pthread_mutex_lock(&g_control_owner_lock);
    int stale = g_control_owner;
    bool expired =
        control_expire_unverified_owner_locked(control_monotonic_nanos());
    bool owned = g_control_owner >= 0;
    pthread_mutex_unlock(&g_control_owner_lock);
    if (expired)
        printf("[AP] Unverified control owner fd=%d timed out; "
               "releasing it for a new ctrl-int connect\n", stale);
    return owned;
}
static bool control_is_owner(int sock) {
    pthread_mutex_lock(&g_control_owner_lock);
    bool owned = g_control_owner == sock;
    pthread_mutex_unlock(&g_control_owner_lock);
    return owned;
}
static bool control_has_encrypted_session(void) {
    pthread_mutex_lock(&g_control_owner_lock);
    bool active = g_control_owner >= 0 && g_enc.active;
    pthread_mutex_unlock(&g_control_owner_lock);
    return active;
}
/* Returns true when sock owns the pairing/session state. *newlyClaimed is set
 * when this call is the one that granted ownership. */
static bool control_claim(int sock, bool *newlyClaimed) {
    if (newlyClaimed) *newlyClaimed = false;
    pthread_mutex_lock(&g_control_owner_lock);
    uint64_t now = control_monotonic_nanos();
    int previous = g_control_owner;
    if (previous != sock && control_expire_unverified_owner_locked(now)) {
        printf("[AP] Unverified control owner fd=%d timed out; "
               "handing pairing to fd=%d\n", previous, sock);
    }
    if (g_control_owner < 0) {
        g_control_owner = sock;
        g_control_claim_nanos = now;
        if (newlyClaimed) *newlyClaimed = true;
    }
    bool owned = g_control_owner == sock;
    pthread_mutex_unlock(&g_control_owner_lock);
    return owned;
}
static dispatch_semaphore_t g_event_send_lock = NULL;
/* Send deadline of the event connection (SO_SNDTIMEO). */
#define EVENT_SEND_TIMEOUT_SEC 3
static bool process_event_command_frame(const uint8_t *bytes, size_t length);

/* Decrypt one encrypted frame from the socket.
 * Returns plaintext length, -2 on idle timeout, or -1 on error.
 * Caller provides outBuf (at least 16*1024 bytes). */
static int enc_recv_frame(int sock, encrypted_ctx_t *enc, uint8_t *outBuf, size_t outBufSize) {
    /* Read 2-byte LE length header */
    uint8_t hdr[2];
    size_t hdrRead = 0;
    while (hdrRead < 2) {
        ssize_t n = recv(sock, hdr + hdrRead, 2 - hdrRead, 0);
        if (n == 0) return -1;
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                if (hdrRead == 0) return -2;
                return -1; /* incomplete header: cannot restart mid-record */
            }
            return -1;
        }
        hdrRead += n;
    }
    uint16_t ptLen = hdr[0] | ((uint16_t)hdr[1] << 8);
    if (ptLen == 0 || ptLen > outBufSize) {
        printf("[ENC] Bad frame length: %u\n", ptLen);
        return -1;
    }

    /* Read ciphertext + 16-byte auth tag */
    size_t totalRead = ptLen + 16;
    uint8_t *frame = malloc(totalRead);
    if (!frame) return -1;
    size_t frameRead = 0;
    while (frameRead < totalRead) {
        ssize_t n = recv(sock, frame + frameRead, totalRead - frameRead, 0);
        if (n == 0) { free(frame); return -1; }
        if (n < 0) {
            int saved = errno;
            if (saved == EAGAIN || saved == EWOULDBLOCK) {
                free(frame);
                return -1; /* header was consumed; never treat this as idle */
            }
            free(frame);
            return -1;
        }
        frameRead += n;
    }

    /* Build 12-byte nonce: 4 zero bytes + 8-byte LE counter */
    uint8_t nonce12[12] = {0};
    memcpy(nonce12 + 4, &enc->readNonce, 8);  /* LE on LE system */

    /* Decrypt with ChaCha20-Poly1305 */
    crypto_aead_ctx ctx;
    crypto_aead_init_ietf(&ctx, enc->readKey, nonce12);
    int ret = crypto_aead_read(&ctx, outBuf, frame + ptLen,
                               hdr, sizeof(hdr), frame, ptLen);
    crypto_wipe(&ctx, sizeof(ctx));
    free(frame);

    if (ret != 0) {
        printf("[ENC] ChaCha20-Poly1305 decrypt FAILED (nonce=%llu)\n", enc->readNonce);
        return -1;
    }
    enc->readNonce++;
    return ptLen;
}

/* Encrypt and send one frame.
 * Returns 0 on success, -1 on error. */
static int enc_send_frame(int sock, encrypted_ctx_t *enc, const uint8_t *data, size_t dataLen) {
    if (dataLen == 0 || dataLen > ENCRYPTED_MAX_WRITE_SIZE) {
        printf("[ENC] Frame too large: %zu\n", dataLen);
        return -1;
    }

    /* 2-byte LE length header (AAD) */
    uint8_t hdr[2];
    hdr[0] = dataLen & 0xFF;
    hdr[1] = (dataLen >> 8) & 0xFF;

    /* Build 12-byte nonce */
    uint8_t nonce12[12] = {0};
    memcpy(nonce12 + 4, &enc->writeNonce, 8);

    /* Encrypt */
    uint8_t *ct = malloc(dataLen);
    uint8_t tag[16];
    if (!ct) return -1;

    crypto_aead_ctx ctx;
    crypto_aead_init_ietf(&ctx, enc->writeKey, nonce12);
    crypto_aead_write(&ctx, ct, tag, hdr, sizeof(hdr),
                      data, dataLen);
    crypto_wipe(&ctx, sizeof(ctx));

    /* Send: header + ciphertext + tag */
    size_t totalLen = 2 + dataLen + 16;
    uint8_t *out = malloc(totalLen);
    if (!out) { free(ct); return -1; }
    memcpy(out, hdr, 2);
    memcpy(out + 2, ct, dataLen);
    memcpy(out + 2 + dataLen, tag, 16);
    free(ct);

    size_t sent = 0;
    while (sent < totalLen) {
        ssize_t n = send(sock, out + sent, totalLen - sent, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            /* A partly written record (for example after a send timeout)
             * cannot be resumed; end the connection so the peer reconnects
             * instead of failing on every following record. */
            int sendErrno = errno;
            if (sent > 0) shutdown(sock, SHUT_RDWR);
            free(out);
            errno = sendErrno;
            return -1;
        }
        sent += n;
    }
    free(out);
    enc->writeNonce++;
    return 0;
}

/*
 * Encrypt a plaintext byte stream using the same segmentation as Apple's
 * NetTransportChaCha20Poly1305 writer. HTTP headers and bodies remain one
 * continuous plaintext stream; only the authenticated transport records are
 * split. This is required for /info responses containing OEM icon data.
 */
static int enc_send_stream(int sock, encrypted_ctx_t *enc,
                           const uint8_t *data, size_t dataLen) {
    size_t offset = 0;
    while (offset < dataLen) {
        size_t chunk = dataLen - offset;
        if (chunk > ENCRYPTED_MAX_WRITE_SIZE)
            chunk = ENCRYPTED_MAX_WRITE_SIZE;
        if (enc_send_frame(sock, enc, data + offset, chunk) < 0) {
            /* Earlier records already carried part of this message; the
             * peer would splice the next message onto the truncated one.
             * Like a partly written record, the stream cannot be resumed. */
            int sendErrno = errno;
            if (offset > 0) shutdown(sock, SHUT_RDWR);
            errno = sendErrno;
            return -1;
        }
        offset += chunk;
    }
    return 0;
}

/* ═══════════════════════════════════════════════════════════════
 * HTTP Request Parser
 * ═══════════════════════════════════════════════════════════════ */

typedef struct {
    char method[32];
    char path[512];
    char protocol[16];
    const uint8_t *headerStart;
    size_t headerLen;
    const uint8_t *body;
    size_t bodyLen;
    size_t contentLength;
    int cseq;
    char contentType[128];
    char xAppleHKP[32];
    char xApplePD[16];
    char xAppleAT[16];
    uint32_t appleStreamID;
    bool invalid;
} HTTPReq;

#define HTTP_STREAM_LIMIT 65536
static const char *http_find(const char *start, const char *end,
                             const char *needle, size_t size) {
    for (const char *p = start; (size_t)(end - p) >= size; p++)
        if (memcmp(p, needle, size) == 0) return p;
    return NULL;
}

static bool parse_http(const uint8_t *buf, size_t len, HTTPReq *r) {
    memset(r, 0, sizeof(*r));
    const char *s = (const char *)buf;
    const char *end = s + len;
    const char *mark = http_find(s, end, "\r\n\r\n", 4);
    if (!mark) { r->invalid = len >= HTTP_STREAM_LIMIT; return false; }
    const char *lineEnd = http_find(s, mark + 2, "\r\n", 2);
    if (!lineEnd) { r->invalid = true; return false; }

    /* Method */
    const char *sp1 = memchr(s, ' ', lineEnd - s);
    if (!sp1 || sp1 == s) { r->invalid = true; return false; }
    size_t n = sp1 - s;
    if (n >= sizeof(r->method)) n = sizeof(r->method) - 1;
    memcpy(r->method, s, n);

    /* Path */
    const char *sp2 = memchr(sp1 + 1, ' ', lineEnd - sp1 - 1);
    if (!sp2 || sp2 == sp1 + 1 || sp2 + 1 == lineEnd) { r->invalid = true; return false; }
    n = sp2 - (sp1 + 1);
    if (n >= sizeof(r->path)) n = sizeof(r->path) - 1;
    memcpy(r->path, sp1 + 1, n);

    /* Protocol */
    n = lineEnd - (sp2 + 1);
    if (n >= sizeof(r->protocol)) n = sizeof(r->protocol) - 1;
    memcpy(r->protocol, sp2 + 1, n);

    /* Headers */
    r->headerStart = (const uint8_t *)(lineEnd + 2);
    r->headerLen = (size_t)((mark + 2) - (const char *)r->headerStart);
    r->body = (const uint8_t *)(mark + 4);
    r->bodyLen = (size_t)((buf + len) - r->body);

    /* Parse key headers */
    const char *hp = (const char *)r->headerStart;
    const char *hend = hp + r->headerLen;
    bool haveLength = false;
    while (hp < hend) {
        const char *le = http_find(hp, hend, "\r\n", 2);
        if (!le) { r->invalid = true; return false; }
        const char *colon = memchr(hp, ':', le - hp);
        if (colon) {
            size_t nameLen = colon - hp;
            const char *val = colon + 1;
            while (val < le && *val == ' ') val++;
            size_t valLen = le - val;

            if (nameLen == 14 && strncasecmp(hp, "Content-Length", 14) == 0) {
                if (haveLength || valLen == 0) { r->invalid = true; return false; }
                haveLength = true;
                size_t value = 0;
                for (const char *p = val; p < le; p++) {
                    if (*p < '0' || *p > '9' || value > (HTTP_STREAM_LIMIT - (size_t)(*p - '0')) / 10) {
                        r->invalid = true; return false;
                    }
                    value = value * 10 + (size_t)(*p - '0');
                }
                r->contentLength = value;
            } else if (nameLen == 12 && strncasecmp(hp, "Content-Type", 12) == 0) {
                if (valLen < sizeof(r->contentType))
                    memcpy(r->contentType, val, valLen);
            } else if (nameLen == 11 && strncasecmp(hp, "X-Apple-HKP", 11) == 0) {
                if (valLen < sizeof(r->xAppleHKP))
                    memcpy(r->xAppleHKP, val, valLen);
            } else if (nameLen == 10 && strncasecmp(hp, "X-Apple-PD", 10) == 0) {
                if (valLen < sizeof(r->xApplePD))
                    memcpy(r->xApplePD, val, valLen);
            } else if (nameLen == 10 && strncasecmp(hp, "X-Apple-AT", 10) == 0) {
                if (valLen < sizeof(r->xAppleAT))
                    memcpy(r->xAppleAT, val, valLen);
            } else if (nameLen == 16 && strncasecmp(hp, "X-Apple-StreamID", 16) == 0) {
                uint32_t id = 0;
                for (const char *p = val; p < le; p++) {
                    if (*p < '0' || *p > '9' || id > (UINT32_MAX - (*p - '0')) / 10) {
                        r->invalid = true;
                        return false;
                    }
                    id = id * 10 + (*p - '0');
                }
                if (id == 0 || r->appleStreamID != 0) { r->invalid = true; return false; }
                r->appleStreamID = id;
            } else if (nameLen == 4 && strncasecmp(hp, "CSeq", 4) == 0) {
                int value = 0;
                for (const char *p = val; p < le && *p >= '0' && *p <= '9'; p++) {
                    if (value > (INT_MAX - (*p - '0')) / 10) { r->invalid = true; return false; }
                    value = value * 10 + (*p - '0');
                }
                r->cseq = value;
            }
        }
        hp = le + 2;
    }
    size_t headerSize = (size_t)(r->body - buf);
    if (headerSize > HTTP_STREAM_LIMIT || r->contentLength > HTTP_STREAM_LIMIT - headerSize) {
        r->invalid = true; return false;
    }
    if (r->bodyLen < r->contentLength) return false;
    r->bodyLen = r->contentLength;
    return true;
}

/* Header limit for a plaintext control connection that does not own the
 * session. Discovery and pairing requests carry a few hundred header bytes. */
#define HTTP_PREAUTH_HEADER_LIMIT 8192

/* Per-connection progress through the request at the front of a buffer. A
 * peer that sends a request a byte at a time would otherwise make every read
 * rescan the whole buffer (quadratic CPU). Reset to {0} whenever bytes are
 * removed from the front of the buffer. */
typedef struct {
    size_t scanned; /* leading bytes searched without finding CRLFCRLF */
    size_t total;   /* header plus body length, once the header is parsed */
} http_progress_t;

/* parse_http for a buffer that only grows between calls (apart from resets
 * of *progress). headerLimit bounds the header, terminator included. */
static bool parse_http_incremental(const uint8_t *buf, size_t len,
                                   size_t headerLimit,
                                   http_progress_t *progress, HTTPReq *r) {
    if (progress->total == 0) {
        /* Restart three bytes back so a terminator split across reads is
         * found. The clamp covers a recv that consumed fewer bytes than a
         * preceding MSG_PEEK scanned. */
        size_t scanned = progress->scanned < len ? progress->scanned : len;
        size_t from = scanned > 3 ? scanned - 3 : 0;
        const char *s = (const char *)buf;
        const char *mark = http_find(s + from, s + len, "\r\n\r\n", 4);
        if (!mark) {
            memset(r, 0, sizeof(*r));
            progress->scanned = len;
            r->invalid = len >= HTTP_STREAM_LIMIT || len >= headerLimit;
            return false;
        }
        if ((size_t)(mark - s) + 4 > headerLimit) {
            memset(r, 0, sizeof(*r));
            r->invalid = true;
            return false;
        }
    } else if (len < progress->total) {
        /* Header already validated; the body is still arriving. */
        memset(r, 0, sizeof(*r));
        return false;
    }
    bool complete = parse_http(buf, len, r);
    if (!complete && !r->invalid && r->body)
        progress->total = (size_t)(r->body - buf) + r->contentLength;
    return complete;
}

/* ═══════════════════════════════════════════════════════════════
 * HTTP Response Helper
 * ═══════════════════════════════════════════════════════════════ */

/* extraHeaders, when non-NULL, is inserted verbatim and must end in CRLF. */
static void send_response_with_headers(int sock, const char *proto, int status,
                                       const char *statusText,
                                       const char *contentType,
                                       const char *extraHeaders,
                                       const uint8_t *body, size_t bodyLen,
                                       int cseq) {
    @autoreleasepool {
        NSMutableString *hdr = [NSMutableString string];
        [hdr appendFormat:@"%s %d %s\r\n", proto, status, statusText];
        [hdr appendFormat:@"Server: AirTunes/%s\r\n", SOURCE_VERSION];
        if (cseq > 0)
            [hdr appendFormat:@"CSeq: %d\r\n", cseq];
        if (extraHeaders)
            [hdr appendFormat:@"%s", extraHeaders];
        if (contentType)
            [hdr appendFormat:@"Content-Type: %s\r\n", contentType];
        [hdr appendFormat:@"Content-Length: %zu\r\n", bodyLen];
        [hdr appendString:@"\r\n"];

        const char *h = hdr.UTF8String;
        size_t hLen = strlen(h);

        if (control_is_encrypted(sock)) {
            /* Encrypted mode: build one HTTP byte stream, then segment it
             * into Apple's 1 KiB authenticated transport records. */
            size_t totalPt = hLen + bodyLen;
            uint8_t *ptBuf = malloc(totalPt);
            if (ptBuf) {
                memcpy(ptBuf, h, hLen);
                if (body && bodyLen > 0) memcpy(ptBuf + hLen, body, bodyLen);
                size_t recordCount =
                    (totalPt + ENCRYPTED_MAX_WRITE_SIZE - 1) /
                    ENCRYPTED_MAX_WRITE_SIZE;
                printf("[ENC] Encrypting response: %zu bytes in %zu "
                       "record(s) (first nonce=%llu)\n",
                       totalPt, recordCount, g_enc.writeNonce);
                if (enc_send_stream(sock, &g_enc, ptBuf, totalPt) < 0) {
                    printf("[ENC] ERROR: Failed to send encrypted response\n");
                }
                free(ptBuf);
            }
        } else {
            /* Plaintext mode */
            send(sock, h, hLen, 0);
            if (body && bodyLen > 0)
                send(sock, body, bodyLen, 0);
        }
    }
}

static void send_response(int sock, const char *proto, int status,
                          const char *statusText, const char *contentType,
                          const uint8_t *body, size_t bodyLen, int cseq) {
    send_response_with_headers(sock, proto, status, statusText, contentType,
                               NULL, body, bodyLen, cseq);
}

/* Typed accessors for plist values received from the network. A value of the
 * wrong class would otherwise raise an unrecognized-selector exception. */
static NSNumber *plist_number(id value) {
    return [value isKindOfClass:[NSNumber class]] ? (NSNumber *)value : nil;
}
static NSString *plist_string(id value) {
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : nil;
}

static void send_ok(int sock, const HTTPReq *r) {
    bool rtsp = (strncmp(r->protocol, "RTSP", 4) == 0);
    send_response(sock, rtsp ? "RTSP/1.0" : "HTTP/1.1",
                  200, "OK", NULL, NULL, 0, r->cseq);
}

/* ═══════════════════════════════════════════════════════════════
 * TLV8 Parser (for HomeKit pair-setup/verify)
 * ═══════════════════════════════════════════════════════════════ */

/* Pair bodies arrive before authentication; a body of empty items must not
 * turn into megabytes of log lines. */
#define TLV8_DUMP_MAX_ITEMS 32

static void dump_tlv8(const uint8_t *data, size_t len) {
    const char *typeNames[] = {
        "Method", "Identifier", "Salt", "PublicKey", "Proof",
        "EncryptedData", "State", "Error", "RetryDelay",
        "Certificate", "Signature", "Permissions", "FragmentData", "FragmentLast"
    };
    size_t i = 0;
    unsigned items = 0;
    while (i + 2 <= len) {
        uint8_t type = data[i];
        uint8_t tlen = data[i + 1];
        if (i + 2 + tlen > len) break;
        if (items++ == TLV8_DUMP_MAX_ITEMS) {
            printf("    ... (%zu more bytes not shown)\n", len - i);
            break;
        }
        const char *name = (type < 14) ? typeNames[type] : "Unknown";
        printf("    TLV type=%d(%s) len=%d", type, name, tlen);
        if (tlen <= 16) {
            printf(" val=");
            for (int j = 0; j < tlen; j++) printf("%02x", data[i + 2 + j]);
        }
        printf("\n");
        i += 2 + tlen;
    }
}

/* ═══════════════════════════════════════════════════════════════
 * Endpoint: GET /info
 * ═══════════════════════════════════════════════════════════════ */

/* Set by handle_client (one thread per connection) for repeated
 * unauthenticated GET /info on the same connection, so a LAN peer cannot grow
 * the daemon log without bound by polling /info.
 *
 * Also set for every unauthenticated request once the pre-auth log budget is
 * spent. It is exported (not static) as showcase_preauth_quiet so the pairing
 * module (carplay_pair.c, which logs through showcase_service_log_printf) can
 * silence its per-M1 diagnostics under the same budget. */
extern __thread bool showcase_preauth_quiet;
__thread bool showcase_preauth_quiet = false;
#define t_quiet_request_log showcase_preauth_quiet

static void handle_info(int sock, const HTTPReq *r) {
    @autoreleasepool {
        if (!t_quiet_request_log)
            printf("[AP] -> GET /info (CSeq=%d, proto=%s)\n",
                   r->cseq, r->protocol);

        bool rtsp = (strncmp(r->protocol, "RTSP", 4) == 0);
        const char *proto = rtsp ? "RTSP/1.0" : "HTTP/1.1";

        uint64_t features = g_useHK ? 0x6104040280ULL : 0x2104040280ULL;

        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[@"deviceID"] = @DEVICE_ID;
        info[@"macAddress"] = @DEVICE_ID;
        info[@"features"] = @(features);
        info[@"model"] = @MODEL_NAME;
        info[@"name"] = instance_name_string();
        info[@"manufacturer"] = @"iPadPlay";
        info[@"sourceVersion"] = @SOURCE_VERSION;
        info[@"protocolVersion"] = @"1.1";

        /* statusFlags: bit 2 (0x4) = AudioLink (always set in reference).
         * Zero flags may signal "not ready" to iPhone. */
        info[@"statusFlags"] = @(0x4);
        NSString *bluetoothID = read_bt_id_at(AT_FDCWD, BT_ID_PATH);
        if (!bluetoothID) {
            /* BT_ID_PERSIST_PATH, walked without following a mobile-owned
             * symlinked directory. */
            int showcaseDir = open_legacy_showcase_dir();
            if (showcaseDir >= 0) {
                bluetoothID = read_bt_id_at(showcaseDir, "bt-id");
                close(showcaseDir);
            }
        }
        if (bluetoothID.length == 17) {
            info[@"bluetoothIDs"] = @[bluetoothID];
            if (!t_quiet_request_log)
                printf("[AP] Bluetooth transport identity: %s\n",
                       bluetoothID.UTF8String);
        } else if (!t_quiet_request_log) {
            printf("[AP] WARN: Bluetooth transport identity unavailable\n");
        }

        info[@"keepAliveLowPower"] = @YES;
        info[@"keepAliveSendStatsAsBody"] = @YES;
        info[@"pi"] = @(g_hk_pi);
        info[@"pk"] = [NSData dataWithBytes:ed25519_pk length:sizeof(ed25519_pk)];

        info[@"firmwareRevision"] = @"1.0.0";
        info[@"hardwareRevision"] = @"1.0";
        info[@"OSInfo"] = @"iPadOS 12.5.8";
        info[@"nightMode"] = @NO;
        info[@"rightHandDrive"] = @(g_right_hand_drive);
        info[@"extendedFeatures"] = @[@"vocoderInfo"];
        if (SHOWCASE_VIDEO_IN_CAR_BENCH)
            info[@"videoPlaybackInfo"] = car_video_capabilities(features);
        /*
         * Apple's receiver advertises this dictionary when buffered main
         * audio is enabled. The dictionary is intentionally empty: the
         * presence of the key is the capability signal. Sender-audio mode
         * omits it so the sender has no buffered media route to this device.
         */
        if (g_receiver_audio)
            info[@"mainBufferedInfo"] = @{};
        if (!t_quiet_request_log)
            printf("[AUDIO] output route: %s\n",
                   g_receiver_audio ? "receiver (MainAudio advertised)"
                                    : "sender (MainAudio left on the iPhone)");
        /*
         * ElectronicTollCollection is an installed-capability declaration,
         * not a generic inactive vehicle state. Advertising it with
         * active=false produces the grey "ETC" item in CarPlay, so omit the
         * capability entirely on receivers that do not implement it.
         *
         * Publish the legacy 104-point icon for compatibility and the
         * structured, pre-rendered icon form used by Apple's receiver sample.
         * The latter tells CarPlay that the supplied Showcase artwork is
         * already a finished app icon and must not be composited as a raw
         * vehicle glyph.
         */
        NSArray<NSString *> *oemIconPaths = @[
            [[NSBundle mainBundle] pathForResource:@"Icon-OEM-104"
                                            ofType:@"png"] ?: @"",
            @"/Applications/Showcase.app/Icon-OEM-104.png",
            @"/var/jb/Applications/Showcase.app/Icon-OEM-104.png"
        ];
        NSData *oemIcon = nil;
        for (NSString *path in oemIconPaths) {
            if (path.length == 0) continue;
            oemIcon = [NSData dataWithContentsOfFile:path];
            if (oemIcon.length > 0) {
                if (!t_quiet_request_log)
                    printf("[AP] OEM vehicle icon: %s (%lu bytes)\n",
                           path.UTF8String, (unsigned long)oemIcon.length);
                break;
            }
        }
        if (oemIcon.length > 0) {
            info[@"oemIcon"] = oemIcon;
            info[@"oemIconLabel"] = instance_name_string();
            info[@"oemIconVisible"] = @YES;
        } else if (!t_quiet_request_log) {
            printf("[AP] WARN: OEM vehicle icon unavailable\n");
        }
        NSArray<NSString *> *oemRenderedIconPaths = @[
            [[NSBundle mainBundle] pathForResource:@"Icon-OEM-120"
                                            ofType:@"png"] ?: @"",
            @"/Applications/Showcase.app/Icon-OEM-120.png",
            @"/var/jb/Applications/Showcase.app/Icon-OEM-120.png"
        ];
        NSData *oemRenderedIcon = nil;
        for (NSString *path in oemRenderedIconPaths) {
            if (path.length == 0) continue;
            oemRenderedIcon = [NSData dataWithContentsOfFile:path];
            if (oemRenderedIcon.length > 0) {
                if (!t_quiet_request_log)
                    printf("[AP] OEM pre-rendered icon: %s (%lu bytes)\n",
                           path.UTF8String,
                           (unsigned long)oemRenderedIcon.length);
                break;
            }
        }
        if (oemRenderedIcon.length > 0) {
            info[@"oemIcons"] = @[
                @{
                    @"widthPixels": @(120),
                    @"heightPixels": @(120),
                    @"prerendered": @YES,
                    @"imageData": oemRenderedIcon
                }
            ];
        } else if (!t_quiet_request_log) {
            printf("[AP] WARN: OEM pre-rendered icon unavailable\n");
        }
        info[@"limitedUI"] = @NO;

        /*
         * Initial resource ownership must include MainAudio. A clean,
         * first-pair run against Apple's CarPlay Simulator proves the
         * required transition:
         *
         *   MainAudio accessory/permanent accessory
         *       -> controller/permanent accessory -> type 100 SETUP
         *       -> controller/permanent controller -> type 103 SETUP
         *
         * Omitting resource 2 made iOS begin at controller/controller. That
         * skipped both audio setup transitions and left audio on the phone.
         *
         * CarPlay Simulator's Config decoder encodes MainScreen at
         * UserInitiated priority (500), but MainAudio at NiceToHave priority
         * (100). Advertising MainAudio at 500 prevents the sender's ordinary
         * temporary controller/accessory transition that precedes type 100.
         *
         * Sender-audio mode restores the beta 2 advertisement exactly:
         * MainAudio at UserInitiated priority (500) with the legacy format
         * rows below. The sender never issued an audio SETUP for that
         * description, so music, prompts, and calls stayed on the iPhone and
         * its own Bluetooth route.
         */
        info[@"modes"] = @{
            @"resources": @[
                @{  @"resourceID": @(1),       /* MainScreen */
                    @"transferType": @(1),      /* Take */
                    @"transferPriority": @(500), /* UserInitiated */
                    @"takeConstraint": @(100),   /* Anytime */
                    @"borrowConstraint": @(100)
                },
                @{  @"resourceID": @(2),       /* MainAudio */
                    @"transferType": @(1),      /* Take */
                    @"transferPriority": @(g_receiver_audio ? 100 : 500),
                    @"takeConstraint": @(100),
                    @"borrowConstraint": @(100)
                }
            ]
        };

        /* Display capabilities — CarPlay touchscreen */
        NSMutableDictionary *display = [NSMutableDictionary dictionary];
        display[@"uuid"] = @"e0ff8a27-6738-3d56-8a16-cc53ce1299b4";
        display[@"widthPixels"] = @(g_display_width);
        display[@"heightPixels"] = @(g_display_height);
        display[@"widthPhysical"] = @0;
        display[@"heightPhysical"] = @0;
        display[@"maxFPS"] = @(g_display_fps);
        /* Advertise only the implemented capacitive touchscreen. Knob and
         * touchpad bits are behavioral contracts, not cosmetic profile data. */
        display[@"features"] = @(0x08);
        display[@"primaryInputDevice"] = @(1);  /* 1=touchscreen */
        display[@"overscanned"] = @NO;
        info[@"displays"] = @[display];

        /*
         * CarPlaySDK builds different audio tables for wired and wireless
         * sessions. The wireless table uses Opus for interactive audio and
         * AAC-LC for buffered media; compatibility PCM entries belong to the
         * wired builder.
         *
         * Static recovery of Apple's current wireless builder established the
         * row order below. Showcase implements types 100, 101, 102, and 103.
         * Do not advertise the later auxiliary speech streams until their
         * receiver contracts are implemented. Preserve the SDK's insertion
         * order.
         */
        const uint64_t opus16 = 0x10000000ULL;
        const uint64_t opus24 = 0x20000000ULL;
        const uint64_t opus48 = 0x40000000ULL;
        const uint64_t opusAll = opus16 | opus24 | opus48;
        const uint64_t aacLC44 = 0x00400000ULL;
        const uint64_t aacLC48 = 0x00800000ULL;
        if (!g_receiver_audio) {
            /* Beta 2 rows, kept byte-for-byte as the sender-audio contract. */
            info[@"audioFormats"] = @[
                @{
                    @"type": @(100),
                    @"audioInputFormats": @(0x01000000),
                    @"audioOutputFormats": @(0x01000000)
                },
                @{
                    @"type": @(96),
                    @"audioInputFormats": @(0x04000000),
                    @"audioOutputFormats": @(0x04000000)
                }
            ];
            info[@"audioLatencies"] = @[
                @{
                    @"type": @(100), @"audioType": @"default",
                    @"inputLatencyMicros": @0, @"outputLatencyMicros": @0
                }
            ];
        } else {
        info[@"audioFormats"] = @[
            @{
                @"audioType": @"default",
                @"type": @(100),             /* MainAudio */
                @"audioInputFormats": @(opusAll),
                @"audioOutputFormats": @(opusAll)
            },
            @{
                @"audioType": @"default",
                @"type": @(101),             /* AltAudio */
                @"audioInputFormats": @(0),
                @"audioOutputFormats": @(opusAll)
            },
            @{
                @"audioType": @"media",
                @"type": @(102),             /* MainAudio media */
                @"audioInputFormats": @(0),
                @"audioOutputFormats": @(aacLC44 | aacLC48)
            },
            @{
                @"audioType": @"media",
                @"type": @(103),             /* MainBufferedAudio */
                @"audioInputFormats": @(0),
                @"audioOutputFormats": @(aacLC44 | aacLC48)
            },
            @{
                @"audioType": @"alert",
                @"type": @(100),
                @"audioInputFormats": @(0),
                @"audioOutputFormats": @(opus48)
            },
            @{
                @"audioType": @"telephony",
                @"type": @(100),
                @"audioInputFormats": @(opusAll),
                @"audioOutputFormats": @(opusAll)
            },
            @{
                @"audioType": @"speechRecognition",
                @"type": @(100),
                @"audioInputFormats": @(opus24),
                @"audioOutputFormats": @(opus24)
            }
        ];

        info[@"audioLatencies"] = @[
            @{
                @"type": @(100), @"audioType": @"default",
                @"inputLatencyMicros": @0, @"outputLatencyMicros": @0
            },
            @{
                @"type": @(100), @"audioType": @"telephony",
                @"inputLatencyMicros": @0, @"outputLatencyMicros": @0
            },
            @{
                @"type": @(100), @"audioType": @"speechRecognition",
                @"inputLatencyMicros": @0, @"outputLatencyMicros": @0
            },
            @{
                @"type": @(100), @"audioType": @"alert",
                @"outputLatencyMicros": @0
            },
            @{
                @"type": @(100), @"audioType": @"media",
                @"outputLatencyMicros": @0
            },
            @{
                @"type": @(101), @"audioType": @"default",
                @"outputLatencyMicros": @0
            }
        ];
        }

        info[@"initialVolume"] = @(-20.0);

        /* HID devices — Apple's single-touch-with-cancel format, used by the
         * CarPlay Simulator when "High Fidelty" and cancel support are enabled.
         * Report = 5 bytes: [touch|cancel<<1][xLo][xHi][yLo][yHi].
         * Coordinates use the negotiated display dimensions. */
        {
            const uint8_t hidDesc[] = {
                0x05, 0x0D,        /* Usage Page (Digitizer) */
                0x09, 0x04,        /* Usage (Touch Screen) */
                0xA1, 0x01,        /* Collection (Application) */
                0x09, 0x22,        /*   Usage (Finger) */
                0xA1, 0x02,        /*   Collection (Logical) */
                0x15, 0x00,        /*     Logical Minimum (0) */
                0x25, 0x01,        /*     Logical Maximum (1) */
                0x09, 0x33,        /*     Usage (Touch) */
                0x09, 0x34,        /*     Usage (Untouch/Cancel) */
                0x75, 0x01,        /*     Report Size (1) */
                0x95, 0x02,        /*     Report Count (2) */
                0x81, 0x02,        /*     Input (Data, Variable, Absolute) */
                0x95, 0x06,        /*     Report Count (6) */
                0x81, 0x01,        /*     Input (Constant) */
                0x05, 0x01,        /*     Usage Page (Generic Desktop) */
                0x26, (uint8_t)g_display_width,
                      (uint8_t)(g_display_width >> 8),
                                      /*     Logical Maximum (display width) */
                0x09, 0x30,        /*     Usage (X) */
                0x75, 0x10,        /*     Report Size (16) */
                0x95, 0x01,        /*     Report Count (1) */
                0x81, 0x02,        /*     Input (Data, Variable, Absolute) */
                0x26, (uint8_t)g_display_height,
                      (uint8_t)(g_display_height >> 8),
                                      /*     Logical Maximum (display height) */
                0x09, 0x31,        /*     Usage (Y) */
                0x81, 0x02,        /*     Input (Data, Variable, Absolute) */
                0xC0,              /*   End Collection */
                0xC0               /* End Collection */
            };
            NSData *descData = [NSData dataWithBytes:hidDesc length:sizeof(hidDesc)];

            NSDictionary *hidDev = @{
                @"name": @"Touch Screen",
                @"uuid": @"1",
                @"displayUUID": @"e0ff8a27-6738-3d56-8a16-cc53ce1299b4",
                @"hidVendorID": @(0),
                @"hidProductID": @(0),
                @"hidCountryCode": @(0),
                @"hidDescriptor": descData
            };
            info[@"hidDevices"] = @[hidDev];
        }

        NSError *err = nil;
        NSData *plist = [NSPropertyListSerialization
            dataWithPropertyList:info
                          format:NSPropertyListBinaryFormat_v1_0
                         options:0
                           error:&err];
        if (!plist) {
            printf("[AP] /info plist error: %s\n",
                   err.localizedDescription.UTF8String);
            send_response(sock, proto, 500, "Internal Server Error",
                         NULL, NULL, 0, r->cseq);
            return;
        }

        /* Log only key names: values include icon NSData that would be
         * hex-dumped (~80 KB per request). */
        if (!t_quiet_request_log) {
            NSArray *keys = [info.allKeys
                sortedArrayUsingSelector:@selector(compare:)];
            printf("[AP] <- /info response: %zu bytes binary plist, keys: %s\n",
                   (size_t)plist.length,
                   [[keys componentsJoinedByString:@","] UTF8String]);
        }
        send_response(sock, proto, 200, "OK",
                     "application/x-apple-binary-plist",
                     plist.bytes, plist.length, r->cseq);
    }
}

/* ═══════════════════════════════════════════════════════════════
 * Endpoint: POST /pair-setup
 * ═══════════════════════════════════════════════════════════════ */

static void handle_pair_setup(int sock, const HTTPReq *r) {
    /* Reachable before pair-verify: nothing once the pre-auth log budget is
     * spent (t_quiet_request_log). */
    if (!t_quiet_request_log) {
        printf("[AP] -> POST /pair-setup (HKP=%s, bodyLen=%zu)\n",
               r->xAppleHKP[0] ? r->xAppleHKP : "none", r->bodyLen);
        if (r->body && r->bodyLen > 0) {
            printf("[AP] pair-setup TLV8 payload:\n");
            dump_tlv8(r->body, r->bodyLen);
        }
    }

    /* Determine protocol (RTSP or HTTP) */
    bool rtsp = (strncmp(r->protocol, "RTSP", 4) == 0);
    const char *proto = rtsp ? "RTSP/1.0" : "HTTP/1.1";

    if (!r->body || r->bodyLen == 0) {
        if (!t_quiet_request_log)
            printf("[AP] pair-setup: no body, sending empty 200\n");
        send_response(sock, proto, 200, "OK",
                     "application/octet-stream", NULL, 0, r->cseq);
        return;
    }

    /* The SRP state machine resets internally on each M1. It is shared by
     * every connection, so it runs under g_pair_lock and only for the
     * connection that still owns the control session: an owner displaced by
     * control_claim may still be inside this handler. */
    size_t resp_len = 0;
    uint8_t *resp_data = NULL;
    bool setupComplete = false;
    app_send_status(STATUS_PAIR_SETUP_STARTED);
    pthread_mutex_lock(&g_pair_lock);
    bool ready = ensure_pair_context();
    bool owner = ready && control_is_owner(sock);
    if (owner) {
        resp_data = pair_setup_handle(g_pair, r->body, r->bodyLen, &resp_len);
        setupComplete = pair_setup_is_complete(g_pair);
        if (setupComplete) save_pairing_registry();
    }
    pthread_mutex_unlock(&g_pair_lock);

    if (!ready) {
        printf("[AP] ERROR: Failed to create pair context\n");
        send_response(sock, proto, 500, "Internal Error",
                     NULL, NULL, 0, r->cseq);
        return;
    }
    if (!owner) {
        if (!t_quiet_request_log)
            printf("[AP] pair-setup on a displaced connection; ignoring\n");
        send_response(sock, proto, 503, "Service Unavailable",
                     NULL, NULL, 0, r->cseq);
        return;
    }

    if (resp_data && resp_len > 0) {
        if (!t_quiet_request_log) {
            printf("[AP] pair-setup response: %zu bytes TLV8\n", resp_len);
            printf("[AP] pair-setup response hex:");
            size_t dumpLen = resp_len > 128 ? 128 : resp_len;
            for (size_t i = 0; i < dumpLen; i++) printf(" %02X", resp_data[i]);
            if (resp_len > 128) printf(" ...");
            printf("\n");
        }

        send_response(sock, proto, 200, "OK",
                     "application/octet-stream",
                     resp_data, resp_len, r->cseq);
        free(resp_data);
    } else {
        if (!t_quiet_request_log)
            printf("[AP] pair-setup: handler returned no data, sending empty 200\n");
        send_response(sock, proto, 200, "OK",
                     "application/octet-stream", NULL, 0, r->cseq);
    }

    if (setupComplete) {
        printf("\n[AP] ╔══════════════════════════════════════╗\n");
        printf("[AP] ║  PAIR-SETUP COMPLETE — SUCCESS!      ║\n");
        printf("[AP] ║  Waiting for pair-verify...           ║\n");
        printf("[AP] ╚══════════════════════════════════════╝\n\n");
        app_send_status(STATUS_PAIR_SETUP_COMPLETE);
    }
}

/* ═══════════════════════════════════════════════════════════════
 * Endpoint: POST /pair-verify
 * ═══════════════════════════════════════════════════════════════ */

static void handle_pair_verify(int sock, const HTTPReq *r) {
    if (!t_quiet_request_log) {
        printf("[AP] -> POST /pair-verify (HKP=%s, PD=%s, bodyLen=%zu)\n",
               r->xAppleHKP[0] ? r->xAppleHKP : "none",
               r->xApplePD[0] ? r->xApplePD : "none",
               r->bodyLen);
        if (r->body && r->bodyLen > 0) {
            printf("[AP] pair-verify TLV8 payload:\n");
            dump_tlv8(r->body, r->bodyLen);
        }
    }

    bool rtsp = (strncmp(r->protocol, "RTSP", 4) == 0);
    const char *proto = rtsp ? "RTSP/1.0" : "HTTP/1.1";

    if (!r->body || r->bodyLen == 0) {
        send_response(sock, proto, 200, "OK",
                     "application/octet-stream", NULL, 0, r->cseq);
        return;
    }

    /* Same serialization as pair-setup. Session keys are derived into local
     * buffers here and published to g_enc/g_event_enc only below, after the
     * plaintext reply, and only while this connection still owns the
     * session. */
    size_t resp_len = 0;
    uint8_t *resp_data = NULL;
    bool verifyComplete = false;
    bool haveControlKeys = false;
    bool haveEventKeys = false;
    encrypted_ctx_t controlKeys = {0};
    encrypted_ctx_t eventKeys = {0};
    pthread_mutex_lock(&g_pair_lock);
    bool ready = ensure_pair_context();
    bool owner = ready && control_is_owner(sock);
    if (owner) {
        resp_data = pair_verify_handle(g_pair, r->body, r->bodyLen, &resp_len);
        verifyComplete = pair_verify_is_complete(g_pair);
        if (verifyComplete) {
            haveControlKeys = pair_derive_control_keys(
                g_pair, controlKeys.readKey, controlKeys.writeKey) == 0;
            haveEventKeys = pair_derive_event_keys(
                g_pair, eventKeys.readKey, eventKeys.writeKey) == 0;
            /* handle_verify_m3 moved this controller to the most recently
             * used end of the registry; persist that order so LRU eviction
             * survives a daemon restart. pair_verify_handle clears the done
             * state on every call, so this runs once per successful verify. */
            save_pairing_registry();
        }
    }
    pthread_mutex_unlock(&g_pair_lock);

    if (!ready) {
        send_response(sock, proto, 500, "Internal Error",
                     NULL, NULL, 0, r->cseq);
        return;
    }
    if (!owner) {
        if (!t_quiet_request_log)
            printf("[AP] pair-verify on a displaced connection; ignoring\n");
        send_response(sock, proto, 503, "Service Unavailable",
                     NULL, NULL, 0, r->cseq);
        return;
    }

    if (resp_data && resp_len > 0) {
        if (!t_quiet_request_log) {
            printf("[AP] pair-verify response: %zu bytes TLV8\n", resp_len);
            printf("[AP] pair-verify response hex:");
            size_t dumpLen = resp_len > 128 ? 128 : resp_len;
            for (size_t i = 0; i < dumpLen; i++) printf(" %02X", resp_data[i]);
            if (resp_len > 128) printf(" ...");
            printf("\n");
        }

        send_response(sock, proto, 200, "OK",
                     "application/octet-stream",
                     resp_data, resp_len, r->cseq);
        free(resp_data);
    } else {
        send_response(sock, proto, 200, "OK",
                     "application/octet-stream", NULL, 0, r->cseq);
    }

    if (verifyComplete) {
        /* Install the control channel keys. A connection displaced by
         * control_claim must not touch the new owner's cipher state, so the
         * keys, nonces and active flag change only under the owner lock and
         * only while this connection still owns the session.
         *
         * Event channel keys are pre-derived so they're ready when iPhone
         * connects to event port (before RECORD). Reference derives these in
         * _ControlStart during RECORD, but our event thread accepts
         * connections earlier. */
        pthread_mutex_lock(&g_control_owner_lock);
        bool stillOwner = g_control_owner == sock;
        if (stillOwner && haveControlKeys) {
            memcpy(g_enc.readKey, controlKeys.readKey, sizeof(g_enc.readKey));
            memcpy(g_enc.writeKey, controlKeys.writeKey, sizeof(g_enc.writeKey));
            g_enc.readNonce = 0;
            g_enc.writeNonce = 0;
            g_enc.active = true;
        }
        if (stillOwner && haveEventKeys) {
            memcpy(g_event_enc.readKey, eventKeys.readKey,
                   sizeof(g_event_enc.readKey));
            memcpy(g_event_enc.writeKey, eventKeys.writeKey,
                   sizeof(g_event_enc.writeKey));
            g_event_enc.readNonce = 0;
            g_event_enc.writeNonce = 0;
            g_event_enc.active = true;
        }
        pthread_mutex_unlock(&g_control_owner_lock);
        crypto_wipe(&controlKeys, sizeof(controlKeys));
        crypto_wipe(&eventKeys, sizeof(eventKeys));
        if (!stillOwner) {
            printf("[AP] pair-verify finished on a displaced connection; "
                   "ignoring\n");
            return;
        }
        if (haveControlKeys) {
            /* Verified: the owner may now idle for the long limit so the
             * iPhone can send SETUP Phase 2 well after RECORD. */
            struct timeval ownerTv = {
                .tv_sec = CONTROL_IDLE_SECONDS_OWNER, .tv_usec = 0 };
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO,
                       &ownerTv, sizeof(ownerTv));
            printf("[AP] *** Encrypted transport layer ACTIVE ***\n");
        }
        if (haveEventKeys)
            printf("[AP] *** Event channel encryption keys PRE-DERIVED ***\n");

        printf("\n[AP] ╔══════════════════════════════════════╗\n");
        printf("[AP] ║  PAIR-VERIFY COMPLETE — SUCCESS!     ║\n");
        printf("[AP] ║  Connection is now authenticated.     ║\n");
        printf("[AP] ╚══════════════════════════════════════╝\n\n");
        app_send_status(STATUS_PAIR_VERIFY_COMPLETE);
    }
}

/* ═══════════════════════════════════════════════════════════════
 * Endpoint: POST /fp-setup (FairPlay)
 * ═══════════════════════════════════════════════════════════════ */

static void handle_fp_setup(int sock, const HTTPReq *r) {
    /* fp-setup is reachable before pair-verify: log only the header bytes
     * (version/mode), and nothing once the pre-auth log budget is spent. */
    if (!t_quiet_request_log) {
        printf("[AP] -> POST /fp-setup (bodyLen=%zu)\n", r->bodyLen);
        if (r->body && r->bodyLen > 0) {
            size_t dumpLen = r->bodyLen > 16 ? 16 : r->bodyLen;
            printf("[AP] fp-setup head (%zu):", r->bodyLen);
            for (size_t i = 0; i < dumpLen; i++) printf(" %02X", r->body[i]);
            if (r->bodyLen > dumpLen) printf(" ...");
            printf("\n");
        }
    }

    send_response(sock, "HTTP/1.1", 200, "OK",
                 "application/octet-stream", NULL, 0, 0);
}

/* ═══════════════════════════════════════════════════════════════
 * Network plist parsing with a bounded container depth
 *
 * CoreFoundation's plist parsers recurse once per nested container, and
 * every network plist is parsed on a 512 KB control-client thread (or a
 * GCD worker), so a ~1 KB plist nested a few hundred levels deep overflows
 * the stack and kills the root daemon. Senders only ever use binary
 * plists, so anything else is refused, and the bplist object graph is
 * walked here without recursion before CoreFoundation sees it.
 * ═══════════════════════════════════════════════════════════════ */

/* Expected request plists are a handful of levels deep (SETUP streams,
 * command dictionaries); auth-setup arrives before pair-verify and is a
 * single flat dictionary. */
#define NETWORK_PLIST_MAX_DEPTH 16
#define AUTH_SETUP_PLIST_MAX_DEPTH 4

#define BPLIST_HEADER_BYTES 8
#define BPLIST_TRAILER_BYTES 32
#define BPLIST_STATE_IN_PROGRESS 0xFF

static uint64_t bplist_read_be(const uint8_t *p, size_t width) {
    uint64_t value = 0;
    for (size_t i = 0; i < width; i++) value = (value << 8) | p[i];
    return value;
}

typedef struct {
    const uint8_t *data;
    uint64_t objectCount;
    uint64_t offsetTable;   /* objects live in [8, offsetTable) */
    size_t offsetSize;
    size_t refSize;
} BPlist;

/* Locates the object reference list of a container object; a non-container
 * object reports zero references. Returns false on malformed input. */
static bool bplist_object_refs(const BPlist *b, uint64_t index,
                               bool *isContainer, uint64_t *refPos,
                               uint64_t *refCount) {
    uint64_t off = bplist_read_be(b->data + b->offsetTable +
                                  index * b->offsetSize, b->offsetSize);
    if (off < BPLIST_HEADER_BYTES || off >= b->offsetTable) return false;
    uint8_t marker = b->data[off];
    uint8_t type = marker >> 4;
    *isContainer = type == 0xA || type == 0xB || type == 0xC || type == 0xD;
    *refPos = 0;
    *refCount = 0;
    if (!*isContainer) return true;

    uint64_t count = marker & 0x0F;
    uint64_t pos = off + 1;
    if (count == 0x0F) {
        if (pos >= b->offsetTable) return false;
        uint8_t intMarker = b->data[pos];
        if ((intMarker >> 4) != 0x1 || (intMarker & 0x0F) > 3) return false;
        size_t width = (size_t)1 << (intMarker & 0x0F);
        if (b->offsetTable - (pos + 1) < width) return false;
        count = bplist_read_be(b->data + pos + 1, width);
        pos += 1 + width;
    }
    uint64_t refs = type == 0xD ? count * 2 : count;
    if (count > b->offsetTable || refs > (b->offsetTable - pos) / b->refSize)
        return false;
    *refPos = pos;
    *refCount = refs;
    return true;
}

/* True when body is a well-formed bplist00 whose container nesting does not
 * exceed maxDepth and whose object graph has no cycles. Iterative, O(objects
 * + references), with at most maxDepth explicit frames. */
static bool bplist_depth_ok(const uint8_t *data, size_t length,
                            unsigned maxDepth) {
    if (!data || maxDepth == 0 || maxDepth >= BPLIST_STATE_IN_PROGRESS - 1 ||
        length < BPLIST_HEADER_BYTES + BPLIST_TRAILER_BYTES ||
        memcmp(data, "bplist00", BPLIST_HEADER_BYTES) != 0)
        return false;

    const uint8_t *trailer = data + length - BPLIST_TRAILER_BYTES;
    BPlist b = {
        .data = data,
        .offsetSize = trailer[6],
        .refSize = trailer[7],
        .objectCount = bplist_read_be(trailer + 8, 8),
        .offsetTable = bplist_read_be(trailer + 24, 8),
    };
    uint64_t top = bplist_read_be(trailer + 16, 8);
    uint64_t trailerStart = length - BPLIST_TRAILER_BYTES;
    if (b.offsetSize < 1 || b.offsetSize > 8 || b.refSize < 1 ||
        b.refSize > 8 || b.objectCount == 0 || top >= b.objectCount ||
        b.offsetTable < BPLIST_HEADER_BYTES || b.offsetTable > trailerStart ||
        b.objectCount > (trailerStart - b.offsetTable) / b.offsetSize)
        return false;

    /* Per-object state: 0 unvisited, IN_PROGRESS on the walk stack (a
     * reference back to it is a cycle), otherwise nesting depth + 1. */
    uint8_t *state = calloc((size_t)b.objectCount, 1);
    if (!state) return false;

    struct { uint64_t index, refPos, refsLeft; unsigned best; }
        stack[NETWORK_PLIST_MAX_DEPTH + 1];
    if (maxDepth > NETWORK_PLIST_MAX_DEPTH) maxDepth = NETWORK_PLIST_MAX_DEPTH;

    bool ok = false, isContainer = false;
    uint64_t refPos = 0, refCount = 0;
    unsigned height = 0;
    if (!bplist_object_refs(&b, top, &isContainer, &refPos, &refCount))
        goto done;
    if (!isContainer) { ok = true; goto done; }
    stack[0].index = top;
    stack[0].refPos = refPos;
    stack[0].refsLeft = refCount;
    stack[0].best = 0;
    state[top] = BPLIST_STATE_IN_PROGRESS;
    height = 1;

    while (height > 0) {
        __typeof__(stack[0]) *frame = &stack[height - 1];
        if (frame->refsLeft == 0) {
            unsigned depth = frame->best + 1;
            if (depth > maxDepth) goto done;
            state[frame->index] = (uint8_t)(depth + 1);
            height--;
            if (height > 0 && stack[height - 1].best < depth)
                stack[height - 1].best = depth;
            continue;
        }
        uint64_t child = bplist_read_be(data + frame->refPos, b.refSize);
        frame->refPos += b.refSize;
        frame->refsLeft--;
        if (child >= b.objectCount) goto done;
        uint8_t childState = state[child];
        if (childState == BPLIST_STATE_IN_PROGRESS) goto done;
        if (childState != 0) {
            if (frame->best < (unsigned)childState - 1)
                frame->best = (unsigned)childState - 1;
            continue;
        }
        if (!bplist_object_refs(&b, child, &isContainer, &refPos, &refCount))
            goto done;
        if (!isContainer) { state[child] = 1; continue; }
        if (height >= maxDepth) goto done;
        stack[height].index = child;
        stack[height].refPos = refPos;
        stack[height].refsLeft = refCount;
        stack[height].best = 0;
        state[child] = BPLIST_STATE_IN_PROGRESS;
        height++;
    }
    ok = true;
done:
    free(state);
    return ok;
}

/* Parses a network-supplied plist body, or returns nil when it is not a
 * binary plist within maxDepth nested containers. */
static id network_plist_parse(const uint8_t *body, size_t length,
                              unsigned maxDepth) {
    if (!body || length == 0 || !bplist_depth_ok(body, length, maxDepth))
        return nil;
    NSData *d = [NSData dataWithBytesNoCopy:(void *)body
                                     length:length
                               freeWhenDone:NO];
    return [NSPropertyListSerialization
        propertyListWithData:d options:NSPropertyListImmutable format:NULL
                       error:NULL];
}

/* ═══════════════════════════════════════════════════════════════
 * Endpoint: POST /auth-setup
 * ═══════════════════════════════════════════════════════════════ */

/* Like TLV8_DUMP_MAX_ITEMS: an auth-setup plist arrives before pair-verify. */
#define AUTH_SETUP_DUMP_MAX_FIELDS 16

static void handle_auth_setup(int sock, const HTTPReq *r) {
    bool rtsp = (strncmp(r->protocol, "RTSP", 4) == 0);
    const char *proto = rtsp ? "RTSP/1.0" : "HTTP/1.1";

    /* Reachable before pair-verify: nothing once the pre-auth log budget is
     * spent (t_quiet_request_log). */
    if (!t_quiet_request_log)
        printf("[AP] -> POST /auth-setup (bodyLen=%zu, CSeq=%d, AT=%s)\n",
               r->bodyLen, r->cseq, r->xAppleAT[0] ? r->xAppleAT : "none");

    if (!r->body || r->bodyLen == 0) {
        if (!t_quiet_request_log)
            printf("[AP] auth-setup: empty body\n");
        send_response(sock, proto, 403, "Forbidden", NULL, NULL, 0, r->cseq);
        return;
    }

    /* Two formats:
     * 1) Raw MFi-SAP v1: 33 bytes = <1:version> <32:Curve25519 pk>
     * 2) Binary plist (iOS 18+): contains key data in plist wrapper */
    uint8_t version = 0;
    const uint8_t *peerPK = NULL;
    uint8_t peerPKBuf[32];
    bool isPlist = false;

    if (r->bodyLen == 33 && r->body[0] <= 2) {
        /* Raw MFi-SAP format */
        version = r->body[0];
        peerPK = r->body + 1;
    } else {
        /* Try binary plist */
        @autoreleasepool {
            id obj = network_plist_parse(r->body, r->bodyLen,
                                         AUTH_SETUP_PLIST_MAX_DEPTH);
            if (obj) {
                isPlist = true;

                /* Extract public key — try known keys */
                NSData *pkData = nil;
                if ([obj isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *dict = (NSDictionary *)obj;
                    /* Network data: a non-NSData value must not reach
                     * -length/-bytes (unrecognized selector aborts root). */
                    id pkValue = dict[@"pk"] ?: dict[@"publicKey"] ?: dict[@"epk"];
                    if ([pkValue isKindOfClass:[NSData class]])
                        pkData = (NSData *)pkValue;
                    if (!pkData) {
                        /* Inspect types and lengths without logging values;
                         * a pre-auth plist may hold thousands of keys, so
                         * only the first few are logged. */
                        unsigned fields = 0;
                        for (NSString *key in dict) {
                            id val = dict[key];
                            bool logField = !t_quiet_request_log &&
                                fields++ < AUTH_SETUP_DUMP_MAX_FIELDS;
                            if ([val isKindOfClass:[NSData class]]) {
                                NSData *dv = (NSData *)val;
                                if (logField)
                                    printf("[AP] auth-setup field: data (%zu bytes)\n", dv.length);
                                if (dv.length == 32 && !pkData) pkData = dv;
                            } else if (!logField) {
                                continue;
                            } else if ([val isKindOfClass:[NSNumber class]]) {
                                printf("[AP] auth-setup field: number\n");
                            } else if ([val isKindOfClass:[NSString class]]) {
                                printf("[AP] auth-setup field: string (%zu bytes)\n",
                                       [(NSString *)val lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
                            }
                        }
                        if (!t_quiet_request_log &&
                            dict.count > AUTH_SETUP_DUMP_MAX_FIELDS)
                            printf("[AP] auth-setup: ... %zu more fields\n",
                                   (size_t)(dict.count - AUTH_SETUP_DUMP_MAX_FIELDS));
                    }
                    if (pkData && pkData.length == 32) {
                        memcpy(peerPKBuf, pkData.bytes, 32);
                        peerPK = peerPKBuf;
                        version = 1;
                    }
                }
            } else if (!t_quiet_request_log) {
                printf("[AP] auth-setup: not a plist (%zu bytes)\n", r->bodyLen);
            }
        }
    }

    if (!peerPK) {
        if (!t_quiet_request_log)
            printf("[AP] auth-setup: could not extract peer public key (bodyLen=%zu)\n", r->bodyLen);
        /* Return 200 OK with empty plist to not kill the connection */
        @autoreleasepool {
            NSDictionary *resp = @{};
            NSData *plistData = [NSPropertyListSerialization
                dataWithPropertyList:resp format:NSPropertyListBinaryFormat_v1_0
                options:0 error:NULL];
            send_response(sock, proto, 200, "OK",
                         "application/x-apple-binary-plist",
                         (const uint8_t *)plistData.bytes, plistData.length, r->cseq);
        }
        return;
    }

    /* Everything below is still pre-auth: honor the pre-auth log budget. */
    if (!t_quiet_request_log) {
        printf("[AP] auth-setup: version=%d, %s, client ECDH pk:", version, isPlist ? "plist" : "raw");
        for (int i = 0; i < 32; i++) printf(" %02x", peerPK[i]);
        printf("\n");
    }

    pthread_mutex_lock(&g_baa_lock);
    bool baaReady = g_baa_ready;
    pthread_mutex_unlock(&g_baa_lock);
    if (!baaReady) {
        if (!t_quiet_request_log)
            printf("[AP] auth-setup: BAA not ready, attempting issuance...\n");
        load_baa_from_broker();
    }
    /* Snapshot pointer and length together; the buffers are never freed
     * or replaced once ready. */
    pthread_mutex_lock(&g_baa_lock);
    baaReady = g_baa_ready;
    const uint8_t *baaLeafDer = g_baa_leaf_der;
    int baaLeafLen = g_baa_leaf_len;
    const uint8_t *baaInterDer = g_baa_inter_der;
    int baaInterLen = g_baa_inter_len;
    pthread_mutex_unlock(&g_baa_lock);
    if (!baaReady || !baaLeafDer || !baaInterDer ||
        baaLeafLen <= 0 || baaInterLen <= 0) {
        if (!t_quiet_request_log)
            printf("[AP] auth-setup: BAA certificate unavailable\n");
        send_response(sock, proto, 403, "Forbidden", NULL, NULL, 0, r->cseq);
        return;
    }

    /* Generate our Curve25519 keypair with the system CSPRNG and embedded
     * Monocypher. */
    uint8_t ourSK[32];
    uint8_t ourPK[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(ourSK), ourSK) !=
        errSecSuccess) {
        if (!t_quiet_request_log)
            printf("[AP] auth-setup: secure random generation failed\n");
        send_response(sock, proto, 500, "Internal Server Error",
                      NULL, NULL, 0, r->cseq);
        return;
    }
    crypto_x25519_public_key(ourPK, ourSK);

    if (!t_quiet_request_log) {
        printf("[AP] auth-setup: our ECDH pk:");
        for (int i = 0; i < 32; i++) printf(" %02x", ourPK[i]);
        printf("\n");
    }

    /* Compute ECDH shared secret */
    uint8_t sharedSecret[32];
    crypto_x25519(sharedSecret, ourSK, peerPK);
    crypto_wipe(ourSK, sizeof(ourSK));

    if (!t_quiet_request_log)
        printf("[AP] auth-setup: shared secret established\n");

    /* Derive AES key and IV: SHA1("AES-KEY" + shared) and SHA1("AES-IV" + shared) */
    uint8_t aesKey[20], aesIV[20];
    CC_SHA1_CTX sha;
    CC_SHA1_Init(&sha);
    CC_SHA1_Update(&sha, "AES-KEY", 7);
    CC_SHA1_Update(&sha, sharedSecret, 32);
    CC_SHA1_Final(aesKey, &sha);

    CC_SHA1_Init(&sha);
    CC_SHA1_Update(&sha, "AES-IV", 6);
    CC_SHA1_Update(&sha, sharedSecret, 32);
    CC_SHA1_Final(aesIV, &sha);

    /* Sign SHA1(ourPK || peerPK) with BAA private key (ECDSA-SHA256) */
    @autoreleasepool {
        /* Build the data to sign: SHA1(ourPK || peerPK) = 20 bytes
         * But we'll sign the raw concatenation with ECDSA-SHA256 instead of
         * doing SHA1-then-RSA like MFi does. The iPhone needs to accept this. */
        uint8_t digestData[64];  /* ourPK || peerPK */
        memcpy(digestData, ourPK, 32);
        memcpy(digestData + 32, peerPK, 32);

        /* Sign with ECDSA-SHA256 (BAA key's native algorithm) */
        uint8_t *sigBytesOwned = NULL;
        int sigLength = 0;
        int signRC = baa_broker_sign(digestData, sizeof(digestData),
                                     &sigBytesOwned, &sigLength);
        if (signRC != 0) {
            if (!t_quiet_request_log)
                printf("[AP] auth-setup: BAA broker sign FAILED: %d\n", signRC);
            send_response(sock, proto, 403, "Forbidden", NULL, NULL, 0, r->cseq);
            return;
        }

        const uint8_t *sigBytes = sigBytesOwned;
        size_t sigLen = (size_t)sigLength;
        if (!t_quiet_request_log)
            printf("[AP] auth-setup: ECDSA signature: %zu bytes\n", sigLen);

        /* Encrypt signature with AES-128-CTR */
        uint8_t *encSig = sigLen > 0 ? malloc(sigLen) : NULL;
        size_t encLen = 0;
        CCCryptorRef cryptor = NULL;
        CCCryptorStatus cryptStatus = encSig
            ? CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR,
                                      kCCAlgorithmAES128, ccNoPadding,
                                      aesIV, aesKey, 16, NULL, 0, 0,
                                      kCCModeOptionCTR_BE, &cryptor)
            : kCCMemoryFailure;
        if (cryptStatus == kCCSuccess)
            cryptStatus = CCCryptorUpdate(cryptor, sigBytes, sigLen,
                                          encSig, sigLen, &encLen);
        if (cryptor) CCCryptorRelease(cryptor);
        free(sigBytesOwned);
        if (cryptStatus != kCCSuccess || encLen != sigLen) {
            if (!t_quiet_request_log)
                printf("[AP] auth-setup: signature encryption failed (%d)\n",
                       (int)cryptStatus);
            free(encSig);
            send_response(sock, proto, 500, "Internal Server Error",
                          NULL, NULL, 0, r->cseq);
            return;
        }

        if (!t_quiet_request_log)
            printf("[AP] auth-setup: encrypted sig: %zu bytes\n", encLen);

        /* ── Build OPACK blob for intermediate cert: {"baIC": inter_der} ──
         *
         * OPACK encoding (from pyatv/Apple CoreUtils):
         *   0xE1             = dict with 1 entry
         *   0x44             = string of length 4 (0x40 + 4)
         *   "baIC"           = 62 61 49 43
         *   0x92 LL LL       = bytes with 2-byte LE length (for 256-65535)
         *   [data...]        = intermediate cert DER
         *
         * For certs <= 255 bytes, use 0x91 + 1-byte LE length instead.
         * For certs <= 32 bytes, use 0x70+len inline (unlikely for certs).
         */
        size_t opackHdrLen;
        uint8_t opackHdr[16];
        opackHdr[0] = 0xE1;             /* dict, 1 entry */
        opackHdr[1] = 0x44;             /* string len=4 */
        opackHdr[2] = 'b'; opackHdr[3] = 'a'; opackHdr[4] = 'I'; opackHdr[5] = 'C';
        if (baaInterLen <= 0x20) {
            opackHdr[6] = 0x70 + (uint8_t)baaInterLen;
            opackHdrLen = 7;
        } else if (baaInterLen <= 0xFF) {
            opackHdr[6] = 0x91;
            opackHdr[7] = (uint8_t)(baaInterLen & 0xFF);
            opackHdrLen = 8;
        } else if (baaInterLen <= 0xFFFF) {
            opackHdr[6] = 0x92;
            opackHdr[7] = (uint8_t)(baaInterLen & 0xFF);        /* LE low */
            opackHdr[8] = (uint8_t)((baaInterLen >> 8) & 0xFF); /* LE high */
            opackHdrLen = 9;
        } else {
            opackHdr[6] = 0x93;
            opackHdr[7] = (uint8_t)(baaInterLen & 0xFF);
            opackHdr[8] = (uint8_t)((baaInterLen >> 8) & 0xFF);
            opackHdr[9] = (uint8_t)((baaInterLen >> 16) & 0xFF);
            opackHdr[10] = (uint8_t)((baaInterLen >> 24) & 0xFF);
            opackHdrLen = 11;
        }
        size_t opackBlobLen = opackHdrLen + baaInterLen;
        uint8_t *opackBlob = malloc(opackBlobLen);
        if (!opackBlob) {
            if (!t_quiet_request_log)
                printf("[AP] auth-setup: out of memory (OPACK blob)\n");
            free(encSig);
            send_response(sock, proto, 500, "Internal Server Error",
                          NULL, NULL, 0, r->cseq);
            return;
        }
        memcpy(opackBlob, opackHdr, opackHdrLen);
        memcpy(opackBlob + opackHdrLen, baaInterDer, baaInterLen);

        if (!t_quiet_request_log)
            printf("[AP] auth-setup: OPACK baIC blob: %zu bytes (hdr=%zu + inter=%d)\n",
                   opackBlobLen, opackHdrLen, baaInterLen);

        /* ── Build BAA MFi-SAP M2 response ──
         *
         * New layout (from CarPlay Simulator disassembly):
         *   server_curve25519_pub[32]
         *   leaf_len_be[4]
         *   leaf_der[leaf_len]         ← ONLY leaf, not leaf+intermediate
         *   enc_sig_len_be[4]
         *   enc_sig[enc_sig_len]
         *   baIC_len_be[4]             ← OPACK blob length
         *   OPACK({"baIC": inter})[baIC_len]
         */
        size_t respLen = 32 + 4 + baaLeafLen + 4 + encLen + 4 + opackBlobLen;
        uint8_t *resp = malloc(respLen);
        if (!resp) {
            if (!t_quiet_request_log)
                printf("[AP] auth-setup: out of memory (M2 response)\n");
            free(opackBlob);
            free(encSig);
            send_response(sock, proto, 500, "Internal Server Error",
                          NULL, NULL, 0, r->cseq);
            return;
        }
        uint8_t *p = resp;

        /* 1) Server Curve25519 public key */
        memcpy(p, ourPK, 32); p += 32;

        /* 2) Leaf cert only */
        p[0] = (baaLeafLen >> 24) & 0xFF;
        p[1] = (baaLeafLen >> 16) & 0xFF;
        p[2] = (baaLeafLen >> 8)  & 0xFF;
        p[3] =  baaLeafLen        & 0xFF;
        p += 4;
        memcpy(p, baaLeafDer, baaLeafLen); p += baaLeafLen;

        /* 3) Encrypted ECDSA signature */
        p[0] = (encLen >> 24) & 0xFF;
        p[1] = (encLen >> 16) & 0xFF;
        p[2] = (encLen >> 8)  & 0xFF;
        p[3] =  encLen        & 0xFF;
        p += 4;
        memcpy(p, encSig, encLen); p += encLen;

        /* 4) OPACK {"baIC": intermediate_der} */
        uint32_t opackBlobLen32 = (uint32_t)opackBlobLen;
        p[0] = (opackBlobLen32 >> 24) & 0xFF;
        p[1] = (opackBlobLen32 >> 16) & 0xFF;
        p[2] = (opackBlobLen32 >> 8)  & 0xFF;
        p[3] =  opackBlobLen32        & 0xFF;
        p += 4;
        memcpy(p, opackBlob, opackBlobLen); p += opackBlobLen;

        if (!t_quiet_request_log)
            printf("[AP] auth-setup M2 response: %zu bytes "
                   "(pk=32 + leaf=%d + sig=%zu + opack=%zu)\n",
                   respLen, baaLeafLen, encLen, opackBlobLen);

        send_response(sock, proto, 200, "OK",
                     "application/octet-stream", resp, respLen, r->cseq);
        app_send_status(STATUS_AUTH_COMPLETE);

        free(resp);
        free(opackBlob);
        free(encSig);
    }
}

/* ═══════════════════════════════════════════════════════════════
 * Endpoint: OPTIONS
 * ═══════════════════════════════════════════════════════════════ */

static void handle_options(int sock, const HTTPReq *r) {
    if (!t_quiet_request_log) printf("[AP] -> OPTIONS\n");
    const char *proto = strncmp(r->protocol, "RTSP", 4) == 0 ?
                        "RTSP/1.0" : "HTTP/1.1";

    /* Shared writer: after pair-verify the reply must be encrypted like
     * every other response on this socket. */
    send_response_with_headers(sock, proto, 200, "OK", NULL,
                               "Public: ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, "
                               "TEARDOWN, OPTIONS, POST, GET, PUT\r\n",
                               NULL, 0, r->cseq);
}

/* ═══════════════════════════════════════════════════════════════
 * Endpoint: RTSP SETUP
 *
 * Two phases:
 *  1) Initial session setup (no "streams" key): return control ports
 *  2) Stream setup (has "streams" array): allocate data/control ports
 * ═══════════════════════════════════════════════════════════════ */

static const char *addr_family_name(int family) {
    switch (family) {
        case AF_INET: return "IPv4";
        case AF_INET6: return "IPv6";
        default: return "unknown";
    }
}

static bool sockaddr_to_numeric(const struct sockaddr *sa, socklen_t slen,
                                char *host, size_t hostLen,
                                char *serv, size_t servLen) {
    int rc = getnameinfo(sa, slen, host, (socklen_t)hostLen,
                         serv, (socklen_t)servLen,
                         NI_NUMERICHOST | NI_NUMERICSERV);
    if (rc == 0) return true;
    snprintf(host, hostLen, "(getnameinfo:%d)", rc);
    if (serv && servLen) snprintf(serv, servLen, "0");
    return false;
}

/*
 * Apple's receiver marks the screen TCP socket as interactive video before
 * accepting the sender. This is not cosmetic DSCP tagging: Darwin's network
 * service type also selects the Wi-Fi WMM access category for locally emitted
 * packets, including TCP ACKs. Captures from CarPlay Simulator show 0x80 in
 * both directions, while Showcase previously returned every screen ACK as
 * best-effort 0x00 even though the iPhone's video packets were 0x80/0x82.
 *
 * Apply the public network-service API plus both layers used by
 * AccessorySDK's SocketSetQoS(kSocketQoS_AirPlayScreenVideo): the IP header
 * class and Darwin's private socket traffic class. The latter is what the
 * Apple implementation says the driver uses for mbuf prioritization.
 *
 * A Personal Hotspot peer can also arrive as an IPv4-mapped address on our
 * dual-stack IPv6 listener. In that case set IP_TOS as well as IPV6_TCLASS;
 * choosing solely from getsockname() would otherwise miss the on-wire IPv4
 * path used by older receivers. Reapply everything to the accepted socket
 * because not every Darwin release inherits every listener option.
 */
#ifndef SO_NET_SERVICE_TYPE
#define SO_NET_SERVICE_TYPE 0x1116
#endif
#ifndef NET_SERVICE_TYPE_VI
#define NET_SERVICE_TYPE_VI 3
#endif
#ifndef SO_TRAFFIC_CLASS
#define SO_TRAFFIC_CLASS 0x1086
#endif
#ifndef SO_TC_VI
#define SO_TC_VI 700
#endif

static void set_screen_socket_qos(int fd, const char *stage) {
    if (fd < 0) return;

    int serviceType = NET_SERVICE_TYPE_VI;
    int serviceResult = setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE,
                                   &serviceType, sizeof(serviceType));
    int serviceError = serviceResult == 0 ? 0 : errno;

    struct sockaddr_storage localAddress;
    memset(&localAddress, 0, sizeof(localAddress));
    socklen_t localLength = sizeof(localAddress);
    int family = AF_UNSPEC;
    if (getsockname(fd, (struct sockaddr *)&localAddress, &localLength) == 0)
        family = localAddress.ss_family;

    struct sockaddr_storage peerAddress;
    memset(&peerAddress, 0, sizeof(peerAddress));
    socklen_t peerLength = sizeof(peerAddress);
    int peerFamily = AF_UNSPEC;
    bool peerIsIPv4Mapped = false;
    if (getpeername(fd, (struct sockaddr *)&peerAddress, &peerLength) == 0) {
        peerFamily = peerAddress.ss_family;
        if (peerFamily == AF_INET6) {
            const struct sockaddr_in6 *peer6 =
                (const struct sockaddr_in6 *)&peerAddress;
            peerIsIPv4Mapped = IN6_IS_ADDR_V4MAPPED(&peer6->sin6_addr);
        }
    }

    int diffServ = 0x80; /* CS4 / WMM interactive video. */
    int ipResult = -1;
    int ipError = 0;
    int ipv6Result = -1;
    int ipv6Error = 0;
    if (family == AF_INET) {
#ifdef IP_TOS
        ipResult = setsockopt(fd, IPPROTO_IP, IP_TOS,
                              &diffServ, sizeof(diffServ));
        if (ipResult != 0) ipError = errno;
#endif
    } else if (family == AF_INET6) {
#ifdef IPV6_TCLASS
        ipv6Result = setsockopt(fd, IPPROTO_IPV6, IPV6_TCLASS,
                                &diffServ, sizeof(diffServ));
        if (ipv6Result != 0) ipv6Error = errno;
#endif
#ifdef IP_TOS
        if (peerIsIPv4Mapped) {
            ipResult = setsockopt(fd, IPPROTO_IP, IP_TOS,
                                  &diffServ, sizeof(diffServ));
            if (ipResult != 0) ipError = errno;
        }
#endif
    }

    int trafficClass = SO_TC_VI;
    int trafficResult = setsockopt(fd, SOL_SOCKET, SO_TRAFFIC_CLASS,
                                   &trafficClass, sizeof(trafficClass));
    int trafficError = trafficResult == 0 ? 0 : errno;

    int appliedServiceType = -1;
    socklen_t appliedLength = sizeof(appliedServiceType);
    int getResult = getsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE,
                               &appliedServiceType, &appliedLength);

    int appliedTrafficClass = -1;
    appliedLength = sizeof(appliedTrafficClass);
    int trafficGetResult = getsockopt(fd, SOL_SOCKET, SO_TRAFFIC_CLASS,
                                      &appliedTrafficClass, &appliedLength);

    printf("[SCREEN] QoS %s fd=%d family=%s peer=%s%s "
           "service=VI(%d) set=%s get=%s(%d) "
           "traffic=VI(%d) set=%s get=%s(%d) "
           "ipv6TClass=%s%s ipTOS=%s%s\n",
           stage ? stage : "socket", fd, addr_family_name(family),
           addr_family_name(peerFamily), peerIsIPv4Mapped ? "(v4-mapped)" : "",
           NET_SERVICE_TYPE_VI,
           serviceResult == 0 ? "OK" : "FAIL",
           getResult == 0 ? "OK" : "FAIL",
           getResult == 0 ? appliedServiceType : -1,
           SO_TC_VI,
           trafficResult == 0 ? "OK" : "FAIL",
           trafficGetResult == 0 ? "OK" : "FAIL",
           trafficGetResult == 0 ? appliedTrafficClass : -1,
           ipv6Result == 0 ? "OK" :
               (ipv6Result < 0 && !ipv6Error ? "N/A" : "FAIL"),
           ipv6Error ? strerror(ipv6Error) : "",
           ipResult == 0 ? "OK" :
               (ipResult < 0 && !ipError ? "N/A" : "FAIL"),
           ipError ? strerror(ipError) : "");
    if (serviceError || trafficError) {
        printf("[SCREEN] QoS %s errors service=%s traffic=%s\n",
               stage ? stage : "socket",
               serviceError ? strerror(serviceError) : "none",
               trafficError ? strerror(trafficError) : "none");
    }
}

/*
 * The event channel carries HID touch reports from this receiver to the
 * sender. On the hotspot link they share the receiver's transmit queue with
 * the screen stream's acknowledgements. Voice class lets a few dozen bytes of
 * touch data bypass that queue; its WMM access category is not aggregated, so
 * a report is not held while the radio builds a larger frame.
 */
#ifndef NET_SERVICE_TYPE_VO
#define NET_SERVICE_TYPE_VO 4
#endif
#ifndef SO_TC_VO
#define SO_TC_VO 800
#endif

static void set_event_socket_qos(int fd) {
    if (fd < 0) return;
    int serviceType = NET_SERVICE_TYPE_VO;
    int serviceResult = setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE,
                                   &serviceType, sizeof(serviceType));
    int trafficClass = SO_TC_VO;
    int trafficResult = setsockopt(fd, SOL_SOCKET, SO_TRAFFIC_CLASS,
                                   &trafficClass, sizeof(trafficClass));
    int diffServ = 0xC0; /* CS6 / WMM voice. */
    int tosResult = -1;
    struct sockaddr_storage local;
    socklen_t localLength = sizeof(local);
    memset(&local, 0, sizeof(local));
    if (getsockname(fd, (struct sockaddr *)&local, &localLength) == 0) {
        if (local.ss_family == AF_INET) {
            tosResult = setsockopt(fd, IPPROTO_IP, IP_TOS,
                                   &diffServ, sizeof(diffServ));
        } else if (local.ss_family == AF_INET6) {
            tosResult = setsockopt(fd, IPPROTO_IPV6, IPV6_TCLASS,
                                   &diffServ, sizeof(diffServ));
            const struct sockaddr_in6 *local6 =
                (const struct sockaddr_in6 *)&local;
            if (IN6_IS_ADDR_V4MAPPED(&local6->sin6_addr))
                setsockopt(fd, IPPROTO_IP, IP_TOS, &diffServ, sizeof(diffServ));
        }
    }
    printf("[EVENT] QoS voice: service=%s traffic=%s tos=%s\n",
           serviceResult == 0 ? "OK" : "FAIL",
           trafficResult == 0 ? "OK" : "FAIL",
           tosResult == 0 ? "OK" : "FAIL");
}

static int bind_udp_port_ipv4(uint16_t *outPort) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = INADDR_ANY;
    sa.sin_port = 0;
    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) { close(fd); return -1; }
    socklen_t sl = sizeof(sa);
    getsockname(fd, (struct sockaddr *)&sa, &sl);
    *outPort = ntohs(sa.sin_port);
    printf("[NET] bound UDP IPv4 fallback port %u fd=%d\n", *outPort, fd);
    return fd;
}

/* Helper: bind a UDP socket to any port and return (fd, port). */
static int bind_udp_port(uint16_t *outPort) {
    int savedErrno = 0;
    int fd = socket(AF_INET6, SOCK_DGRAM, 0);
    if (fd >= 0) {
        int no = 0;
        int yes = 1;
        if (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof(no)) != 0) {
            savedErrno = errno;
            printf("[NET] WARN: UDP IPV6_V6ONLY=0 failed errno=%d (%s)\n",
                   savedErrno, strerror(savedErrno));
            close(fd);
            goto udp_fallback;
        }
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

        struct sockaddr_in6 sa6;
        memset(&sa6, 0, sizeof(sa6));
        sa6.sin6_family = AF_INET6;
        sa6.sin6_addr = in6addr_any;
        sa6.sin6_port = 0;
        if (bind(fd, (struct sockaddr *)&sa6, sizeof(sa6)) == 0) {
            socklen_t sl = sizeof(sa6);
            if (getsockname(fd, (struct sockaddr *)&sa6, &sl) == 0) {
                *outPort = ntohs(sa6.sin6_port);
                printf("[NET] bound UDP dual-stack port %u fd=%d\n", *outPort, fd);
                return fd;
            }
            savedErrno = errno;
            printf("[NET] WARN: dual-stack UDP getsockname failed errno=%d (%s)\n",
                   savedErrno, strerror(savedErrno));
        } else {
            savedErrno = errno;
            printf("[NET] WARN: dual-stack UDP bind failed errno=%d (%s)\n",
                   savedErrno, strerror(savedErrno));
        }
        close(fd);
    } else {
        savedErrno = errno;
        printf("[NET] WARN: dual-stack UDP socket failed errno=%d (%s)\n",
               savedErrno, strerror(savedErrno));
    }

udp_fallback:
    printf("[NET] WARN: dual-stack UDP bind failed errno=%d (%s), falling back to IPv4\n",
           savedErrno, strerror(savedErrno));
    return bind_udp_port_ipv4(outPort);
}

static int bind_tcp_port_ipv4(uint16_t *outPort) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = INADDR_ANY;
    sa.sin_port = 0;
    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) { close(fd); return -1; }
    if (listen(fd, 1) < 0) {
        int savedErrno = errno;
        close(fd);
        errno = savedErrno;
        return -1;
    }
    socklen_t sl = sizeof(sa);
    if (getsockname(fd, (struct sockaddr *)&sa, &sl) < 0) {
        int savedErrno = errno;
        close(fd);
        errno = savedErrno;
        return -1;
    }
    *outPort = ntohs(sa.sin_port);
    printf("[NET] bound TCP IPv4 fallback port %u fd=%d\n", *outPort, fd);
    return fd;
}

/* Helper: bind a TCP listen socket to any port and return (fd, port) */
static int bind_tcp_port(uint16_t *outPort) {
    int savedErrno = 0;
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd >= 0) {
        int no = 0;
        int yes = 1;
        if (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof(no)) != 0) {
            savedErrno = errno;
            printf("[NET] WARN: TCP IPV6_V6ONLY=0 failed errno=%d (%s)\n",
                   savedErrno, strerror(savedErrno));
            close(fd);
            goto tcp_fallback;
        }
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

        struct sockaddr_in6 sa6;
        memset(&sa6, 0, sizeof(sa6));
        sa6.sin6_family = AF_INET6;
        sa6.sin6_addr = in6addr_any;
        sa6.sin6_port = 0;
        if (bind(fd, (struct sockaddr *)&sa6, sizeof(sa6)) == 0) {
            if (listen(fd, 1) == 0) {
                socklen_t sl = sizeof(sa6);
                if (getsockname(fd, (struct sockaddr *)&sa6, &sl) == 0) {
                    *outPort = ntohs(sa6.sin6_port);
                    printf("[NET] bound TCP dual-stack port %u fd=%d\n", *outPort, fd);
                    return fd;
                }
                savedErrno = errno;
                printf("[NET] WARN: dual-stack TCP getsockname failed errno=%d (%s)\n",
                       savedErrno, strerror(savedErrno));
            } else {
                savedErrno = errno;
                printf("[NET] WARN: dual-stack TCP listen failed errno=%d (%s)\n",
                       savedErrno, strerror(savedErrno));
            }
        } else {
            savedErrno = errno;
            printf("[NET] WARN: dual-stack TCP bind failed errno=%d (%s)\n",
                   savedErrno, strerror(savedErrno));
        }
        close(fd);
    } else {
        savedErrno = errno;
        printf("[NET] WARN: dual-stack TCP socket failed errno=%d (%s)\n",
               savedErrno, strerror(savedErrno));
    }

tcp_fallback:
    printf("[NET] WARN: dual-stack TCP bind failed errno=%d (%s), falling back to IPv4\n",
           savedErrno, strerror(savedErrno));
    return bind_tcp_port_ipv4(outPort);
}

/*
 * AirPlayReceiverSession opens its screen socket in the authenticated RTSP
 * peer's address family. That distinction matters on Darwin: accepting an
 * IPv4 sender through an IPv6 dual-stack socket produces an IPv4-mapped
 * socket on which IP_TOS cannot be applied. It also sets SO_RCVBUF before
 * listen(), so the accepted connection inherits the intended window scale.
 */
static int bind_screen_tcp_port(uint16_t *outPort, int peerFamily) {
    int family = peerFamily == AF_INET6 ? AF_INET6 : AF_INET;
    int fd = socket(family, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) {
        printf("[NET] ERROR: screen %s socket failed: %s\n",
               addr_family_name(family), strerror(errno));
        return -1;
    }

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
    if (family == AF_INET6) {
        if (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY,
                       &yes, sizeof(yes)) != 0) {
            printf("[NET] ERROR: screen IPV6_V6ONLY=1 failed: %s\n",
                   strerror(errno));
            close(fd);
            return -1;
        }
    }

    int requestedRcvBuf = g_screen_receive_buffer;
    if (setsockopt(fd, SOL_SOCKET, SO_RCVBUF,
                   &requestedRcvBuf, sizeof(requestedRcvBuf)) != 0) {
        printf("[SCREEN] WARN: listener SO_RCVBUF request %d failed: %s\n",
               requestedRcvBuf, strerror(errno));
    }
    int listenerRcvBuf = 0;
    socklen_t listenerRcvBufLength = sizeof(listenerRcvBuf);
    if (getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &listenerRcvBuf,
                   &listenerRcvBufLength) == 0) {
        printf("[SCREEN] Listener TCP receive buffer: requested=%d actual=%d\n",
               requestedRcvBuf, listenerRcvBuf);
    }

    set_screen_socket_qos(fd, "listener");

    int bindResult = -1;
    if (family == AF_INET) {
        struct sockaddr_in address4;
        memset(&address4, 0, sizeof(address4));
        address4.sin_family = AF_INET;
        address4.sin_addr.s_addr = htonl(INADDR_ANY);
        address4.sin_port = 0;
        bindResult = bind(fd, (struct sockaddr *)&address4, sizeof(address4));
    } else {
        struct sockaddr_in6 address6;
        memset(&address6, 0, sizeof(address6));
        address6.sin6_family = AF_INET6;
        address6.sin6_addr = in6addr_any;
        address6.sin6_port = 0;
        bindResult = bind(fd, (struct sockaddr *)&address6, sizeof(address6));
    }
    if (bindResult != 0 || listen(fd, 1) != 0) {
        printf("[NET] ERROR: screen %s bind/listen failed: %s\n",
               addr_family_name(family), strerror(errno));
        close(fd);
        return -1;
    }

    struct sockaddr_storage local;
    memset(&local, 0, sizeof(local));
    socklen_t localLength = sizeof(local);
    if (getsockname(fd, (struct sockaddr *)&local, &localLength) != 0) {
        printf("[NET] ERROR: screen getsockname failed: %s\n",
               strerror(errno));
        close(fd);
        return -1;
    }
    if (local.ss_family == AF_INET) {
        *outPort = ntohs(((struct sockaddr_in *)&local)->sin_port);
    } else {
        *outPort = ntohs(((struct sockaddr_in6 *)&local)->sin6_port);
    }
    printf("[NET] bound screen TCP %s port %u fd=%d\n",
           addr_family_name(family), *outPort, fd);
    return fd;
}

static int socket_bound_family(int fd) {
    struct sockaddr_storage local;
    socklen_t localLen = sizeof(local);
    memset(&local, 0, sizeof(local));
    if (fd < 0 ||
        getsockname(fd, (struct sockaddr *)&local, &localLen) != 0)
        return AF_UNSPEC;
    return local.ss_family;
}

static bool build_peer_sockaddr(const char *host, uint16_t port,
                                int socketFamily,
                                struct sockaddr_storage *out,
                                socklen_t *outLen,
                                char *display, size_t displayLen) {
    if (!host || !*host || !out || !outLen) return false;

    char addr[NI_MAXHOST];
    char scope[IF_NAMESIZE];
    memset(addr, 0, sizeof(addr));
    memset(scope, 0, sizeof(scope));
    snprintf(addr, sizeof(addr), "%s", host);

    char *pct = strchr(addr, '%');
    if (pct) {
        *pct = '\0';
        snprintf(scope, sizeof(scope), "%s", pct + 1);
    }

    memset(out, 0, sizeof(*out));
    struct in_addr ipv4;
    if (inet_pton(AF_INET, addr, &ipv4) == 1) {
        if (socketFamily == AF_INET6) {
            struct sockaddr_in6 *mapped = (struct sockaddr_in6 *)out;
            mapped->sin6_family = AF_INET6;
            mapped->sin6_port = htons(port);
            mapped->sin6_addr.s6_addr[10] = 0xff;
            mapped->sin6_addr.s6_addr[11] = 0xff;
            memcpy(&mapped->sin6_addr.s6_addr[12], &ipv4, sizeof(ipv4));
            *outLen = sizeof(*mapped);
        } else {
            struct sockaddr_in *sin = (struct sockaddr_in *)out;
            sin->sin_family = AF_INET;
            sin->sin_port = htons(port);
            sin->sin_addr = ipv4;
            *outLen = sizeof(*sin);
        }
        if (display && displayLen) snprintf(display, displayLen, "%s", addr);
        return true;
    }

    struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)out;
    memset(sin6, 0, sizeof(*sin6));
    sin6->sin6_family = AF_INET6;
    sin6->sin6_port = htons(port);
    if (inet_pton(AF_INET6, addr, &sin6->sin6_addr) == 1) {
        if (scope[0]) {
            sin6->sin6_scope_id = if_nametoindex(scope);
            if (sin6->sin6_scope_id == 0) {
                printf("[TIMING] WARN: scope interface '%s' not found for %s\n",
                       scope, host);
            }
        } else if (IN6_IS_ADDR_LINKLOCAL(&sin6->sin6_addr)) {
            sin6->sin6_scope_id = if_nametoindex(g_wifi_interface);
            if (sin6->sin6_scope_id) snprintf(scope, sizeof(scope), "%s", g_wifi_interface);
            printf("[TIMING] IPv6 link-local had no scope; using %s scope_id=%u\n",
                   g_wifi_interface, sin6->sin6_scope_id);
        }
        *outLen = sizeof(struct sockaddr_in6);
        if (display && displayLen) {
            if (scope[0]) snprintf(display, displayLen, "%s%%%s", addr, scope);
            else snprintf(display, displayLen, "%s", addr);
        }
        return true;
    }

    return false;
}

/* Session state */
static int   g_timing_fd = -1;
static int   g_event_fd  = -1;
static int   g_keepalive_fd = -1;
static uint16_t g_timing_port = 0;
static uint16_t g_event_port  = 0;
static uint16_t g_keepalive_port = 0;
static bool  g_session_active = false;
static bool  g_timing_thread_running = false;
static bool  g_event_thread_running = false;
static atomic_int g_event_client_fd = -1;  /* accepted event connection */
static volatile uint64_t g_last_touch_nanos = 0;

/*
 * Upper bound for one screen-stream body. The 32-bit length at the start of
 * the 128-byte header is plaintext that arrives before the AEAD check runs,
 * so it is attacker-controlled. VideoConfig, VideoFrame and KeepAliveWithBody
 * are the only bodies this stream carries, and the largest 4K H.264 access
 * unit is a few MiB, so 16 MiB is far above anything real while staying far
 * below the point where the length arithmetic can wrap.
 */
#define SCREEN_MAX_BODY_BYTES (16u * 1024u * 1024u)

/* Screen stream state */
static int      g_screen_listen_fd = -1;     /* TCP listen socket for screen data */
/* g_screen_lock guards the descriptors below and g_screen_listen_fd handoff:
 * the listener the screen thread owns, the accepted stream socket, and the
 * stream generation that TEARDOWN/replacement SETUP advance. */
#define SCREEN_ACCEPT_TIMEOUT_SECONDS 30
static pthread_mutex_t g_screen_lock = PTHREAD_MUTEX_INITIALIZER;
static int      g_screen_thread_listen_fd = -1;
static int      g_screen_client_fd = -1;
static uint32_t g_screen_generation = 0;
static uint16_t g_screen_data_port = 0;
static uint64_t g_screen_conn_id = 0;        /* streamConnectionID from SETUP Phase 2 */
static uint8_t  g_screen_key[32] = {0};      /* ChaCha20-Poly1305 decryption key */
static bool     g_screen_key_valid = false;

/* iPhone's timing port and IP — needed for server-initiated timing negotiation */
static uint16_t g_iphone_timing_port = 0;
static char     g_iphone_ip[64] = {0};
static int      g_iphone_family = AF_UNSPEC;
static int      g_rtsp_sock = -1;  /* current RTSP control socket, for getpeername */
static volatile int g_timing_sync_count = 0;  /* responses received during negotiation */
static volatile double g_timing_remote_minus_local = 0.0;
static volatile double g_timing_best_rtt = DBL_MAX;
static volatile int32_t g_timing_offset_valid = 0;
/* Recent NTP samples. The offset follows the lowest-RTT sample among the
 * last TIMING_SAMPLE_WINDOW responses: the window holds the whole negotiation
 * burst (so the first choice is its best sample) and then slides over the
 * 2.5 s maintenance probes, so the offset keeps tracking the drift between
 * the two clocks instead of freezing on the best RTT ever seen. Only the
 * timing thread touches the samples; a new negotiation asks it to drop them
 * through g_timing_samples_reset. */
#define TIMING_SAMPLE_WINDOW 8
static double   g_timing_sample_rtt[TIMING_SAMPLE_WINDOW];
static double   g_timing_sample_offset[TIMING_SAMPLE_WINDOW];
static unsigned g_timing_sample_count = 0;
static volatile int32_t g_timing_samples_reset = 0;
static volatile uint32_t g_timing_maintenance_generation = 0;
static bool app_send_video_timing(void);

/* True only for the address of the iPhone whose SETUP created this session.
 * The event, screen and timing endpoints are unauthenticated at the socket
 * level, so other LAN hosts must not be able to occupy or feed them. */
static bool sockaddr_is_session_iphone(const struct sockaddr *sa,
                                       socklen_t length) {
    if (g_iphone_ip[0] == '\0') return false;
    char host[NI_MAXHOST] = {0};
    char serv[NI_MAXSERV] = {0};
    if (!sockaddr_to_numeric(sa, length, host, sizeof(host),
                             serv, sizeof(serv)))
        return false;
    const char *ip = host;
    if (sa->sa_family == AF_INET6 &&
        IN6_IS_ADDR_V4MAPPED(&((const struct sockaddr_in6 *)sa)->sin6_addr) &&
        strncmp(ip, "::ffff:", 7) == 0)
        ip += 7;
    return strcmp(ip, g_iphone_ip) == 0;
}

static uint16_t sockaddr_port(const struct sockaddr *sa) {
    if (sa->sa_family == AF_INET)
        return ntohs(((const struct sockaddr_in *)sa)->sin_port);
    if (sa->sa_family == AF_INET6)
        return ntohs(((const struct sockaddr_in6 *)sa)->sin6_port);
    return 0;
}

/* Transmit timestamps of our outstanding NTP requests. A pt=211 response is
 * accepted only if its originate time echoes one of them, once. */
#define TIMING_PENDING_SLOTS 16
static pthread_mutex_t g_timing_pending_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_timing_pending[TIMING_PENDING_SLOTS];
static unsigned g_timing_pending_next = 0;

static void timing_remember_request(const uint8_t transmit[8]) {
    uint64_t stamp = 0;
    memcpy(&stamp, transmit, sizeof(stamp));
    pthread_mutex_lock(&g_timing_pending_lock);
    g_timing_pending[g_timing_pending_next] = stamp;
    g_timing_pending_next = (g_timing_pending_next + 1) % TIMING_PENDING_SLOTS;
    pthread_mutex_unlock(&g_timing_pending_lock);
}

static bool timing_consume_request(const uint8_t originate[8]) {
    uint64_t stamp = 0;
    memcpy(&stamp, originate, sizeof(stamp));
    if (stamp == 0) return false;
    bool found = false;
    pthread_mutex_lock(&g_timing_pending_lock);
    for (unsigned i = 0; i < TIMING_PENDING_SLOTS; i++) {
        if (g_timing_pending[i] == stamp) {
            g_timing_pending[i] = 0;
            found = true;
            break;
        }
    }
    pthread_mutex_unlock(&g_timing_pending_lock);
    return found;
}

/* ═══════════════════════════════════════════════════════════════
 * NTP Timing Responder Thread
 *
 * The iPhone sends RTCP-style NTP timing requests (packet type 210)
 * to our timing UDP port. We must respond with type 211 containing
 * NTP timestamps for clock synchronisation. Without this, the
 * iPhone tears down the session.
 *
 * Packet format (32 bytes):
 *   [0]    v_p_m           (version/padding/marker, typically 0x80)
 *   [1]    pt              (210 = request, 211 = response)
 *   [2-3]  length          (network-order, 32-bit words minus 1 = 6)
 *   [4-7]  rtpTimestamp    (RTP timestamp, echoed back)
 *   [8-11] ntpOriginateHi  (T1 seconds — server copies client's T3)
 *   [12-15]ntpOriginateLo  (T1 fraction)
 *   [16-19]ntpReceiveHi    (T2 seconds — server receive time)
 *   [20-23]ntpReceiveLo    (T2 fraction)
 *   [24-27]ntpTransmitHi   (T3 seconds — server transmit time)
 *   [28-31]ntpTransmitLo   (T3 fraction)
 *
 * NTP epoch: seconds since 1900-01-01. Unix offset = 2208988800.
 * ═══════════════════════════════════════════════════════════════ */

#define NTP_EPOCH_OFFSET 2208988800UL

static void get_ntp_time(uint32_t *sec, uint32_t *frac) {
    /*
     * AirPlay timing is an NTP-encoded monotonic clock, not civil time.
     * Apple's simulator sends seconds equal to NTP_EPOCH_OFFSET plus its
     * monotonic uptime, and its CarPlaySDK converts between that clock and
     * mach_absolute_time for screen presentation and audio anchors.
     *
     * Using gettimeofday here made every timing exchange advertise a clock
     * billions of seconds away from the sender's media timeline. Pairing and
     * transport survived because NTP can describe a large fixed offset, but
     * the screen and buffered-audio paths then had to recover from a clock
     * domain we invented. Keep the same NTP wire representation Apple uses
     * while sourcing it from the host clock that media timestamps use.
     *
     * This must be mach_absolute_time, not CLOCK_MONOTONIC. On older iOS,
     * CoreMedia's host clock and mach_absolute_time include a different amount
     * of suspended time than CLOCK_MONOTONIC. Feeding the latter into NTP and
     * then scheduling on CMClockGetHostTimeClock moves every frame by the
     * accumulated sleep duration.
     */
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t timebaseOnce;
    dispatch_once(&timebaseOnce, ^{
        mach_timebase_info(&timebase);
    });
    uint64_t ticks = mach_absolute_time();
    long double seconds =
        ((long double)ticks * (long double)timebase.numer) /
        ((long double)timebase.denom * 1000000000.0L);
    uint64_t wholeSeconds = (uint64_t)seconds;
    long double fractionalSeconds = seconds - (long double)wholeSeconds;
    *sec = (uint32_t)((uint64_t)NTP_EPOCH_OFFSET +
                      wholeSeconds);
    *frac = (uint32_t)(fractionalSeconds * 4294967296.0L);
}

static uint64_t synchronized_ntp_for_host_ticks(uint64_t hostTicks,
                                                uint64_t *rawNanos) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t timebaseOnce;
    dispatch_once(&timebaseOnce, ^{
        mach_timebase_info(&timebase);
    });

    long double ticksToSeconds =
        (long double)timebase.numer /
        ((long double)timebase.denom * 1000000000.0L);
    long double hostSeconds = (long double)hostTicks * ticksToSeconds;
    long double synchronizedSeconds =
        hostSeconds + (long double)NTP_EPOCH_OFFSET;
    if (g_timing_offset_valid) {
        synchronizedSeconds +=
            (long double)g_timing_remote_minus_local;
    }
    if (synchronizedSeconds < 0) synchronizedSeconds = 0;

    uint64_t wholeSeconds = (uint64_t)synchronizedSeconds;
    long double fractionalSeconds =
        synchronizedSeconds - (long double)wholeSeconds;
    if (rawNanos) {
        *rawNanos = (uint64_t)((long double)hostTicks *
                               (long double)timebase.numer /
                               (long double)timebase.denom);
    }
    return (wholeSeconds << 32) |
           (uint32_t)(fractionalSeconds * 4294967296.0L);
}

static double ntp_wire_time(const uint8_t bytes[8]) {
    uint32_t secondsNetwork = 0;
    uint32_t fractionNetwork = 0;
    memcpy(&secondsNetwork, bytes, sizeof(secondsNetwork));
    memcpy(&fractionNetwork, bytes + 4, sizeof(fractionNetwork));
    return (double)ntohl(secondsNetwork) +
           (double)ntohl(fractionNetwork) / 4294967296.0;
}

static void timing_thread_func(void *ctx) {
    (void)ctx;
    printf("[TIMING] NTP responder started on UDP port %u (fd=%d)\n",
           g_timing_port, g_timing_fd);
    fflush(stdout);

    uint8_t buf[64];
    struct sockaddr_storage from;
    uint64_t answered = 0;
    uint64_t ignored = 0;
    /* Every per-packet log below is counter-limited (first line, then every
     * 100th with the running total): the session gate only checks the source
     * IP, which UDP does not authenticate, so a spoofing LAN host could
     * otherwise flood the log until its size cap truncates real lines. */
    uint64_t shortPackets = 0;
    uint64_t sendFailures = 0;
    uint64_t unmatchedReplies = 0;
    uint64_t unknownPackets = 0;

    while (g_timing_fd >= 0) {
        socklen_t fromLen = sizeof(from);
        ssize_t n = recvfrom(g_timing_fd, buf, sizeof(buf), 0,
                             (struct sockaddr *)&from, &fromLen);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
            printf("[TIMING] recvfrom error: %s\n", strerror(errno));
            break;
        }
        /* The socket is unconnected: answer and log only the session
         * iPhone. Replying to any source would make this root daemon a
         * spoofable UDP reflector and lets LAN hosts flood app.log. */
        if (!sockaddr_is_session_iphone((struct sockaddr *)&from, fromLen)) {
            if (++ignored % 100 == 1) {
                printf("[TIMING] Ignoring datagram from a host that is "
                       "not the session iPhone (%llu so far)\n",
                       (unsigned long long)ignored);
                fflush(stdout);
            }
            continue;
        }
        if (n < 32) {
            if (++shortPackets % 100 == 1) {
                printf("[TIMING] Short packet (%zd bytes), ignoring "
                       "(%llu so far)\n", n,
                       (unsigned long long)shortPackets);
                fflush(stdout);
            }
            continue;
        }
        bool wroteLog = false;

        char fromHost[NI_MAXHOST] = {0};
        char fromPort[NI_MAXSERV] = {0};
        sockaddr_to_numeric((struct sockaddr *)&from, fromLen,
                            fromHost, sizeof(fromHost),
                            fromPort, sizeof(fromPort));

        uint8_t pt = buf[1];

        if (pt == 210) {
            /* Timing request from iPhone — build response */
            bool logThis = ++answered % 100 == 1;
            wroteLog = logThis;
            if (logThis)
                printf("[TIMING] Received timing REQUEST (%zd bytes) from "
                       "%s:%s family=%s (%llu answered)\n",
                       n, fromHost, fromPort,
                       addr_family_name(from.ss_family),
                       (unsigned long long)answered);

            uint32_t recvSec, recvFrac;
            get_ntp_time(&recvSec, &recvFrac);

            uint8_t resp[32];
            memcpy(resp, buf, 32);

            resp[1] = 211;  /* response type */

            /* T1 (originate) = copy client's T3 (transmit) */
            memcpy(resp + 8, buf + 24, 8);

            /* T2 (receive) = our receive time */
            resp[16] = (recvSec >> 24) & 0xFF;
            resp[17] = (recvSec >> 16) & 0xFF;
            resp[18] = (recvSec >>  8) & 0xFF;
            resp[19] = (recvSec >>  0) & 0xFF;
            resp[20] = (recvFrac >> 24) & 0xFF;
            resp[21] = (recvFrac >> 16) & 0xFF;
            resp[22] = (recvFrac >>  8) & 0xFF;
            resp[23] = (recvFrac >>  0) & 0xFF;

            /* T3 (transmit) = our send time */
            uint32_t sendSec, sendFrac;
            get_ntp_time(&sendSec, &sendFrac);
            resp[24] = (sendSec >> 24) & 0xFF;
            resp[25] = (sendSec >> 16) & 0xFF;
            resp[26] = (sendSec >>  8) & 0xFF;
            resp[27] = (sendSec >>  0) & 0xFF;
            resp[28] = (sendFrac >> 24) & 0xFF;
            resp[29] = (sendFrac >> 16) & 0xFF;
            resp[30] = (sendFrac >>  8) & 0xFF;
            resp[31] = (sendFrac >>  0) & 0xFF;

            ssize_t sent = sendto(g_timing_fd, resp, 32, 0,
                                  (struct sockaddr *)&from, fromLen);
            if (sent != 32) {
                if (++sendFailures % 100 == 1) {
                    printf("[TIMING] NTP response send failed (%zd bytes) "
                           "to %s:%s family=%s (%llu failures so far)\n",
                           sent, fromHost, fromPort,
                           addr_family_name(from.ss_family),
                           (unsigned long long)sendFailures);
                    wroteLog = true;
                }
            } else if (logThis) {
                printf("[TIMING] Sent NTP response (%zd bytes) to %s:%s "
                       "family=%s\n", sent, fromHost, fromPort,
                       addr_family_name(from.ss_family));
            }
        } else if (pt == 211) {
            /* Timing response from iPhone to our negotiation request. Only
             * the session iPhone's timing port may answer, and only a request
             * we actually sent: a forged near-zero-RTT reply would otherwise
             * lock in an arbitrary clock offset that real replies cannot
             * displace. */
            if (!sockaddr_is_session_iphone((struct sockaddr *)&from,
                                            fromLen) ||
                sockaddr_port((struct sockaddr *)&from) !=
                    g_iphone_timing_port ||
                !timing_consume_request(buf + 8)) {
                if (++unmatchedReplies % 100 == 1) {
                    printf("[TIMING] Ignoring unmatched pt=211 from %s:%s "
                           "(%llu so far)\n", fromHost, fromPort,
                           (unsigned long long)unmatchedReplies);
                    fflush(stdout);
                }
                continue;
            }
            uint32_t receiveSeconds = 0;
            uint32_t receiveFraction = 0;
            get_ntp_time(&receiveSeconds, &receiveFraction);
            double t1 = ntp_wire_time(buf + 8);
            double t2 = ntp_wire_time(buf + 16);
            double t3 = ntp_wire_time(buf + 24);
            double t4 = (double)receiveSeconds +
                        (double)receiveFraction / 4294967296.0;
            double rtt = (t4 - t1) - (t3 - t2);
            double remoteMinusLocal =
                ((t2 - t1) + (t3 - t4)) * 0.5;
            bool selected = false;
            if (rtt >= 0.0 && rtt < 1.0) {
                if (__sync_bool_compare_and_swap(&g_timing_samples_reset,
                                                 1, 0))
                    g_timing_sample_count = 0;
                unsigned slot = g_timing_sample_count % TIMING_SAMPLE_WINDOW;
                g_timing_sample_rtt[slot] = rtt;
                g_timing_sample_offset[slot] = remoteMinusLocal;
                g_timing_sample_count++;
                unsigned filled = g_timing_sample_count < TIMING_SAMPLE_WINDOW
                    ? g_timing_sample_count : TIMING_SAMPLE_WINDOW;
                unsigned best = slot;
                for (unsigned i = 0; i < filled; i++) {
                    if (g_timing_sample_rtt[i] < g_timing_sample_rtt[best])
                        best = i;
                }
                selected = best == slot;
                if (!g_timing_offset_valid ||
                    g_timing_sample_offset[best] !=
                        g_timing_remote_minus_local) {
                    g_timing_best_rtt = g_timing_sample_rtt[best];
                    g_timing_remote_minus_local =
                        g_timing_sample_offset[best];
                    g_timing_offset_valid = 1;
                    app_send_video_timing();
                }
            }
            g_timing_sync_count++;
            printf("[TIMING] Received timing RESPONSE (pt=211) from %s:%s "
                   "family=%s sync #%d rtt=%.3fms remote-local=%.3fms "
                   "selected=%d\n",
                   fromHost, fromPort, addr_family_name(from.ss_family),
                   g_timing_sync_count, rtt * 1000.0,
                   remoteMinusLocal * 1000.0, selected ? 1 : 0);
            wroteLog = true;
        } else if (++unknownPackets % 100 == 1) {
            printf("[TIMING] Unknown packet type %u (%zd bytes) "
                   "(%llu so far)\n", pt, n,
                   (unsigned long long)unknownPackets);
            wroteLog = true;
        }
        if (wroteLog) fflush(stdout);
    }
    printf("[TIMING] Responder thread exiting\n");
    g_timing_thread_running = false;
}

static void start_timing_thread(void) {
    if (g_timing_thread_running || g_timing_fd < 0) return;
    g_timing_thread_running = true;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        timing_thread_func(NULL);
    });
}

/* ═══════════════════════════════════════════════════════════════
 * Event Port Acceptor Thread
 *
 * The iPhone connects to our event TCP port after SETUP.
 * We accept the connection and keep it alive. The event channel
 * uses HTTP/RTSP-like messaging for control events.
 * ═══════════════════════════════════════════════════════════════ */

static void event_thread_func(void *ctx) {
    (void)ctx;
    printf("[EVENT] Acceptor started on TCP port %u (fd=%d)\n",
           g_event_port, g_event_fd);
    fflush(stdout);

    /* A connection already accepted and validated by the read loop below
     * that replaces an idle channel. */
    int nextClient = -1;
    struct sockaddr_storage nextAddr;
    socklen_t nextAddrLen = 0;
    /* The listener stays bound on all interfaces for the daemon's
     * lifetime, so any LAN host can connect in a loop. Log rejections
     * sparsely or they fill the capped log and push out session lines. */
    uint64_t rejected = 0;
    while (g_event_fd >= 0) {
        struct sockaddr_storage ca;
        socklen_t cl = sizeof(ca);
        int client;
        if (nextClient >= 0) {
            client = nextClient;
            memcpy(&ca, &nextAddr, sizeof(ca));
            cl = nextAddrLen;
            nextClient = -1;
        } else {
            client = accept(g_event_fd, (struct sockaddr *)&ca, &cl);
        }
        if (client < 0) {
            int acceptErr = errno;
            /* EINTR, and ECONNABORTED (peer reset between the handshake and
             * accept), are per-connection failures: the listener is still
             * usable and the iPhone must be able to (re)connect for the rest
             * of the session. Descriptor exhaustion is transient. Only a
             * closed/invalid listener (teardown) ends the thread. */
            if (acceptErr == EINTR || acceptErr == ECONNABORTED)
                continue;
            if (acceptErr == EAGAIN || acceptErr == EWOULDBLOCK ||
                acceptErr == EMFILE || acceptErr == ENFILE ||
                acceptErr == ENOBUFS || acceptErr == ENOMEM) {
                if (acceptErr != EAGAIN && acceptErr != EWOULDBLOCK)
                    printf("[EVENT] accept error (retrying): %s\n",
                           strerror(acceptErr));
                usleep(100000);
                continue;
            }
            printf("[EVENT] accept error: %s\n", strerror(acceptErr));
            break;
        }

        char host[NI_MAXHOST], serv[NI_MAXSERV];
        sockaddr_to_numeric((struct sockaddr *)&ca, cl,
                            host, sizeof(host), serv, sizeof(serv));

        /* The event channel is served one client at a time. Only the
         * pair-verified session iPhone may hold it; a LAN peer that took it
         * would receive HID/requestUI traffic while the iPhone waited. */
        if (!g_event_enc.active ||
            !sockaddr_is_session_iphone((struct sockaddr *)&ca, cl)) {
            if (++rejected % 100 == 1) {
                printf("[EVENT] Rejecting %s:%s (%s) (%llu so far)\n",
                       host, serv,
                       g_event_enc.active ? "not the session iPhone"
                                          : "no event channel keys",
                       (unsigned long long)rejected);
                fflush(stdout);
            }
            close(client);
            continue;
        }
        printf("[EVENT] *** Connection from %s:%s family=%s ***\n",
               host, serv, addr_family_name(ca.ss_family));
        fflush(stdout);

        /* The iPhone starts the nonces of every new event connection at
         * zero, including a reconnect within the same session. */
        if (g_event_send_lock)
            dispatch_semaphore_wait(g_event_send_lock, DISPATCH_TIME_FOREVER);
        g_event_enc.readNonce = 0;
        g_event_enc.writeNonce = 0;
        g_event_client_fd = client;
        if (g_event_send_lock) dispatch_semaphore_signal(g_event_send_lock);

        /* HID commands are tiny and latency-sensitive. Without TCP_NODELAY,
         * Nagle combines consecutive reports while waiting for the iPhone's
         * ACK, which turns continuous swipes into visible stair-steps. */
        int yes = 1;
        setsockopt(client, SOL_SOCKET, SO_KEEPALIVE, &yes, sizeof(yes));
        setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
        set_event_socket_qos(client);

        /* Read loop — decrypt ChaCha20-Poly1305 framed messages */
        uint8_t buf[16384];
        struct timeval tv = { .tv_sec = 120, .tv_usec = 0 };
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        /* Every event-channel write runs under g_event_send_lock, which the
         * HID queue and IPC-triggered commands also wait for. Bound a write
         * into a stalled connection so they are not held for as long as TCP
         * keeps retransmitting. */
        struct timeval sendTimeout = {
            .tv_sec = EVENT_SEND_TIMEOUT_SEC, .tv_usec = 0 };
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout,
                   sizeof(sendTimeout));

        if (g_event_enc.active) {
            printf("[EVENT] Encrypted event channel active\n");
            fflush(stdout);
            if (SHOWCASE_VIDEO_IN_CAR_BENCH) send_car_video_availability();
            uint64_t normalResponseCount = 0;
            uint8_t pending[HTTP_STREAM_LIMIT + ENCRYPTED_MAX_READ_SIZE];
            size_t used = 0;
            http_progress_t progress = {0};
            while (1) {
                int ptLen = enc_recv_frame(client, &g_event_enc, buf, sizeof(buf));
                if (ptLen == -2) {
                    /* A new connection from the session iPhone replaces one
                     * that went silent (for example a half-open socket).
                     * Anything else waiting on the listener is accepted and
                     * closed here so it cannot displace the live channel. */
                    struct pollfd listener = { .fd = g_event_fd,
                                               .events = POLLIN };
                    bool superseded = false;
                    while (g_event_fd >= 0 && poll(&listener, 1, 0) > 0 &&
                           (listener.revents & POLLIN)) {
                        struct sockaddr_storage na;
                        socklen_t nl = sizeof(na);
                        int candidate = accept(g_event_fd,
                                               (struct sockaddr *)&na, &nl);
                        if (candidate < 0) break;
                        if (!sockaddr_is_session_iphone(
                                (struct sockaddr *)&na, nl)) {
                            if (++rejected % 100 == 1) {
                                char nh[NI_MAXHOST], ns[NI_MAXSERV];
                                sockaddr_to_numeric((struct sockaddr *)&na, nl,
                                                    nh, sizeof(nh),
                                                    ns, sizeof(ns));
                                printf("[EVENT] Rejecting %s:%s while the "
                                       "channel is idle (not the session "
                                       "iPhone) (%llu so far)\n",
                                       nh, ns, (unsigned long long)rejected);
                                fflush(stdout);
                            }
                            close(candidate);
                            continue;
                        }
                        nextClient = candidate;
                        memcpy(&nextAddr, &na, sizeof(nextAddr));
                        nextAddrLen = nl;
                        superseded = true;
                        break;
                    }
                    if (superseded) {
                        printf("[EVENT] Idle channel superseded by a new "
                               "connection from the session iPhone\n");
                        break;
                    }
                    printf("[EVENT] Encrypted channel idle, still alive\n");
                    fflush(stdout);
                    continue;
                }
                if (ptLen < 0) {
                    printf("[EVENT] Encrypted recv error or disconnect\n");
                    break;
                }
                if (ptLen == 0 || (size_t)ptLen > sizeof(pending) - used) break;
                memcpy(pending + used, buf, (size_t)ptLen);
                used += (size_t)ptLen;
                HTTPReq request;
                while (parse_http_incremental(pending, used, HTTP_STREAM_LIMIT,
                                              &progress, &request)) {
                    size_t length = (size_t)(request.body - pending) + request.bodyLen;
                    if (length >= 12 && memcmp(pending, "RTSP/1.0 200", 12) == 0) {
                        if (++normalResponseCount % 250 == 0)
                            printf("[EVENT] %llu normal HID acknowledgements\n",
                                   normalResponseCount);
                    } else if (!process_event_command_frame(pending, length)) {
                        printf("[EVENT] Unhandled event message (%zu bytes)\n", length);
                    }
                    used -= length;
                    memmove(pending, pending + length, used);
                    progress = (http_progress_t){0};
                }
                if (request.invalid) break;
            }
        } else {
            printf("[EVENT] WARNING: plaintext event channel (no encryption keys)\n");
            fflush(stdout);
            while (1) {
                ssize_t n = recv(client, buf, sizeof(buf), 0);
                if (n > 0) {
                    printf("[EVENT] Received %zd bytes:", n);
                    int dump = n > 128 ? 128 : (int)n;
                    for (int i = 0; i < dump; i++) printf(" %02X", buf[i]);
                    if (n > 128) printf(" ...");
                    printf("\n");
                    fflush(stdout);
                } else if (n == 0) {
                    printf("[EVENT] Client disconnected\n");
                    break;
                } else {
                    if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
                    printf("[EVENT] recv error: %s\n", strerror(errno));
                    break;
                }
            }
        }
        if (g_event_send_lock)
            dispatch_semaphore_wait(g_event_send_lock, DISPATCH_TIME_FOREVER);
        g_event_client_fd = -1;
        close(client);
        if (g_event_send_lock) dispatch_semaphore_signal(g_event_send_lock);
        printf("[EVENT] Client connection closed\n");
        fflush(stdout);
    }
    if (nextClient >= 0) close(nextClient);
    g_event_thread_running = false;
}

static void start_event_thread(void) {
    if (g_event_thread_running || g_event_fd < 0) return;
    g_event_thread_running = true;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        event_thread_func(NULL);
    });
}

/* ═══════════════════════════════════════════════════════════════
 * KeepAlive Port Responder
 *
 * UDP keep-alive: just echo back whatever the iPhone sends.
 * ═══════════════════════════════════════════════════════════════ */

static bool g_keepalive_thread_running = false;

static void keepalive_thread_func(void *ctx) {
    (void)ctx;
    printf("[KEEPALIVE] Responder started on UDP port %u (fd=%d)\n",
           g_keepalive_port, g_keepalive_fd);
    fflush(stdout);

    uint8_t buf[256];
    struct sockaddr_storage from;
    uint64_t echoed = 0;
    uint64_t ignored = 0;

    while (g_keepalive_fd >= 0) {
        socklen_t fromLen = sizeof(from);
        ssize_t n = recvfrom(g_keepalive_fd, buf, sizeof(buf), 0,
                             (struct sockaddr *)&from, &fromLen);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
            break;
        }
        /* Echo only to the session iPhone. Answering any source would make
         * this port a reflector and lets a spoofed packet start an endless
         * ping-pong with another UDP echo service. */
        if (!sockaddr_is_session_iphone((struct sockaddr *)&from, fromLen)) {
            if (++ignored % 100 == 1) {
                printf("[KEEPALIVE] Ignoring datagram from a host that is "
                       "not the session iPhone (%llu so far)\n",
                       (unsigned long long)ignored);
                fflush(stdout);
            }
            continue;
        }
        if (++echoed % 100 == 1) {
            printf("[KEEPALIVE] Received %zd bytes (%llu echoed)\n", n,
                   (unsigned long long)echoed);
            fflush(stdout);
        }
        sendto(g_keepalive_fd, buf, (size_t)n, 0,
               (struct sockaddr *)&from, fromLen);
    }
    g_keepalive_thread_running = false;
}

static void start_keepalive_thread(void) {
    if (g_keepalive_thread_running || g_keepalive_fd < 0) return;
    g_keepalive_thread_running = true;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        keepalive_thread_func(NULL);
    });
}

/* ═══════════════════════════════════════════════════════════════
 * Screen Data Receiver Thread
 *
 * Accepts TCP connection from iPhone on the screen data port,
 * derives ChaCha20-Poly1305 decryption key from pair-verify shared
 * secret + streamConnectionID, and reads incoming video frames.
 *
 * Screen data framing: each frame is a 128-byte header followed by
 * encrypted H.264 NAL unit data.
 * ═══════════════════════════════════════════════════════════════ */
static volatile int32_t g_screen_thread_running = 0;
static volatile int32_t g_screen_start_pending = 0;
static uint64_t monotonic_nanos_now(void);

/* ── Helpers: read exactly N bytes from TCP ── */
static bool tcp_read_exact(int fd, uint8_t *buf, size_t len) {
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, buf + got, len - got, 0);
        if (n <= 0) return false;
        got += n;
    }
    return true;
}

/*
 * A completed-frame arrival gap cannot distinguish sender starvation from
 * TCP head-of-line blocking: the old telemetry only sampled the socket after
 * recv() had finally returned the whole record. Keep the screen socket's
 * blocking semantics, but use select() as an observation point while waiting.
 * No timeout is applied to the connection and no bytes or frames are dropped.
 */
typedef struct {
    bool valid;
    uint32_t receiveWindow;
    uint32_t smoothedRTT;
    uint32_t currentRTT;
    uint32_t retransmitTimeout;
    uint32_t flags;
    uint64_t receivedPackets;
    uint64_t receivedBytes;
    uint64_t outOfOrderBytes;
} ScreenTCPSnapshot;

static ScreenTCPSnapshot screen_tcp_snapshot(int fd) {
    ScreenTCPSnapshot snapshot;
    memset(&snapshot, 0, sizeof(snapshot));
#ifdef TCP_CONNECTION_INFO
    struct tcp_connection_info tcpInfo;
    memset(&tcpInfo, 0, sizeof(tcpInfo));
    socklen_t tcpInfoLength = sizeof(tcpInfo);
    if (getsockopt(fd, IPPROTO_TCP, TCP_CONNECTION_INFO, &tcpInfo,
                   &tcpInfoLength) == 0) {
        snapshot.valid = true;
        snapshot.receiveWindow = tcpInfo.tcpi_rcv_wnd;
        snapshot.smoothedRTT = tcpInfo.tcpi_srtt;
        snapshot.currentRTT = tcpInfo.tcpi_rttcur;
        snapshot.retransmitTimeout = tcpInfo.tcpi_rto;
        snapshot.flags = tcpInfo.tcpi_flags;
        snapshot.receivedPackets = tcpInfo.tcpi_rxpackets;
        snapshot.receivedBytes = tcpInfo.tcpi_rxbytes;
        snapshot.outOfOrderBytes = tcpInfo.tcpi_rxoutoforderbytes;
    }
#else
    (void)fd;
#endif
    return snapshot;
}

static void screen_log_tcp_wait(int fd, const char *phase,
                                uint64_t startedNanos, size_t got, size_t need,
                                ScreenTCPSnapshot baseline,
                                const char *event) {
    uint64_t nowNanos = monotonic_nanos_now();
    double waitedMillis = (double)(nowNanos - startedNanos) / 1000000.0;
    int pendingBytes = 0;
    if (ioctl(fd, FIONREAD, &pendingBytes) != 0 || pendingBytes < 0)
        pendingBytes = 0;

    ScreenTCPSnapshot current = screen_tcp_snapshot(fd);
    uint64_t packetDelta = 0;
    uint64_t byteDelta = 0;
    uint64_t outOfOrderDelta = 0;
    if (baseline.valid && current.valid) {
        packetDelta = current.receivedPackets - baseline.receivedPackets;
        byteDelta = current.receivedBytes - baseline.receivedBytes;
        outOfOrderDelta =
            current.outOfOrderBytes - baseline.outOfOrderBytes;
    }

    printf("[SCREEN][TCP-%s] phase=%s waited=%.1fms read=%zu/%zu "
           "socket=%d rxPackets=%llu(+%llu) rxBytes=%llu(+%llu) "
           "rxOOO=%llu(+%llu) rcvWnd=%u srtt=%u rtt=%u rto=%u "
           "flags=0x%x\n",
           event, phase, waitedMillis, got, need, pendingBytes,
           (unsigned long long)current.receivedPackets,
           (unsigned long long)packetDelta,
           (unsigned long long)current.receivedBytes,
           (unsigned long long)byteDelta,
           (unsigned long long)current.outOfOrderBytes,
           (unsigned long long)outOfOrderDelta,
           current.receiveWindow, current.smoothedRTT, current.currentRTT,
           current.retransmitTimeout, current.flags);
}

static bool screen_read_exact(int fd, uint8_t *buf, size_t len,
                              const char *phase) {
    const uint64_t logThresholdNanos = 500ULL * NSEC_PER_MSEC;
    const uint64_t logIntervalNanos = 500ULL * NSEC_PER_MSEC;
    const uint64_t touchWindowNanos = 2ULL * NSEC_PER_SEC;
    const bool isBody = strcmp(phase, "body") == 0;
    uint64_t startedNanos = monotonic_nanos_now();
    uint64_t lastLogNanos = 0;
    bool observedInteractiveWait = false;
    ScreenTCPSnapshot baseline = screen_tcp_snapshot(fd);
    size_t got = 0;

    while (got < len) {
        fd_set readSet;
        FD_ZERO(&readSet);
        FD_SET(fd, &readSet);
        struct timeval timeout = { .tv_sec = 0, .tv_usec = 250000 };
        int ready = select(fd + 1, &readSet, NULL, NULL, &timeout);
        if (ready < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (ready == 0) {
            uint64_t nowNanos = monotonic_nanos_now();
            uint64_t waitedNanos = nowNanos - startedNanos;
            uint64_t lastTouchNanos = g_last_touch_nanos;
            bool touchIsRecent =
                lastTouchNanos != 0 && nowNanos >= lastTouchNanos &&
                nowNanos - lastTouchNanos <= touchWindowNanos;
            if (touchIsRecent) observedInteractiveWait = true;
            if (waitedNanos >= logThresholdNanos &&
                (isBody || touchIsRecent) &&
                (lastLogNanos == 0 ||
                 nowNanos - lastLogNanos >= logIntervalNanos)) {
                screen_log_tcp_wait(fd, phase, startedNanos, got, len,
                                    baseline, "WAIT");
                lastLogNanos = nowNanos;
            }
            continue;
        }

        ssize_t n = recv(fd, buf + got, len - got, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        got += (size_t)n;
    }

    uint64_t completedNanos = monotonic_nanos_now();
    if (completedNanos - startedNanos >= logThresholdNanos &&
        (isBody || observedInteractiveWait)) {
        screen_log_tcp_wait(fd, phase, startedNanos, got, len, baseline,
                            "RECOVER");
    }
    return true;
}

/* ── IPC to iPadPlay app via Unix socket ── */
#define IPADPLAY_SOCK "/tmp/ipadplay.sock"
#define MSG_VIDEO_CONFIG 0x01
#define MSG_VIDEO_FRAME  0x02
#define MSG_STATUS       0x04   /* services → app, 1 byte status code */
#define MSG_APP_VISIBILITY 0x05 /* app → services, 1 while foreground */
#define MSG_VIDEO_TIMING 0x06   /* services → app, uint32 latency in ms */
#define MSG_VIDEO_RESYNC 0x07   /* app → services, renderer needs keyframe */
/* app → services, uint32 streamType: an audio packet arrived for a stream the
 * app has no player for, so AUDIO_CONFIG is sent again. (0x0D/0x0E are the
 * video-in-car bench messages.) */
#define MSG_AUDIO_RESYNC 0x0F
#define VIDEO_FRAME_METADATA_SIZE 56
/* STATUS_* codes are forward-declared at the top of the file. */

static int g_app_sock = -1;
static volatile bool g_app_video_enabled = true;
static volatile uint32_t g_screen_latency_ms = 75;

/* AirPlayScreenHeader.smallParam[1] bit 1 (kAirPlayScreenFlag_RespectTimestamps).
 * When the sender sets it, params[0] of every VideoFrame carries the 32.32
 * fixed-point time on the session timeline at which the frame must appear.
 * Displaying on arrival instead turns delivery jitter straight into judder and
 * throws away frames that arrive inside one refresh of each other. */
static volatile uint32_t g_screen_respect_timestamps = 0;

static uint64_t monotonic_nanos_now(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * NSEC_PER_SEC + (uint64_t)now.tv_nsec;
}

/* Presentation contract:
 * [uint32 latencyMs][uint8 respectTimestamps]
 * [double senderToHostOffset][uint8 offsetValid].
 *
 * NTP gives remote-minus-local. Frame timestamps are on the remote timeline,
 * so senderToHostOffset is its negation. */
static uint32_t build_video_timing_payload(uint8_t out[14]) {
    uint32_t latency = g_screen_latency_ms;
    memcpy(out, &latency, sizeof(latency));
    out[4] = g_screen_respect_timestamps ? 1 : 0;
    double senderToHostOffset = -g_timing_remote_minus_local;
    memcpy(out + 5, &senderToHostOffset, sizeof(senderToHostOffset));
    out[13] = g_timing_offset_valid ? 1 : 0;
    return 14;
}
static dispatch_semaphore_t g_app_send_lock = NULL;
static dispatch_semaphore_t g_video_config_lock = NULL;
static uint8_t *g_latest_video_config = NULL;
static uint32_t g_latest_video_config_length = 0;
static bool start_touch_reader(int fd);  /* forward declaration */
static void send_request_ui_command(const char *reason);
static void send_take_main_screen_command(const char *reason);

/* The app can be suspended by iOS (background, audio stopped) while the
 * sender keeps streaming. A blocking write into a full AF_UNIX buffer would
 * then hold g_app_send_lock forever, and RTSP control (SETRATE, FLUSH,
 * TEARDOWN) waiting on that lock would stall until the iPhone drops the
 * session. Every IPC message therefore has a bounded write deadline; a stalled
 * peer gets its connection dropped (a partial message cannot be resumed) and
 * reconnects are paused briefly so a suspended app is not hammered. */
#define APP_IPC_WRITE_TIMEOUT_MS 300
/* A lock holder writes at most two deadlines' worth: one shared by all
 * catch-up writes (bootstrap, audio configs, pending controls) and one for
 * its own message. */
#define APP_IPC_LOCK_TIMEOUT_MS  (APP_IPC_WRITE_TIMEOUT_MS * 2 + 100)
#define APP_IPC_STALL_BACKOFF_MS 1000
static uint64_t g_app_reconnect_after_nanos = 0; /* guarded by g_app_send_lock */

static uint64_t app_ipc_deadline(void) {
    return monotonic_nanos_now() +
        (uint64_t)APP_IPC_WRITE_TIMEOUT_MS * NSEC_PER_MSEC;
}

static bool app_send_lock_acquire(void) {
    if (!g_app_send_lock) return true;
    return dispatch_semaphore_wait(
        g_app_send_lock,
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)APP_IPC_LOCK_TIMEOUT_MS * NSEC_PER_MSEC)) == 0;
}

/* Non-blocking send + poll so the touch reader can keep using the same
 * (blocking) descriptor. Fails with errno = ETIMEDOUT at the deadline. */
static bool app_write_all(int fd, const uint8_t *data, size_t length,
                          uint64_t deadlineNanos) {
    size_t sent = 0;
    while (sent < length) {
        ssize_t n = send(fd, data + sent, length - sent, MSG_DONTWAIT);
        if (n > 0) {
            sent += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK))
            return false;
        uint64_t now = monotonic_nanos_now();
        if (now >= deadlineNanos) {
            errno = ETIMEDOUT;
            return false;
        }
        uint64_t remainingMs = (deadlineNanos - now + NSEC_PER_MSEC - 1) /
            NSEC_PER_MSEC;
        struct pollfd pfd = { .fd = fd, .events = POLLOUT, .revents = 0 };
        int ready = poll(&pfd, 1, (int)remainingMs);
        if (ready < 0 && errno != EINTR) return false;
        if (ready > 0 && (pfd.revents & (POLLERR | POLLNVAL))) return false;
    }
    return true;
}

static bool app_write_msg_until(int fd, uint8_t type, const uint8_t *data,
                                uint32_t len, uint64_t deadline) {
    uint8_t hdr[5] = {
        len & 0xFF, (len >> 8) & 0xFF,
        (len >> 16) & 0xFF, (len >> 24) & 0xFF, type
    };
    return app_write_all(fd, hdr, sizeof(hdr), deadline) &&
           app_write_all(fd, data, len, deadline);
}

static bool app_write_msg_to_socket(int fd, uint8_t type,
                                    const uint8_t *data, uint32_t len) {
    return app_write_msg_until(fd, type, data, len, app_ipc_deadline());
}

/* A video message that could not be delivered (lock timeout or failed write)
 * leaves the app's H.264 chain without its reference or parameter sets.
 * g_app_needs_keyframe stays set until an IDR reaches the app;
 * g_app_bootstrap_pending makes the next sender re-send the timing contract
 * and latest SPS/PPS before its own message. Both are read and cleared under
 * g_app_send_lock; setting them without it is safe (a redundant resend at
 * worst). */
#define APP_KEYFRAME_REQUEST_INTERVAL_MS 1000
#define APP_RECONNECT_SLACK_MS 50
static volatile bool g_app_needs_keyframe = false;
static volatile bool g_app_bootstrap_pending = false;
/* Set when an AUDIO_CONFIG could not be delivered; the streams concerned
 * carry appConfigPending. Read and cleared under g_app_send_lock like
 * g_app_bootstrap_pending. */
static volatile bool g_app_audio_config_pending = false;
static bool app_write_audio_configs(bool allActive, uint64_t deadline);
/* Set when an AUDIO_CONTROL (PAUSE/RESUME/STOP) could not be delivered; the
 * streams concerned carry appControlPending with their latest action. The
 * app has no other way to learn a rate change, so like AUDIO_CONFIG it is
 * never just dropped. Read and cleared under g_app_send_lock. */
static volatile bool g_app_audio_control_pending = false;
/* MSG_BT_HANDOFF (from the iPhone's one-shot disableBluetooth) has not
 * reached the app yet. Read and cleared under g_app_send_lock. */
static volatile bool g_app_bt_handoff_pending = false;
static bool app_write_pending_controls(uint64_t deadline);
static volatile uint64_t g_app_last_keyframe_request_nanos = 0;
static bool g_app_reconnect_scheduled = false; /* guarded by g_app_send_lock */
static void send_force_key_frame_command(const char *reason);
static bool app_ensure_connected(uint64_t deadline);

/* Event-channel writes can block, so the request is sent off the caller's
 * thread (which may hold g_app_send_lock or be the screen reader). */
static void app_request_keyframe(const char *reason) {
    uint64_t now = monotonic_nanos_now();
    uint64_t last = g_app_last_keyframe_request_nanos;
    if (last != 0 &&
        now - last < (uint64_t)APP_KEYFRAME_REQUEST_INTERVAL_MS * NSEC_PER_MSEC)
        return;
    if (!__sync_bool_compare_and_swap(&g_app_last_keyframe_request_nanos,
                                      last, now))
        return;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        send_force_key_frame_command(reason);
    });
}

static void app_note_send_lock_timeout(uint8_t type) {
    if (type == MSG_VIDEO_CONFIG || type == MSG_VIDEO_TIMING)
        g_app_bootstrap_pending = true;
    if (type == MSG_VIDEO_CONFIG || type == MSG_VIDEO_FRAME) {
        g_app_needs_keyframe = true;
        app_request_keyframe("app IPC lock timeout lost video");
    }
    printf("[SCREEN] App IPC lock wait >%dms; message type=%u not sent\n",
           APP_IPC_LOCK_TIMEOUT_MS, type);
    fflush(stdout);
}

static void app_schedule_reconnect(void);

/* Caller holds g_app_send_lock. Must be called right after the failed write
 * so errno still describes it. */
static void app_drop_connection(void) {
    bool stalled = errno == ETIMEDOUT;
    if (g_app_sock >= 0) {
        /* The touch reader owns a dup() of this socket; shutdown wakes it
         * with EOF so it closes its own copy and exits. */
        shutdown(g_app_sock, SHUT_RDWR);
        close(g_app_sock);
    }
    g_app_sock = -1;
    if (stalled) {
        g_app_reconnect_after_nanos = monotonic_nanos_now() +
            (uint64_t)APP_IPC_STALL_BACKOFF_MS * NSEC_PER_MSEC;
        printf("[SCREEN] App IPC write stalled >%dms; dropped connection\n",
               APP_IPC_WRITE_TIMEOUT_MS);
        fflush(stdout);
    }
    /* Senders only reconnect when they have something to send. With the app
     * backgrounded, video is paused and nothing else may be sent for a long
     * time, so the app would return to a dead channel (no frames, touches
     * going nowhere). Reconnect on our own once the backoff has passed. */
    app_schedule_reconnect();
}

static void app_reconnect_after(uint64_t delayMs);

static void app_reconnect_attempt(void) {
    if (!app_send_lock_acquire()) {
        /* Another sender holds the channel; look again later. */
        app_reconnect_after(APP_IPC_STALL_BACKOFF_MS);
        return;
    }
    g_app_reconnect_scheduled = false;
    if (g_app_sock < 0 && !app_ensure_connected(app_ipc_deadline()) &&
        g_app_sock < 0)
        app_schedule_reconnect();
    if (g_app_send_lock) dispatch_semaphore_signal(g_app_send_lock);
}

static void app_reconnect_after(uint64_t delayMs) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)delayMs * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        app_reconnect_attempt();
    });
}

/* Caller holds g_app_send_lock. At most one attempt is pending; it keeps
 * retrying (one connect per backoff period) until a connection exists. */
static void app_schedule_reconnect(void) {
    if (g_app_reconnect_scheduled) return;
    g_app_reconnect_scheduled = true;
    app_reconnect_after(APP_IPC_STALL_BACKOFF_MS + APP_RECONNECT_SLACK_MS);
}

/* Caller holds g_app_send_lock and g_app_sock is connected. Writes the
 * timing contract and the latest SPS/PPS under the caller's catch-up
 * deadline, which the other catch-up writes share, so catch-up plus the
 * caller's own message stay within APP_IPC_LOCK_TIMEOUT_MS and queued
 * senders do not time out behind it. */
static bool app_write_bootstrap(bool *configSent, uint64_t deadline) {
    *configSent = false;
    g_app_bootstrap_pending = false;
    uint8_t timingPayload[14];
    uint32_t timingLen = build_video_timing_payload(timingPayload);
    if (!app_write_msg_until(g_app_sock, MSG_VIDEO_TIMING,
                             timingPayload, timingLen, deadline))
        goto fail;
    if (g_video_config_lock)
        dispatch_semaphore_wait(g_video_config_lock,
                                DISPATCH_TIME_FOREVER);
    if (g_latest_video_config && g_latest_video_config_length > 0) {
        bool sent = app_write_msg_until(
            g_app_sock, MSG_VIDEO_CONFIG, g_latest_video_config,
            g_latest_video_config_length, deadline);
        int configErrno = errno;
        if (g_video_config_lock)
            dispatch_semaphore_signal(g_video_config_lock);
        if (!sent) {
            errno = configErrno;
            goto fail;
        }
        *configSent = true;
    } else if (g_video_config_lock) {
        dispatch_semaphore_signal(g_video_config_lock);
    }
    return true;

fail:
    {
        int writeErrno = errno;
        g_app_bootstrap_pending = true;
        errno = writeErrno;
    }
    return false;
}

/* Caller holds g_app_send_lock and g_app_sock is connected. Re-sends what an
 * earlier lock timeout lost before the caller's own message, all under the
 * catch-up deadline. On failure errno describes the write, as
 * app_drop_connection expects. */
static bool app_flush_pending_bootstrap(uint64_t deadline) {
    if (g_app_bootstrap_pending) {
        bool configSent = false;
        if (!app_write_bootstrap(&configSent, deadline)) return false;
        printf("[SCREEN] Re-sent video timing%s lost to an IPC lock timeout\n",
               configSent ? " + config" : "");
        fflush(stdout);
    }
    if (g_app_audio_config_pending &&
        !app_write_audio_configs(false, deadline))
        return false;
    /* After the configs: a pending PAUSE/RESUME applies to the player a
     * re-sent AUDIO_CONFIG may just have created. */
    if ((g_app_audio_control_pending || g_app_bt_handoff_pending) &&
        !app_write_pending_controls(deadline))
        return false;
    return true;
}

/* Caller holds g_app_send_lock. deadline is the caller's catch-up deadline,
 * shared by every bootstrap write to a new connection. */
static bool app_ensure_connected(uint64_t deadline) {
    if (g_app_sock >= 0) return true;
    if (monotonic_nanos_now() < g_app_reconnect_after_nanos) return false;
    g_app_sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (g_app_sock < 0) return false;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, IPADPLAY_SOCK, sizeof(addr.sun_path) - 1);
    if (connect(g_app_sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(g_app_sock);
        g_app_sock = -1;
        return false;
    }
    int yes = 1;
    setsockopt(g_app_sock, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    /* The AF_UNIX default (~8 KB) is smaller than one IDR frame, so a brief
     * stall in the app's reader would hit the write timeout immediately. */
    int ipcBuffer = 512 * 1024;
    setsockopt(g_app_sock, SOL_SOCKET, SO_SNDBUF, &ipcBuffer, sizeof(ipcBuffer));
    printf("[SCREEN] Connected to iPadPlay app via %s\n", IPADPLAY_SOCK);
    fflush(stdout);

    /* Start touch reader on this socket (reads touch events from app).
     * Without one, touches and visibility/resync messages would go unread,
     * so a connection the reader cannot own is dropped and retried. */
    if (!start_touch_reader(g_app_sock)) goto fail;

    /* A relaunched UI process has no H.264 format description. Bootstrap each
     * new IPC connection with the negotiated timing and latest SPS/PPS before
     * the next video frame. */
    bool configSent = false;
    if (!app_write_bootstrap(&configSent, deadline)) goto fail;
    /* A relaunched UI process has no audio players either, and AUDIO_CONFIG
     * is otherwise sent only once per stream: give the new connection the
     * config of every active stream. */
    if (!app_write_audio_configs(true, deadline)) goto fail;
    /* Controls and the BT hand-off lost to the old connection (or to a
     * lock timeout) go out now, also when only the background reconnect
     * opened this connection and no other sender follows. */
    if ((g_app_audio_control_pending || g_app_bt_handoff_pending) &&
        !app_write_pending_controls(deadline))
        goto fail;
    if (configSent) {
        printf("[SCREEN] Bootstrapped new app connection with video config\n");
        /* The new decoder cannot consume an arbitrary delta frame. Cycling
         * MainScreen asks the phone for a fresh config + IDR instead of
         * copying and replaying an ever-growing compressed GOP.
         *
         * The caller holds g_app_send_lock; event-channel writes can block
         * on the radio or the HID queue, so they are sent off this thread.
         * requestUI would pull CarPlay back to the car screen, so it is only
         * sent while Showcase is in the foreground; a backgrounded app's
         * MSG_APP_VISIBILITY=1 requests the UI when it returns. */
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            send_take_main_screen_command("new app decoder");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         100 * NSEC_PER_MSEC),
                           dispatch_get_global_queue(0, 0), ^{
                if (g_app_video_enabled)
                    send_request_ui_command("new app decoder");
            });
        });
    }
    return true;

fail:
    app_drop_connection();
    return false;
}

/* Runs under g_app_send_lock right before the message is written, so a
 * decision it makes is ordered against every other IPC message. Returning
 * false skips the write. It may take g_audio_control_lock (lock order:
 * g_app_send_lock, then g_audio_control_lock). */
typedef bool (*app_send_guard_fn)(void *context);

static bool app_send_msg_guarded(uint8_t type, const uint8_t *data,
                                 uint32_t len, app_send_guard_fn guard,
                                 void *guardContext) {
    if (!app_send_lock_acquire()) {
        app_note_send_lock_timeout(type);
        return false;
    }
    bool success = false;
    if (guard && !guard(guardContext)) goto done;
    uint64_t catchUpDeadline = app_ipc_deadline();
    if (!app_ensure_connected(catchUpDeadline)) goto done;
    if (!app_flush_pending_bootstrap(catchUpDeadline)) goto fail;
    if (!app_write_msg_to_socket(g_app_sock, type, data, len)) goto fail;
    success = true;
    goto done;
fail:
    app_drop_connection();
done:
    if (g_app_send_lock) dispatch_semaphore_signal(g_app_send_lock);
    return success;
}

static bool app_send_msg(uint8_t type, const uint8_t *data, uint32_t len) {
    return app_send_msg_guarded(type, data, len, NULL, NULL);
}

static bool app_send_video_timing(void) {
    uint8_t payload[14];
    uint32_t len = build_video_timing_payload(payload);
    return app_send_msg(MSG_VIDEO_TIMING, payload, len);
}

/* ═══════════════════════════════════════════════════════════════
 * Wireless CarPlay audio
 *
 * Low-latency audio arrives as encrypted RTP/UDP. MainBuffered (type 103)
 * instead uses a TCP byte stream containing 2-byte, big-endian, inclusive
 * record lengths followed by encrypted RTP packets. The network service
 * authenticates and decrypts packets, then forwards codec frames to Showcase;
 * the app owns the system audio session and hardware codec.
 * ═══════════════════════════════════════════════════════════════ */

/* Recent audio nonces remembered per stream, and how many consecutive
 * counter steps make the "too old" check apply. */
#define AUDIO_REPLAY_WINDOW 256
#define AUDIO_REPLAY_COUNTER_RUNS 16

typedef struct {
    uint32_t type;
    int dataFd;
    int controlFd;
    uint16_t dataPort;
    uint16_t controlPort;
    uint64_t connectionID;
    uint64_t formatMask;
    uint32_t framesPerPacket;
    uint32_t latencyMs;
    uint8_t key[32];
    bool keyValid;
    volatile int32_t running;
    volatile uint64_t generation;
    bool haveSequence;
    uint16_t lastSequence;
    uint64_t packetCount;
    uint64_t decryptErrors;
    uint64_t sequenceGaps;
    uint64_t lastArrivalNanos;
    uint64_t maxArrivalGapNanos;
    uint64_t longArrivalGaps;
    uint32_t lastRtpTimestamp;
    uint64_t lastHostNTP;
    int64_t renderedSampleTime;
    uint64_t renderedHostNTP;
    uint64_t renderedHostRawNanos;
    uint64_t renderUpdateCount;
    bool flushPending;
    uint16_t flushUntilSequence;
    uint32_t flushUntilTimestamp;
    uint64_t flushDropCount;
    /* Deferred FLUSHBUFFERED (flushFromSeq present, AirPlay 2 Up Next /
     * gapless transitions): packets before "from" keep playing, only the
     * [from, until) range is dropped once it arrives and the app's queue is
     * not reset. Guarded by g_audio_control_lock. deferredFlushChecked is
     * set by the receiver thread once it has compared the request with the
     * last packet it already forwarded to the app. */
    bool deferredFlushPending;
    bool deferredFlushChecked;
    uint16_t deferredFlushFromSequence;
    uint16_t deferredFlushUntilSequence;
    uint32_t deferredFlushUntilTimestamp;
    uint64_t deferredFlushDropCount;
    /* Bumped (under g_audio_control_lock, while holding g_app_send_lock)
     * by every FLUSHBUFFERED in the same critical section that sends the
     * FLUSH to the app. A packet is written to the app only if the epoch
     * it was judged against is still current under g_app_send_lock, so it
     * can never land on the wrong side of the app's AudioQueueReset. */
    uint64_t flushEpoch;
    bool usesTCP;
    /* Accepted MainBuffered sender connection, owned by the receiver thread.
     * Guarded by g_audio_control_lock; stop_audio_receiver only shuts it
     * down, the receiver thread clears and closes it. */
    int tcpClientFd;
    /* Set (under g_audio_control_lock) once a receiver thread holds dataFd.
     * stop_audio_receiver then only shuts the socket down and the thread
     * closes it, so the fd number cannot be reused by the next SETUP's
     * socket while the old thread may still poll/accept/recv on it. */
    bool dataFdOwnedByThread;
    /* Anti-replay state of the receiver thread, reset with haveSequence.
     * The AEAD nonce travels in the packet and the sequence number is not
     * authenticated, so a captured packet would otherwise decrypt again.
     * Each ring entry is the nonce plus the authenticated RTP timestamp +
     * SSRC (the AAD): a replay must repeat both, while a sender that
     * restarts its nonce counter after a flush sends new timestamps. */
    uint64_t replayNonces[AUDIO_REPLAY_WINDOW];
    uint64_t replayAad[AUDIO_REPLAY_WINDOW];
    unsigned replayCount;
    uint64_t replayHighestNonce;
    uint32_t replayCounterRuns;
    /* Set at a flush boundary: the next nonce may restart the counter. */
    bool replayNewEpoch;
    uint64_t replayDropCount;
    uint64_t rejectedSenderCount;
    /* AUDIO_CONFIG for this stream has not reached the app yet; see
     * g_app_audio_config_pending. */
    volatile bool appConfigPending;
    /* The latest AUDIO_CONTROL action (PAUSE/RESUME/STOP) for this stream
     * has not reached the app yet; a newer action replaces an undelivered
     * one. Guarded by g_audio_control_lock; see
     * g_app_audio_control_pending. */
    bool appControlPending;
    uint8_t appControlAction;
} carplay_audio_stream_t;

/* Clears the anti-replay state when a stream (re)starts with a new key. */
static void audio_replay_reset(carplay_audio_stream_t *stream) {
    stream->replayCount = 0;
    stream->replayHighestNonce = 0;
    stream->replayCounterRuns = 0;
    stream->replayNewEpoch = false;
}

/* A flush starts a new RTP epoch under the SAME key. The sender may restart
 * its nonce counter, so the counter-mode lower bound must be re-learned, but
 * the ring of already accepted (nonce, AAD) pairs is kept: a pre-flush packet
 * captured or delayed on the network decrypts fine and would otherwise be
 * replayed into the freshly flushed AudioQueue. Matching on the AAD as well
 * keeps the restarted counter's genuine packets (new timestamps) from
 * colliding with the old epoch's ring entries. */
static void audio_replay_begin_epoch(carplay_audio_stream_t *stream) {
    stream->replayNewEpoch = true;
}

/* Returns false for a (nonce, AAD) pair this stream already accepted or,
 * once the sender has shown that its nonce is a little-endian packet counter,
 * a nonce older than the replay window. Called only for packets that passed
 * AEAD; aadBytes is the authenticated RTP timestamp + SSRC. */
static bool audio_replay_accept(carplay_audio_stream_t *stream,
                                const uint8_t nonceBytes[8],
                                const uint8_t aadBytes[8],
                                uint64_t *dropCount) {
    uint64_t nonce = 0;
    for (int i = 7; i >= 0; i--) nonce = (nonce << 8) | nonceBytes[i];
    uint64_t aad = 0;
    memcpy(&aad, aadBytes, sizeof(aad));
    unsigned filled = stream->replayCount < AUDIO_REPLAY_WINDOW
        ? stream->replayCount : AUDIO_REPLAY_WINDOW;
    for (unsigned i = 0; i < filled; i++) {
        if (stream->replayNonces[i] == nonce &&
            stream->replayAad[i] == aad) {
            *dropCount = ++stream->replayDropCount;
            return false;
        }
    }
    if (stream->replayNewEpoch) {
        stream->replayNewEpoch = false;
        if (filled > 0 && nonce < stream->replayHighestNonce) {
            /* The counter restarted: track it from here. A replayed packet
             * of the old epoch still in the ring was rejected above. */
            stream->replayHighestNonce = nonce;
            stream->replayCounterRuns = 0;
            goto record;
        }
    }
    if (filled > 0) {
        bool counterMode =
            stream->replayCounterRuns >= AUDIO_REPLAY_COUNTER_RUNS;
        if (counterMode && nonce < stream->replayHighestNonce &&
            stream->replayHighestNonce - nonce >= AUDIO_REPLAY_WINDOW) {
            *dropCount = ++stream->replayDropCount;
            return false;
        }
        if (nonce == stream->replayHighestNonce + 1 &&
            stream->replayCounterRuns < AUDIO_REPLAY_COUNTER_RUNS)
            stream->replayCounterRuns++;
        if (nonce > stream->replayHighestNonce)
            stream->replayHighestNonce = nonce;
    } else {
        stream->replayHighestNonce = nonce;
    }
record:
    stream->replayNonces[stream->replayCount % AUDIO_REPLAY_WINDOW] = nonce;
    stream->replayAad[stream->replayCount % AUDIO_REPLAY_WINDOW] = aad;
    stream->replayCount++;
    return true;
}

typedef struct {
    carplay_audio_stream_t *stream;
    uint64_t generation;
    int dataFd;
    uint16_t dataPort;
    bool usesTCP;
} carplay_audio_receiver_context_t;

static pthread_mutex_t g_audio_feedback_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_audio_control_lock = PTHREAD_MUTEX_INITIALIZER;

static carplay_audio_stream_t g_audio_streams[4] = {
    { .type = 100, .dataFd = -1, .controlFd = -1, .tcpClientFd = -1 },
    { .type = 101, .dataFd = -1, .controlFd = -1, .tcpClientFd = -1 },
    { .type = 102, .dataFd = -1, .controlFd = -1, .tcpClientFd = -1 },
    { .type = 103, .dataFd = -1, .controlFd = -1,
      .tcpClientFd = -1 }   /* MainBufferedAudio */
};

static carplay_audio_stream_t *audio_stream_for_type(uint32_t type) {
    for (size_t i = 0; i < sizeof(g_audio_streams) /
                            sizeof(g_audio_streams[0]); i++) {
        if (g_audio_streams[i].type == type) return &g_audio_streams[i];
    }
    return NULL;
}

static uint32_t audio_default_frames_per_packet(uint64_t formatMask) {
    if (formatMask & 0x00008854ULL)
        return 1; /* PCM */
    if (formatMask == 0x00400000ULL || formatMask == 0x00800000ULL)
        return 1024; /* AAC-LC */
    if (formatMask == 0x10000000ULL) return 320; /* Opus 16 kHz, 20 ms */
    if (formatMask == 0x20000000ULL) return 480; /* Opus 24 kHz, 20 ms */
    if (formatMask == 0x40000000ULL) return 960; /* Opus 48 kHz, 20 ms */
    return 512;      /* AAC-ELD */
}

static double audio_sample_rate(uint64_t formatMask) {
    switch (formatMask) {
        case 0x00000004ULL: return 8000.0;
        case 0x00000010ULL: return 16000.0;
        case 0x00000040ULL: return 24000.0;
        case 0x00000800ULL:
        case 0x00400000ULL:
        case 0x01000000ULL: return 44100.0;
        case 0x00008000ULL:
        case 0x00800000ULL:
        case 0x02000000ULL: return 48000.0;
        case 0x04000000ULL: return 16000.0;
        case 0x08000000ULL: return 24000.0;
        case 0x10000000ULL: return 16000.0;
        case 0x20000000ULL: return 24000.0;
        case 0x40000000ULL: return 48000.0;
        default: return 0.0;
    }
}

/* Caller holds g_app_send_lock and g_app_sock is connected. Writes
 * AUDIO_CONFIG for every running stream (allActive: a new connection) or only
 * for those still marked appConfigPending, all under one write deadline. A
 * stream that is not running (stopped, or SETUP still filling it in) is
 * skipped: its receiver sends the config when it starts. On failure the
 * unsent streams stay pending and errno describes the write. */
static bool app_write_audio_configs(bool allActive, uint64_t deadline) {
    g_app_audio_config_pending = false;
    size_t count = sizeof(g_audio_streams) / sizeof(g_audio_streams[0]);
    for (size_t i = 0; i < count; i++) {
        carplay_audio_stream_t *stream = &g_audio_streams[i];
        if (!allActive && !stream->appConfigPending) continue;
        uint8_t payload[20] = {0};
        pthread_mutex_lock(&g_audio_control_lock);
        bool active = stream->running && stream->formatMask != 0;
        if (active) {
            memcpy(payload, &stream->type, 4);
            memcpy(payload + 4, &stream->formatMask, 8);
            memcpy(payload + 12, &stream->framesPerPacket, 4);
            memcpy(payload + 16, &stream->latencyMs, 4);
        }
        stream->appConfigPending = false;
        pthread_mutex_unlock(&g_audio_control_lock);
        if (!active) continue;
        if (!app_write_msg_until(g_app_sock, MSG_AUDIO_CONFIG, payload,
                                 sizeof(payload), deadline)) {
            int writeErrno = errno;
            /* Streams after this one were not reached: a new connection
             * owes them their config too; otherwise their own pending flag
             * is still set. */
            stream->appConfigPending = true;
            for (size_t j = i + 1; allActive && j < count; j++)
                g_audio_streams[j].appConfigPending = true;
            g_app_audio_config_pending = true;
            errno = writeErrno;
            return false;
        }
        printf("[AUDIO] stream=%u config sent to app%s\n", stream->type,
               allActive ? " (new app connection)" : "");
    }
    return true;
}

/* Caller holds g_app_send_lock and g_app_sock is connected. Writes every
 * pending AUDIO_CONTROL (latest action per stream) and a pending BT
 * hand-off under one deadline. On failure the unsent items stay pending and
 * errno describes the write. */
static bool app_write_pending_controls(uint64_t deadline) {
    g_app_audio_control_pending = false;
    size_t count = sizeof(g_audio_streams) / sizeof(g_audio_streams[0]);
    for (size_t i = 0; i < count; i++) {
        carplay_audio_stream_t *stream = &g_audio_streams[i];
        pthread_mutex_lock(&g_audio_control_lock);
        bool pending = stream->appControlPending;
        uint8_t action = stream->appControlAction;
        stream->appControlPending = false;
        pthread_mutex_unlock(&g_audio_control_lock);
        if (!pending) continue;
        uint8_t payload[5] = {0};
        memcpy(payload, &stream->type, 4);
        payload[4] = action;
        if (!app_write_msg_until(g_app_sock, MSG_AUDIO_CONTROL, payload,
                                 sizeof(payload), deadline)) {
            int writeErrno = errno;
            /* A newer action queued meanwhile supersedes this one. */
            pthread_mutex_lock(&g_audio_control_lock);
            if (!stream->appControlPending) {
                stream->appControlPending = true;
                stream->appControlAction = action;
            }
            pthread_mutex_unlock(&g_audio_control_lock);
            /* Streams after this one keep their own pending flag. */
            g_app_audio_control_pending = true;
            errno = writeErrno;
            return false;
        }
        printf("[AUDIO] control stream=%u action=%u delivered to app\n",
               stream->type, action);
    }
    if (g_app_bt_handoff_pending) {
        g_app_bt_handoff_pending = false;
        const uint8_t request = 1;
        if (!app_write_msg_until(g_app_sock, MSG_BT_HANDOFF, &request,
                                 sizeof(request), deadline)) {
            int writeErrno = errno;
            g_app_bt_handoff_pending = true;
            errno = writeErrno;
            return false;
        }
        printf("[HANDOFF] app teardown request delivered\n");
    }
    return true;
}

/* Delivers whatever is marked pending (bootstrap, configs, controls, BT
 * hand-off) right now if the channel allows it. A failure (lock timeout,
 * reconnect backoff, failed write) leaves it pending for the next IPC
 * message or the next app connection. */
static void app_deliver_pending(uint8_t type) {
    if (!app_send_lock_acquire()) {
        app_note_send_lock_timeout(type);
        return;
    }
    uint64_t catchUpDeadline = app_ipc_deadline();
    if (app_ensure_connected(catchUpDeadline) &&
        !app_flush_pending_bootstrap(catchUpDeadline))
        app_drop_connection();
    if (g_app_send_lock) dispatch_semaphore_signal(g_app_send_lock);
}

/* AUDIO_CONFIG is the only thing that creates the app's player for a stream,
 * so it is never just dropped: the stream is marked pending first, and a send
 * that fails here (lock timeout, reconnect backoff, failed write) is retried
 * before the next IPC message or on the next app connection. */
static void app_send_audio_config(carplay_audio_stream_t *stream) {
    /* A (re)started stream supersedes an undelivered STOP of its previous
     * run, which would otherwise follow the new config and stop it. */
    pthread_mutex_lock(&g_audio_control_lock);
    if (stream->appControlPending &&
        stream->appControlAction == AUDIO_CONTROL_STOP)
        stream->appControlPending = false;
    pthread_mutex_unlock(&g_audio_control_lock);
    stream->appConfigPending = true;
    g_app_audio_config_pending = true;
    app_deliver_pending(MSG_AUDIO_CONFIG);
    if (stream->appConfigPending)
        printf("[AUDIO] stream=%u config not delivered to app; "
               "will retry\n", stream->type);
}

typedef struct {
    carplay_audio_stream_t *stream;
    uint64_t expectedFlushEpoch;
} audio_packet_send_guard_t;

static bool audio_packet_epoch_current(void *context) {
    audio_packet_send_guard_t *guard = context;
    pthread_mutex_lock(&g_audio_control_lock);
    bool current = guard->stream->flushEpoch == guard->expectedFlushEpoch;
    pthread_mutex_unlock(&g_audio_control_lock);
    return current;
}

/* Returns false when the packet was not written, including when a
 * FLUSHBUFFERED arrived after the drop decision made at expectedFlushEpoch:
 * such a packet was judged against a stale boundary and is dropped (had it
 * been written just before the FLUSH, the app's reset would discard it). */
static bool app_send_audio_packet(carplay_audio_stream_t *stream,
                                  uint64_t expectedFlushEpoch,
                                  uint16_t sequence, uint32_t timestamp,
                                  const uint8_t *bytes, uint32_t length) {
    uint32_t msgLength = 12 + length;
    uint8_t *message = malloc(msgLength);
    if (!message) return false;
    memset(message, 0, 12);
    memcpy(message, &stream->type, 4);
    memcpy(message + 4, &sequence, 2);
    memcpy(message + 8, &timestamp, 4);
    memcpy(message + 12, bytes, length);
    audio_packet_send_guard_t guard = {
        .stream = stream, .expectedFlushEpoch = expectedFlushEpoch };
    bool sent = app_send_msg_guarded(MSG_AUDIO_PACKET, message, msgLength,
                                     audio_packet_epoch_current, &guard);
    free(message);
    return sent;
}

/* PAUSE/RESUME/STOP are the app player's only rate signal, so like
 * AUDIO_CONFIG they are never just dropped: the stream records its latest
 * action as pending first, and a send that fails here is retried before the
 * next IPC message or on the next app connection. */
static void app_send_audio_control(uint32_t streamType, uint8_t action) {
    carplay_audio_stream_t *stream = audio_stream_for_type(streamType);
    if (!stream) {
        uint8_t payload[5] = {0};
        memcpy(payload, &streamType, 4);
        payload[4] = action;
        bool sent = app_send_msg(MSG_AUDIO_CONTROL, payload, sizeof(payload));
        printf("[AUDIO] control stream=%u action=%u app=%s\n",
               streamType, action, sent ? "sent" : "failed");
        return;
    }
    pthread_mutex_lock(&g_audio_control_lock);
    stream->appControlAction = action;
    stream->appControlPending = true;
    pthread_mutex_unlock(&g_audio_control_lock);
    g_app_audio_control_pending = true;
    app_deliver_pending(MSG_AUDIO_CONTROL);
    pthread_mutex_lock(&g_audio_control_lock);
    bool pending = stream->appControlPending;
    pthread_mutex_unlock(&g_audio_control_lock);
    if (pending)
        printf("[AUDIO] control stream=%u action=%u not delivered to app; "
               "will retry\n", streamType, action);
}

static void audio_flush_app_until(carplay_audio_stream_t *audio,
                                  uint16_t untilSequence,
                                  uint32_t untilTimestamp);

/* Caller holds g_audio_control_lock. True for a packet inside the pending
 * deferred flush range [from, until). */
static bool audio_deferred_flush_covers(const carplay_audio_stream_t *stream,
                                        uint16_t sequence,
                                        uint32_t timestamp) {
    return (int16_t)(sequence - stream->deferredFlushFromSequence) >= 0 &&
           (int16_t)(sequence - stream->deferredFlushUntilSequence) < 0 &&
           timestamp != stream->deferredFlushUntilTimestamp;
}

/* Caller holds g_audio_control_lock. True for the new epoch's first packet
 * (or one modularly after it). */
static bool audio_deferred_flush_reached(const carplay_audio_stream_t *stream,
                                         uint16_t sequence,
                                         uint32_t timestamp) {
    return (int16_t)(sequence - stream->deferredFlushUntilSequence) >= 0 ||
           timestamp == stream->deferredFlushUntilTimestamp;
}

static void audio_process_rtp_packet(carplay_audio_stream_t *stream,
                                     uint8_t *packet, size_t packetLength) {
    if (!stream || !packet || packetLength < 12 + 24 ||
        !stream->keyValid) return;

    uint16_t sequenceNetwork = 0;
    uint32_t timestampNetwork = 0;
    memcpy(&sequenceNetwork, packet + 2, 2);
    memcpy(&timestampNetwork, packet + 4, 4);
    uint16_t sequence = ntohs(sequenceNetwork);
    uint32_t timestamp = ntohl(timestampNetwork);
    uint64_t arrivalNanos = monotonic_nanos_now();
    uint64_t arrivalGapNanos = stream->lastArrivalNanos
        ? arrivalNanos - stream->lastArrivalNanos : 0;
    stream->lastArrivalNanos = arrivalNanos;
    if (arrivalGapNanos > stream->maxArrivalGapNanos)
        stream->maxArrivalGapNanos = arrivalGapNanos;
    if (arrivalGapNanos >= 100 * NSEC_PER_MSEC) {
        stream->longArrivalGaps++;
        printf("[AUDIO] stream=%u arrival gap #%llu %.1fms seq=%u\n",
               stream->type,
               (unsigned long long)stream->longArrivalGaps,
               (double)arrivalGapNanos / 1000000.0, sequence);
    }

    /*
     * FLUSHBUFFERED names the first packet of the sender's new RTP epoch with
     * an extended sequence number and timestamp. The RTP header carries only
     * the low 16 sequence bits. Drop the old epoch until that boundary (or the
     * first packet modularly after it) so it cannot refill the AudioQueue
     * after the app has discarded its stale buffered media. A deferred
     * FLUSHBUFFERED (flushFromSeq) instead drops only [from, until) and
     * leaves the app's queue, and the packets before "from", playing.
     */
    /* The drop decision may use the unauthenticated header, but only a
     * packet that passes AEAD below may close the flush window: a forged or
     * corrupt packet must not let the stale epoch back in. */
    /* A deferred flush whose "from" packet was already forwarded cannot be
     * trimmed out of the app's AudioQueue: only a reset removes it, so fall
     * back to the immediate flush for that request. lastSequence is owned by
     * this receiver thread. */
    bool convertDeferred = false;
    uint16_t convertUntilSequence = 0;
    uint32_t convertUntilTimestamp = 0;
    pthread_mutex_lock(&g_audio_control_lock);
    if (stream->deferredFlushPending && !stream->deferredFlushChecked) {
        stream->deferredFlushChecked = true;
        if (stream->haveSequence &&
            (int16_t)(stream->lastSequence -
                      stream->deferredFlushFromSequence) >= 0) {
            convertDeferred = true;
            convertUntilSequence = stream->deferredFlushUntilSequence;
            convertUntilTimestamp = stream->deferredFlushUntilTimestamp;
            stream->deferredFlushPending = false;
        }
    }
    pthread_mutex_unlock(&g_audio_control_lock);
    if (convertDeferred) {
        printf("[AUDIO] stream=%u deferred flush start already forwarded "
               "(last=%u); flushing app until rtp=%u\n",
               stream->type, stream->lastSequence, convertUntilSequence);
        audio_flush_app_until(stream, convertUntilSequence,
                              convertUntilTimestamp);
    }

    bool dropForFlush = false;
    bool flushWasPending = false;
    bool deferredWasPending = false;
    uint64_t droppedForFlush = 0;
    pthread_mutex_lock(&g_audio_control_lock);
    uint64_t flushEpoch = stream->flushEpoch;
    if (stream->flushPending) {
        flushWasPending = true;
        int16_t relative =
            (int16_t)(sequence - stream->flushUntilSequence);
        if (relative < 0 && timestamp != stream->flushUntilTimestamp) {
            stream->flushDropCount++;
            droppedForFlush = stream->flushDropCount;
            dropForFlush = true;
        }
    }
    if (!dropForFlush && stream->deferredFlushPending) {
        deferredWasPending = true;
        if (audio_deferred_flush_covers(stream, sequence, timestamp)) {
            stream->deferredFlushDropCount++;
            droppedForFlush = stream->deferredFlushDropCount;
            dropForFlush = true;
        }
    }
    pthread_mutex_unlock(&g_audio_control_lock);
    if (dropForFlush) {
        if (droppedForFlush <= 3 || (droppedForFlush % 100) == 0) {
            printf("[AUDIO] stream=%u flush drop #%llu seq=%u ts=%u\n",
                   stream->type, (unsigned long long)droppedForFlush,
                   sequence, timestamp);
        }
        return;
    }

    uint8_t *encrypted = packet + 12;
    size_t encryptedLength = packetLength - 12;
    if (encryptedLength < 24) return;

    size_t ciphertextLength = encryptedLength - 24;
    uint8_t nonce[12] = {0};
    memcpy(nonce + 4, encrypted + encryptedLength - 8, 8);
    uint8_t *tag = encrypted + encryptedLength - 24;

    /* Modern CarPlay audio authenticates RTP timestamp + SSRC, both in
     * their network-order wire representation. */
    crypto_aead_ctx crypto;
    crypto_aead_init_ietf(&crypto, stream->key, nonce);
    int result = crypto_aead_read(&crypto, encrypted, tag,
                                  packet + 4, 8,
                                  encrypted, ciphertextLength);
    crypto_wipe(&crypto, sizeof(crypto));
    if (result != 0) {
        stream->decryptErrors++;
        if (stream->decryptErrors <= 3 ||
            (stream->decryptErrors % 100) == 0) {
            printf("[AUDIO] stream=%u decrypt failure #%llu seq=%u\n",
                   stream->type,
                   (unsigned long long)stream->decryptErrors, sequence);
        }
        return;
    }

    if (flushWasPending) {
        bool completedFlush = false;
        pthread_mutex_lock(&g_audio_control_lock);
        /* Re-evaluate: FLUSHBUFFERED may have moved the boundary meanwhile. */
        flushEpoch = stream->flushEpoch;
        if (stream->flushPending) {
            int16_t relative =
                (int16_t)(sequence - stream->flushUntilSequence);
            if (relative < 0 && timestamp != stream->flushUntilTimestamp) {
                stream->flushDropCount++;
                pthread_mutex_unlock(&g_audio_control_lock);
                return;
            }
            stream->flushPending = false;
            completedFlush = true;
            droppedForFlush = stream->flushDropCount;
        }
        pthread_mutex_unlock(&g_audio_control_lock);
        if (completedFlush) {
            printf("[AUDIO] stream=%u flush boundary reached seq=%u ts=%u "
                   "dropped=%llu\n",
                   stream->type, sequence, timestamp,
                   (unsigned long long)droppedForFlush);
            /* The new epoch may restart the sender's nonce counter; the
             * key is unchanged, so keep rejecting replays of the old
             * epoch's (nonce, AAD) pairs. */
            audio_replay_begin_epoch(stream);
        }
    }

    if (deferredWasPending) {
        bool completedDeferred = false;
        uint64_t droppedDeferred = 0;
        pthread_mutex_lock(&g_audio_control_lock);
        if (stream->deferredFlushPending) {
            if (audio_deferred_flush_covers(stream, sequence, timestamp)) {
                stream->deferredFlushDropCount++;
                pthread_mutex_unlock(&g_audio_control_lock);
                return;
            }
            if (audio_deferred_flush_reached(stream, sequence, timestamp)) {
                stream->deferredFlushPending = false;
                completedDeferred = true;
                droppedDeferred = stream->deferredFlushDropCount;
            }
        }
        pthread_mutex_unlock(&g_audio_control_lock);
        if (completedDeferred) {
            printf("[AUDIO] stream=%u deferred flush boundary reached "
                   "seq=%u ts=%u dropped=%llu\n",
                   stream->type, sequence, timestamp,
                   (unsigned long long)droppedDeferred);
            audio_replay_begin_epoch(stream);
        }
    }

    uint64_t replayDrops = 0;
    if (!audio_replay_accept(stream, nonce + 4, packet + 4, &replayDrops)) {
        if (replayDrops <= 3 || (replayDrops % 100) == 0)
            printf("[AUDIO] stream=%u dropped replayed packet #%llu "
                   "seq=%u\n", stream->type,
                   (unsigned long long)replayDrops, sequence);
        return;
    }

    if (stream->haveSequence &&
        sequence != (uint16_t)(stream->lastSequence + 1)) {
        stream->sequenceGaps++;
        printf("[AUDIO] stream=%u RTP gap #%llu expected=%u got=%u\n",
               stream->type,
               (unsigned long long)stream->sequenceGaps,
               (uint16_t)(stream->lastSequence + 1), sequence);
    }
    stream->lastSequence = sequence;
    stream->haveSequence = true;
    stream->packetCount++;
    uint32_t hostSeconds = 0;
    uint32_t hostFraction = 0;
    get_ntp_time(&hostSeconds, &hostFraction);
    stream->lastRtpTimestamp = timestamp;
    stream->lastHostNTP =
        ((uint64_t)hostSeconds << 32) | hostFraction;
    /* The epoch is re-checked under g_app_send_lock: a FLUSHBUFFERED that
     * landed after the decision above drops this packet instead of letting
     * it reach the AudioQueue after the app's flush. */
    if (!app_send_audio_packet(stream, flushEpoch, sequence, timestamp,
                               encrypted, (uint32_t)ciphertextLength)) {
        pthread_mutex_lock(&g_audio_control_lock);
        bool superseded = stream->flushEpoch != flushEpoch;
        pthread_mutex_unlock(&g_audio_control_lock);
        if (superseded)
            printf("[AUDIO] stream=%u dropped packet superseded by flush "
                   "seq=%u ts=%u\n", stream->type, sequence, timestamp);
    }
    if (stream->packetCount <= 3 ||
        (stream->packetCount % 500) == 0) {
        printf("[AUDIO] stream=%u packet #%llu seq=%u ts=%u bytes=%zu\n",
               stream->type, (unsigned long long)stream->packetCount,
               sequence, timestamp, ciphertextLength);
    }
}

/* Polling interval of the MainBuffered TCP receiver: how quickly it notices
 * that its stream was stopped or replaced while no data arrives. */
#define AUDIO_TCP_POLL_MS 1000

static bool audio_receiver_current(carplay_audio_stream_t *stream,
                                   uint64_t generation) {
    return stream->running && stream->generation == generation;
}

/* Like tcp_read_exact, but a receive timeout only ends the read when the
 * stream was stopped or replaced: a paused sender legitimately sends nothing
 * for a long time, and a vanished one is caught by TCP keepalive. */
static bool audio_tcp_read_exact(carplay_audio_stream_t *stream,
                                 uint64_t generation, int fd,
                                 uint8_t *buf, size_t len) {
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, buf + got, len - got, 0);
        if (n > 0) {
            got += (size_t)n;
            continue;
        }
        if (n < 0 && (errno == EINTR || errno == EAGAIN ||
                      errno == EWOULDBLOCK) &&
            audio_receiver_current(stream, generation))
            continue;
        return false;
    }
    return true;
}

/* Waits for the session iPhone to connect to the MainBuffered listener.
 * Other LAN hosts are refused, so one cannot take the single sender slot.
 * Returns -1 when the stream is stopped or the listener fails. */
static int audio_accept_session_sender(carplay_audio_stream_t *stream,
                                       uint64_t generation, int dataFd) {
    while (audio_receiver_current(stream, generation)) {
        struct pollfd listener = { .fd = dataFd, .events = POLLIN };
        int ready = poll(&listener, 1, AUDIO_TCP_POLL_MS);
        if (ready < 0) {
            if (errno == EINTR) continue;
            printf("[AUDIO] stream=%u TCP poll failed: %s\n",
                   stream->type, strerror(errno));
            return -1;
        }
        if (ready == 0) continue;
        if (!audio_receiver_current(stream, generation)) break;
        if (listener.revents & (POLLERR | POLLHUP | POLLNVAL)) return -1;
        struct sockaddr_storage peer;
        socklen_t peerLength = sizeof(peer);
        int client = accept(dataFd, (struct sockaddr *)&peer, &peerLength);
        if (client < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK ||
                errno == ECONNABORTED)
                continue;
            printf("[AUDIO] stream=%u TCP accept failed: %s\n",
                   stream->type, strerror(errno));
            return -1;
        }
        if (!sockaddr_is_session_iphone((struct sockaddr *)&peer,
                                        peerLength)) {
            char host[NI_MAXHOST], serv[NI_MAXSERV];
            sockaddr_to_numeric((struct sockaddr *)&peer, peerLength,
                                host, sizeof(host), serv, sizeof(serv));
            printf("[AUDIO] stream=%u rejecting TCP sender %s:%s "
                   "(not the session iPhone)\n", stream->type, host, serv);
            close(client);
            continue;
        }
        return client;
    }
    return -1;
}

static void audio_receiver_func(void *arg) {
    carplay_audio_receiver_context_t *context = arg;
    carplay_audio_stream_t *stream = context->stream;
    uint64_t generation = context->generation;
    int dataFd = context->dataFd;
    uint8_t packet[65536];
    printf("[AUDIO] stream=%u receiver started %s port=%u fd=%d "
           "generation=%llu format=0x%llx framesPerPacket=%u key=%d\n",
           stream->type, context->usesTCP ? "TCP" : "UDP",
           context->dataPort, dataFd, (unsigned long long)generation,
           (unsigned long long)stream->formatMask,
           stream->framesPerPacket, stream->keyValid ? 1 : 0);
    app_send_audio_config(stream);

    if (context->usesTCP) {
        int client = audio_accept_session_sender(stream, generation, dataFd);
        if (client >= 0) {
            /* Publish the connection so stop_audio_receiver can shut it
             * down; a stop that already happened wins. */
            pthread_mutex_lock(&g_audio_control_lock);
            bool current = audio_receiver_current(stream, generation);
            if (current) stream->tcpClientFd = client;
            pthread_mutex_unlock(&g_audio_control_lock);
            if (!current) {
                close(client);
                client = -1;
            }
        }
        if (client >= 0) {
            int receiveBuffer = 2 * 1024 * 1024;
            setsockopt(client, SOL_SOCKET, SO_RCVBUF,
                       &receiveBuffer, sizeof(receiveBuffer));
            struct timeval timeout = { .tv_sec = AUDIO_TCP_POLL_MS / 1000,
                                       .tv_usec = 0 };
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO,
                       &timeout, sizeof(timeout));
            /* An iPhone that leaves Wi-Fi never closes the connection. */
            int yes = 1, idle = 10, interval = 3, count = 3;
            setsockopt(client, SOL_SOCKET, SO_KEEPALIVE, &yes, sizeof(yes));
            setsockopt(client, IPPROTO_TCP, TCP_KEEPALIVE,
                       &idle, sizeof(idle));
            setsockopt(client, IPPROTO_TCP, TCP_KEEPINTVL,
                       &interval, sizeof(interval));
            setsockopt(client, IPPROTO_TCP, TCP_KEEPCNT,
                       &count, sizeof(count));
            printf("[AUDIO] stream=%u TCP sender connected fd=%d\n",
                   stream->type, client);
            while (audio_receiver_current(stream, generation)) {
                uint8_t lengthBytes[2];
                if (!audio_tcp_read_exact(stream, generation, client,
                                          lengthBytes,
                                          sizeof(lengthBytes))) break;
                uint16_t inclusiveLength =
                    ((uint16_t)lengthBytes[0] << 8) | lengthBytes[1];
                if (inclusiveLength < 2 + 12 + 24) {
                    printf("[AUDIO] stream=%u invalid TCP record length=%u\n",
                           stream->type, inclusiveLength);
                    break;
                }
                size_t packetLength = (size_t)inclusiveLength - 2;
                if (!audio_tcp_read_exact(stream, generation, client,
                                          packet, packetLength)) break;
                if (stream->generation != generation) break;
                audio_process_rtp_packet(stream, packet, packetLength);
            }
            pthread_mutex_lock(&g_audio_control_lock);
            if (stream->tcpClientFd == client) stream->tcpClientFd = -1;
            pthread_mutex_unlock(&g_audio_control_lock);
            close(client);
        }
    } else {
        while (stream->running &&
               stream->generation == generation) {
            struct sockaddr_storage from;
            socklen_t fromLength = sizeof(from);
            ssize_t received = recvfrom(dataFd, packet, sizeof(packet), 0,
                                        (struct sockaddr *)&from,
                                        &fromLength);
            if (received < 0) {
                if (errno == EINTR || errno == EAGAIN ||
                    errno == EWOULDBLOCK) continue;
                printf("[AUDIO] stream=%u recv error: %s\n",
                       stream->type, strerror(errno));
                break;
            }
            if (stream->generation != generation) break;
            /* The socket is bound to the wildcard address and not
             * connected: accept datagrams from the session iPhone only. */
            if (!sockaddr_is_session_iphone((struct sockaddr *)&from,
                                            fromLength)) {
                stream->rejectedSenderCount++;
                if (stream->rejectedSenderCount <= 3 ||
                    (stream->rejectedSenderCount % 100) == 0) {
                    char host[NI_MAXHOST], serv[NI_MAXSERV];
                    sockaddr_to_numeric((struct sockaddr *)&from,
                                        fromLength, host, sizeof(host),
                                        serv, sizeof(serv));
                    printf("[AUDIO] stream=%u ignoring UDP sender %s:%s "
                           "(not the session iPhone) #%llu\n",
                           stream->type, host, serv,
                           (unsigned long long)stream->rejectedSenderCount);
                }
                continue;
            }
            audio_process_rtp_packet(stream, packet, (size_t)received);
        }
    }
    if (stream->generation == generation)
        __sync_bool_compare_and_swap(&stream->running, 1, 0);
    /* This thread owns the data socket (see dataFdOwnedByThread). If the
     * stream still holds it (the receiver ended on its own), hand ownership
     * back so stop_audio_receiver closes it as before; otherwise a stop has
     * already detached it and only this thread may close it. */
    pthread_mutex_lock(&g_audio_control_lock);
    bool stillAttached = stream->dataFd == dataFd;
    if (stillAttached) stream->dataFdOwnedByThread = false;
    pthread_mutex_unlock(&g_audio_control_lock);
    if (!stillAttached) close(dataFd);
    printf("[AUDIO] stream=%u receiver stopped generation=%llu "
           "packets=%llu gaps=%llu decryptErrors=%llu "
           "arrivalGaps=%llu maxArrival=%.1fms\n",
           stream->type, (unsigned long long)generation,
           (unsigned long long)stream->packetCount,
           (unsigned long long)stream->sequenceGaps,
           (unsigned long long)stream->decryptErrors,
           (unsigned long long)stream->longArrivalGaps,
           (double)stream->maxArrivalGapNanos / 1000000.0);
    free(context);
}

static void start_audio_receiver(carplay_audio_stream_t *stream) {
    if (!stream || stream->dataFd < 0 ||
        !__sync_bool_compare_and_swap(&stream->running, 0, 1)) return;
    carplay_audio_receiver_context_t *context =
        calloc(1, sizeof(*context));
    if (!context) {
        stream->running = 0;
        return;
    }
    context->stream = stream;
    context->generation = stream->generation;
    context->dataFd = stream->dataFd;
    context->dataPort = stream->dataPort;
    context->usesTCP = stream->usesTCP;
    pthread_mutex_lock(&g_audio_control_lock);
    stream->dataFdOwnedByThread = true;
    pthread_mutex_unlock(&g_audio_control_lock);
    if (!stream->usesTCP) {
        int receiveBuffer = 512 * 1024;
        setsockopt(stream->dataFd, SOL_SOCKET, SO_RCVBUF,
                   &receiveBuffer, sizeof(receiveBuffer));
        struct timeval timeout = { .tv_sec = 1, .tv_usec = 0 };
        setsockopt(stream->dataFd, SOL_SOCKET, SO_RCVTIMEO,
                   &timeout, sizeof(timeout));
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
                   ^{ audio_receiver_func(context); });
}

static void stop_audio_receiver(carplay_audio_stream_t *stream,
                                const char *reason) {
    if (!stream) return;
    pthread_mutex_lock(&g_audio_control_lock);
    bool hasClient = stream->tcpClientFd >= 0;
    pthread_mutex_unlock(&g_audio_control_lock);
    bool wasActive =
        stream->running || stream->dataFd >= 0 || stream->controlFd >= 0 ||
        stream->formatMask != 0 || hasClient;
    if (!wasActive) return;

    uint64_t oldGeneration = stream->generation;
    pthread_mutex_lock(&g_audio_control_lock);
    __sync_add_and_fetch(&stream->generation, 1);
    stream->running = 0;
    /* The receiver thread owns and closes the accepted sender connection;
     * shutting it down here ends its blocking read at once. */
    if (stream->tcpClientFd >= 0) shutdown(stream->tcpClientFd, SHUT_RDWR);
    int dataFd = stream->dataFd;
    bool threadOwnsData = stream->dataFdOwnedByThread;
    stream->dataFdOwnedByThread = false;
    stream->dataFd = -1;
    stream->dataPort = 0;
    pthread_mutex_unlock(&g_audio_control_lock);

    int controlFd = stream->controlFd;
    stream->controlFd = -1;
    stream->controlPort = 0;
    if (dataFd >= 0) {
        /* A running receiver thread closes its own socket after it sees
         * the new generation (within one poll/recv timeout); closing it
         * here would let the next SETUP reuse the fd under that thread. */
        shutdown(dataFd, SHUT_RDWR);
        if (!threadOwnsData) close(dataFd);
    }
    if (controlFd >= 0 && controlFd != dataFd) {
        shutdown(controlFd, SHUT_RDWR);
        close(controlFd);
    }

    stream->formatMask = 0;
    stream->keyValid = false;
    stream->haveSequence = false;
    audio_replay_reset(stream);
    pthread_mutex_lock(&g_audio_feedback_lock);
    stream->renderedSampleTime = 0;
    stream->renderedHostNTP = 0;
    stream->renderedHostRawNanos = 0;
    stream->renderUpdateCount = 0;
    pthread_mutex_unlock(&g_audio_feedback_lock);
    app_send_audio_control(stream->type, AUDIO_CONTROL_STOP);
    printf("[AUDIO] stream=%u stopped generation=%llu reason=%s\n",
           stream->type, (unsigned long long)oldGeneration,
           reason ? reason : "unspecified");
}

/* ── Send a single-byte status update to the iPadPlay app (best-effort) ── */
static void app_send_status(uint8_t code) {
    app_send_msg(MSG_STATUS, &code, 1);
}

static bool h264_frame_contains_idr(const uint8_t *bytes, size_t length) {
    size_t offset = 0;
    while (offset + 5 <= length) {
        uint32_t nalLength =
            ((uint32_t)bytes[offset] << 24) |
            ((uint32_t)bytes[offset + 1] << 16) |
            ((uint32_t)bytes[offset + 2] << 8) |
            (uint32_t)bytes[offset + 3];
        if (nalLength == 0 || offset + 4 + nalLength > length) break;
        if ((bytes[offset + 4] & 0x1f) == 5) return true;
        offset += 4 + nalLength;
    }
    return false;
}

static bool app_send_video_frame(uint64_t timestamp, bool isIDR,
                                 const uint8_t *bytes, uint32_t length,
                                 uint32_t serviceSequence,
                                 uint64_t serviceArrivalNanos,
                                 uint32_t arrivalGapMicros,
                                 uint32_t tcpPendingBytes,
                                 uint32_t tcpReceiveWindow,
                                 uint32_t tcpSmoothedRTT,
                                 uint32_t tcpCurrentRTT,
                                 uint32_t tcpFlags,
                                 uint32_t decryptMicros) {
    uint32_t messageLength = VIDEO_FRAME_METADATA_SIZE + length;
    uint8_t header[5] = {
        messageLength & 0xff, (messageLength >> 8) & 0xff,
        (messageLength >> 16) & 0xff, (messageLength >> 24) & 0xff,
        MSG_VIDEO_FRAME
    };
    uint8_t metadata[VIDEO_FRAME_METADATA_SIZE] = {0};
    memcpy(metadata, &timestamp, sizeof(timestamp));
    metadata[8] = isIDR ? 1 : 0;
    metadata[9] = 1; /* metadata layout version */
    memcpy(metadata + 12, &serviceSequence, sizeof(serviceSequence));
    memcpy(metadata + 16, &serviceArrivalNanos,
           sizeof(serviceArrivalNanos));
    memcpy(metadata + 24, &arrivalGapMicros, sizeof(arrivalGapMicros));
    memcpy(metadata + 28, &tcpPendingBytes, sizeof(tcpPendingBytes));
    memcpy(metadata + 32, &tcpReceiveWindow, sizeof(tcpReceiveWindow));
    memcpy(metadata + 36, &tcpSmoothedRTT, sizeof(tcpSmoothedRTT));
    memcpy(metadata + 40, &tcpCurrentRTT, sizeof(tcpCurrentRTT));
    memcpy(metadata + 44, &tcpFlags, sizeof(tcpFlags));
    memcpy(metadata + 48, &decryptMicros, sizeof(decryptMicros));

    uint64_t lockStarted = monotonic_nanos_now();
    if (!app_send_lock_acquire()) {
        /* The connection stays open, so the frames after this one would
         * reach the decoder without their reference: ask for an IDR. */
        app_note_send_lock_timeout(MSG_VIDEO_FRAME);
        return false;
    }
    uint64_t lockAcquired = monotonic_nanos_now();
    bool success = false;
    uint64_t catchUpDeadline = app_ipc_deadline();
    if (!app_ensure_connected(catchUpDeadline)) goto done;
    if (!app_flush_pending_bootstrap(catchUpDeadline)) {
        app_drop_connection();
        goto done;
    }
    uint64_t deadline = app_ipc_deadline();
    success = app_write_all(g_app_sock, header, sizeof(header), deadline) &&
              app_write_all(g_app_sock, metadata, sizeof(metadata),
                            deadline) &&
              app_write_all(g_app_sock, bytes, length, deadline);
    if (!success) {
        app_drop_connection();
        g_app_needs_keyframe = true;
        app_request_keyframe("app IPC write lost video");
    } else if (isIDR) {
        g_app_needs_keyframe = false;
    } else if (g_app_needs_keyframe) {
        /* Still decoding without the lost reference; repeat the request
         * (throttled) in case the earlier one was not honoured. */
        app_request_keyframe("app video chain awaiting keyframe");
    }
done:
    ;
    uint64_t writeFinished = monotonic_nanos_now();
    double lockWaitMs = (double)(lockAcquired - lockStarted) / 1000000.0;
    double ipcHoldMs = (double)(writeFinished - lockAcquired) / 1000000.0;
    if (!success || arrivalGapMicros > 50000 ||
        serviceSequence % 300 == 0 || lockWaitMs > 5.0 ||
        ipcHoldMs > 5.0) {
        printf("[SCREEN-TL] seq=%u arrival=%llu gap=%.1fms bytes=%u "
               "decrypt=%.2fms pending=%u rcvWnd=%u srtt=%ums rtt=%ums "
               "tcpFlags=0x%x ipcWait=%.2fms ipcHold=%.2fms sent=%d\n",
               serviceSequence,
               (unsigned long long)serviceArrivalNanos,
               (double)arrivalGapMicros / 1000.0, length,
               (double)decryptMicros / 1000.0, tcpPendingBytes,
               tcpReceiveWindow, tcpSmoothedRTT, tcpCurrentRTT, tcpFlags,
               lockWaitMs, ipcHoldMs, success ? 1 : 0);
    }
    if (g_app_send_lock) dispatch_semaphore_signal(g_app_send_lock);
    return success;
}

/* ── HID report sender — sends touch events to iPhone via event channel ── */
#define MSG_TOUCH 0x03
static int g_event_cmd_cseq = 10;
static dispatch_queue_t g_hid_send_queue = NULL;

static void send_event_command_on_stream(NSDictionary *cmd, const char *name,
                                         const char *reason, uint32_t streamID) {
    if (g_event_client_fd < 0 || !g_event_enc.active) {
        printf("[EVENT-CMD] %s unavailable (%s): fd=%d enc=%d\n",
               name, reason ?: "unspecified", g_event_client_fd,
               g_event_enc.active);
        return;
    }
    @autoreleasepool {
        NSData *plist = [NSPropertyListSerialization
            dataWithPropertyList:cmd
                          format:NSPropertyListBinaryFormat_v1_0
                         options:0
                           error:nil];
        if (!plist) return;
        NSMutableString *header = [NSMutableString string];
        [header appendString:@"POST /command RTSP/1.0\r\n"];
        [header appendFormat:@"Content-Length: %lu\r\n",
                             (unsigned long)plist.length];
        [header appendString:
            @"Content-Type: application/x-apple-binary-plist\r\n"];
        int commandSequence = __sync_fetch_and_add(&g_event_cmd_cseq, 1);
        [header appendFormat:@"CSeq: %d\r\n", commandSequence];
        [header appendFormat:@"User-Agent: AirPlay/%s\r\n", SOURCE_VERSION];
        if (streamID != 0)
            [header appendFormat:@"X-Apple-StreamID: %u\r\n", streamID];
        [header appendString:@"\r\n"];
        NSMutableData *message =
            [NSMutableData dataWithBytes:header.UTF8String
                                  length:strlen(header.UTF8String)];
        [message appendData:plist];

        if (g_event_send_lock)
            dispatch_semaphore_wait(g_event_send_lock, DISPATCH_TIME_FOREVER);
        int result = g_event_client_fd < 0 ? -1 :
            enc_send_stream(g_event_client_fd, &g_event_enc,
                            message.bytes, message.length);
        if (g_event_send_lock) dispatch_semaphore_signal(g_event_send_lock);
        printf("[EVENT-CMD] %s %s (%s, nonce=%llu)\n",
               name,
               result == 0 ? "sent" : "failed", reason ?: "unspecified",
               g_event_enc.writeNonce ? g_event_enc.writeNonce - 1 : 0);
    }
}

static void send_event_command(NSDictionary *cmd, const char *name,
                               const char *reason) {
    send_event_command_on_stream(cmd, name, reason, 0);
}

static void send_car_video_availability(void) {
    if (!atomic_load(&g_car_video_negotiated)) return;
    send_event_command(@{@"type": @"setVideoPlaybackAllowed",
                         @"params": @{@"videoPlaybackAllowed": @YES}},
                       "setVideoPlaybackAllowed", "bench");
}

static void send_request_ui_command(const char *reason) {
    @autoreleasepool {
        send_event_command(@{ @"type": @"requestUI" }, "requestUI", reason);
    }
}

static void send_force_key_frame_command(const char *reason) {
    @autoreleasepool {
        send_event_command(@{ @"type": @"forceKeyFrame" },
                           "forceKeyFrame", reason);
    }
}

/* When Showcase leaves the foreground, its own UI becomes the active native
 * display. Tell the iPhone's CarPlay resource manager that the accessory is
 * taking MainScreen. requestUI returns the screen to CarPlay later and causes
 * a fresh screen stream/config/keyframe instead of trying to reconstruct an
 * arbitrarily long H.264 dependency chain. */
static void send_take_main_screen_command(const char *reason) {
    @autoreleasepool {
        NSDictionary *resource = @{
            @"resourceID": @(1),        /* MainScreen */
            @"transferType": @(1),      /* Take */
            @"transferPriority": @(500),/* UserInitiated */
            @"takeConstraint": @(100),  /* Anytime */
            @"borrowConstraint": @(100) /* Anytime */
        };
        NSDictionary *cmd = @{
            @"type": @"changeModes",
            @"params": @{ @"resources": @[resource] }
        };
        send_event_command(cmd, "changeModes(MainScreen=Take)", reason);
    }
}

#define HID_CONGESTED_MAX_PENDING 3
#define HID_HEALTHY_BURST_MAX_PENDING 12
#define HID_SEND_STALL_NANOS (50ULL * NSEC_PER_MSEC)
static volatile int32_t g_hid_pending_moves = 0;
static volatile int64_t g_hid_dropped_moves = 0;
static volatile uint64_t g_hid_oldest_pending_nanos = 0;
static volatile uint64_t g_hid_slow_send_count = 0;

static void send_hid_report(const uint8_t *report, size_t reportLen) {
    if (g_event_client_fd < 0 || !g_event_enc.active) return;

    @autoreleasepool {
        NSDictionary *cmd = @{
            @"type": @"hidSendReport",
            @"uuid": @"1",
            @"hidReport": [NSData dataWithBytes:report length:reportLen]
        };

        NSData *plist = [NSPropertyListSerialization
            dataWithPropertyList:cmd
                          format:NSPropertyListBinaryFormat_v1_0
                         options:0
                           error:nil];
        if (!plist) return;

        NSMutableString *hdrStr = [NSMutableString string];
        [hdrStr appendString:@"POST /command RTSP/1.0\r\n"];
        [hdrStr appendFormat:@"Content-Length: %lu\r\n", (unsigned long)plist.length];
        [hdrStr appendString:@"Content-Type: application/x-apple-binary-plist\r\n"];
        int commandSequence = __sync_fetch_and_add(&g_event_cmd_cseq, 1);
        [hdrStr appendFormat:@"CSeq: %d\r\n", commandSequence];
        [hdrStr appendString:@"\r\n"];

        NSMutableData *msg = [NSMutableData dataWithBytes:hdrStr.UTF8String
                                                   length:strlen(hdrStr.UTF8String)];
        [msg appendData:plist];

        uint64_t startedNanos = monotonic_nanos_now();
        if (g_event_send_lock)
            dispatch_semaphore_wait(
                g_event_send_lock, DISPATCH_TIME_FOREVER);
        uint64_t lockAcquiredNanos = monotonic_nanos_now();
        int result = enc_send_frame(
            g_event_client_fd, &g_event_enc, msg.bytes, msg.length);
        if (g_event_send_lock) dispatch_semaphore_signal(g_event_send_lock);
        uint64_t completedNanos = monotonic_nanos_now();
        uint64_t totalNanos = completedNanos - startedNanos;
        if (result != 0 || totalNanos >= 20 * NSEC_PER_MSEC) {
            uint64_t slowCount =
                __sync_add_and_fetch(&g_hid_slow_send_count, 1);
            if (slowCount <= 10 || (slowCount % 50) == 0) {
                printf("[TOUCH-WIRE] #%llu result=%d total=%.2fms "
                       "lock=%.2fms write=%.2fms pending=%d shed=%lld\n",
                       (unsigned long long)slowCount, result,
                       (double)totalNanos / 1000000.0,
                       (double)(lockAcquiredNanos - startedNanos) /
                           1000000.0,
                       (double)(completedNanos - lockAcquiredNanos) /
                           1000000.0,
                       (int)g_hid_pending_moves,
                       (long long)g_hid_dropped_moves);
            }
        }
    }
}

/* Down and up are never shed. UIKit may deliver several coalesced samples in
 * one IPC message, so queue depth by itself is not congestion: the previous
 * three-report admission cap discarded the end of healthy short swipes before
 * the event queue had a chance to run. Permit a bounded coalesced burst and
 * shed interior points only when the oldest queued write has made no progress
 * for 50 ms. */
static bool queue_touch_report(uint8_t phase, uint16_t x, uint16_t y,
                               uint8_t contact, uint64_t timestampNs) {
    if (!g_hid_send_queue) return false;
    /* Preserve the complete path. CarPlay derives gesture velocity from the
     * intermediate reports, so replacing moves with the newest point creates
     * sluggish or intermittently missed swipes even on a healthy transport.
     *
     * The event socket is blocking, so when the radio congests, enc_send_frame
     * stalls and moves pile up behind it. Releasing that backlog delivers a
     * dozen points to the iPhone within a few milliseconds; CarPlay times
     * touches on arrival, reads that as an enormous velocity, and flings the
     * map. Bounding the queue keeps the path intact while the transport is
     * healthy — the overwhelmingly common case — and sheds interior points only
     * while it is behind, which is exactly when a stale point is worthless. */
    bool isMove = (phase == 1);
    if (isMove) {
        uint64_t nowNanos = monotonic_nanos_now();
        int32_t pending = g_hid_pending_moves;
        uint64_t oldestNanos = g_hid_oldest_pending_nanos;
        bool sendStalled =
            pending >= HID_CONGESTED_MAX_PENDING &&
            oldestNanos != 0 &&
            nowNanos - oldestNanos >= HID_SEND_STALL_NANOS;
        if (pending >= HID_HEALTHY_BURST_MAX_PENDING || sendStalled) {
            __sync_fetch_and_add(&g_hid_dropped_moves, 1);
            return false;
        }
        int32_t newPending =
            __sync_add_and_fetch(&g_hid_pending_moves, 1);
        if (newPending == 1)
            __sync_lock_test_and_set(
                &g_hid_oldest_pending_nanos, nowNanos);
    }
    dispatch_async(g_hid_send_queue, ^{
        uint8_t report[5] = {
            phase == 3 ? 2 : (phase == 2 ? 0 : 1),
            (uint8_t)(x & 0xff),
            (uint8_t)(x >> 8),
            (uint8_t)(y & 0xff),
            (uint8_t)(y >> 8)
        };
        send_hid_report(report, sizeof(report));
        if (isMove) {
            int32_t remaining =
                __sync_sub_and_fetch(&g_hid_pending_moves, 1);
            __sync_lock_test_and_set(
                &g_hid_oldest_pending_nanos,
                remaining > 0 ? monotonic_nanos_now() : 0);
        }
        (void)contact;
        (void)timestampNs;
    });
    return true;
}

/* ── Video in Car (stream 130) ── */
static pthread_mutex_t g_car_video_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t g_car_video_streams[2];
static uint32_t g_car_video_next_id = 3;
static unsigned g_car_video_settings_generation;
static int g_car_video_settings_client = -1;

static bool car_video_stream_active_locked(uint32_t streamID) {
    return streamID >= 3 && atomic_load(&g_car_video_negotiated) &&
        (g_car_video_streams[0] == streamID || g_car_video_streams[1] == streamID);
}

static void car_video_close_stream(uint32_t streamID) {
    pthread_mutex_lock(&g_car_video_lock);
    bool notifyApp = streamID == 0 || car_video_stream_active_locked(streamID);
    if (streamID == 0 || streamID == 2) {
        ++g_car_video_settings_generation;
        if (g_car_video_settings_client >= 0)
            shutdown(g_car_video_settings_client, SHUT_RDWR);
    }
    for (size_t i = 0; i < 2; i++) {
        if (streamID == 0 || g_car_video_streams[i] == streamID)
            g_car_video_streams[i] = 0;
    }
    if (notifyApp) {
        NSData *body = car_video_encode(@{@"streamID": @(streamID)});
        if (body) app_send_msg(MSG_CAR_VIDEO_COMMAND, body.bytes, (uint32_t)body.length);
    }
    pthread_mutex_unlock(&g_car_video_lock);
}

#define CAR_VIDEO_SETTINGS_ACCEPT_MS 30000
#define CAR_VIDEO_SETTINGS_IDLE_SEC 5

static void car_video_read_settings(int fd, encrypted_ctx_t *keys,
                                    unsigned generation) {
    uint8_t data[ENCRYPTED_MAX_READ_SIZE];
    uint8_t header[32];
    size_t headerLength = 0, remaining = 0;
    for (;;) {
        int length = enc_recv_frame(fd, keys, data, sizeof(data));
        if (length == -2) {
            /* Idle between records (SO_RCVTIMEO): the sender may sync only
             * occasionally, so silence is not an error while this channel
             * is still the current one. */
            pthread_mutex_lock(&g_car_video_lock);
            bool current = generation == g_car_video_settings_generation;
            pthread_mutex_unlock(&g_car_video_lock);
            if (current) continue;
            return;
        }
        if (length <= 0) return;
        size_t offset = 0;
        while (offset < (size_t)length) {
            if (headerLength < sizeof(header)) {
                size_t count = MIN(sizeof(header) - headerLength, (size_t)length - offset);
                memcpy(header + headerLength, data + offset, count);
                headerLength += count;
                offset += count;
                if (headerLength < sizeof(header)) continue;
                uint32_t networkLength;
                memcpy(&networkLength, header, sizeof(networkLength));
                uint32_t packageLength = ntohl(networkLength);
                if (packageLength < sizeof(header) || packageLength > 8 * 1024 * 1024)
                    return;
                remaining = packageLength - sizeof(header);
            }
            size_t count = MIN(remaining, (size_t)length - offset);
            remaining -= count;
            offset += count;
            if (remaining != 0) continue;
            if (memcmp(header + 4, "sync\0\0\0\0\0\0\0\0", 12) == 0) {
                uint8_t reply[32] = {0, 0, 0, 32, 'r', 'p', 'l', 'y'};
                memcpy(reply + 20, header + 20, 8);
                if (enc_send_frame(fd, keys, reply, sizeof(reply)) < 0) return;
            }
            headerLength = 0;
        }
    }
}

static void car_video_start_settings(int listener, encrypted_ctx_t keys) {
    car_video_close_stream(2);
    pthread_mutex_lock(&g_car_video_lock);
    unsigned generation = g_car_video_settings_generation;
    pthread_mutex_unlock(&g_car_video_lock);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int client = -1;
        /* The worker owns both descriptors. Teardown invalidates the pending
         * accept and wakes an active read without closing a reused fd.
         *
         * The port listens on every interface, so only the session iPhone may
         * take the channel: anything else is closed and the wait continues
         * until the original deadline. A wall-clock deadline (not a poll
         * count) keeps a flood of rejected connects from ending it early. */
        uint64_t acceptDeadline = monotonic_nanos_now() +
            (uint64_t)CAR_VIDEO_SETTINGS_ACCEPT_MS * NSEC_PER_MSEC;
        uint64_t rejected = 0;
        for (;;) {
            if (monotonic_nanos_now() >= acceptDeadline) break;
            struct pollfd pending = { .fd = listener, .events = POLLIN };
            int result = poll(&pending, 1, 250);
            pthread_mutex_lock(&g_car_video_lock);
            bool current = generation == g_car_video_settings_generation;
            pthread_mutex_unlock(&g_car_video_lock);
            if (!current) break;
            if (result < 0) {
                if (errno == EINTR) continue;
                break;
            }
            if (result == 0) continue;
            if (!(pending.revents & POLLIN)) break;
            struct sockaddr_storage peer;
            socklen_t peerLen = sizeof(peer);
            int accepted = accept(listener, (struct sockaddr *)&peer, &peerLen);
            if (accepted < 0) {
                if (errno == EINTR || errno == ECONNABORTED ||
                    errno == EAGAIN || errno == EWOULDBLOCK)
                    continue;
                break;
            }
            if (!sockaddr_is_session_iphone((struct sockaddr *)&peer,
                                            peerLen)) {
                if (++rejected % 100 == 1) {
                    printf("[CARVIDEO] Rejecting settings connection that "
                           "is not from the session iPhone (%llu so far)\n",
                           (unsigned long long)rejected);
                    fflush(stdout);
                }
                close(accepted);
                continue;
            }
            client = accepted;
            break;
        }
        close(listener);
        if (client >= 0) {
            int yes = 1;
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
            setsockopt(client, SOL_SOCKET, SO_KEEPALIVE, &yes, sizeof(yes));
            /* Bounded reads let the reader notice teardown or a dead peer
             * even if the wake-up shutdown is missed; see
             * car_video_read_settings for how an idle period is handled. */
            struct timeval tv = {
                .tv_sec = CAR_VIDEO_SETTINGS_IDLE_SEC, .tv_usec = 0 };
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            pthread_mutex_lock(&g_car_video_lock);
            bool current = generation == g_car_video_settings_generation;
            if (current) g_car_video_settings_client = client;
            pthread_mutex_unlock(&g_car_video_lock);
            encrypted_ctx_t context = keys;
            if (current) car_video_read_settings(client, &context, generation);
            crypto_wipe(&context, sizeof(context));
            pthread_mutex_lock(&g_car_video_lock);
            if (g_car_video_settings_client == client) g_car_video_settings_client = -1;
            close(client);
            pthread_mutex_unlock(&g_car_video_lock);
        }
    });
}

/* Stream identifiers and plist fields follow the observed DiPlay receiver
 * protocol: github.com/yashvardhan-techie/DiPlay-fixes (BYD_NAVIGATION.md). */
static NSDictionary *car_video_setup_stream(NSDictionary *stream) {
    NSString *uuid = stream[@"clientTypeUUID"];
    if (![uuid isKindOfClass:[NSString class]]) return nil;
    uuid = uuid.uppercaseString;
    if ([uuid isEqualToString:@"BB493F61-A6B8-4769-8D74-80C23A9F71C4"]) {
        NSNumber *seed = stream[@"seed"];
        encrypted_ctx_t keys = {0};
        if (![seed isKindOfClass:[NSNumber class]]) return nil;
        pthread_mutex_lock(&g_pair_lock);
        int derived = pair_derive_data_stream_keys(
            g_pair, seed.unsignedLongLongValue, keys.readKey, keys.writeKey);
        pthread_mutex_unlock(&g_pair_lock);
        if (derived != 0) return nil;
        uint16_t port = 0;
        int listener = bind_screen_tcp_port(&port, g_iphone_family);
        if (listener < 0) {
            crypto_wipe(&keys, sizeof(keys));
            return nil;
        }
        car_video_start_settings(listener, keys);
        crypto_wipe(&keys, sizeof(keys));
        NSMutableDictionary *response = [@{@"type": @130, @"streamID": @2,
                                           @"dataPort": @(port)} mutableCopy];
        if ([stream[@"streamConnectionID"] isKindOfClass:[NSNumber class]])
            response[@"streamConnectionID"] = stream[@"streamConnectionID"];
        return response;
    }

    NSArray *uuids = @[@"A6B27562-B43A-4F2D-B75F-82391E250194",
                       @"E3DC3EA6-E6C3-4B30-847C-B7ACFEBEA654"];
    NSUInteger slot = [uuids indexOfObject:uuid];
    NSNumber *controlType = stream[@"controlType"];
    if (slot == NSNotFound || ![controlType isKindOfClass:[NSNumber class]] ||
        controlType.intValue != 1) return nil;
    pthread_mutex_lock(&g_car_video_lock);
    if (!g_car_video_streams[slot]) g_car_video_streams[slot] = g_car_video_next_id++;
    uint32_t streamID = g_car_video_streams[slot];
    pthread_mutex_unlock(&g_car_video_lock);
    return @{@"type": @130, @"streamID": @(streamID)};
}

static void car_video_forward_command(uint32_t streamID, NSDictionary *outer) {
    NSDictionary *params = outer[@"params"];
    if (![params isKindOfClass:[NSDictionary class]]) return;
    NSData *data = params[@"data"];
    if (![data isKindOfClass:[NSData class]]) return;
    NSDictionary *command = car_video_decode(data);
    if (!command) return;
    NSData *body = car_video_encode(@{@"streamID": @(streamID), @"message": command});
    pthread_mutex_lock(&g_car_video_lock);
    if (body.length && body.length <= CAR_VIDEO_MAX_MESSAGE &&
        car_video_stream_active_locked(streamID))
        app_send_msg(MSG_CAR_VIDEO_COMMAND, body.bytes, (uint32_t)body.length);
    pthread_mutex_unlock(&g_car_video_lock);
}

static void car_video_request_ui(void) {
    pthread_mutex_lock(&g_car_video_lock);
    uint32_t streamID = g_car_video_streams[0] ?: g_car_video_streams[1];
    if (car_video_stream_active_locked(streamID)) {
        NSData *body = car_video_encode(@{@"streamID": @(streamID),
                                          @"message": @{@"type": @"requestUI"}});
        if (body) app_send_msg(MSG_CAR_VIDEO_COMMAND, body.bytes, (uint32_t)body.length);
    }
    pthread_mutex_unlock(&g_car_video_lock);
}

static void car_video_send_reply(NSData *body) {
    NSDictionary *packet = car_video_decode(body);
    NSNumber *idNumber = packet[@"streamID"];
    if (![idNumber isKindOfClass:[NSNumber class]]) return;
    uint32_t streamID = idNumber.unsignedIntValue;
    NSDictionary *reply = packet[@"message"];
    if (![reply isKindOfClass:[NSDictionary class]]) return;
    NSData *payload = car_video_encode(reply);
    pthread_mutex_lock(&g_car_video_lock);
    bool active = car_video_stream_active_locked(streamID);
    pthread_mutex_unlock(&g_car_video_lock);
    if (active && payload.length && payload.length <= CAR_VIDEO_MAX_MESSAGE)
        send_event_command_on_stream(@{@"params": @{@"data": payload}},
                                     "videoPlayback", "player response", streamID);
}

/* ── Touch reader thread — reads touch events from iPadPlay app via IPC ──
 * Every app connection gets its own reader on its own dup() of the socket,
 * so a reader still blocked in an event-channel send cannot keep the next
 * connection unread, and its fd number cannot be reused under it.
 * app_drop_connection shuts the socket down; the reader closes its copy. */
static void touch_reader_func(void *arg) {
    int fd = (int)(intptr_t)arg;
    printf("[TOUCH] Reader started on fd=%d\n", fd);
    fflush(stdout);

    int touchCount = 0;
    uint64_t gestureCount = 0;
    uint64_t gestureStartSample = 0;
    uint64_t gestureStartHost = 0;
    uint16_t gestureStartX = 0, gestureStartY = 0;
    uint16_t gestureLastX = 0, gestureLastY = 0;
    double gesturePath = 0;
    uint32_t gestureMoves = 0;
    uint32_t gestureQueuedMoves = 0;
    int64_t gestureShedStart = 0;

    while (1) {
        /* Read IPC header: [4 byte len LE][1 byte type] */
        uint8_t hdr[5];
        if (!tcp_read_exact(fd, hdr, 5)) break;

        uint32_t len = hdr[0] | (hdr[1]<<8) | (hdr[2]<<16) | (hdr[3]<<24);
        uint8_t type = hdr[4];

        if (type == MSG_TOUCH && len > 0) {
            uint8_t *payload = malloc(len);
            if (!payload || !tcp_read_exact(fd, payload, len)) {
                free(payload);
                break;
            }

            if (len == 5) {
                /* Accept Beta 2 clients during package transition. */
                uint8_t phase = payload[0];
                uint16_t x = payload[1] | (payload[2] << 8);
                uint16_t y = payload[3] | (payload[4] << 8);
                queue_touch_report(phase, x, y, 0, 0);
                touchCount++;
            } else if ((len % 14) == 0) {
                for (uint32_t offset = 0; offset < len; offset += 14) {
                    uint8_t phase = payload[offset];
                    uint8_t contact = payload[offset + 1];
                    uint16_t x = payload[offset + 2] |
                                 (payload[offset + 3] << 8);
                    uint16_t y = payload[offset + 4] |
                                 (payload[offset + 5] << 8);
                    uint64_t timestampNs = 0;
                    memcpy(&timestampNs, payload + offset + 6,
                           sizeof(timestampNs));
                    uint64_t touchHostNanos = monotonic_nanos_now();
                    g_last_touch_nanos = touchHostNanos;
                    if (phase == 0) {
                        gestureCount++;
                        gestureStartSample = timestampNs;
                        gestureStartHost = touchHostNanos;
                        gestureStartX = gestureLastX = x;
                        gestureStartY = gestureLastY = y;
                        gesturePath = 0;
                        gestureMoves = 0;
                        gestureQueuedMoves = 0;
                        gestureShedStart = g_hid_dropped_moves;
                    } else if (phase == 1) {
                        double dx = (double)x - gestureLastX;
                        double dy = (double)y - gestureLastY;
                        gesturePath += hypot(dx, dy);
                        gestureLastX = x;
                        gestureLastY = y;
                        gestureMoves++;
                    }
                    bool queued = queue_touch_report(
                        phase, x, y, contact, timestampNs);
                    if (phase == 1 && queued) gestureQueuedMoves++;
                    touchCount++;
                    if (touchCount <= 3 || touchCount % 100 == 0) {
                        printf("[TOUCH] #%d: phase=%d contact=%u x=%u y=%u "
                               "sample=%llu → HID btn=%d pending=%d shed=%lld\n",
                               touchCount, phase, contact, x, y,
                               (unsigned long long)timestampNs,
                               phase == 2 ? 0 : 1,
                               (int)g_hid_pending_moves,
                               (long long)g_hid_dropped_moves);
                    }
                    if (phase == 2 || phase == 3) {
                        double dx = (double)x - gestureStartX;
                        double dy = (double)y - gestureStartY;
                        double displacement = hypot(dx, dy);
                        double durationMs =
                            timestampNs >= gestureStartSample &&
                            gestureStartSample != 0
                                ? (double)(timestampNs -
                                    gestureStartSample) / 1000000.0
                                : (double)(touchHostNanos -
                                    gestureStartHost) / 1000000.0;
                        int64_t shed =
                            g_hid_dropped_moves - gestureShedStart;
                        printf("[TOUCH-GESTURE] #%llu phase=%u "
                               "duration=%.1fms moves=%u queued=%u "
                               "shed=%lld displacement=%.1f path=%.1f "
                               "end=(%u,%u)\n",
                               (unsigned long long)gestureCount, phase,
                               durationMs, gestureMoves,
                               gestureQueuedMoves, (long long)shed,
                               displacement, gesturePath, x, y);
                    }
                }
            } else {
                printf("[TOUCH] ignored malformed payload len=%u\n", len);
            }
            free(payload);
            fflush(stdout);
        } else if (SHOWCASE_VIDEO_IN_CAR_BENCH && type == MSG_CAR_VIDEO_REPLY &&
                   len > 0 && len <= CAR_VIDEO_MAX_MESSAGE) {
            @autoreleasepool {
                NSMutableData *body = [NSMutableData dataWithLength:len];
                if (!tcp_read_exact(fd, body.mutableBytes, len)) break;
                car_video_send_reply(body);
            }
        } else if (type == MSG_APP_VISIBILITY && len == 1) {
            uint8_t visible = 0;
            if (!tcp_read_exact(fd, &visible, 1)) break;
            g_app_video_enabled = visible != 0;
            printf("[SCREEN] Showcase is %s; video forwarding %s\n",
                   g_app_video_enabled ? "foreground" : "background",
                   g_app_video_enabled ? "resumed" : "paused");
            if (g_app_video_enabled) {
                send_request_ui_command("foreground resync");
            } else {
                send_take_main_screen_command("Showcase backgrounded");
            }
        } else if (type == MSG_VIDEO_RESYNC && len == 1) {
            uint8_t requested = 0;
            if (!tcp_read_exact(fd, &requested, 1)) break;
            if (requested) {
                printf("[SCREEN] Renderer requested a fresh screen stream\n");
                send_force_key_frame_command("decoder/stale-chain recovery");
            }
        } else if (type == MSG_AUDIO_RESYNC && len == 4) {
            uint8_t streamBytes[4];
            if (!tcp_read_exact(fd, streamBytes, sizeof(streamBytes))) break;
            uint32_t streamType = 0;
            memcpy(&streamType, streamBytes, sizeof(streamType));
            carplay_audio_stream_t *audio = audio_stream_for_type(streamType);
            /* The app repeats this while packets keep arriving without a
             * player; one re-send in flight is enough. Sent off this reader
             * thread, which must keep draining the socket. */
            if (audio && audio->running && !audio->appConfigPending) {
                printf("[AUDIO] app has no player for stream=%u; "
                       "re-sending config\n", streamType);
                dispatch_async(dispatch_get_global_queue(0, 0), ^{
                    app_send_audio_config(audio);
                });
            }
        } else if (type == MSG_AUDIO_RENDER && len == 20) {
            uint8_t payload[20];
            if (!tcp_read_exact(fd, payload, sizeof(payload))) break;
            uint32_t streamType = 0;
            int64_t sampleTime = 0;
            uint64_t hostTicks = 0;
            memcpy(&streamType, payload, 4);
            memcpy(&sampleTime, payload + 4, 8);
            memcpy(&hostTicks, payload + 12, 8);

            carplay_audio_stream_t *audio =
                audio_stream_for_type(streamType);
            if (audio) {
                uint64_t rawNanos = 0;
                uint64_t hostNTP =
                    synchronized_ntp_for_host_ticks(hostTicks, &rawNanos);
                pthread_mutex_lock(&g_audio_feedback_lock);
                audio->renderedSampleTime = sampleTime;
                audio->renderedHostNTP = hostNTP;
                audio->renderedHostRawNanos = rawNanos;
                audio->renderUpdateCount++;
                uint64_t updateCount = audio->renderUpdateCount;
                pthread_mutex_unlock(&g_audio_feedback_lock);
                if (updateCount <= 3 || (updateCount % 20) == 0) {
                    printf("[AUDIO] render stream=%u update=%llu "
                           "sample=%lld hostNTP=%llu rawNs=%llu\n",
                           streamType, (unsigned long long)updateCount,
                           (long long)sampleTime,
                           (unsigned long long)hostNTP,
                           (unsigned long long)rawNanos);
                }
            }
        } else {
            /* Skip unknown message type — read and discard payload */
            if (len > 0 && len < 65536) {
                uint8_t *discard = malloc(len);
                tcp_read_exact(fd, discard, len);
                free(discard);
            }
        }
    }

    printf("[TOUCH] Reader exiting on fd=%d (%d events processed)\n",
           fd, touchCount);
    fflush(stdout);
    close(fd);
}

static bool start_touch_reader(int fd) {
    int readerFd = dup(fd);
    if (readerFd < 0) {
        int dupErrno = errno;
        printf("[TOUCH] dup(fd=%d) failed: %s; touch reader not started\n",
               fd, strerror(dupErrno));
        fflush(stdout);
        errno = dupErrno;
        return false;
    }
    intptr_t fdArg = readerFd;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        touch_reader_func((void *)fdArg);
    });
    return true;
}

static bool screen_generation_is_current(uint32_t generation) {
    pthread_mutex_lock(&g_screen_lock);
    bool current = g_screen_generation == generation;
    pthread_mutex_unlock(&g_screen_lock);
    return current;
}

static void *screen_thread_func(void *arg) {
    (void)arg;
    pthread_mutex_lock(&g_screen_lock);
    int listenFd = g_screen_listen_fd;
    uint32_t generation = g_screen_generation;
    g_screen_thread_listen_fd = listenFd;
    pthread_mutex_unlock(&g_screen_lock);
    printf("[SCREEN] Waiting for iPhone to connect on port %u (fd=%d)...\n",
           g_screen_data_port, listenFd);
    fflush(stdout);

    /* Poll instead of blocking in accept() so TEARDOWN or a replacement
     * SETUP (a new generation) and a sender that never connects all release
     * this thread; otherwise every later screen stream would queue behind it. */
    struct sockaddr_storage peer;
    socklen_t peerLen = sizeof(peer);
    int clientFd = -1;
    uint64_t acceptDeadline = monotonic_nanos_now() +
        (uint64_t)SCREEN_ACCEPT_TIMEOUT_SECONDS * NSEC_PER_SEC;
    uint64_t rejected = 0;
    while (listenFd >= 0) {
        if (!screen_generation_is_current(generation)) {
            printf("[SCREEN] Listener superseded before the iPhone connected\n");
            break;
        }
        if (monotonic_nanos_now() >= acceptDeadline) {
            printf("[SCREEN] ERROR: iPhone did not connect within %d s\n",
                   SCREEN_ACCEPT_TIMEOUT_SECONDS);
            break;
        }
        struct pollfd pending = { .fd = listenFd, .events = POLLIN };
        int ready = poll(&pending, 1, 250);
        if (ready < 0 && errno != EINTR) {
            printf("[SCREEN] ERROR: poll failed: %s\n", strerror(errno));
            break;
        }
        if (ready <= 0) continue;
        peerLen = sizeof(peer);
        int accepted = accept(listenFd, (struct sockaddr *)&peer, &peerLen);
        if (accepted < 0) {
            if (errno == EINTR || errno == ECONNABORTED ||
                errno == EAGAIN || errno == EWOULDBLOCK)
                continue;
            printf("[SCREEN] ERROR: accept failed: %s\n", strerror(errno));
            break;
        }
        if (!sockaddr_is_session_iphone((struct sockaddr *)&peer, peerLen)) {
            if (++rejected % 100 == 1) {
                printf("[SCREEN] Rejecting connection that is not from the "
                       "session iPhone (%llu so far)\n",
                       (unsigned long long)rejected);
                fflush(stdout);
            }
            close(accepted);
            continue;
        }
        clientFd = accepted;
        break;
    }
    fflush(stdout);

    pthread_mutex_lock(&g_screen_lock);
    if (listenFd >= 0) close(listenFd);
    if (g_screen_listen_fd == listenFd)
        g_screen_listen_fd = -1;
    g_screen_thread_listen_fd = -1;
    if (clientFd >= 0 && g_screen_generation != generation) {
        close(clientFd);
        clientFd = -1;
    }
    if (clientFd >= 0) g_screen_client_fd = clientFd;
    pthread_mutex_unlock(&g_screen_lock);
    if (clientFd < 0) {
        __sync_lock_release(&g_screen_thread_running);
        return NULL;
    }

    char peerIP[NI_MAXHOST] = {0};
    char peerPort[NI_MAXSERV] = {0};
    sockaddr_to_numeric((struct sockaddr *)&peer, peerLen,
                        peerIP, sizeof(peerIP), peerPort, sizeof(peerPort));
    printf("[SCREEN] *** Connected from %s:%s family=%s ***\n",
           peerIP, peerPort, addr_family_name(peer.ss_family));
    set_screen_socket_qos(clientFd, "accepted");

    /*
     * The iPhone encoder emits short bursts far above its average bitrate.
     * A shallow fixed window works on fast PCIe radios, but on older HSIC
     * receivers it propagates temporary radio loss back to the sender, where
     * the screen sink starts discarding frames. The app selects this window
     * from the runtime WLAN transport rather than jailbreak layout or a device
     * model table.
     */
    int requestedRcvBuf = g_screen_receive_buffer;
    int rcvBuf = requestedRcvBuf;
    if (setsockopt(clientFd, SOL_SOCKET, SO_RCVBUF,
                   &requestedRcvBuf, sizeof(requestedRcvBuf)) != 0) {
        printf("[SCREEN] WARN: SO_RCVBUF request %d failed: %s\n",
               requestedRcvBuf, strerror(errno));
    }
    socklen_t rcvBufLength = sizeof(rcvBuf);
    if (getsockopt(clientFd, SOL_SOCKET, SO_RCVBUF,
                   &rcvBuf, &rcvBufLength) == 0) {
        printf("[SCREEN] TCP receive buffer: requested=%d actual=%d bytes\n",
               requestedRcvBuf, rcvBuf);
    }

    /*
     * Leave Darwin's stretch ACKs alone. On HSIC Wi-Fi the chip shares one
     * USB-class bus between transmit and receive; forcing an ACK every other
     * segment raised the iPad4,2's transmit/receive frame ratio from 0.34 to
     * 0.74 and its discarded-frame rate from 5% to 28%. Across three
     * recorded sessions, windows with transmit below half the receive rate
     * discarded 1-2% of frames and windows above it about 20%.
     */
    printf("[SCREEN] Key valid=%d, connID=%llu\n", g_screen_key_valid, g_screen_conn_id);
    fflush(stdout);

    /* ── Frame processing state ── */
    uint8_t header[128];
    uint8_t *body = NULL;
    size_t bodyAlloc = 0;
    uint64_t chachaNonce = 0;  /* 8-byte LE nonce, incremented per video frame */
    int videoFrameCount = 0;
    uint64_t totalBytes = 0;
    int msgCount = 0;
    double arrivalWindowStart = 0;
    double lastFrameArrival = 0;
    double maxFrameGap = 0;
    uint64_t arrivalWindowBytes = 0;
    unsigned int arrivalWindowFrames = 0;
    unsigned int gapsOver50ms = 0;
    unsigned int gapsOver100ms = 0;
    double lastStatsLogSeconds = 0;

    while (1) {
        /* Read 128-byte header */
        if (!screen_read_exact(clientFd, header, 128, "header")) {
            printf("[SCREEN] Connection closed (header read)\n");
            break;
        }

        uint32_t bodySize = header[0] | (header[1] << 8) | (header[2] << 8*2) | (header[3] << 8*3);
        uint8_t opcode = header[4];

        /*
         * Bound the length before it is used for arithmetic. bodySize is a
         * 32-bit plaintext field, so `bodySize + 4096` used to wrap for
         * anything at or above 0xFFFFF000: the buffer was reallocated to a
         * few kilobytes (or zero) and the next read then filled it with up
         * to 4 GiB of socket data. Rejecting the frame here keeps the growth
         * arithmetic and the later `8 + bodySize` message length in range.
         */
        if (bodySize > SCREEN_MAX_BODY_BYTES) {
            printf("[SCREEN] Rejecting oversized body: %u bytes (max %u)\n",
                   bodySize, SCREEN_MAX_BODY_BYTES);
            fflush(stdout);
            break;
        }

        /* Ensure body buffer is big enough */
        if (bodySize > 0) {
            if (bodySize > bodyAlloc) {
                size_t grown = (size_t)bodySize + 4096;
                uint8_t *resized = realloc(body, grown);
                if (!resized) {
                    printf("[SCREEN] ERROR: body realloc %zu failed\n", grown);
                    fflush(stdout);
                    break;
                }
                body = resized;
                bodyAlloc = grown;
            }
            if (!screen_read_exact(clientFd, body, bodySize, "body")) {
                printf("[SCREEN] Connection closed (body read, expected %u)\n", bodySize);
                break;
            }
        }

        uint64_t messageArrivalNanos = monotonic_nanos_now();
        totalBytes += 128 + bodySize;
        msgCount++;

        switch (opcode) {
            case 1: { /* VideoConfig — SPS/PPS (AVCC), display dimensions */
                float width = *(float *)(header + 8 + 8);   /* params[1].f32[0] */
                float height = *(float *)(header + 8 + 12);  /* params[1].f32[1] */

                /* smallParam[1] carries the screen flags. Bit 1 is
                 * RespectTimestamps, bit 2 Encrypted — the latter is a useful
                 * cross-check because this stream is in fact encrypted. */
                uint8_t screenFlags = header[6];
                g_screen_respect_timestamps = (screenFlags & 0x02) ? 1 : 0;
                printf("[SCREEN] VideoConfig: %.0fx%.0f, AVCC=%u bytes, "
                       "flags=0x%02x (respectTimestamps=%u encrypted=%u)\n",
                       width, height, bodySize, screenFlags,
                       g_screen_respect_timestamps,
                       (screenFlags & 0x04) ? 1u : 0u);

                /* The renderer must learn the contract before the first frame
                 * that depends on it. */
                app_send_video_timing();

                /* Send config to iPadPlay app: [float width][float height][AVCC] */
                uint32_t msgLen = 8 + bodySize;
                uint8_t *msg = malloc(msgLen);
                if (!msg) {
                    printf("[SCREEN] ERROR: VideoConfig alloc %u failed\n", msgLen);
                    fflush(stdout);
                    break;
                }
                memcpy(msg, &width, 4);
                memcpy(msg + 4, &height, 4);
                memcpy(msg + 8, body, bodySize);
                if (g_video_config_lock)
                    dispatch_semaphore_wait(g_video_config_lock,
                                            DISPATCH_TIME_FOREVER);
                free(g_latest_video_config);
                g_latest_video_config = malloc(msgLen);
                if (g_latest_video_config) {
                    memcpy(g_latest_video_config, msg, msgLen);
                    g_latest_video_config_length = msgLen;
                } else {
                    g_latest_video_config_length = 0;
                }
                if (g_video_config_lock)
                    dispatch_semaphore_signal(g_video_config_lock);
                bool sent = app_send_msg(MSG_VIDEO_CONFIG, msg, msgLen);
                free(msg);
                printf("[SCREEN] VideoConfig → app: %s\n", sent ? "OK" : "not connected");
                fflush(stdout);
                break;
            }

            case 0: { /* VideoFrame — encrypted H.264 data */
                videoFrameCount++;

                if (!g_screen_key_valid || bodySize < 16) {
                    if (videoFrameCount <= 3)
                        printf("[SCREEN] VideoFrame #%d: %u bytes (no key or too small)\n",
                               videoFrameCount, bodySize);
                    chachaNonce++;
                    break;
                }

                /* Decrypt with ChaCha20-Poly1305 (DJB 64x64 variant)
                 * Map to IETF 12-byte nonce: [4 zero bytes][8-byte LE nonce]
                 * AAD = 128-byte header, body = ciphertext + 16-byte tag */
                uint8_t ietfNonce[12];
                memset(ietfNonce, 0, 4);
                memcpy(ietfNonce + 4, &chachaNonce, 8);  /* LE nonce */

                uint32_t ctLen = bodySize - 16;  /* last 16 = poly1305 tag */

                crypto_aead_ctx ctx;
                crypto_aead_init_ietf(&ctx, g_screen_key, ietfNonce);
                int authResult = crypto_aead_read(
                    &ctx, body, body + ctLen, header, sizeof(header),
                    body, ctLen);
                crypto_wipe(&ctx, sizeof(ctx));
                int authOK = authResult == 0;

                if (videoFrameCount <= 3) {
                    printf("[SCREEN] VideoFrame #%d: %u bytes ct, decrypt=%s, nonce=%llu\n",
                           videoFrameCount, ctLen, authOK ? "OK" : "FAIL", chachaNonce);
                    fflush(stdout);
                }

                chachaNonce++;

                if (!authOK) break;

                uint64_t decryptDoneNanos = monotonic_nanos_now();
                uint64_t decryptNanos = decryptDoneNanos -
                    messageArrivalNanos;
                uint32_t decryptMicros = decryptNanos / 1000ULL > UINT32_MAX
                    ? UINT32_MAX : (uint32_t)(decryptNanos / 1000ULL);
                double arrivalSeconds =
                    (double)messageArrivalNanos / 1000000000.0;
                uint32_t arrivalGapMicros = 0;
                if (arrivalWindowStart == 0)
                    arrivalWindowStart = arrivalSeconds;
                if (lastFrameArrival > 0) {
                    double gap = arrivalSeconds - lastFrameArrival;
                    double gapMicros = gap * 1000000.0;
                    if (gapMicros > (double)UINT32_MAX)
                        arrivalGapMicros = UINT32_MAX;
                    else if (gapMicros > 0)
                        arrivalGapMicros = (uint32_t)gapMicros;
                    if (gap > maxFrameGap) maxFrameGap = gap;
                    if (gap > 0.050) gapsOver50ms++;
                    if (gap > 0.100) gapsOver100ms++;
                }
                lastFrameArrival = arrivalSeconds;
                arrivalWindowFrames++;
                arrivalWindowBytes += ctLen;

                /* packet[5] bit 0x10 marks an IDR frame in the AirPlay screen
                 * protocol. params[0] is the sender's 32.32 fixed-point
                 * presentation time on the session timeline; the renderer maps
                 * it into host time and schedules the frame there whenever
                 * RespectTimestamps is set. */
                uint64_t ntpTimestamp = 0;
                memcpy(&ntpTimestamp, header + 8, sizeof(ntpTimestamp));
                bool isIDR = (header[5] & 0x10) != 0 ||
                    h264_frame_contains_idr(body, ctLen);
                if (g_app_video_enabled) {
                    int pendingBytes = 0;
                    if (ioctl(clientFd, FIONREAD, &pendingBytes) != 0 ||
                        pendingBytes < 0)
                        pendingBytes = 0;

                    uint32_t receiveWindow = 0;
                    uint32_t smoothedRTT = 0;
                    uint32_t currentRTT = 0;
                    uint32_t tcpFlags = 0;
#ifdef TCP_CONNECTION_INFO
                    if (arrivalGapMicros > 50000 ||
                        videoFrameCount % 300 == 0) {
                        struct tcp_connection_info tcpInfo;
                        memset(&tcpInfo, 0, sizeof(tcpInfo));
                        socklen_t tcpInfoLength = sizeof(tcpInfo);
                        if (getsockopt(clientFd, IPPROTO_TCP,
                                       TCP_CONNECTION_INFO, &tcpInfo,
                                       &tcpInfoLength) == 0) {
                            receiveWindow = tcpInfo.tcpi_rcv_wnd;
                            smoothedRTT = tcpInfo.tcpi_srtt;
                            currentRTT = tcpInfo.tcpi_rttcur;
                            tcpFlags = tcpInfo.tcpi_flags;
                        }
                    }
#endif
                    app_send_video_frame(
                        ntpTimestamp, isIDR, body, ctLen,
                        (uint32_t)videoFrameCount, messageArrivalNanos,
                        arrivalGapMicros, (uint32_t)pendingBytes,
                        receiveWindow, smoothedRTT, currentRTT, tcpFlags,
                        decryptMicros);
                }

                double windowDuration = arrivalSeconds - arrivalWindowStart;
                if (windowDuration >= 5.0) {
                    double fps = arrivalWindowFrames / windowDuration;
                    double mbps = (arrivalWindowBytes * 8.0) /
                        (windowDuration * 1000000.0);
                    printf("[SCREEN] Live arrival: %.1f fps %.2f Mbps, "
                           "max gap %.1fms (>50=%u >100=%u), forwarding=%d\n",
                           fps, mbps, maxFrameGap * 1000.0,
                           gapsOver50ms, gapsOver100ms,
                           g_app_video_enabled ? 1 : 0);
                    arrivalWindowStart = arrivalSeconds;
                    arrivalWindowBytes = 0;
                    arrivalWindowFrames = 0;
                    maxFrameGap = 0;
                    gapsOver50ms = 0;
                    gapsOver100ms = 0;
                }
                break;
            }

            case 5: { /* KeepAliveWithBody — carries sender video statistics.
                       * The AccessorySDK ignores this opcode outright. Parsing
                       * the plist and printing the dictionary costs a copy, a
                       * deserialisation and ~17 line-buffered write() calls,
                       * and it used to happen on this thread once a second —
                       * long enough to stop draining the screen socket and turn
                       * the next frames into a late burst. Snapshot the bytes,
                       * hand them to a background queue, and sample rarely. */
                static dispatch_queue_t statsQueue;
                static dispatch_once_t statsOnce;
                dispatch_once(&statsOnce, ^{
                    statsQueue = dispatch_queue_create(
                        "com.reng.showcase.screenstats", DISPATCH_QUEUE_SERIAL);
                    dispatch_set_target_queue(statsQueue,
                        dispatch_get_global_queue(
                            DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
                });
                struct timespec statsNow;
                clock_gettime(CLOCK_MONOTONIC, &statsNow);
                double statsSeconds = (double)statsNow.tv_sec +
                    (double)statsNow.tv_nsec / 1000000000.0;
                if (statsSeconds - lastStatsLogSeconds >= 15.0 &&
                    bodySize > 0 && bodySize < 4u * 1024u * 1024u) {
                    lastStatsLogSeconds = statsSeconds;
                    size_t plistLength = bodySize;
                    if (plistLength > 25000) plistLength -= 25000;
                    NSData *snapshot = [NSData dataWithBytes:body
                                                      length:plistLength];
                    dispatch_async(statsQueue, ^{
                        @autoreleasepool {
                            id stats = network_plist_parse(
                                snapshot.bytes, snapshot.length,
                                NETWORK_PLIST_MAX_DEPTH);
                            if (stats)
                                printf("[SCREEN] Sender performance: %s\n",
                                       [[stats description] UTF8String]);
                        }
                    });
                }
                break;
            }
            case 2: /* KeepAlive */
            case 4: /* Ignore (bandwidth measurement) */
                break;

            default:
                if (msgCount <= 10)
                    printf("[SCREEN] Unknown opcode %d, body=%u\n", opcode, bodySize);
                break;
        }

        if (msgCount % 500 == 0) {
            printf("[SCREEN] %d msgs, %d video frames, %llu bytes total\n",
                   msgCount, videoFrameCount, totalBytes);
            fflush(stdout);
        }
    }

    printf("[SCREEN] Thread exit: %d msgs, %d video frames, %llu bytes\n",
           msgCount, videoFrameCount, totalBytes);
    fflush(stdout);
    free(body);
    /* Clear the shared descriptor before closing so screen_stream_stop can
     * never shut down a number that has been reused. */
    pthread_mutex_lock(&g_screen_lock);
    if (g_screen_client_fd == clientFd) g_screen_client_fd = -1;
    pthread_mutex_unlock(&g_screen_lock);
    close(clientFd);
    __sync_lock_release(&g_screen_thread_running);
    return NULL;
}

/* Ends the current screen stream (connected or still listening) so TEARDOWN
 * of type 110 or a replacement SETUP never leaves a thread holding it. */
static void screen_stream_stop(const char *reason) {
    pthread_mutex_lock(&g_screen_lock);
    g_screen_generation++;
    if (g_screen_client_fd >= 0) {
        printf("[SCREEN] Stopping stream (%s)\n", reason);
        shutdown(g_screen_client_fd, SHUT_RDWR);
    }
    /* A listener no thread has taken yet belongs to nobody else. */
    if (g_screen_listen_fd >= 0 &&
        g_screen_listen_fd != g_screen_thread_listen_fd) {
        close(g_screen_listen_fd);
        g_screen_listen_fd = -1;
    }
    pthread_mutex_unlock(&g_screen_lock);
    fflush(stdout);
}

static void start_screen_thread(void) {
    if (g_screen_listen_fd < 0) return;
    if (!__sync_bool_compare_and_swap(&g_screen_thread_running, 0, 1)) {
        /* A replacement SETUP can arrive while the old stream thread is
         * finishing its socket cleanup. Retry off the RTSP thread so the
         * SETUP response is never delayed. */
        if (__sync_bool_compare_and_swap(&g_screen_start_pending, 0, 1)) {
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                while (g_screen_thread_running)
                    usleep(20000);
                __sync_lock_release(&g_screen_start_pending);
                start_screen_thread();
            });
        }
        return;
    }
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        screen_thread_func(NULL);
    });
}

static ssize_t send_timing_request(int fd,
                                   const struct sockaddr *destination,
                                   socklen_t destinationLength) {
    uint8_t packet[32] = {0};
    packet[0] = 0x80;
    packet[1] = 0xD2;
    packet[2] = 0x00;
    packet[3] = 0x07;

    uint32_t seconds = 0;
    uint32_t fraction = 0;
    get_ntp_time(&seconds, &fraction);
    packet[24] = (seconds >> 24) & 0xFF;
    packet[25] = (seconds >> 16) & 0xFF;
    packet[26] = (seconds >> 8) & 0xFF;
    packet[27] = seconds & 0xFF;
    packet[28] = (fraction >> 24) & 0xFF;
    packet[29] = (fraction >> 16) & 0xFF;
    packet[30] = (fraction >> 8) & 0xFF;
    packet[31] = fraction & 0xFF;
    timing_remember_request(packet + 24);
    return sendto(fd, packet, sizeof(packet), 0,
                  destination, destinationLength);
}

/* ═══════════════════════════════════════════════════════════════
 * Timing Negotiation — server-initiated NTP sync
 *
 * The reference implementation (AirPlayReceiverSession.c) calls
 * _TimingNegotiate() from AirPlayReceiverSessionStart() (RECORD).
 * The SERVER sends NTP requests to the CLIENT's timing port.
 * The client responds, and we compute clock offset.
 *
 * We send from our timing socket (g_timing_fd) so responses
 * come back to our timing responder thread.
 * ═══════════════════════════════════════════════════════════════ */

/* Blocking timing negotiation — sends NTP requests and waits for responses.
 * The reference (AirPlayReceiverSession.c _TimingNegotiate) blocks until
 * at least 3 successful NTP roundtrips complete. The RECORD 200 OK must
 * NOT be sent until timing is synchronized. */
static bool timing_negotiate_blocking(void) {
    if (g_iphone_timing_port == 0 || g_iphone_ip[0] == '\0' || g_timing_fd < 0) {
        printf("[TIMING-NEG] Cannot negotiate — no iPhone timing port/IP/fd\n");
        return false;
    }

    printf("[TIMING-NEG] Starting BLOCKING negotiation -> %s:%u\n",
           g_iphone_ip, g_iphone_timing_port);
    fflush(stdout);

    struct sockaddr_storage dest;
    socklen_t destLen = 0;
    char destDisplay[NI_MAXHOST + IF_NAMESIZE + 4];
    memset(destDisplay, 0, sizeof(destDisplay));
    int timingFamily = socket_bound_family(g_timing_fd);
    if (!build_peer_sockaddr(g_iphone_ip, g_iphone_timing_port,
                             timingFamily,
                             &dest, &destLen,
                             destDisplay, sizeof(destDisplay))) {
        printf("[TIMING] WARN: could not parse timing destination %s; waiting for client timing packets\n",
               g_iphone_ip);
        return false;
    }
    printf("[TIMING] negotiate socket=%s destination=%s %s port=%u\n",
           addr_family_name(timingFamily), addr_family_name(dest.ss_family),
           destDisplay, g_iphone_timing_port);

    g_timing_sync_count = 0;
    g_timing_best_rtt = DBL_MAX;
    g_timing_remote_minus_local = 0.0;
    g_timing_offset_valid = 0;
    g_timing_samples_reset = 1;
    app_send_video_timing();

    /* Send 5 NTP requests with 100ms spacing, then wait for responses */
    for (int i = 0; i < 5; i++) {
        ssize_t sent = send_timing_request(
            g_timing_fd, (struct sockaddr *)&dest, destLen);
        if (sent < 0) {
            printf("[TIMING] WARN: sendto failed for %s errno=%d (%s); waiting for client timing packets\n",
                   destDisplay, errno, strerror(errno));
        } else {
            printf("[TIMING-NEG] Sent NTP request %d/5 (%zd bytes)\n", i + 1, sent);
        }
        fflush(stdout);

        /* Wait 100ms between requests */
        usleep(100000);
    }

    /* Wait up to 2 seconds for at least 3 responses
     * (responses are counted by the timing responder thread) */
    int waitMs = 0;
    while (g_timing_sync_count < 3 && waitMs < 2000) {
        usleep(50000);  /* 50ms poll */
        waitMs += 50;
    }

    printf("[TIMING-NEG] Negotiation complete: %d responses in %dms\n",
           g_timing_sync_count, waitMs);
    fflush(stdout);

    /*
     * CarPlaySDK continues probing roughly every 2–3 seconds for the lifetime
     * of a session. Keep one generation alive so resume/re-RECORD replaces the
     * old destination without accumulating maintenance loops.
     */
    uint32_t generation =
        __sync_add_and_fetch(&g_timing_maintenance_generation, 1);
    struct sockaddr_storage maintenanceDestination = dest;
    socklen_t maintenanceLength = destLen;
    int maintenanceFd = g_timing_fd;
    dispatch_async(dispatch_get_global_queue(
                       DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        while (generation == g_timing_maintenance_generation &&
               maintenanceFd == g_timing_fd && maintenanceFd >= 0) {
            usleep(2500000);
            if (generation != g_timing_maintenance_generation) break;
            ssize_t sent = send_timing_request(
                maintenanceFd,
                (struct sockaddr *)&maintenanceDestination,
                maintenanceLength);
            if (sent < 0 && errno != EINTR)
                printf("[TIMING] maintenance request failed: %s\n",
                       strerror(errno));
        }
    });

    return (g_timing_sync_count >= 3);
}

/* Ports opened for stream types this receiver does not process (and a type
 * 130 SETUP that the car video path declined). Nothing reads them, but the
 * sender is given their numbers, so they stay open until the stream or the
 * session is torn down or the same type is set up again. */
#define AUX_STREAM_SLOTS 8
typedef struct {
    bool used;
    int type;
    int dataFd;
    int ctrlFd;
} aux_stream_fds_t;
static pthread_mutex_t g_aux_streams_lock = PTHREAD_MUTEX_INITIALIZER;
static aux_stream_fds_t g_aux_streams[AUX_STREAM_SLOTS];
static unsigned g_aux_streams_next = 0;

static void aux_stream_close_slot_locked(aux_stream_fds_t *slot) {
    if (!slot->used) return;
    if (slot->dataFd >= 0) close(slot->dataFd);
    if (slot->ctrlFd >= 0) close(slot->ctrlFd);
    printf("[NET] auxiliary stream=%d closed (data fd=%d control fd=%d)\n",
           slot->type, slot->dataFd, slot->ctrlFd);
    slot->used = false;
    slot->dataFd = -1;
    slot->ctrlFd = -1;
}

/* Closes the auxiliary ports of one stream type, or of every type when
 * allTypes is set. */
static void aux_stream_close(int type, bool allTypes) {
    pthread_mutex_lock(&g_aux_streams_lock);
    for (size_t i = 0; i < AUX_STREAM_SLOTS; i++) {
        if (g_aux_streams[i].used &&
            (allTypes || g_aux_streams[i].type == type))
            aux_stream_close_slot_locked(&g_aux_streams[i]);
    }
    pthread_mutex_unlock(&g_aux_streams_lock);
}

static void aux_stream_remember(int type, int dataFd, int ctrlFd) {
    if (dataFd < 0 && ctrlFd < 0) return;
    pthread_mutex_lock(&g_aux_streams_lock);
    aux_stream_fds_t *slot = NULL;
    for (size_t i = 0; i < AUX_STREAM_SLOTS; i++) {
        if (g_aux_streams[i].used && g_aux_streams[i].type == type)
            aux_stream_close_slot_locked(&g_aux_streams[i]);
        if (!slot && !g_aux_streams[i].used) slot = &g_aux_streams[i];
    }
    if (!slot) {
        slot = &g_aux_streams[g_aux_streams_next % AUX_STREAM_SLOTS];
        g_aux_streams_next++;
        aux_stream_close_slot_locked(slot);
    }
    slot->used = true;
    slot->type = type;
    slot->dataFd = dataFd;
    slot->ctrlFd = ctrlFd;
    pthread_mutex_unlock(&g_aux_streams_lock);
}

static void handle_rtsp_setup(int sock, const HTTPReq *r) {
    printf("[AP] -> SETUP %s (CSeq=%d, bodyLen=%zu)\n",
           r->path, r->cseq, r->bodyLen);

    NSDictionary *reqDict = nil;
    if (r->body && r->bodyLen > 0) {
        @autoreleasepool {
            id obj = network_plist_parse(r->body, r->bodyLen,
                                         NETWORK_PLIST_MAX_DEPTH);
            if ([obj isKindOfClass:[NSDictionary class]]) {
                reqDict = (NSDictionary *)obj;
            }
        }
    }

    @autoreleasepool {
        NSMutableDictionary *respDict = [NSMutableDictionary dictionary];
        bool enableCarVideo = false;
        NSArray *streams = reqDict[@"streams"];
        if (streams && ![streams isKindOfClass:[NSArray class]]) {
            send_response(sock, "RTSP/1.0", 400, "Bad Request", NULL, NULL, 0, r->cseq);
            return;
        }

        if (!streams) {
            /* ── Phase 1: Initial session control setup ── */
            printf("[AP] SETUP: initial session setup (no streams)\n");

            /* Extract iPhone's timing port from request */
            NSNumber *iphoneTimingPort = plist_number(reqDict[@"timingPort"]);
            if (iphoneTimingPort) {
                g_iphone_timing_port = [iphoneTimingPort unsignedShortValue];
                printf("[AP] iPhone's timing port: %u\n", g_iphone_timing_port);
            }

            /* Extract iPhone's IP from socket peer address */
            g_rtsp_sock = sock;
            struct sockaddr_storage peerAddr;
            socklen_t peerLen = sizeof(peerAddr);
            if (getpeername(sock, (struct sockaddr *)&peerAddr, &peerLen) == 0) {
                char host[NI_MAXHOST] = {0};
                char serv[NI_MAXSERV] = {0};
                sockaddr_to_numeric((struct sockaddr *)&peerAddr, peerLen,
                                    host, sizeof(host), serv, sizeof(serv));
                /* Strip ::ffff: prefix for IPv4-mapped IPv6 */
                const char *ip = host;
                g_iphone_family = peerAddr.ss_family;
                if (peerAddr.ss_family == AF_INET6) {
                    const struct sockaddr_in6 *peer6 =
                        (const struct sockaddr_in6 *)&peerAddr;
                    if (IN6_IS_ADDR_V4MAPPED(&peer6->sin6_addr)) {
                        ip += strncmp(ip, "::ffff:", 7) == 0 ? 7 : 0;
                        g_iphone_family = AF_INET;
                    }
                }
                snprintf(g_iphone_ip, sizeof(g_iphone_ip), "%s", ip);
                printf("[AP] iPhone IP: %s (socketFamily=%s "
                       "screenFamily=%s peer_port=%s)\n",
                       g_iphone_ip, addr_family_name(peerAddr.ss_family),
                       addr_family_name(g_iphone_family), serv);
            }

            /* Allocate control ports if not already done */
            if (!g_session_active) {
                if (g_timing_fd < 0)
                    g_timing_fd = bind_udp_port(&g_timing_port);
                if (g_event_fd < 0)
                    g_event_fd = bind_tcp_port(&g_event_port);
                if (g_keepalive_fd < 0)
                    g_keepalive_fd = bind_udp_port(&g_keepalive_port);
                g_session_active = true;

                /* Start background threads for timing, event, keepalive */
                start_timing_thread();
                start_event_thread();
                start_keepalive_thread();
            }

            respDict[@"timingPort"] = @(g_timing_port);
            respDict[@"eventPort"]  = @(g_event_port);

            /* Enable only explicitly implemented features the sender proposed. */
            NSArray *requestedFeatures = reqDict[@"features"];
            if ([requestedFeatures isKindOfClass:[NSArray class]]) {
                NSMutableArray *enabled = [NSMutableArray array];
                if (g_receiver_audio && [requestedFeatures containsObject:@"mainBuffered"]) {
                    [enabled addObject:@"mainBuffered"];
                    printf("[AUDIO] enabled session feature: mainBuffered\n");
                }
                if (SHOWCASE_VIDEO_IN_CAR_BENCH && control_is_encrypted(sock) &&
                    [requestedFeatures containsObject:@"videoPlayback"]) {
                    [enabled addObject:@"videoPlayback"];
                    enableCarVideo = true;
                    printf("[CAR-VIDEO] enabled session feature: videoPlayback\n");
                }
                if (enabled.count) respDict[@"enabledFeatures"] = enabled;
            }

            /* iPhone sent keepAliveLowPower=1 */
            if ([plist_number(reqDict[@"keepAliveLowPower"]) boolValue]) {
                respDict[@"keepAlivePort"] = @(g_keepalive_port);
            }

            printf("[AP] SETUP response: timingPort=%u eventPort=%u keepAlivePort=%u (dual-stack when available)\n",
                   g_timing_port, g_event_port, g_keepalive_port);
            app_send_status(STATUS_SESSION_SETUP);

        } else {
            /* ── Phase 2: Stream setup ── */
            printf("[AP] SETUP: stream setup (%lu streams)\n", (unsigned long)[streams count]);

            NSMutableArray *respStreams = [NSMutableArray array];

            for (NSDictionary *stream in streams) {
                if (![stream isKindOfClass:[NSDictionary class]]) continue;
                NSNumber *typeNum = stream[@"type"];
                if (![typeNum isKindOfClass:[NSNumber class]]) continue;
                int type = [typeNum intValue];
                printf("[AP] SETUP stream type=%d\n", type);

                if (type == 130 && atomic_load(&g_car_video_negotiated)) {
                    NSDictionary *response = car_video_setup_stream(stream);
                    if (response) {
                        [respStreams addObject:response];
                        continue;
                    }
                }

                NSMutableDictionary *rs = [NSMutableDictionary dictionary];
                rs[@"type"] = typeNum;

                uint16_t dataPort = 0;
                int dataFd = -1;

                /* Screen is H.264/TCP. CarPlay audio types 100/101/102 are
                 * encrypted RTP/UDP and are handled by dedicated receivers. */
                if (type == 110) {
                    screen_stream_stop("replaced by a new SETUP");
                    dataFd = bind_screen_tcp_port(&dataPort, g_iphone_family);
                    printf("[NET] screen/video dataPort=%u fd=%d family=%s\n",
                           dataPort, dataFd,
                           addr_family_name(socket_bound_family(dataFd)));

                    NSNumber *latency = plist_number(stream[@"latencyMs"]);
                    if (latency) {
                        uint32_t requestedLatency =
                            (uint32_t)[latency unsignedIntValue];
                        if (requestedLatency >= 20 &&
                            requestedLatency <= 500) {
                            g_screen_latency_ms = requestedLatency;
                        }
                    }
                    printf("[AP] Screen target latency: %u ms\n",
                           g_screen_latency_ms);
                    app_send_video_timing();

                    /* Save screen stream state for screen thread */
                    pthread_mutex_lock(&g_screen_lock);
                    g_screen_listen_fd = dataFd;
                    pthread_mutex_unlock(&g_screen_lock);
                    g_screen_data_port = dataPort;

                    /* Get streamConnectionID for key derivation */
                    NSNumber *connID = plist_number(stream[@"streamConnectionID"]);
                    if (connID) {
                        g_screen_conn_id = [connID unsignedLongLongValue];
                        printf("[AP] Screen streamConnectionID: %llu\n", g_screen_conn_id);

                        /* Derive ChaCha20-Poly1305 key via pair context */
                        pthread_mutex_lock(&g_pair_lock);
                        int derived = pair_derive_stream_key(
                            g_pair, g_screen_conn_id, g_screen_key);
                        pthread_mutex_unlock(&g_pair_lock);
                        if (derived == 0) {
                            g_screen_key_valid = true;
                            printf("[AP] Screen decryption key ready\n");
                        }
                    }

                    /* Start screen receiver thread */
                    start_screen_thread();
                    app_send_status(STATUS_STREAM_SETUP);
                } else if (type == 100 || type == 101 ||
                           type == 102 || type == 103) {
                    printf("[AUDIO] SETUP requested type=%d (%s)\n", type,
                           type == 103 ? "MainBuffered" :
                           type == 102 ? "MainHigh" :
                           type == 101 ? "Alt" : "Main");
                    /* Apple's MainBuffered receiver opens a TCP server. Its
                     * SETUP response also advertises the 8 MiB buffer used for
                     * the prefetched media stream. Types 100-102 remain UDP. */
                    bool bufferedTCP = type == 103;
                    carplay_audio_stream_t *audio =
                        audio_stream_for_type((uint32_t)type);
                    if (audio) {
                        stop_audio_receiver(
                            audio, "replaced by a new SETUP");
                    }
                    dataFd = bufferedTCP
                        ? bind_tcp_port(&dataPort)
                        : bind_udp_port(&dataPort);
                    if (audio && dataFd >= 0) {
                        audio->dataFd = dataFd;
                        audio->dataPort = dataPort;
                        audio->usesTCP = bufferedTCP;
                        audio->packetCount = 0;
                        audio->decryptErrors = 0;
                        audio->sequenceGaps = 0;
                        audio->lastArrivalNanos = 0;
                        audio->maxArrivalGapNanos = 0;
                        audio->longArrivalGaps = 0;
                        audio->haveSequence = false;
                        audio_replay_reset(audio);
                        audio->rejectedSenderCount = 0;
                        pthread_mutex_lock(&g_audio_control_lock);
                        audio->flushPending = false;
                        audio->flushUntilSequence = 0;
                        audio->flushUntilTimestamp = 0;
                        audio->flushDropCount = 0;
                        audio->deferredFlushPending = false;
                        audio->deferredFlushChecked = false;
                        audio->deferredFlushDropCount = 0;
                        pthread_mutex_unlock(&g_audio_control_lock);
                        pthread_mutex_lock(&g_audio_feedback_lock);
                        audio->renderedSampleTime = 0;
                        audio->renderedHostNTP = 0;
                        audio->renderedHostRawNanos = 0;
                        audio->renderUpdateCount = 0;
                        pthread_mutex_unlock(&g_audio_feedback_lock);

                        NSNumber *connectionID =
                            plist_number(stream[@"streamConnectionID"]);
                        audio->connectionID = connectionID
                            ? connectionID.unsignedLongLongValue : 0;
                        NSNumber *format = plist_number(stream[@"audioFormat"]);
                        if (format) {
                            audio->formatMask =
                                format.unsignedLongLongValue;
                        } else {
                            /* SDK fallback: uncompressed stereo output. */
                            audio->formatMask = 0x00008000ULL;
                        }
                        NSNumber *samplesPerFrame = plist_number(stream[@"spf"]);
                        audio->framesPerPacket = samplesPerFrame
                            ? samplesPerFrame.unsignedIntValue
                            : audio_default_frames_per_packet(
                                  audio->formatMask);
                        NSNumber *audioLatency = plist_number(stream[@"audioLatencyMs"]);
                        audio->latencyMs = audioLatency
                            ? audioLatency.unsignedIntValue : 100;
                        /* MainBuffered carries its own 32-byte key in the
                         * SETUP body ("shk") rather than having one derived
                         * from the stream connection ID, which is how the
                         * screen and the low-latency audio types work. Observed
                         * directly in Apple's receiver log. */
                        audio->keyValid = false;
                        NSData *sharedKey = stream[@"shk"];
                        if ([sharedKey isKindOfClass:[NSData class]] &&
                            sharedKey.length == sizeof(audio->key)) {
                            memcpy(audio->key, sharedKey.bytes,
                                   sizeof(audio->key));
                            audio->keyValid = true;
                            printf("[AUDIO] stream=%d key supplied in SETUP "
                                   "(shk, %u bytes)\n", type,
                                   (unsigned)sharedKey.length);
                        } else if (audio->connectionID) {
                            pthread_mutex_lock(&g_pair_lock);
                            int derived = pair_derive_stream_key(
                                g_pair, audio->connectionID, audio->key);
                            pthread_mutex_unlock(&g_pair_lock);
                            if (derived == 0) {
                                audio->keyValid = true;
                                printf("[AUDIO] stream=%d key derived from "
                                       "connID\n", type);
                            }
                        }

                        /* Recorded for the renderer and for diagnosis: the
                         * compression type and mode select the decoder, and
                         * clientID identifies which app is playing. */
                        NSNumber *compression = plist_number(stream[@"ct"]);
                        NSString *audioMode = plist_string(stream[@"audioMode"]);
                        NSString *audioTypeStr = plist_string(stream[@"audioType"]);
                        NSString *clientID = plist_string(stream[@"clientID"]);
                        printf("[AUDIO] stream=%d ct=%s mode=%s audioType=%s "
                               "client=%s formatIndex=%s\n", type,
                               compression ? compression.stringValue.UTF8String : "-",
                               audioMode ? audioMode.UTF8String : "-",
                               audioTypeStr ? audioTypeStr.UTF8String : "-",
                               clientID ? clientID.UTF8String : "-",
                               plist_number(stream[@"audioFormatIndex"])
                                   ? [plist_number(stream[@"audioFormatIndex"]) stringValue].UTF8String
                                   : "-");
                        if (audio->connectionID)
                            rs[@"streamConnectionID"] =
                                @(audio->connectionID);

                        /* MainHigh uses a companion RTCP port. MainBuffered
                         * carries its records over TCP and has no controlPort
                         * in Apple's SETUP response. */
                        if (type == 102) {
                            uint16_t controlPort = 0;
                            int controlFd =
                                bind_udp_port(&controlPort);
                            audio->controlFd = controlFd;
                            audio->controlPort = controlPort;
                            if (controlFd >= 0)
                                rs[@"controlPort"] = @(controlPort);
                        }
                        if (type == 103)
                            rs[@"audioBufferSize"] = @(8 * 1024 * 1024);
                        printf("[NET] audio stream=%d %s dataPort=%u fd=%d "
                               "controlPort=%u format=0x%llx spf=%u "
                               "latency=%ums connID=%llu key=%d\n",
                               type, bufferedTCP ? "TCP" : "UDP",
                               dataPort, dataFd,
                               audio->controlPort,
                               (unsigned long long)audio->formatMask,
                               audio->framesPerPacket, audio->latencyMs,
                               (unsigned long long)audio->connectionID,
                               audio->keyValid ? 1 : 0);
                        start_audio_receiver(audio);
                    }
                } else {
                    dataFd = bind_udp_port(&dataPort);
                    printf("[NET] auxiliary stream=%d UDP dataPort=%u fd=%d\n",
                           type, dataPort, dataFd);
                }
                rs[@"dataPort"] = @(dataPort);

                /* Unknown auxiliary streams retain the legacy control port.
                 * Known audio streams above use the per-type SDK contract. */
                if (type != 110 && type != 100 && type != 101 &&
                    type != 102 && type != 103) {
                    uint16_t ctrlPort = 0;
                    int ctrlFd = bind_udp_port(&ctrlPort);
                    rs[@"controlPort"] = @(ctrlPort);
                    /* Keep control fd alive until this stream is torn down */
                    if (ctrlFd >= 0) {
                        printf("[AP] SETUP stream type=%d controlPort=%u (fd=%d, kept open, dual-stack when available)\n",
                               type, ctrlPort, ctrlFd);
                    }
                    aux_stream_remember(type, dataFd, ctrlFd);
                }

                printf("[AP] SETUP stream type=%d → dataPort=%u (fd=%d, kept open)\n",
                       type, dataPort, dataFd);
                [respStreams addObject:rs];
                /* DO NOT close dataFd — iPhone will connect/send data to it */
            }

            respDict[@"streams"] = respStreams;
        }

        /* Serialize response plist */
        NSError *err = nil;
        NSData *plistData = [NSPropertyListSerialization
            dataWithPropertyList:respDict
            format:NSPropertyListBinaryFormat_v1_0
            options:0 error:&err];

        if (plistData) {
            printf("[AP] SETUP response plist (%zu bytes): %s\n",
                   plistData.length, [[respDict description] UTF8String]);
            send_response(sock, "RTSP/1.0", 200, "OK",
                         "application/x-apple-binary-plist",
                         (const uint8_t *)plistData.bytes, plistData.length, r->cseq);
            if (enableCarVideo) {
                atomic_store(&g_car_video_negotiated, true);
                send_car_video_availability();
            }
        } else {
            printf("[AP] SETUP plist serialization error: %s\n",
                   [[err description] UTF8String]);
            send_response(sock, "RTSP/1.0", 500, "Internal Server Error",
                         NULL, NULL, 0, r->cseq);
        }
    }
}

/* ═══════════════════════════════════════════════════════════════
 * Endpoint: RTSP RECORD / TEARDOWN / FLUSH / other
 * ═══════════════════════════════════════════════════════════════ */

static bool g_recording = false;

static void handle_record(int sock, const HTTPReq *r) {
    printf("[AP] -> RECORD (CSeq=%d)\n", r->cseq);

    if (!g_session_active) {
        printf("[AP] RECORD received before SETUP — rejecting\n");
        send_response(sock, "RTSP/1.0", 403, "Forbidden",
                     NULL, NULL, 0, r->cseq);
        return;
    }

    g_recording = true;

    /* Ensure background threads are running */
    start_timing_thread();
    start_event_thread();
    start_keepalive_thread();

    printf("[AP] RECORD: Starting session — timing negotiation first...\n");
    fflush(stdout);

    /* ── CRITICAL: Timing negotiation MUST complete BEFORE sending 200 OK ──
     * The reference (AirPlayReceiverSession.c) calls AirPlayReceiverSessionStart()
     * which blocks on _TimingNegotiate() before returning. The iPhone expects
     * timing to be synchronized by the time it receives RECORD 200 OK.
     * If we send 200 OK before timing is done, iPhone tears down immediately. */
    bool timingOK = timing_negotiate_blocking();

    printf("[AP] ╔══════════════════════════════════════╗\n");
    printf("[AP] ║  RECORD — Session is LIVE            ║\n");
    printf("[AP] ║  Timing:%u Event:%u KeepAlive:%u     ║\n",
           g_timing_port, g_event_port, g_keepalive_port);
    printf("[AP] ║  iPhone timing port: %u              ║\n",
           g_iphone_timing_port);
    printf("[AP] ║  Timing sync: %s (%d responses)    ║\n",
           timingOK ? "YES" : "NO", g_timing_sync_count);
    printf("[AP] ╚══════════════════════════════════════╝\n");
    fflush(stdout);

    send_response(sock, "RTSP/1.0", 200, "OK", NULL, NULL, 0, r->cseq);

    /* Ask the phone for the first UI frame. The same command is reused after
     * foregrounding so the decoder can restart from a clean keyframe. */
    send_request_ui_command("record started");
}

static void handle_teardown(int sock, const HTTPReq *r) {
    printf("[AP] -> TEARDOWN (CSeq=%d, bodyLen=%zu)\n", r->cseq, r->bodyLen);

    bool hadStreamTargets = false;
    if (r->body && r->bodyLen > 0) {
        @autoreleasepool {
            id obj = network_plist_parse(r->body, r->bodyLen,
                                         NETWORK_PLIST_MAX_DEPTH);
            if (obj) {
                if ([obj isKindOfClass:[NSDictionary class]]) {
                    NSArray *streams = obj[@"streams"];
                    if ([streams isKindOfClass:[NSArray class]] &&
                        streams.count > 0) {
                        hadStreamTargets = true;
                        for (id entry in streams) {
                            if (![entry isKindOfClass:
                                    [NSDictionary class]]) continue;
                            NSNumber *type = entry[@"type"];
                            if (![type isKindOfClass:[NSNumber class]]) continue;
                            if (type.intValue == 110) {
                                screen_stream_stop("sender stream TEARDOWN");
                                continue;
                            }
                            if (type.intValue == 130 && atomic_load(&g_car_video_negotiated)) {
                                NSNumber *streamID = entry[@"streamID"];
                                if ([streamID isKindOfClass:[NSNumber class]] &&
                                    streamID.unsignedIntValue >= 2)
                                    car_video_close_stream(streamID.unsignedIntValue);
                                continue;
                            }
                            carplay_audio_stream_t *audio =
                                audio_stream_for_type(
                                    type.unsignedIntValue);
                            if (audio)
                                stop_audio_receiver(
                                    audio, "sender stream TEARDOWN");
                            else
                                aux_stream_close(type.intValue, false);
                        }
                    }
                }
            }
        }
    }

    if (!hadStreamTargets) {
        if (atomic_exchange(&g_car_video_negotiated, false)) {
            @autoreleasepool { car_video_close_stream(0); }
        }
        g_recording = false;
        __sync_add_and_fetch(&g_timing_maintenance_generation, 1);
        for (size_t index = 0;
             index < sizeof(g_audio_streams) /
                     sizeof(g_audio_streams[0]);
             index++) {
            stop_audio_receiver(
                &g_audio_streams[index], "full session TEARDOWN");
        }
        aux_stream_close(0, true);
    }

    send_response(sock, "RTSP/1.0", 200, "OK", NULL, NULL, 0, r->cseq);
    printf("[AP] %s torn down.\n",
           hadStreamTargets ? "Requested stream(s)" : "Session");
    fflush(stdout);
}

static void handle_setrate(int sock, const HTTPReq *r) {
    @autoreleasepool {
        NSDictionary *request = nil;
        if (r->body && r->bodyLen > 0) {
            id object = network_plist_parse(r->body, r->bodyLen,
                                         NETWORK_PLIST_MAX_DEPTH);
            if ([object isKindOfClass:[NSDictionary class]])
                request = object;
        }

        NSNumber *rtpTime = plist_number(request[@"rtpTime"]);
        NSNumber *rate = plist_number(request[@"rate"]);
        if (!rtpTime || !rate) {
            printf("[AUDIO] SETRATE missing rtpTime/rate\n");
            send_response(sock, "RTSP/1.0", 400, "Bad Request",
                          NULL, NULL, 0, r->cseq);
            return;
        }

        /*
         * MainBuffered uses SETRATE as its playback anchor. Apple's receiver
         * returns the requested RTP position together with the accessory's
         * current synchronized network time, then applies that same anchor
         * locally. The network-time seconds in this plist omit the NTP epoch
         * bias used on the UDP timing wire.
         */
        uint64_t synchronizedNTP =
            synchronized_ntp_for_host_ticks(mach_absolute_time(), NULL);
        uint32_t ntpSeconds = (uint32_t)(synchronizedNTP >> 32);
        uint32_t ntpFraction = (uint32_t)synchronizedNTP;
        uint32_t networkSeconds = ntpSeconds - NTP_EPOCH_OFFSET;
        NSDictionary *response = @{
            @"networkTimeFlags": @0,
            @"networkTimeTimelineID": @0,
            @"networkTimeSecs": @(networkSeconds),
            @"networkTimeFrac": @(ntpFraction),
            @"rtpTime": rtpTime,
            @"rate": rate
        };
        NSData *body = [NSPropertyListSerialization
            dataWithPropertyList:response
                          format:NSPropertyListBinaryFormat_v1_0
                         options:0
                           error:NULL];
        printf("[AUDIO] SETRATE rate=%s rtpTime=%s anchor=%u.%u\n",
               rate.stringValue.UTF8String,
               rtpTime.stringValue.UTF8String,
               networkSeconds, ntpFraction);
        send_response(sock, "RTSP/1.0", 200, "OK",
                      "application/x-apple-binary-plist",
                      body.bytes, body.length, r->cseq);
        app_send_audio_control(103, rate.doubleValue == 0.0
                                    ? AUDIO_CONTROL_PAUSE
                                    : AUDIO_CONTROL_RESUME);
    }
}

static void handle_setrate_anchor_time(int sock, const HTTPReq *r) {
    @autoreleasepool {
        NSDictionary *request = nil;
        if (r->body && r->bodyLen > 0) {
            id object = network_plist_parse(r->body, r->bodyLen,
                                         NETWORK_PLIST_MAX_DEPTH);
            if ([object isKindOfClass:[NSDictionary class]])
                request = object;
        }

        NSNumber *rate = plist_number(request[@"rate"]);
        if (!rate) {
            printf("[AUDIO] SETRATEANCHORTIME missing rate\n");
            send_response(sock, "RTSP/1.0", 400, "Bad Request",
                          NULL, NULL, 0, r->cseq);
            return;
        }

        bool paused = rate.doubleValue == 0.0;
        printf("[AUDIO] SETRATEANCHORTIME rate=%s -> %s\n",
               rate.stringValue.UTF8String,
               paused ? "pause" : "resume");
        app_send_audio_control(103, paused
                                    ? AUDIO_CONTROL_PAUSE
                                    : AUDIO_CONTROL_RESUME);
        send_response(sock, "RTSP/1.0", 200, "OK",
                      NULL, NULL, 0, r->cseq);
    }
}

typedef struct {
    carplay_audio_stream_t *stream;
    uint16_t untilSequence;
    uint32_t untilTimestamp;
    bool applied;
} audio_flush_request_t;

/* app_send_guard_fn for FLUSHBUFFERED: starts the new flush epoch. */
static bool audio_flush_apply(void *context) {
    audio_flush_request_t *flush = context;
    flush->applied = true;
    carplay_audio_stream_t *audio = flush->stream;
    if (!audio) return true;
    pthread_mutex_lock(&g_audio_control_lock);
    audio->flushPending = true;
    audio->flushUntilSequence = flush->untilSequence;
    audio->flushUntilTimestamp = flush->untilTimestamp;
    audio->flushDropCount = 0;
    /* An immediate flush supersedes any deferred one. */
    audio->deferredFlushPending = false;
    audio->flushEpoch++;
    pthread_mutex_unlock(&g_audio_control_lock);
    return true;
}

/* Immediate flush: resets the app's AudioQueue and drops the old epoch
 * until untilSequence/untilTimestamp. Callable from the RTSP handler and the
 * audio receiver thread. */
static void audio_flush_app_until(carplay_audio_stream_t *audio,
                                  uint16_t untilSequence,
                                  uint32_t untilTimestamp) {
    audio_flush_request_t flush = {
        .stream = audio,
        .untilSequence = untilSequence,
        .untilTimestamp = untilTimestamp,
        .applied = false,
    };
    if (audio) {
        /* Old render coordinates no longer describe the media epoch. */
        pthread_mutex_lock(&g_audio_feedback_lock);
        audio->renderedSampleTime = 0;
        audio->renderedHostNTP = 0;
        audio->renderedHostRawNanos = 0;
        audio->renderUpdateCount = 0;
        pthread_mutex_unlock(&g_audio_feedback_lock);
    }

    /* The new boundary and epoch are published under g_app_send_lock,
     * in the same critical section that writes the FLUSH, so every
     * audio packet the app receives is ordered against its reset. */
    uint8_t payload[5] = {0};
    uint32_t streamType = 103;
    memcpy(payload, &streamType, 4);
    payload[4] = AUDIO_CONTROL_FLUSH;
    bool sent = app_send_msg_guarded(MSG_AUDIO_CONTROL, payload,
                                     sizeof(payload),
                                     audio_flush_apply, &flush);
    /* If the send lock timed out the FLUSH never reached the app, but
     * the stale epoch must still be dropped from now on. */
    if (!flush.applied) audio_flush_apply(&flush);
    printf("[AUDIO] control stream=%u action=%u app=%s\n",
           streamType, (unsigned)AUDIO_CONTROL_FLUSH,
           sent ? "sent" : "failed");
}

static void handle_flush_buffered(int sock, const HTTPReq *r) {
    @autoreleasepool {
        NSDictionary *request = nil;
        if (r->body && r->bodyLen > 0) {
            id object = network_plist_parse(r->body, r->bodyLen,
                                         NETWORK_PLIST_MAX_DEPTH);
            if ([object isKindOfClass:[NSDictionary class]])
                request = object;
        }

        NSNumber *flushUntilSeq = plist_number(request[@"flushUntilSeq"]);
        NSNumber *flushUntilTS = plist_number(request[@"flushUntilTS"]);
        if (!flushUntilSeq || !flushUntilTS) {
            printf("[AUDIO] FLUSHBUFFERED missing sequence/timestamp\n");
            send_response(sock, "RTSP/1.0", 400, "Bad Request",
                          NULL, NULL, 0, r->cseq);
            return;
        }
        /* Optional: a deferred flush that starts at a future packet. */
        NSNumber *flushFromSeq = plist_number(request[@"flushFromSeq"]);
        NSNumber *flushFromTS = plist_number(request[@"flushFromTS"]);

        carplay_audio_stream_t *audio = audio_stream_for_type(103);
        uint64_t extendedSequence =
            flushUntilSeq.unsignedLongLongValue;
        uint32_t timestamp = flushUntilTS.unsignedIntValue;
        uint16_t untilSequence = (uint16_t)(extendedSequence & 0xffff);

        if (flushFromSeq) {
            uint64_t extendedFrom = flushFromSeq.unsignedLongLongValue;
            uint16_t fromSequence = (uint16_t)(extendedFrom & 0xffff);
            printf("[AUDIO] FLUSHBUFFERED fromSeq=%llu (rtp=%u) fromTS=%s "
                   "untilSeq=%llu (rtp=%u) untilTS=%u\n",
                   (unsigned long long)extendedFrom, (unsigned)fromSequence,
                   flushFromTS ? flushFromTS.stringValue.UTF8String : "-",
                   (unsigned long long)extendedSequence,
                   (unsigned)untilSequence, timestamp);
            /* A range that does not run forward has nothing to defer;
             * treat it as the immediate flush below. */
            if ((int16_t)(untilSequence - fromSequence) > 0) {
                if (audio) {
                    /* Packets before "from" keep playing and the app's
                     * queue is not reset; the receiver drops
                     * [from, until) as it arrives. */
                    pthread_mutex_lock(&g_audio_control_lock);
                    audio->deferredFlushPending = true;
                    audio->deferredFlushChecked = false;
                    audio->deferredFlushFromSequence = fromSequence;
                    audio->deferredFlushUntilSequence = untilSequence;
                    audio->deferredFlushUntilTimestamp = timestamp;
                    audio->deferredFlushDropCount = 0;
                    pthread_mutex_unlock(&g_audio_control_lock);
                }
                send_response(sock, "RTSP/1.0", 200, "OK",
                              NULL, NULL, 0, r->cseq);
                return;
            }
        } else {
            printf("[AUDIO] FLUSHBUFFERED untilSeq=%llu (rtp=%u) "
                   "untilTS=%u\n",
                   (unsigned long long)extendedSequence,
                   (unsigned)untilSequence, timestamp);
        }
        audio_flush_app_until(audio, untilSequence, timestamp);
        send_response(sock, "RTSP/1.0", 200, "OK",
                      NULL, NULL, 0, r->cseq);
    }
}

static void handle_rtsp_generic(int sock, const HTTPReq *r) {
    printf("[AP] -> %s %s (CSeq=%d, bodyLen=%zu)\n",
           r->method, r->path, r->cseq, r->bodyLen);

    const char *proto = strncmp(r->protocol, "RTSP", 4) == 0 ?
                        "RTSP/1.0" : "HTTP/1.1";
    send_response(sock, proto, 200, "OK", NULL, NULL, 0, r->cseq);
}

/* ═══════════════════════════════════════════════════════════════
 * Endpoint: POST /command, /feedback
 * ═══════════════════════════════════════════════════════════════ */

static void handle_command_dictionary(NSDictionary *command, bool authenticated) {
    NSString *type = command[@"type"];
    if (![type isKindOfClass:[NSString class]]) return;

    if ([type isEqualToString:@"modesChanged"]) {
        NSDictionary *params = command[@"params"];
        if ([params isKindOfClass:[NSDictionary class]]) {
            /* Log the local value: this runs on both the event-channel and
             * per-connection control threads, so an unlocked global strong
             * store here raced (double release / use-after-free). */
            printf("[CONTROL] modesChanged state updated: %s\n",
                   params.description.UTF8String);
        }
    } else if ([type isEqualToString:@"requestUI"]) {
        NSDictionary *params = command[@"params"];
        if (params && ![params isKindOfClass:[NSDictionary class]]) return;
        id url = params[@"url"];
        if ([url isEqual:@"videoplayback:"]) {
            if (atomic_load(&g_car_video_negotiated)) car_video_request_ui();
        } else if (SHOWCASE_MIRROR_BENCH && authenticated &&
                   (!url || [url isEqual:@""])) {
            app_send_status(STATUS_HOST_UI_REQUESTED);
        }
    } else if ([type isEqualToString:@"disableBluetooth"]) {
        /* Tears down the Bluetooth helper: only the pair-verified iPhone
         * may ask for it. */
        if (!authenticated) {
            printf("[HANDOFF] ignoring unauthenticated disableBluetooth\n");
            return;
        }
        /* The iPhone asks only once, so the request stays pending until
         * it reaches the app (retried before the next IPC message or on the
         * next app connection). */
        g_app_bt_handoff_pending = true;
        app_deliver_pending(MSG_BT_HANDOFF);
        printf("[HANDOFF] disableBluetooth honored; app teardown request %s\n",
               g_app_bt_handoff_pending ? "pending (will retry)" : "sent");
    } else if ([type isEqualToString:@"duckAudio"] ||
               [type isEqualToString:@"unduckAudio"]) {
        printf("[CONTROL] %s received\n", type.UTF8String);
    } else if ([type isEqualToString:@"forceKeyFrame"]) {
        printf("[CONTROL] forceKeyFrame received\n");
    } else {
        printf("[CONTROL] unhandled command type=%s\n", type.UTF8String);
    }
}

static bool process_event_command_frame(const uint8_t *bytes, size_t length) {
    HTTPReq request;
    if (!parse_http(bytes, length, &request) ||
        strcasecmp(request.method, "POST") != 0 ||
        !strstr(request.path, "/command") ||
        request.bodyLen < request.contentLength) return false;

    @autoreleasepool {
        id object = network_plist_parse(request.body, request.bodyLen,
                                        NETWORK_PLIST_MAX_DEPTH);
        if ([object isKindOfClass:[NSDictionary class]]) {
            if (request.appleStreamID)
                car_video_forward_command(request.appleStreamID, object);
            else
                handle_command_dictionary(object, true);
        }
    }

    char response[160];
    int responseLength = snprintf(
        response, sizeof(response),
        "RTSP/1.0 200 OK\r\nContent-Length: 0\r\nCSeq: %d\r\n\r\n",
        request.cseq);
    if (g_event_send_lock)
        dispatch_semaphore_wait(g_event_send_lock, DISPATCH_TIME_FOREVER);
    int result = enc_send_frame(g_event_client_fd, &g_event_enc,
                                (const uint8_t *)response,
                                (size_t)responseLength);
    if (g_event_send_lock) dispatch_semaphore_signal(g_event_send_lock);
    printf("[EVENT] command response %s CSeq=%d\n",
           result == 0 ? "sent" : "failed", request.cseq);
    return true;
}

static void handle_feedback(int sock, const HTTPReq *request) {
    @autoreleasepool {
        NSMutableArray *streams = [NSMutableArray array];
        for (size_t index = 0;
             index < sizeof(g_audio_streams) / sizeof(g_audio_streams[0]);
             index++) {
            carplay_audio_stream_t *audio = &g_audio_streams[index];
            if (audio->dataFd < 0 || audio->formatMask == 0) continue;

            NSMutableDictionary *stream = [NSMutableDictionary dictionary];
            stream[@"type"] = @(audio->type);
            double rate = audio_sample_rate(audio->formatMask);
            if (rate > 0) stream[@"sampleRate"] = @(rate);
            int64_t renderedSampleTime = 0;
            uint64_t renderedHostNTP = 0;
            uint64_t renderedHostRawNanos = 0;
            uint64_t renderUpdateCount = 0;
            pthread_mutex_lock(&g_audio_feedback_lock);
            renderedSampleTime = audio->renderedSampleTime;
            renderedHostNTP = audio->renderedHostNTP;
            renderedHostRawNanos = audio->renderedHostRawNanos;
            renderUpdateCount = audio->renderUpdateCount;
            pthread_mutex_unlock(&g_audio_feedback_lock);
            if (renderUpdateCount > 0 && renderedHostNTP != 0) {
                stream[@"streamConnectionID"] = @(audio->connectionID);
                stream[@"timestamp"] = @(renderedHostNTP);
                stream[@"timestampRawNs"] = @(renderedHostRawNanos);
                stream[@"sampleTime"] = @(renderedSampleTime);
            }
            [streams addObject:stream];
        }

        NSDictionary *feedback = @{ @"streams": streams };
        NSError *error = nil;
        NSData *body = [NSPropertyListSerialization
            dataWithPropertyList:feedback
                          format:NSPropertyListBinaryFormat_v1_0
                         options:0
                           error:&error];
        printf("[AUDIO] feedback streams=%lu render=%s%s\n",
               (unsigned long)streams.count,
               streams.count > 0 &&
                       [streams[0][@"sampleTime"] isKindOfClass:
                           [NSNumber class]] ? "valid" : "pending",
               error ? " serialization-error" : "");
        bool rtsp = strncmp(request->protocol, "RTSP", 4) == 0;
        send_response(sock, rtsp ? "RTSP/1.0" : "HTTP/1.1",
                      error ? 500 : 200, error ? "Error" : "OK",
                      "application/x-apple-binary-plist",
                      body.bytes, body.length, request->cseq);
    }
}

static bool request_path_is(const char *target, const char *expected);

static void handle_post_generic(int sock, const HTTPReq *r) {
    printf("[AP] -> POST %s (bodyLen=%zu, ct=%s)\n",
           r->path, r->bodyLen,
           r->contentType[0] ? r->contentType : "none");

    if (r->body && r->bodyLen > 0) {
        /* Try binary plist */
        @autoreleasepool {
            id obj = network_plist_parse(r->body, r->bodyLen,
                                         NETWORK_PLIST_MAX_DEPTH);
            /* Commands change session state and are accepted only on the
             * pair-verified, encrypted control channel. */
            if (obj && request_path_is(r->path, "/command") &&
                [obj isKindOfClass:[NSDictionary class]] &&
                control_is_encrypted(sock)) {
                if (r->appleStreamID)
                    car_video_forward_command(r->appleStreamID, obj);
                else
                    handle_command_dictionary(obj, control_is_encrypted(sock));
            }
        }
    }

    bool rtsp = (strncmp(r->protocol, "RTSP", 4) == 0);
    const char *proto = rtsp ? "RTSP/1.0" : "HTTP/1.1";
    send_response(sock, proto, 200, "OK",
                 "application/x-apple-binary-plist", NULL, 0, r->cseq);
}

/* ═══════════════════════════════════════════════════════════════
 * Request Router
 * ═══════════════════════════════════════════════════════════════ */

static void route_request(int sock, const HTTPReq *r) {
    if (!t_quiet_request_log) {
        printf("\n[AP] ── %s %s %s ──\n", r->method, r->path, r->protocol);
        fflush(stdout);
    }

    if (strcasecmp(r->method, "GET") == 0) {
        if (request_path_is(r->path, "/info"))
            handle_info(sock, r);
        else {
            printf("[AP] -> GET %s (unknown)\n", r->path);
            send_ok(sock, r);
        }
    }
    else if (strcasecmp(r->method, "POST") == 0) {
        if (request_path_is(r->path, "/pair-setup"))
            handle_pair_setup(sock, r);
        else if (request_path_is(r->path, "/pair-verify"))
            handle_pair_verify(sock, r);
        else if (request_path_is(r->path, "/fp-setup"))
            handle_fp_setup(sock, r);
        else if (request_path_is(r->path, "/auth-setup"))
            handle_auth_setup(sock, r);
        else if (request_path_is(r->path, "/pair-pin-start")) {
            /* The PIN is fixed; there is nothing to start. Acknowledge it
             * without treating the body as anything else. */
            if (!t_quiet_request_log)
                printf("[AP] -> POST /pair-pin-start\n");
            send_response(sock, strncmp(r->protocol, "RTSP", 4) == 0
                                     ? "RTSP/1.0" : "HTTP/1.1",
                          200, "OK", "application/x-apple-binary-plist",
                          NULL, 0, r->cseq);
        }
        else if (request_path_is(r->path, "/feedback"))
            handle_feedback(sock, r);
        else
            handle_post_generic(sock, r);
    }
    else if (strcasecmp(r->method, "OPTIONS") == 0) {
        handle_options(sock, r);
    }
    else if (strcasecmp(r->method, "SETUP") == 0) {
        handle_rtsp_setup(sock, r);
    }
    else if (strcasecmp(r->method, "RECORD") == 0) {
        handle_record(sock, r);
    }
    else if (strcasecmp(r->method, "SETRATE") == 0) {
        handle_setrate(sock, r);
    }
    else if (strcasecmp(r->method, "SETRATEANCHORTIME") == 0) {
        handle_setrate_anchor_time(sock, r);
    }
    else if (strcasecmp(r->method, "FLUSHBUFFERED") == 0) {
        handle_flush_buffered(sock, r);
    }
    else if (strcasecmp(r->method, "TEARDOWN") == 0) {
        handle_teardown(sock, r);
    }
    else {
        /* FLUSH, ANNOUNCE, PAUSE, PUT, etc. */
        handle_rtsp_generic(sock, r);
    }
    fflush(stdout);
}

/* ═══════════════════════════════════════════════════════════════
 * TCP Listener — port 7000 with keep-alive
 * ═══════════════════════════════════════════════════════════════ */

static bool request_allowed_before_pair_verify(const HTTPReq *r);

/* True when the request target names exactly this path. An absolute
 * "rtsp://host" / "http://host" prefix and any query or fragment are
 * ignored, so "/command/pair-pin-start" is not "/pair-pin-start" and
 * "/pair-setup?x" is "/pair-setup". */
static bool request_path_is(const char *target, const char *expected) {
    const char *path = target;
    if (path[0] != '/') {
        const char *scheme = strstr(path, "://");
        if (!scheme) return false;
        path = strchr(scheme + 3, '/');
        if (!path) path = "/";
    }
    size_t length = strcspn(path, "?#");
    return length == strlen(expected) && strncmp(path, expected, length) == 0;
}

/* Requests an unauthenticated connection may make. Everything else mutates
 * session state (SETUP, RECORD, TEARDOWN, POST /command, ...) and requires the
 * pair-verified, encrypted control channel. */
static bool request_allowed_before_pair_verify(const HTTPReq *r) {
    if (strcasecmp(r->method, "OPTIONS") == 0) return true;
    if (strcasecmp(r->method, "GET") == 0)
        return request_path_is(r->path, "/info");
    if (strcasecmp(r->method, "POST") == 0)
        return request_path_is(r->path, "/pair-setup") ||
               request_path_is(r->path, "/pair-pin-start") ||
               request_path_is(r->path, "/pair-verify") ||
               request_path_is(r->path, "/auth-setup") ||
               request_path_is(r->path, "/fp-setup");
    return false;
}

/*
 * Log budget for requests that arrive before pair-verify. Any LAN host can
 * reach port 7000, reconnect freely and pipeline many small requests in one
 * read, so their log lines pass a per-connection budget and a process-wide
 * per-second budget. Suppressed lines are only counted and reported with the
 * next line that is allowed.
 */
#define PREAUTH_LOG_PER_CONNECTION 16
#define PREAUTH_LOG_PER_SECOND     20
static pthread_mutex_t g_preauth_log_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_preauth_log_second = 0;
static unsigned g_preauth_log_in_second = 0;
static unsigned long g_preauth_log_suppressed = 0;

static bool preauth_log_allowed(unsigned *connectionLines) {
    bool allowed = *connectionLines < PREAUTH_LOG_PER_CONNECTION;
    if (allowed) (*connectionLines)++;
    unsigned long reportSuppressed = 0;
    uint64_t second = control_monotonic_nanos() / CONTROL_NANOS_PER_SECOND;
    pthread_mutex_lock(&g_preauth_log_lock);
    if (second != g_preauth_log_second) {
        g_preauth_log_second = second;
        g_preauth_log_in_second = 0;
    }
    if (allowed && g_preauth_log_in_second >= PREAUTH_LOG_PER_SECOND)
        allowed = false;
    if (allowed) {
        g_preauth_log_in_second++;
        reportSuppressed = g_preauth_log_suppressed;
        g_preauth_log_suppressed = 0;
    } else if (g_preauth_log_suppressed < ULONG_MAX) {
        g_preauth_log_suppressed++;
    }
    pthread_mutex_unlock(&g_preauth_log_lock);
    if (reportSuppressed > 0)
        printf("[AP] Suppressed %lu log lines for requests before "
               "pair-verify\n", reportSuppressed);
    return allowed;
}

static void handle_client(int);
/* The iPhone uses one control connection plus short discovery probes. */
#define CONTROL_MAX_CLIENTS 6
/* Connections from one address that do not own the session. */
#define CONTROL_MAX_UNCLAIMED_PER_ADDRESS 2
/* Absolute lifetime of a connection that never claims the session, counted
 * from accept. Unlike SO_RCVTIMEO it is not renewed by traffic, so a peer
 * that trickles bytes or repeats GET /info cannot hold a slot. */
#define CONTROL_UNCLAIMED_DEADLINE_SECONDS 15
#define CONTROL_CLIENT_STACK_BYTES (512 * 1024)

typedef struct {
    bool used;
    int fd;
    uint64_t acceptedNanos;
    char host[NI_MAXHOST];
} control_client_slot_t;
static pthread_mutex_t g_control_clients_lock = PTHREAD_MUTEX_INITIALIZER;
static control_client_slot_t g_control_clients[CONTROL_MAX_CLIENTS];

/* Numeric peer address with an IPv4-mapped prefix removed, so IPv4 and
 * mapped connections from one host compare equal. */
static void control_peer_host(const struct sockaddr *sa, socklen_t length,
                              char *host, size_t hostLength) {
    char serv[NI_MAXSERV];
    host[0] = '\0';
    if (!sockaddr_to_numeric(sa, length, host, hostLength,
                             serv, sizeof(serv)))
        return;
    if (strncmp(host, "::ffff:", 7) == 0)
        memmove(host, host + 7, strlen(host + 7) + 1);
}

/* Drops a connection that does not own the session to make room. The slot is
 * released now; the handler thread sees EOF and exits. Called with
 * g_control_clients_lock and g_control_owner_lock held, so the victim cannot
 * have claimed the session since it was chosen, and its descriptor cannot
 * have been closed and reused yet (handlers leave the table before they
 * close). */
static void control_client_evict_locked(control_client_slot_t *slot,
                                        const char *why) {
    /* Any LAN host can force evictions by reconnecting in a loop, so this
     * line shares the process-wide pre-auth log budget. */
    unsigned evictLogLines = 0;
    if (preauth_log_allowed(&evictLogLines))
        printf("[AP] Dropping control connection fd=%d from %s (%s)\n",
               slot->fd, slot->host, why);
    shutdown(slot->fd, SHUT_RDWR);
    slot->used = false;
}

/* Admits a new control connection. The session owner is never displaced; a
 * full table or a busy address makes room by dropping the oldest connection
 * that does not own the session, preferring ones that are not from the
 * session iPhone. Returns false when no room can be made. */
static bool control_client_admit(int c, const char *host) {
    bool fromSessionIphone = g_iphone_ip[0] && strcmp(host, g_iphone_ip) == 0;
    uint64_t now = control_monotonic_nanos();
    pthread_mutex_lock(&g_control_clients_lock);
    /* Held until the evictions are done (lock order: clients, then owner;
     * control_claim takes only the owner lock), so a connection cannot claim
     * the session between the owner check and its shutdown. */
    pthread_mutex_lock(&g_control_owner_lock);
    int owner = g_control_owner;

    control_client_slot_t *oldestSameHost = NULL;
    size_t sameHost = 0;
    for (size_t i = 0; i < CONTROL_MAX_CLIENTS; i++) {
        control_client_slot_t *slot = &g_control_clients[i];
        if (!slot->used || slot->fd == owner || strcmp(slot->host, host) != 0)
            continue;
        sameHost++;
        if (!oldestSameHost ||
            slot->acceptedNanos < oldestSameHost->acceptedNanos)
            oldestSameHost = slot;
    }
    if (sameHost >= CONTROL_MAX_UNCLAIMED_PER_ADDRESS && oldestSameHost)
        control_client_evict_locked(oldestSameHost,
                                    "too many connections from one address");

    control_client_slot_t *room = NULL;
    control_client_slot_t *victim = NULL;
    control_client_slot_t *iphoneVictim = NULL;
    for (size_t i = 0; i < CONTROL_MAX_CLIENTS; i++) {
        control_client_slot_t *slot = &g_control_clients[i];
        if (!slot->used) {
            if (!room) room = slot;
            continue;
        }
        if (slot->fd == owner) continue;
        bool isIphone = g_iphone_ip[0] && strcmp(slot->host, g_iphone_ip) == 0;
        control_client_slot_t **pick = isIphone ? &iphoneVictim : &victim;
        if (!*pick || slot->acceptedNanos < (*pick)->acceptedNanos)
            *pick = slot;
    }
    if (!room) {
        if (!victim && fromSessionIphone) victim = iphoneVictim;
        if (victim) {
            control_client_evict_locked(victim, "connection table full");
            room = victim;
        }
    }
    if (room) {
        room->used = true;
        room->fd = c;
        room->acceptedNanos = now;
        snprintf(room->host, sizeof(room->host), "%s", host);
    }
    pthread_mutex_unlock(&g_control_owner_lock);
    pthread_mutex_unlock(&g_control_clients_lock);
    return room != NULL;
}

/* Must run before the descriptor is closed (see control_client_evict_locked). */
static void control_client_release(int c) {
    pthread_mutex_lock(&g_control_clients_lock);
    for (size_t i = 0; i < CONTROL_MAX_CLIENTS; i++) {
        if (g_control_clients[i].used && g_control_clients[i].fd == c)
            g_control_clients[i].used = false;
    }
    pthread_mutex_unlock(&g_control_clients_lock);
}

static void *control_client_thread(void *arg) {
    handle_client((int)(intptr_t)arg);
    return NULL;
}

static void handle_client(int c) {
    /* Room for one final encrypted record containing the end of a maximal
     * request and the beginning of the next pipelined request. */
    uint8_t buf[HTTP_STREAM_LIMIT + ENCRYPTED_MAX_READ_SIZE];
    size_t bufUsed = 0;
    http_progress_t progress = {0};
    bool infoLogged = false;
    unsigned preauthLogLines = 0;
    bool sessionConnection = false;

    struct timeval tv = { .tv_sec = CONTROL_IDLE_SECONDS_UNCLAIMED,
                          .tv_usec = 0 };
    setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    uint64_t unclaimedDeadline = control_monotonic_nanos() +
        (uint64_t)CONTROL_UNCLAIMED_DEADLINE_SECONDS *
            CONTROL_NANOS_PER_SECOND;

    /* TCP keepalive. An iPhone that leaves Wi-Fi never closes the
     * connection, so probe after 10 s of silence and give up after 3 misses.
     * The iPhone posts /feedback every 2 s while a session runs. */
    int yes = 1, idle = 10, interval = 3, count = 3;
    setsockopt(c, SOL_SOCKET, SO_KEEPALIVE, &yes, sizeof(yes));
    setsockopt(c, IPPROTO_TCP, TCP_KEEPALIVE, &idle, sizeof(idle));
    setsockopt(c, IPPROTO_TCP, TCP_KEEPINTVL, &interval, sizeof(interval));
    setsockopt(c, IPPROTO_TCP, TCP_KEEPCNT, &count, sizeof(count));

    while (1) {
        if (control_is_encrypted(c)) {
            uint8_t ptBuf[ENCRYPTED_MAX_READ_SIZE];
            int n = enc_recv_frame(c, &g_enc, ptBuf, sizeof(ptBuf));
            if (n == -2) continue;
            if (n <= 0) break;
            if ((size_t)n > sizeof(buf) - bufUsed) {
                printf("[AP] Encrypted request exceeds stream limit\n");
                break;
            }
            memcpy(buf + bufUsed, ptBuf, (size_t)n);
            bufUsed += (size_t)n;
        } else {
            /* Peek so the final plaintext pair-verify request cannot consume
             * bytes belonging to the first encrypted transport record. */
            bool owner = control_is_owner(c);
            if (bufUsed == sizeof(buf)) {
                if (owner || preauth_log_allowed(&preauthLogLines))
                    printf("[AP] Request exceeds stream limit\n");
                break;
            }
            if (!owner) {
                uint64_t now = control_monotonic_nanos();
                int waitMs = now >= unclaimedDeadline ? 0 :
                    (int)((unclaimedDeadline - now) / 1000000ULL) + 1;
                struct pollfd readable = { .fd = c, .events = POLLIN };
                int ready = waitMs > 0 ? poll(&readable, 1, waitMs) : 0;
                if (ready < 0 && errno == EINTR) continue;
                if (ready <= 0) {
                    if (preauth_log_allowed(&preauthLogLines))
                        printf("[AP] Connection did not start pairing within "
                               "%d s; closing\n",
                               CONTROL_UNCLAIMED_DEADLINE_SECONDS);
                    break;
                }
            }
            ssize_t n = recv(c, buf + bufUsed, sizeof(buf) - bufUsed, MSG_PEEK);
            if (n <= 0) {
                if (n < 0 && errno == EINTR) continue;
                break;
            }
            HTTPReq preview;
            size_t headerLimit = owner ? HTTP_STREAM_LIMIT :
                                         HTTP_PREAUTH_HEADER_LIMIT;
            bool complete = parse_http_incremental(buf, bufUsed + (size_t)n,
                                                   headerLimit, &progress,
                                                   &preview);
            if (preview.invalid) {
                if (owner || preauth_log_allowed(&preauthLogLines))
                    printf("[AP] Invalid or oversized request\n");
                break;
            }
            size_t take = (size_t)n;
            if (complete) {
                size_t total = (size_t)(preview.body - buf) + preview.contentLength;
                take = total - bufUsed;
            }
            n = recv(c, buf + bufUsed, take, 0);
            if (n <= 0) {
                if (n < 0 && errno == EINTR) continue;
                break;
            }
            bufUsed += (size_t)n;
        }

        /* One TCP read or encrypted record may contain partial, complete, or
         * multiple requests. Route only complete bounded messages. */
        while (bufUsed > 0) {
            HTTPReq r;
            size_t headerLimit = control_is_encrypted(c) || control_is_owner(c) ?
                HTTP_STREAM_LIMIT : HTTP_PREAUTH_HEADER_LIMIT;
            if (!parse_http_incremental(buf, bufUsed, headerLimit,
                                        &progress, &r)) {
                if (r.invalid || bufUsed == sizeof(buf)) goto client_done;
                break;
            }
            size_t total = (size_t)(r.body - buf) + r.contentLength;
            bool rtsp = strncmp(r.protocol, "RTSP", 4) == 0;
            const char *proto = rtsp ? "RTSP/1.0" : "HTTP/1.1";
            bool encrypted = control_is_encrypted(c);
            bool readOnly = strcasecmp(r.method, "GET") == 0 ||
                            strcasecmp(r.method, "OPTIONS") == 0;
            bool newlyClaimed = false;
            if (!encrypted && !request_allowed_before_pair_verify(&r)) {
                if (preauth_log_allowed(&preauthLogLines))
                    printf("[AP] Rejecting %s %s before pair-verify\n",
                           r.method, r.path);
                if (rtsp)
                    send_response(c, proto, 470,
                                  "Connection Authorization Required",
                                  NULL, NULL, 0, r.cseq);
                else
                    send_response(c, proto, 403, "Forbidden",
                                  NULL, NULL, 0, r.cseq);
            } else if (!readOnly && !control_claim(c, &newlyClaimed)) {
                send_response(c, proto, 503, "Service Unavailable",
                              NULL, NULL, 0, r.cseq);
            } else {
                if (newlyClaimed) {
                    /* Only the connection that starts pairing is the
                     * iPhone joining; discovery probes are not. */
                    app_send_status(STATUS_IPHONE_CONNECTED);
                    struct timeval ownerTv = {
                        .tv_sec = CONTROL_IDLE_SECONDS_UNVERIFIED_OWNER,
                        .tv_usec = 0 };
                    setsockopt(c, SOL_SOCKET, SO_RCVTIMEO,
                               &ownerTv, sizeof(ownerTv));
                }
                /* Log unauthenticated /info once per connection, and every
                 * other unauthenticated request (read-only probes and the
                 * pre-auth POSTs of an unverified owner alike) within the
                 * pre-auth log budget. */
                bool unverifiedInfo = !encrypted &&
                    strcasecmp(r.method, "GET") == 0 &&
                    request_path_is(r.path, "/info");
                bool quiet = unverifiedInfo && infoLogged;
                if (!quiet && !encrypted)
                    quiet = !preauth_log_allowed(&preauthLogLines);
                t_quiet_request_log = quiet;
                if (unverifiedInfo) infoLogged = true;
                route_request(c, &r);
                t_quiet_request_log = false;
            }
            if (encrypted || control_is_owner(c)) sessionConnection = true;
            memmove(buf, buf + total, bufUsed - total);
            bufUsed -= total;
            progress = (http_progress_t){0};
        }
    }
client_done:
    pthread_mutex_lock(&g_control_owner_lock);
    bool endedSession = g_control_owner == c && g_enc.active;
    if (g_control_owner == c && !endedSession) g_control_owner = -1;
    pthread_mutex_unlock(&g_control_owner_lock);
    control_client_release(c);
    close(c);
    if (sessionConnection || endedSession ||
        preauth_log_allowed(&preauthLogLines))
        printf("[AP] Connection closed\n");
    if (endedSession) {
        printf("[AP] CarPlay session ended; exiting\n");
        fflush(stdout);
        exit(0);
    }
}

static bool start_airplay_server(uint16_t port) {
    int sock = socket(AF_INET6, SOCK_STREAM, 0);
    if (sock < 0) { perror("[AP] socket"); return false; }

    int yes = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    int no = 0;
    setsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof(no));

    struct sockaddr_in6 addr = {0};
    addr.sin6_family = AF_INET6;
    addr.sin6_port = htons(port);
    addr.sin6_addr = in6addr_any;

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("[AP] bind"); close(sock); return false;
    }
    if (listen(sock, 5) < 0) {
        perror("[AP] listen"); close(sock); return false;
    }
    printf("[AP] AirPlay server listening on port %d (IPv4+IPv6)\n", port);

    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        unsigned long acceptFailures = 0;
        while (1) {
            struct sockaddr_storage ca;
            socklen_t cl = sizeof(ca);
            int c = accept(sock, (struct sockaddr *)&ca, &cl);
            if (c < 0) {
                int acceptErr = errno;
                /* Same classification as the event acceptor: a per-connection
                 * failure retries at once; resource exhaustion leaves the
                 * connection in the backlog, so accept() would fail again
                 * immediately -- back off instead of spinning a core and
                 * flooding the log (only the first and every 100th failure
                 * is logged). Anything else means the listener itself is
                 * unusable, and retrying would spin forever. */
                if (acceptErr == EINTR || acceptErr == ECONNABORTED)
                    continue;
                if (acceptErr == EAGAIN || acceptErr == EWOULDBLOCK ||
                    acceptErr == EMFILE || acceptErr == ENFILE ||
                    acceptErr == ENOBUFS || acceptErr == ENOMEM) {
                    if (acceptFailures++ % 100 == 0)
                        printf("[AP] accept error (retrying, %lu so far): %s\n",
                               acceptFailures, strerror(acceptErr));
                    usleep(100000);
                    continue;
                }
                printf("[AP] accept error, AirPlay listener stopped: %s\n",
                       strerror(acceptErr));
                fflush(stdout);
                close(sock);
                break;
            }
            acceptFailures = 0;

            char host[NI_MAXHOST], serv[NI_MAXSERV];
            sockaddr_to_numeric((struct sockaddr *)&ca, cl,
                                host, sizeof(host), serv, sizeof(serv));
            /* Any LAN host can reconnect in a loop: these lines share the
             * process-wide pre-auth log budget. */
            unsigned acceptLogLines = 0;
            bool logAccept = preauth_log_allowed(&acceptLogLines);
            if (logAccept) {
                printf("\n[AP] *** NEW CONNECTION from %s:%s family=%s ***\n",
                       host, serv, addr_family_name(ca.ss_family));
                fflush(stdout);
            }

            char peer[NI_MAXHOST];
            control_peer_host((struct sockaddr *)&ca, cl, peer, sizeof(peer));
            if (!control_client_admit(c, peer)) {
                if (logAccept)
                    printf("[AP] Too many control connections; closing %s:%s\n",
                           host, serv);
                close(c);
                continue;
            }

            /* Each connection blocks in recv for up to its idle limit, so it
             * gets its own thread instead of a shared GCD worker: a burst of
             * connections must not starve the audio, screen, touch and
             * timing work that runs on the global queues. */
            pthread_t thread;
            pthread_attr_t attr;
            pthread_attr_init(&attr);
            pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
            pthread_attr_setstacksize(&attr, CONTROL_CLIENT_STACK_BYTES);
            int rc = pthread_create(&thread, &attr, control_client_thread,
                                    (void *)(intptr_t)c);
            pthread_attr_destroy(&attr);
            if (rc != 0) {
                printf("[AP] Could not start client thread: %s\n",
                       strerror(rc));
                control_client_release(c);
                close(c);
            }
        }
    });
    return true;
}

/* ═══════════════════════════════════════════════════════════════
 * Control Channel — connect to iPhone's _carplay-ctrl._tcp
 * Keep connection alive and read continuously
 * ═══════════════════════════════════════════════════════════════ */

static void trim_dot(const char *src, char *dst, size_t dstLen) {
    if (!src || !dst || dstLen == 0) return;
    size_t n = strlen(src);
    while (n > 0 && src[n - 1] == '.') n--;
    if (n >= dstLen) n = dstLen - 1;
    memcpy(dst, src, n);
    dst[n] = '\0';
}

/* try_connect — verbose=true prints each attempt, false is silent (for probing) */
static int try_connect(const char *host, uint16_t port, uint32_t ifIndex,
                       bool verbose, int timeout_sec) {
    char portStr[8];
    snprintf(portStr, sizeof(portStr), "%u", (unsigned)port);

    char clean[256];
    trim_dot(host, clean, sizeof(clean));

    /* Force IPv4 — IPv6 outbound on bridge100 consistently fails
     * (SYN never gets SYN-ACK, blocks for 75s) */
    struct addrinfo hints = { .ai_family = AF_INET,
                              .ai_socktype = SOCK_STREAM };
    struct addrinfo *res = NULL;
    int gai = getaddrinfo(clean, portStr, &hints, &res);
    if (gai != 0) {
        if (verbose)
            printf("[CTRL] getaddrinfo(%s:%s) failed: %s\n",
                   clean, portStr, gai_strerror(gai));
        if (gai != EAI_SYSTEM) errno = EHOSTUNREACH;
        return -1;
    }

    int lastError = EHOSTUNREACH;
    for (const struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        int s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (s < 0) { lastError = errno; continue; }

#ifdef IP_BOUND_IF
        /* Keep the discovered control service on the same network on which
         * Bonjour found it, even when another interface has a default route. */
        if (ifIndex && setsockopt(s, IPPROTO_IP, IP_BOUND_IF, &ifIndex, sizeof(ifIndex)) != 0) {
            lastError = errno;
            if (verbose) printf("[CTRL] Cannot bind interface %u: %s\n", ifIndex, strerror(lastError));
            close(s);
            continue;
        }
#endif

        char addrStr[NI_MAXHOST], portS[NI_MAXSERV];
        getnameinfo(ai->ai_addr, ai->ai_addrlen,
                    addrStr, sizeof(addrStr), portS, sizeof(portS),
                    NI_NUMERICHOST | NI_NUMERICSERV);
        if (verbose)
            printf("[CTRL] Trying %s:%s\n", addrStr, portS);

        /* Non-blocking connect with configurable timeout via select() */
        int flags = fcntl(s, F_GETFL, 0);
        fcntl(s, F_SETFL, flags | O_NONBLOCK);

        int ret = connect(s, ai->ai_addr, ai->ai_addrlen);
        if (ret < 0 && errno == EINPROGRESS) {
            fd_set wset;
            FD_ZERO(&wset);
            FD_SET(s, &wset);
            struct timeval tv = { .tv_sec = timeout_sec, .tv_usec = 0 };
            int sel = select(s + 1, NULL, &wset, NULL, &tv);
            if (sel > 0) {
                int serr = 0;
                socklen_t slen = sizeof(serr);
                if (getsockopt(s, SOL_SOCKET, SO_ERROR, &serr, &slen) < 0)
                    serr = errno;
                if (serr == 0) ret = 0;
                else { errno = serr; ret = -1; }
            } else {
                if (sel == 0) errno = ETIMEDOUT;
                ret = -1;
            }
        }

        int connectError = ret < 0 ? errno : 0;
        /* Restore blocking mode */
        fcntl(s, F_SETFL, flags);

        if (ret == 0) {
            printf("[CTRL] Connected %s:%s\n", addrStr, portS);
            freeaddrinfo(res);
            return s;
        }
        if (verbose)
            printf("[CTRL] Failed: %s\n", strerror(connectError));
        lastError = connectError;
        close(s);
    }
    freeaddrinfo(res);
    errno = lastError; /* cleanup must not hide refusal of a stale port */
    return -1;
}

/* ═══════════════════════════════════════════════════════════════
 * Ctrl Service State — stored globally for re-resolution
 * ═══════════════════════════════════════════════════════════════ */

static char g_ctrlName[256]    = {0};
static char g_ctrlRegType[256] = {0};
static char g_ctrlDomain[256]  = {0};
static uint32_t g_ctrlIfIndex  = 0;
static volatile bool g_ctrlFound = false;
static volatile bool g_ctrlConnected = false;
/* Set while a ctrl_connect_thread runs; cleared when it returns so a later
 * browse result or the retry timer can try again (g_ctrlFound only records
 * that the service is known). */
static atomic_bool g_ctrlThreadRunning = false;
#define CTRL_RESTART_DELAY_SEC 5
/* Idle recv timeout on the open ctrl-int channel, and how many consecutive
 * idle periods without an authenticated session end it so a fresh connect
 * can be sent. */
#define CTRL_IDLE_RECV_SEC 120
#define CTRL_IDLE_LIMIT_WITHOUT_SESSION 2
/* A browse Add for an already-open channel only replaces it once the channel
 * has had this long to produce a pairing attempt. */
#define CTRL_REPLACE_MIN_AGE_SEC 10
/* Descriptor of the open ctrl-int channel, or -1. Guarded by g_ctrlSockLock
 * so a shutdown from another thread never hits a reused descriptor. */
static pthread_mutex_t g_ctrlSockLock = PTHREAD_MUTEX_INITIALIZER;
static int g_ctrlSock = -1;
static uint64_t g_ctrlSockOpenedNanos = 0;

/* Wakes ctrl_send_connect's recv so the ctrl thread returns and a retry can
 * be scheduled. minAgeSec skips a channel opened more recently than that. */
static bool ctrl_abort_channel(unsigned minAgeSec) {
    bool aborted = false;
    pthread_mutex_lock(&g_ctrlSockLock);
    if (g_ctrlSock >= 0 &&
        control_monotonic_nanos() - g_ctrlSockOpenedNanos >=
            (uint64_t)minAgeSec * CONTROL_NANOS_PER_SECOND) {
        shutdown(g_ctrlSock, SHUT_RDWR);
        aborted = true;
    }
    pthread_mutex_unlock(&g_ctrlSockLock);
    return aborted;
}

/* Synchronous re-resolve: returns fresh port, or 0 on failure */
typedef struct { char host[256]; uint16_t port; bool resolved; } ResolveResult;

static void sync_resolve_cb(DNSServiceRef ref, DNSServiceFlags flags,
                             uint32_t ifIndex, DNSServiceErrorType err,
                             const char *fullname, const char *hosttarget,
                             uint16_t port, uint16_t txtLen,
                             const unsigned char *txtRecord, void *ctx) {
    (void)ref; (void)flags; (void)ifIndex; (void)fullname;
    (void)txtLen; (void)txtRecord;
    ResolveResult *r = (ResolveResult *)ctx;
    if (err == kDNSServiceErr_NoError) {
        trim_dot(hosttarget, r->host, sizeof(r->host));
        r->port = ntohs(port);
        r->resolved = true;
    }
}

static bool resolve_ctrl_port(ResolveResult *out) {
    if (!g_ctrlFound) return false;

    DNSServiceRef ref = NULL;
    DNSServiceErrorType e = DNSServiceResolve(
        &ref, kDNSServiceFlagsForceMulticast, g_ctrlIfIndex,
        g_ctrlName, g_ctrlRegType, g_ctrlDomain,
        sync_resolve_cb, out);
    if (e != kDNSServiceErr_NoError) return false;

    /* Wait up to 3s for resolve response */
    int fd = DNSServiceRefSockFD(ref);
    fd_set rset;
    FD_ZERO(&rset);
    FD_SET(fd, &rset);
    struct timeval tv = { .tv_sec = 3, .tv_usec = 0 };
    if (select(fd + 1, &rset, NULL, NULL, &tv) > 0) {
        DNSServiceProcessResult(ref);
    }
    DNSServiceRefDeallocate(ref);
    return out->resolved;
}

/* ═══════════════════════════════════════════════════════════════
 * Ctrl Channel — smart connect with re-resolve on failure
 * ═══════════════════════════════════════════════════════════════ */

/*
 * The ctrl channel peer is whatever answered the last _carplay-ctrl._tcp
 * browse result, so its traffic is unauthenticated: cap each dump and log
 * only the first CTRL_RECV_LOG_FULL receives in full, then a byte count on
 * every CTRL_RECV_LOG_EVERY-th. Output goes through printf (the locked,
 * size-capped service log) so a flood cannot interleave with other lines or
 * push the real session's diagnostics past the log cap.
 */
#define CTRL_RECV_LOG_FULL   16
#define CTRL_RECV_LOG_EVERY  100
#define CTRL_RECV_DUMP_BYTES 256

static void ctrl_log_received(const char *label, const uint8_t *buf,
                              ssize_t n, bool printable) {
    printf("[CTRL] %s (%zd bytes):\n", label, n);
    int shown = n < CTRL_RECV_DUMP_BYTES ? (int)n : CTRL_RECV_DUMP_BYTES;
    if (printable) {
        char text[CTRL_RECV_DUMP_BYTES + 1];
        for (int i = 0; i < shown; i++) {
            uint8_t c = buf[i];
            text[i] = (c == '\r' || c == '\n' || c == '\t' ||
                       (c >= 0x20 && c < 0x7f)) ? (char)c : '.';
        }
        text[shown] = '\0';
        printf("%s%s\n", text, n > shown ? " ..." : "");
    }
    printf("[CTRL] Hex (%zd):", n);
    for (int i = 0; i < shown; i++) printf(" %02X", buf[i]);
    if (n > shown) printf(" ...");
    printf("\n");
}

static void ctrl_send_connect(int sock, const char *host) {
    printf("[CTRL] *** Connected to CarPlay control channel ***\n");
    g_ctrlConnected = true;
    pthread_mutex_lock(&g_ctrlSockLock);
    g_ctrlSock = sock;
    g_ctrlSockOpenedNanos = control_monotonic_nanos();
    pthread_mutex_unlock(&g_ctrlSockLock);

    /* Send GET /ctrl-int/1/connect
     * CRITICAL: AirPlay-Receiver-Device-ID must be DECIMAL INTEGER,
     * not MAC format. TomSignalius uses "%llu", wiomoc uses str(mac_int). */
    char request[1024];
    int reqlen = snprintf(request, sizeof(request),
        "GET /ctrl-int/1/connect HTTP/1.1\r\n"
        "Host: %s\r\n"
        "User-Agent: AirPlay/%s\r\n"
        "AirPlay-Receiver-Device-ID: %s\r\n"
        "\r\n",
        host, SOURCE_VERSION, DEVICE_ID_INT);

    printf("[CTRL] Sending:\n%s", request);
    ssize_t sent = send(sock, request, reqlen, 0);
    printf("[CTRL] Sent %zd bytes\n", sent);
    if (sent <= 0) goto done;  /* done: is the single close */

    /* TCP keepalive. An iPhone that leaves Wi-Fi (bridge rebuilt on the
     * BT-to-Wi-Fi handoff, Wi-Fi toggled, out of range) never closes the
     * channel, so probe after 10 s of silence and give up after 3 misses,
     * as handle_client does; recv then fails and a retry is scheduled. */
    int yes = 1, idle = 10, interval = 3, count = 3;
    setsockopt(sock, SOL_SOCKET, SO_KEEPALIVE, &yes, sizeof(yes));
    setsockopt(sock, IPPROTO_TCP, TCP_KEEPALIVE, &idle, sizeof(idle));
    setsockopt(sock, IPPROTO_TCP, TCP_KEEPINTVL, &interval, sizeof(interval));
    setsockopt(sock, IPPROTO_TCP, TCP_KEEPCNT, &count, sizeof(count));

    /* Read the initial 200 OK response, then keep channel open
     * and read any further commands the iPhone sends. */
    struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    uint8_t buf[8192];
    ssize_t n = recv(sock, buf, sizeof(buf) - 1, 0);
    if (n > 0) {
        buf[n] = '\0';
        ctrl_log_received("Response", buf, n,
                          n > 4 && (buf[0] == 'H' || buf[0] == 'R'));

        if (strstr((char *)buf, "200") || strstr((char *)buf, "OK"))
            printf("[CTRL] *** ctrl-int connect SUCCEEDED — keeping channel open ***\n");
        else {
            printf("[CTRL] *** ctrl-int connect got non-200 response ***\n");
            goto done;
        }
    } else if (n == 0) {
        printf("[CTRL] iPhone closed connection without responding (FIN)\n");
        goto done;
    } else {
        printf("[CTRL] recv error: %s\n", strerror(errno));
        goto done;
    }
    fflush(stdout);

    /* Keep channel open — read any commands iPhone sends.
     * Use a long recv timeout so we stay alive but don't block forever. */
    tv.tv_sec = CTRL_IDLE_RECV_SEC;
    tv.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    int idleWithoutSession = 0;
    unsigned long recvCount = 0;
    while (1) {
        n = recv(sock, buf, sizeof(buf) - 1, 0);
        if (n > 0) {
            idleWithoutSession = 0;
            buf[n] = '\0';
            if (recvCount < ULONG_MAX) recvCount++;
            bool logFull = recvCount <= CTRL_RECV_LOG_FULL;
            if (logFull) {
                ctrl_log_received("Received", buf, n,
                                  n > 4 && (buf[0] >= 0x20 && buf[0] < 0x7f));
            } else if (recvCount % CTRL_RECV_LOG_EVERY == 0) {
                printf("[CTRL] Received %zd bytes (receive #%lu; "
                       "per-receive logging suppressed)\n", n, recvCount);
            }

            /* Echo back 200 OK for any HTTP-looking request */
            if (buf[0] == 'G' || buf[0] == 'P' || buf[0] == 'H') {
                const char *resp = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
                send(sock, resp, strlen(resp), 0);
                if (logFull) printf("[CTRL] Sent 200 OK reply\n");
            }
            fflush(stdout);
        } else if (n == 0) {
            printf("[CTRL] iPhone closed ctrl channel (FIN)\n");
            break;
        } else {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                /* A channel that never led to an authenticated session is
                 * half-open or abandoned; drop it so the retry path sends a
                 * fresh connect instead of waiting here forever. */
                if (control_has_encrypted_session()) {
                    idleWithoutSession = 0;
                } else if (++idleWithoutSession >=
                           CTRL_IDLE_LIMIT_WITHOUT_SESSION) {
                    printf("[CTRL] Ctrl channel idle %ds without a session; "
                           "reconnecting\n",
                           CTRL_IDLE_RECV_SEC * idleWithoutSession);
                    break;
                }
                printf("[CTRL] Ctrl channel idle (%ds), still alive\n",
                       CTRL_IDLE_RECV_SEC);
                fflush(stdout);
                continue;
            }
            printf("[CTRL] Ctrl channel recv error: %s\n", strerror(errno));
            break;
        }
    }

done:
    pthread_mutex_lock(&g_ctrlSockLock);
    g_ctrlSock = -1;
    close(sock);
    pthread_mutex_unlock(&g_ctrlSockLock);
    g_ctrlConnected = false;
    printf("[CTRL] Control channel closed\n");
    fflush(stdout);
}

static void ctrl_connect_thread(void *ctx) {
    (void)ctx;

    /* ── Phase 1: Wait for iPhone to actually be on the network ──
     * mDNS browse returns cached results from previous sessions, so we
     * often fire before the BT handshake has even happened. We probe
     * silently with short timeouts until the host responds. */
    printf("[CTRL] iPhone service found (likely cached). "
           "Waiting for BT handshake...\n");
    fflush(stdout);

    int waitSecs = 0;
    while (1) {
        ResolveResult rr = { .resolved = false };
        if (!resolve_ctrl_port(&rr)) {
            sleep(1); waitSecs += 1;
            if (waitSecs % 30 == 0)
                printf("[CTRL] Still waiting for iPhone... (%ds)\n", waitSecs);
            continue;
        }

        /* Ports change between sessions. Re-resolve promptly so a cached
         * endpoint cannot stall the new Bluetooth-to-Wi-Fi handoff. */
        int sock = try_connect(rr.host, rr.port, g_ctrlIfIndex, false, 1);
        if (sock >= 0) {
            /* Connected on first probe! */
            ctrl_send_connect(sock, rr.host);
            return;
        }

        int connectError = errno;
        printf("[CTRL] Probe %s:%u failed: %s\n", rr.host,
               (unsigned)rr.port, strerror(connectError));
        fflush(stdout);
        if (connectError == ECONNREFUSED) {
            /* iPhone IS on the network (TCP RST = host reachable).
             * This port is stale — move to Phase 2 with re-resolve. */
            printf("[CTRL] iPhone is online! (port %u stale, re-resolving)\n",
                   (unsigned)rr.port);
            break;
        }

        /* EHOSTDOWN / ETIMEDOUT / EHOSTUNREACH — not on network yet */
        sleep(1); waitSecs += 1;
        if (waitSecs % 30 == 0 && waitSecs > 0) {
            printf("[CTRL] Still waiting for iPhone... (%ds)\n", waitSecs);
            fflush(stdout);
        }
    }

    /* ── Phase 2: iPhone is reachable — resolve & connect ──
     * Now we do the verbose re-resolve loop since we know the
     * iPhone is actually on the network. */
    for (int round = 1; round <= CTRL_RESOLVE_ROUNDS; round++) {
        ResolveResult rr = { .resolved = false };
        printf("[CTRL] Resolve round %d/%d...\n", round, CTRL_RESOLVE_ROUNDS);

        if (!resolve_ctrl_port(&rr)) {
            printf("[CTRL] Resolve failed, retrying in %ds...\n", CTRL_RETRY_SEC * 2);
            sleep(CTRL_RETRY_SEC * 2);
            continue;
        }

        printf("[CTRL] Resolved: %s:%u\n", rr.host, (unsigned)rr.port);

        for (int attempt = 1; attempt <= CTRL_CONNECT_ATTEMPTS; attempt++) {
            printf("[CTRL] Connect attempt %d/%d to %s:%u\n",
                   attempt, CTRL_CONNECT_ATTEMPTS,
                   rr.host, (unsigned)rr.port);

            int sock = try_connect(rr.host, rr.port, g_ctrlIfIndex, true, 5);
            if (sock >= 0) {
                ctrl_send_connect(sock, rr.host);
                return;
            }

            if (errno == ECONNREFUSED) {
                printf("[CTRL] Port %u refused — re-resolving\n",
                       (unsigned)rr.port);
                break;
            }
            if (attempt < CTRL_CONNECT_ATTEMPTS) {
                printf("[CTRL] Retrying in %ds...\n", CTRL_RETRY_SEC);
                sleep(CTRL_RETRY_SEC);
            }
        }

        if (round < CTRL_RESOLVE_ROUNDS) {
            sleep(CTRL_RETRY_SEC);
        }
    }
    printf("[CTRL] *** ALL RESOLVE ROUNDS EXHAUSTED ***\n");
}

static void start_ctrl_connect_thread(void);

/* Without an authenticated session the iPhone is still expected, and mDNS
 * does not repeat Add for a service it already reported, so retry after a
 * pause. While some connection is mid-pairing, wait rather than send a second
 * connect request. Once a session exists, its end terminates this process. */
static void schedule_ctrl_restart(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)CTRL_RESTART_DELAY_SEC *
                                     NSEC_PER_SEC),
                   dispatch_get_global_queue(0, 0), ^{
        if (control_has_encrypted_session()) return;
        if (control_has_live_owner()) {
            schedule_ctrl_restart();
            return;
        }
        start_ctrl_connect_thread();
    });
}

static void ctrl_connect_thread_main(void) {
    ctrl_connect_thread(NULL);
    atomic_store(&g_ctrlThreadRunning, false);
    if (!control_has_encrypted_session()) {
        printf("[CTRL] Control channel ended without a session; retrying "
               "in %ds\n", CTRL_RESTART_DELAY_SEC);
        fflush(stdout);
        schedule_ctrl_restart();
    }
}

static void start_ctrl_connect_thread(void) {
    if (!g_ctrlFound) return;
    bool expected = false;
    if (!atomic_compare_exchange_strong(&g_ctrlThreadRunning, &expected, true))
        return;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        ctrl_connect_thread_main();
    });
}

/* ═══════════════════════════════════════════════════════════════
 * mDNS Callbacks
 * ═══════════════════════════════════════════════════════════════ */

static void reg_callback(DNSServiceRef ref, DNSServiceFlags flags,
                         DNSServiceErrorType err, const char *name,
                         const char *regtype, const char *domain, void *ctx) {
    (void)ref; (void)flags; (void)ctx;
    if (err == kDNSServiceErr_NoError)
        printf("[MDNS] Registered: %s.%s%s\n", name, regtype, domain);
    else
        printf("[MDNS] Register failed: err=%d\n", err);
}

static void browse_callback(DNSServiceRef ref, DNSServiceFlags flags,
                            uint32_t ifIndex, DNSServiceErrorType err,
                            const char *name, const char *regtype,
                            const char *domain, void *ctx) {
    (void)ref; (void)ctx;
    if (err != kDNSServiceErr_NoError) {
        printf("[MDNS] Browse error: %d\n", err);
        return;
    }
    if (flags & kDNSServiceFlagsAdd) {
        printf("\n[MDNS] *** FOUND: %s.%s%s (if=%u) ***\n",
               name, regtype, domain, ifIndex);

        /* Store service info for re-resolution */
        snprintf(g_ctrlName, sizeof(g_ctrlName), "%s", name);
        snprintf(g_ctrlRegType, sizeof(g_ctrlRegType), "%s", regtype);
        snprintf(g_ctrlDomain, sizeof(g_ctrlDomain), "%s", domain);
        g_ctrlIfIndex = ifIndex;

        /* One ctrl thread at a time; a new Add after it gave up (non-200,
         * FIN, exhausted rounds) starts another. */
        g_ctrlFound = true;
        if (!control_has_encrypted_session()) {
            /* A new Add while an older channel is still open and nobody is
             * pairing means that channel is stale (e.g. bridge rebuilt);
             * end it so the exiting thread schedules a fresh connect. */
            if (atomic_load(&g_ctrlThreadRunning) && !control_has_live_owner() &&
                ctrl_abort_channel(CTRL_REPLACE_MIN_AGE_SEC)) {
                printf("[CTRL] New browse result; replacing open ctrl "
                       "channel\n");
            }
            start_ctrl_connect_thread();
        }
    } else {
        printf("[MDNS] Removed: %s.%s%s\n", name, regtype, domain);
    }
}

/* ═══════════════════════════════════════════════════════════════
 * TXT Record Builder — _airplay._tcp
 * ═══════════════════════════════════════════════════════════════ */

static TXTRecordRef build_airplay_txt(void) {
    TXTRecordRef txt;
    TXTRecordCreate(&txt, 0, NULL);

    const char *ft = g_useHK ? FEATURES_WITH_HK : FEATURES_NO_HK;

    /* Apple SDK order: deviceid, features, fv, flags, model, protovers, pi, pk, srcvers */
    TXTRecordSetValue(&txt, "deviceid",    strlen(DEVICE_ID),      DEVICE_ID);
    TXTRecordSetValue(&txt, "features",    strlen(ft),             ft);
    TXTRecordSetValue(&txt, "flags",       strlen("0x4"),          "0x4");
    TXTRecordSetValue(&txt, "model",       strlen(MODEL_NAME),    MODEL_NAME);
    TXTRecordSetValue(&txt, "protovers",   3,                      "1.1");
    TXTRecordSetValue(&txt, "pi",          strlen(g_hk_pi),       g_hk_pi);
    TXTRecordSetValue(&txt, "pk",          strlen(g_hk_pk_hex),   g_hk_pk_hex);
    TXTRecordSetValue(&txt, "srcvers",     strlen(SOURCE_VERSION), SOURCE_VERSION);
    return txt;
}

/* ═══════════════════════════════════════════════════════════════
 * TXT Record Builder — _raop._tcp
 * Every working AirPlay 2 receiver registers BOTH _airplay._tcp
 * AND _raop._tcp. Without _raop._tcp, the iPhone sees an
 * incomplete advertisement and never connects to port 7000.
 * ═══════════════════════════════════════════════════════════════ */

static TXTRecordRef build_raop_txt(void) {
    TXTRecordRef txt;
    TXTRecordCreate(&txt, 0, NULL);

    const char *ft = g_useHK ? FEATURES_WITH_HK : FEATURES_NO_HK;

    TXTRecordSetValue(&txt, "txtvers",  1,                      "1");
    TXTRecordSetValue(&txt, "ch",       1,                      "2");
    TXTRecordSetValue(&txt, "cn",       7,                      "0,1,2,3");
    TXTRecordSetValue(&txt, "da",       4,                      "true");
    TXTRecordSetValue(&txt, "et",       5,                      "0,3,5");
    TXTRecordSetValue(&txt, "md",       5,                      "0,1,2");
    TXTRecordSetValue(&txt, "pw",       5,                      "false");
    TXTRecordSetValue(&txt, "sv",       5,                      "false");
    TXTRecordSetValue(&txt, "sr",       5,                      "44100");
    TXTRecordSetValue(&txt, "ss",       2,                      "16");
    TXTRecordSetValue(&txt, "tp",       3,                      "UDP");
    TXTRecordSetValue(&txt, "vn",       5,                      "65537");
    TXTRecordSetValue(&txt, "vs",       strlen(SOURCE_VERSION), SOURCE_VERSION);
    TXTRecordSetValue(&txt, "am",       strlen(MODEL_NAME),     MODEL_NAME);
    TXTRecordSetValue(&txt, "sf",       3,                      "0x0");
    TXTRecordSetValue(&txt, "ft",       strlen(ft),             ft);
    TXTRecordSetValue(&txt, "pk",       strlen(g_hk_pk_hex),    g_hk_pk_hex);
    return txt;
}


/* ═══════════════════════════════════════════════════════════════
 * Wire-level unsolicited mDNS announcer
 *
 * DNSServiceUpdateRecord() can return success without putting a fresh
 * multicast announcement on bridge100. The failing iOS 26 sender joins the
 * hotspot but never queries _airplay._tcp, so it must receive an unsolicited
 * announcement after DHCP/ARP. This helper sends the minimum AirPlay/RAOP
 * records directly to 224.0.0.251:5353 during the handoff window.
 * ═══════════════════════════════════════════════════════════════ */

static bool mdns_put_u16(uint8_t *buf, size_t cap, size_t *off, uint16_t v) {
    if (*off + 2 > cap) return false;
    buf[(*off)++] = (uint8_t)(v >> 8);
    buf[(*off)++] = (uint8_t)(v & 0xff);
    return true;
}

static bool mdns_put_u32(uint8_t *buf, size_t cap, size_t *off, uint32_t v) {
    if (*off + 4 > cap) return false;
    buf[(*off)++] = (uint8_t)(v >> 24);
    buf[(*off)++] = (uint8_t)(v >> 16);
    buf[(*off)++] = (uint8_t)(v >> 8);
    buf[(*off)++] = (uint8_t)(v & 0xff);
    return true;
}

static bool mdns_put_bytes(uint8_t *buf, size_t cap, size_t *off,
                           const void *data, size_t len) {
    if (*off + len > cap) return false;
    memcpy(buf + *off, data, len);
    *off += len;
    return true;
}

/* Dotted name made only of fixed labels (service type, host). Must never be
 * given a user-chosen instance name: use mdns_put_instance_name for that. */
static bool mdns_put_name(uint8_t *buf, size_t cap, size_t *off,
                          const char *name) {
    const char *p = name;
    while (*p) {
        const char *dot = strchr(p, '.');
        size_t len = dot ? (size_t)(dot - p) : strlen(p);
        if (len == 0 || len > 63 || *off + 1 + len > cap) return false;
        buf[(*off)++] = (uint8_t)len;
        memcpy(buf + *off, p, len);
        *off += len;
        if (!dot) break;
        p = dot + 1;
    }
    if (*off + 1 > cap) return false;
    buf[(*off)++] = 0;
    return true;
}

/* <instance>.<service>: the instance (the free-text car name) is ONE label,
 * exactly as DNSServiceRegister publishes it, so a '.' inside it ("Golf 1.6",
 * "Araba.") stays part of the name instead of splitting or ending it. */
static bool mdns_put_instance_name(uint8_t *buf, size_t cap, size_t *off,
                                   const char *instance, const char *service) {
    size_t len = strlen(instance);
    if (len == 0 || len > 63 || *off + 1 + len > cap) return false;
    buf[(*off)++] = (uint8_t)len;
    memcpy(buf + *off, instance, len);
    *off += len;
    return mdns_put_name(buf, cap, off, service);
}

static bool mdns_put_ptr(uint8_t *buf, size_t cap, size_t *off,
                         const char *service, const char *instance,
                         uint32_t ttl) {
    if (!mdns_put_name(buf, cap, off, service)) return false;
    if (!mdns_put_u16(buf, cap, off, 12)) return false;      /* PTR */
    if (!mdns_put_u16(buf, cap, off, 1)) return false;       /* IN */
    if (!mdns_put_u32(buf, cap, off, ttl)) return false;
    size_t rdlen_at = *off;
    if (!mdns_put_u16(buf, cap, off, 0)) return false;
    size_t rstart = *off;
    if (!mdns_put_instance_name(buf, cap, off, instance, service))
        return false;
    uint16_t rdlen = (uint16_t)(*off - rstart);
    buf[rdlen_at] = (uint8_t)(rdlen >> 8);
    buf[rdlen_at + 1] = (uint8_t)(rdlen & 0xff);
    return true;
}

static bool mdns_put_srv(uint8_t *buf, size_t cap, size_t *off,
                         const char *instance, const char *service,
                         const char *target, uint16_t port, uint32_t ttl) {
    if (!mdns_put_instance_name(buf, cap, off, instance, service))
        return false;
    if (!mdns_put_u16(buf, cap, off, 33)) return false;      /* SRV */
    if (!mdns_put_u16(buf, cap, off, 0x8001)) return false;  /* cache flush + IN */
    if (!mdns_put_u32(buf, cap, off, ttl)) return false;
    size_t rdlen_at = *off;
    if (!mdns_put_u16(buf, cap, off, 0)) return false;
    size_t rstart = *off;
    if (!mdns_put_u16(buf, cap, off, 0)) return false;       /* priority */
    if (!mdns_put_u16(buf, cap, off, 0)) return false;       /* weight */
    if (!mdns_put_u16(buf, cap, off, port)) return false;
    if (!mdns_put_name(buf, cap, off, target)) return false;
    uint16_t rdlen = (uint16_t)(*off - rstart);
    buf[rdlen_at] = (uint8_t)(rdlen >> 8);
    buf[rdlen_at + 1] = (uint8_t)(rdlen & 0xff);
    return true;
}

static bool mdns_put_txt_bytes(uint8_t *buf, size_t cap, size_t *off,
                               const char *instance, const char *service,
                               const void *txt, uint16_t txt_len,
                               uint32_t ttl) {
    if (!mdns_put_instance_name(buf, cap, off, instance, service))
        return false;
    if (!mdns_put_u16(buf, cap, off, 16)) return false;      /* TXT */
    if (!mdns_put_u16(buf, cap, off, 0x8001)) return false;  /* cache flush + IN */
    if (!mdns_put_u32(buf, cap, off, ttl)) return false;
    if (!mdns_put_u16(buf, cap, off, txt_len)) return false;
    return mdns_put_bytes(buf, cap, off, txt, txt_len);
}

static bool mdns_put_a(uint8_t *buf, size_t cap, size_t *off,
                       const char *name, uint32_t addr_be, uint32_t ttl) {
    if (!mdns_put_name(buf, cap, off, name)) return false;
    if (!mdns_put_u16(buf, cap, off, 1)) return false;       /* A */
    if (!mdns_put_u16(buf, cap, off, 0x8001)) return false;  /* cache flush + IN */
    if (!mdns_put_u32(buf, cap, off, ttl)) return false;
    if (!mdns_put_u16(buf, cap, off, 4)) return false;
    return mdns_put_bytes(buf, cap, off, &addr_be, 4);
}

static uint32_t wifi_ipv4_addr(void) {
    struct ifaddrs *ifas = NULL;
    uint32_t out = g_shared_wifi ? INADDR_ANY : inet_addr("172.20.10.1");
    if (getifaddrs(&ifas) == 0) {
        for (struct ifaddrs *ifa = ifas; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_name || !ifa->ifa_addr) continue;
            if (strcmp(ifa->ifa_name, g_wifi_interface) != 0) continue;
            if (!(ifa->ifa_flags & IFF_UP)) continue;
            if (ifa->ifa_addr->sa_family != AF_INET) continue;
            struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
            out = sin->sin_addr.s_addr;
            break;
        }
        freeifaddrs(ifas);
    }
    return out;
}

static void local_mdns_target_name(char *out, size_t out_len) {
    char host[128] = {0};
    if (gethostname(host, sizeof(host) - 1) != 0 || !host[0]) {
        snprintf(host, sizeof(host), "Carplay-Receiver");
    }
    /* Strip an existing .local suffix if present, then append exactly once. */
    char *dotlocal = strstr(host, ".local");
    if (dotlocal) *dotlocal = '\0';
    snprintf(out, out_len, "%s.local", host);
}

static int send_unsolicited_mdns_airplay_announcement(void) {
    uint32_t wifiAddress = wifi_ipv4_addr();
    if (wifiAddress == INADDR_ANY) {
        printf("[MDNS] No IPv4 address on %s; skipping wire announcement\n", g_wifi_interface);
        return -1;
    }
    char target[160];
    local_mdns_target_name(target, sizeof(target));

    TXTRecordRef apTxt = build_airplay_txt();
    TXTRecordRef raopTxt = build_raop_txt();

    uint8_t pkt[1800];
    size_t off = 0;
    bool ok = true;

    /* DNS header: response, authoritative answer, no questions, 7 answers. */
    ok &= mdns_put_u16(pkt, sizeof(pkt), &off, 0x0000);
    ok &= mdns_put_u16(pkt, sizeof(pkt), &off, 0x8400);
    ok &= mdns_put_u16(pkt, sizeof(pkt), &off, 0);
    ok &= mdns_put_u16(pkt, sizeof(pkt), &off, 7);
    ok &= mdns_put_u16(pkt, sizeof(pkt), &off, 0);
    ok &= mdns_put_u16(pkt, sizeof(pkt), &off, 0);

    ok &= mdns_put_ptr(pkt, sizeof(pkt), &off, "_airplay._tcp.local", g_instance_name, 4500);
    ok &= mdns_put_srv(pkt, sizeof(pkt), &off, g_instance_name, "_airplay._tcp.local",
                       target, AIRPLAY_PORT, 120);
    ok &= mdns_put_txt_bytes(pkt, sizeof(pkt), &off, g_instance_name, "_airplay._tcp.local",
                             TXTRecordGetBytesPtr(&apTxt),
                             TXTRecordGetLength(&apTxt), 4500);
    ok &= mdns_put_ptr(pkt, sizeof(pkt), &off, "_raop._tcp.local", g_raop_name, 4500);
    ok &= mdns_put_srv(pkt, sizeof(pkt), &off, g_raop_name, "_raop._tcp.local",
                       target, AIRPLAY_PORT, 120);
    ok &= mdns_put_txt_bytes(pkt, sizeof(pkt), &off, g_raop_name, "_raop._tcp.local",
                             TXTRecordGetBytesPtr(&raopTxt),
                             TXTRecordGetLength(&raopTxt), 4500);
    ok &= mdns_put_a(pkt, sizeof(pkt), &off, target, wifiAddress, 120);

    TXTRecordDeallocate(&apTxt);
    TXTRecordDeallocate(&raopTxt);

    if (!ok) {
        printf("[MDNS] wire announce build failed\n");
        return -1;
    }

    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) {
        printf("[MDNS] wire announce socket failed: %s\n", strerror(errno));
        return -1;
    }

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
#ifdef SO_REUSEPORT
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, sizeof(yes));
#endif

    struct sockaddr_in local;
    memset(&local, 0, sizeof(local));
    local.sin_family = AF_INET;
    local.sin_port = htons(5353);
    local.sin_addr.s_addr = wifiAddress;
    if (bind(fd, (struct sockaddr *)&local, sizeof(local)) != 0) {
        /* Do not fail the announcement solely because mDNSResponder owns 5353.
         * A 5353 source port is preferred, but the packet still helps as a
         * multicast hint on some iOS builds. */
        memset(&local, 0, sizeof(local));
        local.sin_family = AF_INET;
        local.sin_port = 0;
        local.sin_addr.s_addr = wifiAddress;
        bind(fd, (struct sockaddr *)&local, sizeof(local));
    }

    uint8_t ttl = 255;
    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl));
    uint8_t loop = 0;
    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, sizeof(loop));

    struct in_addr ifaddr;
    ifaddr.s_addr = wifiAddress;
    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &ifaddr, sizeof(ifaddr));

    struct sockaddr_in dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = htons(5353);
    inet_aton("224.0.0.251", &dst.sin_addr);

    ssize_t n = sendto(fd, pkt, off, 0, (struct sockaddr *)&dst, sizeof(dst));
    close(fd);
    if (n < 0) {
        printf("[MDNS] wire announce send failed: %s\n", strerror(errno));
        return -1;
    }
    return (int)n;
}

static DNSServiceErrorType update_registered_txt(DNSServiceRef ref, TXTRecordRef *txt) {
    if (!ref) return kDNSServiceErr_BadReference;
    return DNSServiceUpdateRecord(ref, NULL, 0,
                                  TXTRecordGetLength(txt),
                                  TXTRecordGetBytesPtr(txt),
                                  0);
}

static void start_mdns_reannounce_loop(DNSServiceRef airplayRef,
                                       DNSServiceRef raopRef) {
    if (!airplayRef && !raopRef) return;

    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        int ticks = MDNS_REANNOUNCE_SECONDS / MDNS_REANNOUNCE_INTERVAL;
        printf("[MDNS] Reannounce loop: every %ds for %ds\n",
               MDNS_REANNOUNCE_INTERVAL, MDNS_REANNOUNCE_SECONDS);

        for (int i = 1; i <= ticks; i++) {
            sleep(MDNS_REANNOUNCE_INTERVAL);

            DNSServiceErrorType apErr = kDNSServiceErr_NoError;
            DNSServiceErrorType raopErr = kDNSServiceErr_NoError;

            if (airplayRef) {
                TXTRecordRef apTxt = build_airplay_txt();
                apErr = update_registered_txt(airplayRef, &apTxt);
                TXTRecordDeallocate(&apTxt);
            }
            if (raopRef) {
                TXTRecordRef raopTxt = build_raop_txt();
                raopErr = update_registered_txt(raopRef, &raopTxt);
                TXTRecordDeallocate(&raopTxt);
            }

            int wireBytes = send_unsolicited_mdns_airplay_announcement();

            if (i == 1 || i % 5 == 0 || apErr || raopErr || wireBytes < 0) {
                printf("[MDNS] Reannounce tick %d/%d: airplay=%d raop=%d wire=%d\n",
                       i, ticks, apErr, raopErr, wireBytes);
            }
        }
        printf("[MDNS] Reannounce loop finished\n");
    });
}

/* ═══════════════════════════════════════════════════════════════
 * Main
 * ═══════════════════════════════════════════════════════════════ */

int main(int argc, char *argv[]) {
    /* Line-buffered stdout/stderr so logs survive SIGTERM (default is
     * fully-buffered when stdout is a file, which loses everything). */
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IOLBF, 0);

    /* Parse car name (--name X) early so g_instance_name/g_raop_name are set */
    parse_args(argc, argv);

    /* Parse remaining flags */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--hk") == 0) {
            g_useHK = true;
            printf("[SVC] HomeKit pairing ENABLED (features: %s)\n",
                   FEATURES_WITH_HK);
        }
    }

    signal(SIGPIPE, SIG_IGN);
    if (g_baa_broker_mode) {
        printf("[SVC] Starting pre-hotspot BAA broker mode\n");
        return run_baa_broker();
    }
    g_event_send_lock = dispatch_semaphore_create(1);
    g_app_send_lock = dispatch_semaphore_create(1);
    g_video_config_lock = dispatch_semaphore_create(1);
    g_hid_send_queue = dispatch_queue_create(
        "com.reng.showcase.hid", DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(g_hid_send_queue,
                              dispatch_get_global_queue(
                                  DISPATCH_QUEUE_PRIORITY_HIGH, 0));
    if (!ensure_pair_context()) {
        printf("[SVC] FATAL: could not initialize pairing context\n");
        return 1;
    }

    printf("[SVC] CarPlay Network Services v5.1 (real Ed25519 pk, no HK)\n");
    printf("[SVC] DeviceID:  %s\n", DEVICE_ID);
    printf("[SVC] Features:  %s\n", g_useHK ? FEATURES_WITH_HK : FEATURES_NO_HK);
    printf("[SVC] Model:     %s\n", MODEL_NAME);
    printf("[SVC] srcvers:   %s\n", SOURCE_VERSION);
    printf("[SVC] HK:        %s\n", g_useHK ? "YES" : "NO");
    printf("[SVC] RAOP name: %s\n", g_raop_name);
    printf("[SVC] Display:   %ux%u @ %u FPS\n",
           g_display_width, g_display_height, g_display_fps);
    printf("[SVC] pi:        %s\n", g_hk_pi);
    printf("[SVC] pk:        %s\n", g_hk_pk_hex);
    printf("[SVC] Ed25519:   REAL keypair (sk stored for pair-verify)\n");

    /* Load the certificate preheated by the long-lived broker helper. */
    load_baa_from_broker();

    /* Prefer bridge100 when it is already present. Personal Hotspot can
     * briefly remove and recreate the bridge during the Bluetooth-to-Wi-Fi
     * transition; DNS-SD interface 0 safely advertises on eligible
     * interfaces instead of killing the receiver during that race. */
    unsigned int br = if_nametoindex(g_wifi_interface);
    if (g_shared_wifi && (!br || wifi_ipv4_addr() == INADDR_ANY)) {
        printf("[SVC] FATAL: selected shared Wi-Fi interface %s has no IPv4 address\n", g_wifi_interface);
        return 1;
    }
    if (br == 0) {
        printf("[SVC] WARN: bridge100 is transiently unavailable; "
               "registering DNS-SD on all eligible interfaces\n");
    } else {
        printf("[SVC] %s ifIndex = %u\n", g_wifi_interface, br);
    }

    /* Start AirPlay HTTP/RTSP server on port 7000 */
    if (!start_airplay_server(AIRPLAY_PORT)) {
        printf("[SVC] FATAL: cannot listen on AirPlay port %d; aborting\n",
               AIRPLAY_PORT);
        return 1;
    }

    /* ── Register _airplay._tcp ── */
    printf("[MDNS] Registering _airplay._tcp on port %d (if=%u)...\n",
           AIRPLAY_PORT, br);
    DNSServiceRef regRef = NULL;
    TXTRecordRef apTxt = build_airplay_txt();
    DNSServiceErrorType err = DNSServiceRegister(
        &regRef, kDNSServiceFlagsKnownUnique, br,
        g_instance_name, "_airplay._tcp",
        NULL, SRV_HOSTNAME, htons(AIRPLAY_PORT),
        TXTRecordGetLength(&apTxt), TXTRecordGetBytesPtr(&apTxt),
        reg_callback, NULL);
    if (err != kDNSServiceErr_NoError) {
        printf("[MDNS] _airplay._tcp register FAILED: %d\n", err);
    } else {
        DNSServiceProcessResult(regRef);
        printf("[MDNS] _airplay._tcp registered\n");
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            while (1) {
                DNSServiceErrorType e = DNSServiceProcessResult(regRef);
                if (e != kDNSServiceErr_NoError) {
                    printf("[MDNS] _airplay._tcp error: %d\n", e);
                    break;
                }
            }
        });
    }
    TXTRecordDeallocate(&apTxt);

    /* ── Register _raop._tcp ──
     * CRITICAL: Every working AirPlay 2 receiver needs BOTH services.
     * Name format: AABBCCDDEEFF@DeviceName (MAC without colons @ name)
     * Port: same as AirPlay (7000). */
    printf("[MDNS] Registering _raop._tcp as '%s' on port %d (if=%u)...\n",
           g_raop_name, AIRPLAY_PORT, br);
    DNSServiceRef raopRef = NULL;
    TXTRecordRef raopTxt = build_raop_txt();
    err = DNSServiceRegister(
        &raopRef, kDNSServiceFlagsKnownUnique, br,
        g_raop_name, "_raop._tcp",
        NULL, SRV_HOSTNAME, htons(AIRPLAY_PORT),
        TXTRecordGetLength(&raopTxt), TXTRecordGetBytesPtr(&raopTxt),
        reg_callback, NULL);
    if (err != kDNSServiceErr_NoError) {
        printf("[MDNS] _raop._tcp register FAILED: %d\n", err);
    } else {
        DNSServiceProcessResult(raopRef);
        printf("[MDNS] _raop._tcp registered\n");
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            while (1) {
                DNSServiceErrorType e = DNSServiceProcessResult(raopRef);
                if (e != kDNSServiceErr_NoError) {
                    printf("[MDNS] _raop._tcp error: %d\n", e);
                    break;
                }
            }
        });
    }
    TXTRecordDeallocate(&raopTxt);

    /* iOS can join the Personal Hotspot after our first unsolicited mDNS
     * advertisements have already gone out. Keep nudging mDNSResponder to
     * re-announce _airplay/_raop while the phone is expected to join. */
    start_mdns_reannounce_loop(regRef, raopRef);

    /* Browse for _carplay-ctrl._tcp on the active Wi-Fi network.
     * Browse fires immediately with cached results, but ctrl_connect_thread
     * re-resolves with kDNSServiceFlagsForceMulticast on each round,
     * so stale ports get refreshed automatically. */
    printf("[MDNS] Browsing for _carplay-ctrl._tcp on %s (if=%u)...\n",
           g_shared_wifi ? "shared Wi-Fi" : "bridge100", br);
    DNSServiceRef browseRef = NULL;
    err = DNSServiceBrowse(&browseRef, 0, br,
                           "_carplay-ctrl._tcp", NULL,
                           browse_callback, NULL);
    if (err != kDNSServiceErr_NoError) {
        printf("[MDNS] Browse failed: %d\n", err);
    } else {
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            while (1) {
                DNSServiceErrorType e = DNSServiceProcessResult(browseRef);
                if (e != kDNSServiceErr_NoError) {
                    printf("[MDNS] Browse error: %d\n", e);
                    break;
                }
            }
        });
    }

    printf("[SVC] All services running. Ctrl-C to stop.\n\n");
    while (1) sleep(60);
    return 0;
}
