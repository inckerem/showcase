/*
 * Showcase.m - Wireless CarPlay receiver application
 *
 * Self-contained orchestrator app with state machine, car management,
 * hotspot credential storage, receiver media, touch input, and lifecycle
 * recovery for jailbroken iPhones and iPads.
 *
 * Compile (on-device):
 *   clang -fobjc-arc -isysroot /tmp/iPhoneOS10.3.sdk \
 *         -o Showcase Showcase.m \
 *         -framework UIKit -framework AVFoundation -framework AudioToolbox \
 *         -framework CoreMedia -framework Foundation -framework Security \
 *         -Wl,-undefined,dynamic_lookup
 */

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <Security/Security.h>
#import "video_in_car.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <pthread.h>
#include <spawn.h>
#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <float.h>
#include <math.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <mach/mach_time.h>
#include <notify.h>
#include "baa_broker.h"

extern char **environ;

/* ═══════════════════════════════════════════════════════════════
 * Languages
 *
 * English strings are the keys; <language>.lproj/Localizable.strings in the
 * app bundle holds the others. Showcase follows the device's preferred
 * languages unless one is chosen in Settings. The app runs as root, whose
 * preferences do not carry the user's languages, so mobile's are read.
 * ═══════════════════════════════════════════════════════════════ */

#define LANGUAGE_KEY @"appLanguage"
#define MOBILE_GLOBAL_PREFERENCES @"/var/mobile/Library/Preferences/.GlobalPreferences.plist"

static NSArray<NSString *> *showcase_languages(void) {
    return @[@"en", @"fr", @"es", @"zh-Hans", @"ja", @"tr"];
}

/* The language's own name, as iOS lists it. */
static NSString *showcase_language_name(NSString *language) {
    NSDictionary *names = @{@"en": @"English", @"fr": @"Français", @"es": @"Español",
                            @"zh-Hans": @"简体中文", @"ja": @"日本語", @"tr": @"Türkçe"};
    return names[language] ?: language;
}

static NSString *showcase_device_language(void) {
    NSArray *preferred = [NSDictionary dictionaryWithContentsOfFile:MOBILE_GLOBAL_PREFERENCES][@"AppleLanguages"];
    if (![preferred isKindOfClass:[NSArray class]] || !preferred.count) preferred = [NSLocale preferredLanguages];
    for (NSString *tag in preferred) {
        if (![tag isKindOfClass:[NSString class]]) continue;
        NSString *lower = tag.lowercaseString;
        if ([lower hasPrefix:@"zh"]) return @"zh-Hans";
        for (NSString *language in showcase_languages())
            if ([lower isEqualToString:language] || [lower hasPrefix:[language stringByAppendingString:@"-"]])
                return language;
    }
    return @"en";
}

static NSBundle *g_language_bundle;
static BOOL g_language_loaded;

/* The chosen language, or nil to follow the device. */
static NSString *showcase_chosen_language(void) {
    NSString *chosen = [[NSUserDefaults standardUserDefaults] stringForKey:LANGUAGE_KEY];
    return [showcase_languages() containsObject:chosen] ? chosen : nil;
}

static NSString *showcase_language(void) {
    return showcase_chosen_language() ?: showcase_device_language();
}

static void showcase_set_language(NSString *language) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (language) [d setObject:language forKey:LANGUAGE_KEY];
    else [d removeObjectForKey:LANGUAGE_KEY];
    [d synchronize];
    g_language_loaded = NO;
}

static NSString *L(NSString *english) {
    if (!g_language_loaded) {
        NSString *language = showcase_language();
        NSString *path = [language isEqualToString:@"en"] ? nil
            : [[NSBundle mainBundle] pathForResource:language ofType:@"lproj"];
        g_language_bundle = path ? [NSBundle bundleWithPath:path] : nil;
        g_language_loaded = YES;
    }
    return g_language_bundle ? [g_language_bundle localizedStringForKey:english value:english table:nil] : english;
}

/* ═══════════════════════════════════════════════════════════════
 * Application logger
 * ═══════════════════════════════════════════════════════════════ */

#define CONNECTION_STEPS_KEY @"kcsShowConnectionSteps"
#define LOG_DIR     "/var/mobile/Library/Showcase/logs"
#define APP_LOG     LOG_DIR "/app.log"
/* app.log is written for every launch and every session, diagnostics on or
 * off. Past this size it moves to app.previous.log so it can never outgrow
 * the diagnostics archive or the disk of a small iPad. The name ends in .log
 * so the diagnostics archive picks it up and may keep its newest bytes. */
#define APP_LOG_PREVIOUS LOG_DIR "/app.previous.log"
/* Name used for the rotated log up to 1.0~beta5. */
#define APP_LOG_PREVIOUS_LEGACY APP_LOG ".1"
#define APP_LOG_MAX_BYTES (2 * 1024 * 1024)
#define TCPDUMP_DIR  "/var/mobile/Library/Showcase/dumps"
#define TCPDUMP_LOG  TCPDUMP_DIR "/tcpdump.log"
#define TCPDUMP_MAX_SECONDS 300
#define DIAGNOSTICS_ARCHIVE_MAX_BYTES (8 * 1024 * 1024)
/* Room kept for environment.txt, command output and tar headers. */
#define DIAGNOSTICS_ARCHIVE_RESERVE_BYTES (1024 * 1024)
#define DIAGNOSTICS_TAR_ENTRY_OVERHEAD 1024
#define DIAGNOSTICS_ENABLED_KEY @"diagnosticsEnabled"
#define RECEIVER_AUDIO_KEY      @"receiverAudioEnabled"
#define RIGHT_HAND_DRIVE_KEY    @"rightHandDriveDock"
#define SMOOTH_VIDEO_KEY        @"preferSmoothVideo"
#define QUALITY_VIDEO_KEY       @"prioritizeVideoQuality"
#define VIDEO_WIDTH_KEY         @"videoWidth"
#define VIDEO_HEIGHT_KEY        @"videoHeight"
#define VIDEO_FPS_KEY           @"videoFramesPerSecond"
#define AUTO_START_KEY          @"startCarPlayOnLaunch"
#define DEDICATED_RADIO_KEY     @"leaveOtherWiFiDuringCarPlay"
#define HELD_WIFI_NETWORK_KEY   @"heldWiFiNetworkSSID"
#define HOTSPOT_OWNED_KEY       @"hotspotStartedByShowcase"
/* Set while the hotspot retry has Wi-Fi powered off; cleared once it is on. */
#define WIFI_POWER_CYCLE_KEY    @"wifiPowerCycleInProgress"
#define SHARED_WIFI_KEY         @"useExistingWiFi"
/* Beta 6 turns Prioritize Quality on once; later choices are kept. */
#define QUALITY_DEFAULT_SET_KEY @"qualityDefaultApplied"
#define USAGE_KEY               @"kcsAnonymousUsageEnabled"
#define USAGE_ID_KEY            @"kcsAnonymousUsageID"
#define USAGE_SENT_KEY          @"kcsAnonymousUsageSentPayload"
#define USAGE_SENT_DATE_KEY     @"kcsAnonymousUsageSentDate"
#define GITHUB_URL              @"https://github.com/inckerem/showcase"
#define USAGE_URL               @"https://kcs.net.tr/repo/api/ping.php"
#define LOGS_URL                @"https://kcs.net.tr/repo/api/logs.php"
#define MIS_STATE_OFF           1022
#define MIS_STATE_ON            1023
#define SHOWCASE_BT_PROGRESS_NOTIFICATION "com.rostane.showcase.bt-progress"
#define BT_PROGRESS_CONNECTED   0x01ULL
#define BT_PROGRESS_AUTHORIZED  0x02ULL
#define BT_PROGRESS_IDENTIFIED  0x04ULL
#define BT_PROGRESS_WIFI_SENT   0x08ULL
static FILE *g_logfile = NULL;
/* Every thread logs, and Clear Logs swaps the file from the main thread while
 * a session may be running; all access to g_logfile goes through this lock. */
static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;

static uint64_t monotonic_nanos_now(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * NSEC_PER_SEC + (uint64_t)now.tv_nsec;
}

static void ip_log(const char *fmt, ...) {
    char ts[32];
    time_t t = time(NULL);
    struct tm tm; localtime_r(&t, &tm);
    strftime(ts, sizeof(ts), "%H:%M:%S", &tm);
    uint64_t monotonicNanos = monotonic_nanos_now();
    pthread_mutex_lock(&g_log_lock);
    if (!g_logfile) {
        pthread_mutex_unlock(&g_log_lock);
        return;
    }
    fprintf(g_logfile, "[%s mono=%llu.%06llu] ", ts,
            (unsigned long long)(monotonicNanos / NSEC_PER_SEC),
            (unsigned long long)((monotonicNanos % NSEC_PER_SEC) / 1000ULL));
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_logfile, fmt, ap);
    va_end(ap);
    fprintf(g_logfile, "\n");
    fflush(g_logfile);
    /* An iPad left in the car keeps one launch for days; rotate in place. */
    long size = ftell(g_logfile);
    if (size > APP_LOG_MAX_BYTES) {
        fclose(g_logfile);
        rename(APP_LOG, APP_LOG_PREVIOUS);
        g_logfile = fopen(APP_LOG, "a");
    }
    pthread_mutex_unlock(&g_log_lock);
}

static void ip_log_open(void) {
    mkdir("/var/mobile/Library/Showcase", 0755);
    mkdir(LOG_DIR, 0755);
    pthread_mutex_lock(&g_log_lock);
    struct stat logStat;
    if (stat(APP_LOG_PREVIOUS_LEGACY, &logStat) == 0) {
        if (stat(APP_LOG_PREVIOUS, &logStat) == 0) unlink(APP_LOG_PREVIOUS_LEGACY);
        else rename(APP_LOG_PREVIOUS_LEGACY, APP_LOG_PREVIOUS);
    }
    if (!g_logfile && stat(APP_LOG, &logStat) == 0 &&
        logStat.st_size > APP_LOG_MAX_BYTES)
        rename(APP_LOG, APP_LOG_PREVIOUS);
    if (!g_logfile) g_logfile = fopen(APP_LOG, "a");
    if (g_logfile) {
        fprintf(g_logfile, "\n══════════════ Showcase launch ══════════════\n");
        fflush(g_logfile);
    }
    pthread_mutex_unlock(&g_log_lock);
}

static void ip_log_close(void) {
    pthread_mutex_lock(&g_log_lock);
    if (g_logfile) {
        fclose(g_logfile);
        g_logfile = NULL;
    }
    pthread_mutex_unlock(&g_log_lock);
}

/* ═══════════════════════════════════════════════════════════════
 * Configuration
 * ═══════════════════════════════════════════════════════════════ */

#define APP_NAME          "Showcase KCS"
/* Release builds pass APP_VERSION from the VERSION file. */
#ifndef APP_VERSION
#define APP_VERSION       "development"
#endif
#ifndef PACKAGE_VERSION
#define PACKAGE_VERSION   "development"
#endif
#define APP_AUTHOR        "Kerem Cloud Services"
#define SOCK_PATH         "/tmp/ipadplay.sock"   /* IPC socket — kept for compat with carplay_services */
#define BLUETOOTHD_PLIST  "/System/Library/LaunchDaemons/com.apple.bluetoothd.plist"
#define BT_READY_PATH     "/tmp/showcase_bt_ready"
#define BLUETOOL_PLIST    "/System/Library/LaunchDaemons/com.apple.BlueTool.plist"
#ifdef SHOWCASE_ROOTLESS
#define JB_PREFIX         "/var/jb"
#ifndef SHOWCASE_BTSTACK_PLIST
#define SHOWCASE_BTSTACK_PLIST JB_PATH("/Library/LaunchDaemons/ch.ringwald.BTstack.plist")
#endif
#ifndef SHOWCASE_BTSTACK_SOCKET
#define SHOWCASE_BTSTACK_SOCKET "/tmp/BTstack"
#endif
#else
#define JB_PREFIX         ""
#ifndef SHOWCASE_BTSTACK_PLIST
#define SHOWCASE_BTSTACK_PLIST "/Library/LaunchDaemons/ch.ringwald.BTstack.plist"
#endif
#ifndef SHOWCASE_BTSTACK_SOCKET
#define SHOWCASE_BTSTACK_SOCKET "/tmp/BTstack"
#endif
#endif
#define JB_PATH(path)     JB_PREFIX path
#define BTSTACK_PLIST     SHOWCASE_BTSTACK_PLIST
#define BTSTACK_SOCKET    SHOWCASE_BTSTACK_SOCKET
#ifndef SHOWCASE_BTDAEMON_PATH
#define SHOWCASE_BTDAEMON_PATH JB_PATH("/usr/bin/BTdaemon")
#endif
#define BTDAEMON_PATH     SHOWCASE_BTDAEMON_PATH
#ifndef SHOWCASE_BTSTACK_DYLIB_PATH
#define SHOWCASE_BTSTACK_DYLIB_PATH JB_PATH("/usr/lib/libBTstack.dylib")
#endif
#define BTSTACK_DYLIB_PATH SHOWCASE_BTSTACK_DYLIB_PATH
#ifndef SHOWCASE_BTSTACK_LOG_PATH
#define SHOWCASE_BTSTACK_LOG_PATH "/var/log/BTstack.log"
#endif
#ifdef SHOWCASE_ROOTLESS
#define BT_HELPER_NAME    "CarDisplaySim"
#define SVC_HELPER_NAME   "CarPlay Simulator"
#else
#define BT_HELPER_NAME    "carplay_bt"
#define SVC_HELPER_NAME   "carplay_services"
#endif
#define AP_INTERFACE      "bridge100"
#define PHONE_CANVAS_W    1024.0
#define PHONE_CANVAS_H    768.0
#define BTSTACK_PREFS_NAME "ch.ringwald.btstack.plist"
#define BTSTACK_PREFS "/var/mobile/Library/Preferences/" BTSTACK_PREFS_NAME

/* IPC message types */
#define MSG_VIDEO_CONFIG  0x01
#define MSG_VIDEO_FRAME   0x02
#define MSG_TOUCH         0x03
#define MSG_STATUS        0x04   /* services → app, 1 byte status code */
#define MSG_APP_VISIBILITY 0x05  /* app → services, 1 while foreground */
#define MSG_VIDEO_TIMING  0x06   /* services → app, uint32 latency in ms */
#define MSG_VIDEO_RESYNC  0x07   /* app → services, renderer needs keyframe */
#define MSG_AUDIO_CONFIG  0x08   /* services → app, negotiated audio stream */
#define MSG_AUDIO_PACKET  0x09   /* services → app, decrypted RTP payload */
#define MSG_BT_HANDOFF    0x0A   /* services → app, end Bluetooth transport */
#define MSG_AUDIO_RENDER  0x0B   /* app → services, hardware render clock */
#define MSG_AUDIO_CONTROL 0x0C   /* services → app, buffered playback control */
#define MSG_AUDIO_RESYNC  0x0F   /* app → services, uint32 streamType: no player, re-send AUDIO_CONFIG */
#define VIDEO_FRAME_METADATA_SIZE 56
#define VIDEO_STALE_RECOVERY_MIN_MS 250.0

#define AUDIO_CONTROL_PAUSE  0
#define AUDIO_CONTROL_RESUME 1
#define AUDIO_CONTROL_FLUSH  2
#define AUDIO_CONTROL_STOP   3

#define STATUS_IPHONE_CONNECTED     0x01
#define STATUS_PAIR_SETUP_COMPLETE  0x02
#define STATUS_PAIR_VERIFY_COMPLETE 0x03
#define STATUS_STREAM_SETUP         0x04
#define STATUS_PAIR_SETUP_STARTED   0x05
#define STATUS_AUTH_COMPLETE        0x06
#define STATUS_SESSION_SETUP        0x07
#define STATUS_HOST_UI_REQUESTED    0x08

#define TOUCH_DOWN  0
#define TOUCH_MOVE  1
#define TOUCH_UP    2
#define TOUCH_CANCEL 3

typedef NS_ENUM(NSInteger, ShowcaseState) {
    StateIdle = 0,
    StateAwaitingAP,
    StatePreparingBT,
    StatePreparingNet,
    StateAwaitingPhone,
    StateActive,
    StateStopping,
};

static const char *launchctl_path(void) {
#ifdef SHOWCASE_ROOTLESS
    static const char *paths[] = {
        "/var/jb/usr/bin/launchctl",
        "/var/jb/bin/launchctl",
        "/bin/launchctl",
        "/usr/bin/launchctl",
        NULL
    };
#else
    static const char *paths[] = {
        "/bin/launchctl",
        "/usr/bin/launchctl",
        "/var/jb/usr/bin/launchctl",
        "/var/jb/bin/launchctl",
        NULL
    };
#endif
    for (int i = 0; paths[i]; i++) {
        if (access(paths[i], X_OK) == 0) return paths[i];
    }
    return NULL;
}

/*
 * Hand the controller back to Apple's stack: BlueTool first, because
 * bluetoothd asks it to initialise the chip, then bluetoothd.
 *
 * The rootful BTstack daemon unloads BlueTool when it powers the controller
 * on and only reloads it in a clean power-off path that launchctl unload
 * never reaches. Without BlueTool, bluetoothd retries forever: measured on an
 * iPad4,2, bluetoothd 52% plus powerd 43% CPU until reboot. While bluetoothd
 * itself is unloaded, launchd and mediaserverd keep looking it up and burn
 * 57% and 50%. Loading an already loaded job is harmless.
 */
static int run_blocking(const char *path, char *const argv[]);
#define BT_GUARD_DIR "/var/root/Library/ShowcaseBluetooth"
#define BT_GUARD_PLIST BT_GUARD_DIR "/recovery.plist"
#define BT_GUARD_READY BT_GUARD_DIR "/ready"
#define BT_GUARD_RESTORE BT_GUARD_DIR "/restore"
#define BT_GUARD_LABEL "com.reng.showcase.bluetooth-recovery"
/* The app recreates this while it runs; the guard deletes it every second.
 * kill -0 still succeeds for a process iOS has suspended, so a heartbeat the
 * guard misses for 30 s means the app is frozen with Bluetooth taken. */
#define BT_GUARD_HEARTBEAT BT_GUARD_DIR "/heartbeat"
/* Left by the guard when a missed heartbeat made it hand Bluetooth back and
 * exit. The flow that armed it must not take the controller again. */
#define BT_GUARD_RECLAIMED BT_GUARD_DIR "/reclaimed"
#define BLUETOOL_LABEL "com.apple.BlueTool"
#define BLUETOOTHD_LABEL "com.apple.bluetoothd"
/* Exists while BTstack owns the controller; the Taurine package's BTQuiet
 * throttles Bluetooth clients' reconnects only then. /tmp is emptied at boot. */
#define BT_OWNED_FLAG "/tmp/showcase_bt_owned"
#ifdef SHOWCASE_TAURINE
/* Controller init takes about thirty seconds on an A10 iPad on iOS 14. */
#define BT_READY_SECONDS 45
#define BT_RETRY_READY_SECONDS 45
#else
#define BT_READY_SECONDS 12
#define BT_RETRY_READY_SECONDS 20
#endif

static BOOL stop_bluetooth_guard(void) {
    const char *ctl = launchctl_path();
    if (!ctl) return NO;
    if (access(BT_GUARD_PLIST, F_OK) != 0) return errno == ENOENT;
    char *args[] = { (char *)"launchctl", (char *)"unload",
                     (char *)BT_GUARD_PLIST, NULL };
    if (run_blocking(ctl, args) != 0 &&
        (access(BT_GUARD_READY, F_OK) == 0 ||
         access(BT_GUARD_RESTORE, F_OK) == 0)) {
        /* Markers survive a reboot/ldrestart/panic but the ad hoc job does
         * not: if launchd no longer knows the guard, nothing live owns them. */
        char *list[] = { (char *)"launchctl", (char *)"list",
                         (char *)BT_GUARD_LABEL, NULL };
        if (run_blocking(ctl, list) == 0) return NO;
        ip_log("[BT] recovery guard not loaded; clearing stale markers");
    }
    unlink(BT_GUARD_READY);
    unlink(BT_GUARD_RESTORE);
    return YES;
}

static BOOL restore_system_bluetooth(const char *reason);
static BOOL hand_back_system_bluetooth(const char *reason);

static void touch_bluetooth_guard_heartbeat(void) {
    if (access(BT_GUARD_HEARTBEAT, F_OK) == 0) return;
    int fd = open(BT_GUARD_HEARTBEAT, O_WRONLY | O_CREAT | O_NOFOLLOW, 0600);
    if (fd >= 0) close(fd);
}

/* Off the main thread, so only a suspended (or dead) app stops it. */
static void start_bluetooth_guard_heartbeat(void) {
    static dispatch_source_t timer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW,
                                  2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
        dispatch_source_set_event_handler(timer, ^{ touch_bluetooth_guard_heartbeat(); });
        dispatch_resume(timer);
    });
}

/* launchd owns this shell, so an app crash/force-quit cannot kill recovery.
 * Arm it before removing Apple's services; disarm only after returning them.
 * All shell inputs are positional arguments, never interpolated commands. */
static BOOL start_bluetooth_guard(void) {
    const char *ctl = launchctl_path();
    if (!ctl) return NO;
    mkdir(BT_GUARD_DIR, 0700);
    struct stat st;
    if (lstat(BT_GUARD_DIR, &st) || !S_ISDIR(st.st_mode) ||
        st.st_uid != 0 || (st.st_mode & 077) != 0) return NO;
    if (access(BT_GUARD_READY, F_OK) == 0) {
        if (!hand_back_system_bluetooth("previous recovery")) return NO;
    } else if (!stop_bluetooth_guard()) return NO;
    unlink(BT_GUARD_HEARTBEAT);
    unlink(BT_GUARD_RECLAIMED);
    touch_bluetooth_guard_heartbeat();
    start_bluetooth_guard_heartbeat();
    NSString *script =
        @"echo ready > \"$6\" || exit 1; "
         "m=0; while [ ! -f \"${11}\" ] && kill -0 \"$1\" 2>/dev/null; do "
         "if [ -f \"${14}\" ]; then rm -f \"${14}\"; m=0; "
         "else m=$((m+1)); [ \"$m\" -ge 30 ] && break; fi; "
         "sleep 1; done; "
         /* The app is alive but frozen: tell it, before Bluetooth goes back,
          * that this flow lost the controller (bluetooth_guard_problem). */
         "if [ \"$m\" -ge 30 ]; then echo reclaimed > \"${15}\"; fi; "
         "\"$7\" -TERM \"${10}\" 2>/dev/null; "
         "\"$2\" unload \"$3\"; "
         /* A BTdaemon wedged in its BlueTool hand-off outlives the unload and
          * keeps the UART; reloading Apple's jobs on top of it fails. */
         "\"$7\" -KILL BTdaemon 2>/dev/null; "
         "n=0; while \"$7\" -0 BTdaemon 2>/dev/null; do "
         "n=$((n+1)); [ \"$n\" -ge 10 ] && exit 1; sleep 1; done; "
         "rm -f \"$8\"; "
         "if [ -f \"$4\" ]; then "
         "\"$2\" load \"$4\" || \"$2\" list \"${12}\" || exit 1; fi; "
         "\"$2\" load \"$5\" || \"$2\" list \"${13}\" || exit 1; "
         "rm -f \"$9\"; "
         "rm -f \"${11}\"; "
         "rm -f \"$6\"";
    NSDictionary *job = @{
        @"Label": @BT_GUARD_LABEL,
        @"ProgramArguments": @[@JB_PATH("/bin/sh"), @"-c", script,
            @"showcase-bluetooth-recovery", [NSString stringWithFormat:@"%d", getpid()],
            @(ctl), @BTSTACK_PLIST, @BLUETOOL_PLIST, @BLUETOOTHD_PLIST,
            @BT_GUARD_READY, @JB_PATH("/usr/bin/killall"), @BTSTACK_SOCKET,
            @BT_OWNED_FLAG, @BT_HELPER_NAME, @BT_GUARD_RESTORE,
            @BLUETOOL_LABEL, @BLUETOOTHD_LABEL, @BT_GUARD_HEARTBEAT,
            @BT_GUARD_RECLAIMED],
        @"RunAtLoad": @YES,
        @"KeepAlive": @{@"SuccessfulExit": @NO},
        @"ThrottleInterval": @10,
        @"EnvironmentVariables": @{@"PATH": @JB_PATH("/usr/bin") ":" JB_PATH("/bin") ":/usr/bin:/bin"},
        @"StandardOutPath": @LOG_DIR "/bluetooth-recovery.log",
        @"StandardErrorPath": @LOG_DIR "/bluetooth-recovery.log"
    };
    if (![job writeToFile:@BT_GUARD_PLIST atomically:YES]) return NO;
    char *args[] = { (char *)"launchctl", (char *)"load",
                     (char *)BT_GUARD_PLIST, NULL };
    if (run_blocking(ctl, args) != 0) return NO;
    for (int i = 0; i < 50; i++) {
        if (access(BT_GUARD_READY, F_OK) == 0) return YES;
        usleep(100000);
    }
    ip_log("[BT] recovery guard did not start; keeping system Bluetooth loaded");
    return NO;
}

/* nil while the recovery guard is armed for this flow, otherwise why the flow
 * must stop. Checked before every step that takes Apple's Bluetooth away: a
 * flow suspended in the background past the heartbeat timeout resumes after
 * the guard already handed Bluetooth back and exited, and taking it again
 * would leave the system without Bluetooth and without a guard. */
static NSString *bluetooth_guard_problem(void) {
    if (access(BT_GUARD_RECLAIMED, F_OK) == 0)
        return @"Bluetooth was handed back to iOS while Showcase was suspended.";
    const char *ctl = launchctl_path();
    if (!ctl) return @"launchctl was not found.";
    char *list[] = { (char *)"launchctl", (char *)"list",
                     (char *)BT_GUARD_LABEL, NULL };
    BOOL wasReady = access(BT_GUARD_READY, F_OK) == 0;
    if (wasReady) {
        if (run_blocking(ctl, list) == 0) return nil;
        /* launchctl can time out under load; a guard that is really gone
         * fails twice. */
        ip_log("[BT] recovery guard list failed; checking once more");
        if (run_blocking(ctl, list) == 0) return nil;
    }
    ip_log("[BT] recovery guard is not armed; arming it again");
    if (!start_bluetooth_guard()) return @"Bluetooth crash recovery could not start.";
    /* With READY still present, start_bluetooth_guard first handed Bluetooth
     * back to iOS (hand_back_system_bluetooth): this flow no longer owns the
     * controller and must not carry on with its takeover. */
    if (wasReady) return @"The Bluetooth recovery guard state was lost; "
                          "Bluetooth was handed back to iOS.";
    return nil;
}

static BOOL load_bluetooth_job(const char *ctl, const char *plist, const char *label) {
    char *load[] = { (char *)"launchctl", (char *)"load", (char *)plist, NULL };
    if (run_blocking(ctl, load) == 0) return YES;
    /* launchctl load can fail because launchd already knows about this job. */
    char *list[] = { (char *)"launchctl", (char *)"list", (char *)label, NULL };
    return run_blocking(ctl, list) == 0;
}

static BOOL restore_system_bluetooth(const char *reason) {
    const char *launchctl = launchctl_path();
    BOOL restored = launchctl &&
        ((access(BLUETOOL_PLIST, F_OK) != 0 && errno == ENOENT) ||
         load_bluetooth_job(launchctl, BLUETOOL_PLIST, BLUETOOL_LABEL)) &&
        load_bluetooth_job(launchctl, BLUETOOTHD_PLIST, BLUETOOTHD_LABEL);
    if (!restored) {
        if (access(BT_GUARD_READY, F_OK) == 0) {
            int fd = open(BT_GUARD_RESTORE, O_WRONLY | O_CREAT | O_NOFOLLOW, 0600);
            if (fd >= 0) close(fd);
        }
        ip_log("[BT] system Bluetooth restore failed (%s)", reason);
        return NO;
    }
    unlink(BT_OWNED_FLAG);
    ip_log("[BT] system Bluetooth restored (%s)", reason);
    return stop_bluetooth_guard();
}

/* ═══════════════════════════════════════════════════════════════
 * Globals
 * ═══════════════════════════════════════════════════════════════ */

static volatile int g_touch_fd = -1;
static volatile uint32_t g_touch_epoch = 0;
static pthread_mutex_t g_ipc_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t g_flow_epoch = 0;
static bool g_flow_cancelled = true;
static bool flow_cancelled(void) { return __atomic_load_n(&g_flow_cancelled, __ATOMIC_ACQUIRE); }
static uint32_t flow_epoch(void) { return __atomic_load_n(&g_flow_epoch, __ATOMIC_ACQUIRE); }
static dispatch_queue_t g_touch_write_queue = NULL;
static volatile float g_carplay_w = 0;
static volatile float g_carplay_h = 0;
static volatile int32_t g_video_suspended = 0;
static volatile int32_t g_video_needs_resync = 0;
static volatile uint32_t g_video_target_latency_ms = 75;
static volatile int32_t g_video_respect_timestamps = 0;
static volatile double g_video_sender_to_host_offset = 0.0;
static volatile int32_t g_video_timing_offset_valid = 0;

/* ── Sender-timeline clock recovery and presentation scheduling ───
 * Every VideoFrame carries params[0]: a 32.32 fixed-point instant on the
 * sender's session timeline. Presenting a frame needs that instant expressed in
 * host time, which means an offset between the two clocks plus a budget for
 * transport jitter.
 *
 * Offset. Estimated from the minimum of (hostArrival - senderTime): the
 * fastest-delivered frame is the one that suffered least queueing, so it is the
 * best available view of the true offset. The minimum is taken over a trailing
 * window rather than the whole session, otherwise a single unusually fast frame
 * anchors the timeline forever and the budget silently erodes. The applied
 * offset slews toward that target instead of stepping, because a step moves
 * every future frame's slot and shows up as a hitch.
 *
 * Budget. Fixed at the sender's latencyMs, frames whose transport delay exceeds
 * it miss their slot. The budget therefore tracks recent jitter and grows up to
 * the 2x latency that the AccessorySDK itself treats as the late threshold.
 *
 * Pacing. A frame that has missed its slot must not simply be dumped at "now":
 * after a hiccup a whole burst arrives at once, every frame lands within a
 * millisecond or two, and the display shows only the last of them — the same
 * collapse that displaying on arrival caused. Late frames are instead paced off
 * the previous frame's presentation time at slightly under one frame interval,
 * so the backlog drains in order and slightly faster than real time until it
 * rejoins the grid. This also makes presentation timestamps monotonic by
 * construction.
 * ──────────────────────────────────────────────────────────────── */
#define VIDEO_CLOCK_WINDOW_SECONDS  8.0    /* trailing window for the offset   */
#define VIDEO_CLOCK_SLEW_PER_SEC    0.004  /* 4 ms/s, both directions          */
#define VIDEO_CLOCK_RESET_SECONDS   5.0    /* beyond this, a new timeline      */
/* Budget sizing. The AccessorySDK never adds latencyMs to the display time at
 * all — it maps the timestamp through the synchronised clock and presents at
 * exactly that instant, using latencyMs only to decide what counts as late.
 * Our anchor is a delay minimum rather than a true NTP clock, so some budget is
 * required, but latencyMs is the sender's statement of expected latency and so
 * belongs as the ceiling, never the floor. Buffering is the expensive way to
 * buy smoothness: every millisecond here is a millisecond of touch response.
 * Pacing absorbs the tail instead. */
#define VIDEO_BUDGET_FLOOR_FRAMES   2.0    /* two frames of slack, ~33 ms      */
#define VIDEO_JITTER_DEVIATIONS     3.0    /* budget = mean + 3 deviations     */
#define VIDEO_JITTER_EWMA_SHIFT     16.0   /* smoothing for mean and deviation */
#define VIDEO_CATCHUP_GAP_FRACTION  0.80   /* drain bursts 20% faster than 1x  */
#define VIDEO_FRAME_INTERVAL_MIN    (1.0 / 240.0)
#define VIDEO_FRAME_INTERVAL_MAX    (1.0 / 15.0)

static double g_video_clock_offset = 0.0;   /* hostTime - senderTime, seconds */
static double g_video_clock_last_update = 0.0;
static bool   g_video_clock_valid = false;
static double g_video_window_min = 0.0;     /* min delay, current window      */
static double g_video_window_prev_min = 0.0;/* min delay, previous window     */
static double g_video_window_start = 0.0;
static bool   g_video_window_has_sample = false;
static double g_video_jitter_mean = 0.0;    /* EWMA of delay above offset     */
static double g_video_jitter_dev = 0.0;     /* EWMA of deviation from mean    */
static double g_video_budget_seconds = 0.0; /* applied jitter budget          */
static double g_video_last_pts = 0.0;       /* last scheduled presentation    */
static bool   g_video_last_pts_valid = false;
static double g_video_last_sender = 0.0;
static bool   g_video_last_sender_valid = false;
static double g_video_frame_interval = 1.0 / 60.0;  /* sender's actual cadence */

static void video_clock_reset(void) {
    g_video_clock_valid = false;
    g_video_clock_offset = 0.0;
    g_video_clock_last_update = 0.0;
    g_video_window_min = 0.0;
    g_video_window_prev_min = 0.0;
    g_video_window_start = 0.0;
    g_video_window_has_sample = false;
    g_video_jitter_mean = 0.0;
    g_video_jitter_dev = 0.0;
    g_video_budget_seconds = 0.0;
    g_video_last_pts = 0.0;
    g_video_last_pts_valid = false;
    g_video_last_sender = 0.0;
    g_video_last_sender_valid = false;
    g_video_frame_interval = 1.0 / 60.0;
}

/* Computes the presentation host time for a frame. outMissedSlot reports that
 * the frame's own slot had already passed, i.e. transport exceeded the budget,
 * and outLatenessSeconds by how much.
 *
 * Magnitude is what matters, not the count. Apple's own receiver, measured on a
 * wired link, reports roughly half its frames past their slot — but never by
 * more than about 11 ms, and its headroom sits around 33 ms. A high late count
 * with small magnitudes is normal; large magnitudes are the defect. */
static double video_clock_schedule(uint64_t senderTimestamp,
                                   double hostArrival,
                                   bool *outMissedSlot,
                                   double *outLatenessSeconds) {
    double senderSeconds = (double)senderTimestamp / 4294967296.0;

    /*
     * Normal path: use the NTP mapping measured on the AirPlay timing socket.
     * This is what CarPlaySDK does through
     * AirTunesClock_GetUpTicksNearSynchronizedNTPTime. Arrival time is not a
     * clock sample; it includes Wi-Fi and TCP jitter, so it must never move a
     * correctly synchronized presentation timestamp.
     */
    if (g_video_timing_offset_valid) {
        double pts = senderSeconds + g_video_sender_to_host_offset;
        bool missed = pts <= hostArrival;
        if (outMissedSlot) *outMissedSlot = missed;
        if (outLatenessSeconds)
            *outLatenessSeconds = missed ? hostArrival - pts : 0.0;
        if (g_video_last_sender_valid) {
            double senderDelta = senderSeconds - g_video_last_sender;
            if (senderDelta >= VIDEO_FRAME_INTERVAL_MIN &&
                senderDelta <= VIDEO_FRAME_INTERVAL_MAX)
                g_video_frame_interval = senderDelta;
        }
        g_video_budget_seconds = 0.0;
        g_video_clock_offset = g_video_sender_to_host_offset;
        g_video_clock_valid = true;
        g_video_last_pts = pts;
        g_video_last_pts_valid = true;
        g_video_last_sender = senderSeconds;
        g_video_last_sender_valid = true;
        return pts;
    }

    double observed = hostArrival - senderSeconds;
    double latencySeconds = (double)g_video_target_latency_ms / 1000.0;

    if (!g_video_clock_valid ||
        fabs(observed - g_video_clock_offset) > VIDEO_CLOCK_RESET_SECONDS) {
        g_video_clock_valid = true;
        g_video_clock_offset = observed;
        g_video_clock_last_update = hostArrival;
        g_video_window_min = observed;
        g_video_window_prev_min = observed;
        g_video_window_start = hostArrival;
        g_video_window_has_sample = true;
        g_video_jitter_mean = 0.0;
        g_video_jitter_dev = 0.0;
        g_video_budget_seconds = 0.0;
        g_video_last_pts_valid = false;
        g_video_last_sender_valid = false;
    }

    /* Trailing-window minimum, kept as two half-windows so the estimate can
     * rise again when the path genuinely slows down. */
    if (!g_video_window_has_sample || observed < g_video_window_min)
        g_video_window_min = observed;
    g_video_window_has_sample = true;
    double jitter = observed - g_video_clock_offset;
    if (jitter < 0) jitter = 0;
    double deviation = fabs(jitter - g_video_jitter_mean);
    g_video_jitter_mean += (jitter - g_video_jitter_mean) / VIDEO_JITTER_EWMA_SHIFT;
    g_video_jitter_dev  += (deviation - g_video_jitter_dev) / VIDEO_JITTER_EWMA_SHIFT;

    if (hostArrival - g_video_window_start >= VIDEO_CLOCK_WINDOW_SECONDS) {
        g_video_window_prev_min = g_video_window_min;
        g_video_window_min = observed;
        g_video_window_start = hostArrival;
    }

    double target = g_video_window_min < g_video_window_prev_min
                  ? g_video_window_min : g_video_window_prev_min;
    double elapsed = hostArrival - g_video_clock_last_update;
    if (elapsed > 0) {
        double allowed = elapsed * VIDEO_CLOCK_SLEW_PER_SEC;
        double delta = target - g_video_clock_offset;
        if (delta > allowed) delta = allowed;
        else if (delta < -allowed) delta = -allowed;
        g_video_clock_offset += delta;
    }
    g_video_clock_last_update = hostArrival;

    /* Budget from the smoothed jitter estimate. A window maximum was pinned at
     * the ceiling by a single bad frame per window and never recovered, which
     * spent the whole allowance on latency without buying smoothness. */
    double wanted = g_video_jitter_mean +
                    VIDEO_JITTER_DEVIATIONS * g_video_jitter_dev;
    double floorBudget = g_video_frame_interval * VIDEO_BUDGET_FLOOR_FRAMES;
    if (wanted < floorBudget) wanted = floorBudget;
    if (wanted > latencySeconds) wanted = latencySeconds;
    if (g_video_budget_seconds <= 0.0) g_video_budget_seconds = wanted;
    else if (elapsed > 0) {
        /* Grow quickly to stop dropping frames, shrink slowly to hold latency
         * down without oscillating. */
        double rate = (wanted > g_video_budget_seconds) ? 0.050 : 0.005;
        double allowed = elapsed * rate;
        double delta = wanted - g_video_budget_seconds;
        if (delta > allowed) delta = allowed;
        else if (delta < -allowed) delta = -allowed;
        g_video_budget_seconds += delta;
    }

    double gridPTS = senderSeconds + g_video_clock_offset + g_video_budget_seconds;

    /* Pace anything that missed its slot instead of dumping it at "now". */
    double interval = g_video_frame_interval;
    if (g_video_last_sender_valid) {
        double senderDelta = senderSeconds - g_video_last_sender;
        if (senderDelta >= VIDEO_FRAME_INTERVAL_MIN &&
            senderDelta <= VIDEO_FRAME_INTERVAL_MAX) {
            interval = senderDelta;
            g_video_frame_interval = senderDelta;
        }
    }
    double floorPTS = hostArrival;
    if (g_video_last_pts_valid) {
        floorPTS = g_video_last_pts + interval * VIDEO_CATCHUP_GAP_FRACTION;
        if (floorPTS < hostArrival) floorPTS = hostArrival;
    }

    bool missed = (gridPTS <= hostArrival);
    double pts = (gridPTS > floorPTS) ? gridPTS : floorPTS;
    if (outLatenessSeconds)
        *outLatenessSeconds = missed ? (hostArrival - gridPTS) : 0.0;

    g_video_last_pts = pts;
    g_video_last_pts_valid = true;
    g_video_last_sender = senderSeconds;
    g_video_last_sender_valid = true;
    if (outMissedSlot) *outMissedSlot = missed;
    return pts;
}

static double video_host_now(void) {
    return CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()));
}

/* AVSampleBufferDisplayLayer ignores presentationTimeStamp unless a control
 * timebase is attached — without one it paints every buffer as soon as it is
 * enqueued, which is the behaviour we are removing. Running the timebase on the
 * host clock at rate 1.0 makes sample PTS values plain host-time seconds. */
static void video_install_timebase(AVSampleBufferDisplayLayer *layer) {
    if (!layer || layer.controlTimebase) return;
    CMTimebaseRef timebase = NULL;
    OSStatus status = CMTimebaseCreateWithMasterClock(
        kCFAllocatorDefault, CMClockGetHostTimeClock(), &timebase);
    if (status != noErr || !timebase) {
        ip_log("timebase create failed (%d); falling back to immediate display",
               (int)status);
        return;
    }
    CMTimebaseSetTime(timebase, CMClockGetTime(CMClockGetHostTimeClock()));
    CMTimebaseSetRate(timebase, 1.0);
    layer.controlTimebase = timebase;
    CFRelease(timebase);
}

typedef NS_ENUM(uint8_t, CarPlayWLANAttachment) {
    CarPlayWLANAttachmentUnknown = 0,
    CarPlayWLANAttachmentHSIC,
    CarPlayWLANAttachmentPCIe,
};

static const char *carplay_wlan_attachment_name(
    CarPlayWLANAttachment attachment) {
    switch (attachment) {
        case CarPlayWLANAttachmentHSIC: return "HSIC";
        case CarPlayWLANAttachmentPCIe: return "PCIe";
        default: return "unknown";
    }
}

typedef struct {
    uint16_t width;
    uint16_t height;
    uint16_t nativeLong;
    uint16_t nativeShort;
    uint64_t pixelBudget;
    uint64_t physicalMemory;
    NSUInteger activeProcessors;
    uint16_t framesPerSecond;
    CarPlayWLANAttachment wlanAttachment;
} CarPlayDisplayProfile;

static const char *first_existing_tool(const char *const paths[]);

/* All callers own these spawned children. Reap on timeout so an
 * unresponsive system command cannot pin the serial connection queue. */
static int wait_for_command(pid_t pid, uint64_t deadline) {
    int status;
    for (;;) {
        pid_t done = waitpid(pid, &status, WNOHANG);
        if (done == pid) return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        if (done < 0 && errno != EINTR) return -1;
        if (monotonic_nanos_now() >= deadline) break;
        usleep(20000);
    }
    kill(pid, SIGKILL);
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return -1;
}

/* Children get stdin/stdout/stderr from their file actions and nothing else.
 * Without POSIX_SPAWN_CLOEXEC_DEFAULT a root helper spawned on one thread
 * inherits whatever this process has open at that instant: the IPC sockets,
 * app.log, or the write end of an ioreg capture pipe — which then never
 * reaches EOF while the helper lives. */
static int spawn_isolated(pid_t *pid, const char *path,
                          const posix_spawn_file_actions_t *actions,
                          char *const argv[]) {
    posix_spawnattr_t attr;
    int err = posix_spawnattr_init(&attr);
    if (err != 0) return err;
    err = posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);
    if (err == 0) err = posix_spawn(pid, path, actions, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    return err;
}

static NSData *capture_process_output(const char *path, char *const argv[]) {
    int pipes[2];
    if (!path || pipe(pipes) != 0) return nil;
    /* The dup2 file action clears the flag on the child's fd 1 only. */
    fcntl(pipes[0], F_SETFD, FD_CLOEXEC);
    fcntl(pipes[1], F_SETFD, FD_CLOEXEC);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, pipes[1], 1);
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addclose(&actions, pipes[0]);
    posix_spawn_file_actions_addclose(&actions, pipes[1]);

    pid_t pid = 0;
    int spawnError = spawn_isolated(&pid, path, &actions, argv);
    posix_spawn_file_actions_destroy(&actions);
    close(pipes[1]);
    if (spawnError != 0) {
        close(pipes[0]);
        return nil;
    }

    uint64_t deadline = monotonic_nanos_now() + 5 * NSEC_PER_SEC;
    NSMutableData *output = [NSMutableData data];
    uint8_t buffer[8192];
    BOOL complete = NO;
    for (;;) {
        uint64_t now = monotonic_nanos_now();
        if (now >= deadline) break;
        struct pollfd input = { .fd = pipes[0], .events = POLLIN };
        int remainingMs = (int)((deadline - now + 999999) / 1000000);
        int ready = poll(&input, 1, remainingMs);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) break;
        ssize_t count = read(pipes[0], buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count == 0) complete = YES;
        if (count <= 0 || output.length + (NSUInteger)count > 4 * 1024 * 1024) break;
        [output appendBytes:buffer length:(NSUInteger)count];
    }
    close(pipes[0]);
    int rc = wait_for_command(pid, complete ? deadline : monotonic_nanos_now());
    return complete && rc == 0 ? output : nil;
}

static NSString *wlan_ioreg_snapshot(BOOL fullTree) {
    const char *ioregPaths[] = { "/usr/sbin/ioreg", "/usr/bin/ioreg", NULL };
    const char *ioreg = first_existing_tool(ioregPaths);
    if (!ioreg) return nil;
    char *fullArgv[] = {
        (char *)"ioreg", (char *)"-l", (char *)"-w", (char *)"0", NULL
    };
    char *interfaceArgv[] = {
        (char *)"ioreg", (char *)"-r", (char *)"-c",
        (char *)"IO80211Interface", (char *)"-l", (char *)"-w",
        (char *)"0", NULL
    };
    NSData *data = capture_process_output(
        ioreg, fullTree ? fullArgv : interfaceArgv);
    if (!data.length) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

typedef NS_ENUM(NSInteger, BluetoothRegistryProbeState) {
    BluetoothRegistryProbeUnavailable = -1,
    BluetoothRegistryProbeMissing = 0,
    BluetoothRegistryProbeLegacyUART = 1,
    BluetoothRegistryProbeSkywalk = 2,
};

static BluetoothRegistryProbeState bluetooth_registry_probe(void) {
    @autoreleasepool {
        NSString *tree = wlan_ioreg_snapshot(YES);
        if (!tree.length) return BluetoothRegistryProbeUnavailable;

        BOOL uartService =
            [tree rangeOfString:@"<class AppleSimpleUARTSync"].location !=
                NSNotFound;
        BOOL bluetoothEndpoint =
            [tree rangeOfString:@"\"IOTTYBaseName\" = \"bluetooth\""].location !=
                NSNotFound ||
            [tree rangeOfString:@"\"device_type\" = <\"bluetooth\">"].location !=
                NSNotFound ||
            [tree rangeOfString:@"com.apple.uart.bluetooth"].location !=
                NSNotFound;
        BOOL convergedInterface =
            [tree rangeOfString:@"AppleConvergedIPCRTIInterface"].location !=
                NSNotFound ||
            [tree rangeOfString:@"AppleConvergedIPCInterface"].location !=
                NSNotFound;
        BOOL skywalkTransport =
            [tree rangeOfString:@"\"ACIPCInterfaceTransport\" = \"skywalk\""]
                    .location != NSNotFound;
        BOOL hciProtocol =
            [tree rangeOfString:@"\"ACIPCInterfaceProtocol\" = \"hci\""]
                    .location != NSNotFound;
        BOOL aclProtocol =
            [tree rangeOfString:@"\"ACIPCInterfaceProtocol\" = \"acl\""]
                    .location != NSNotFound;
        BOOL nexusUUID =
            [tree rangeOfString:@"IOSkywalkNexusUUID"].location != NSNotFound;
        if (convergedInterface && skywalkTransport && hciProtocol &&
            aclProtocol && nexusUUID) {
            return BluetoothRegistryProbeSkywalk;
        }
        return uartService && bluetoothEndpoint
            ? BluetoothRegistryProbeLegacyUART
            : BluetoothRegistryProbeMissing;
    }
}

static NSString *hardware_machine_identifier(void) {
    char machine[128] = {0};
    size_t length = sizeof(machine);
    if (sysctlbyname("hw.machine", machine, &length, NULL, 0) == 0 &&
        machine[0]) {
        machine[sizeof(machine) - 1] = '\0';
        return [NSString stringWithUTF8String:machine];
    }
    return @"unknown";
}

/* Tail of path that lies at or after byte offset `after`. A file that shrank
 * below `after` was cleared or replaced, so all of it is new. */
static NSString *bounded_log_tail_after(NSString *path, unsigned long long after,
                                        NSUInteger maxBytes, NSUInteger maxLines) {
    if (!path.length || maxBytes == 0 || maxLines == 0) return @"";
    @try {
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
        if (!handle) return @"";
        unsigned long long end = [handle seekToEndOfFile];
        if (after > end) after = 0;
        unsigned long long start = end > maxBytes ? end - maxBytes : 0;
        if (start < after) start = after;
        [handle seekToFileOffset:start];
        NSData *data = [handle readDataToEndOfFile];
        [handle closeFile];
        if (!data.length) return @"";

        NSString *text = [[NSString alloc] initWithData:data
                                               encoding:NSUTF8StringEncoding];
        if (!text) {
            text = [[NSString alloc] initWithData:data
                                         encoding:NSISOLatin1StringEncoding];
        }
        if (!text.length) return @"";
        NSArray<NSString *> *lines =
            [text componentsSeparatedByCharactersInSet:
                [NSCharacterSet newlineCharacterSet]];
        NSUInteger first = lines.count > maxLines ? lines.count - maxLines : 0;
        NSArray<NSString *> *tail =
            [lines subarrayWithRange:NSMakeRange(first, lines.count - first)];
        return [tail componentsJoinedByString:@"\n"];
    } @catch (__unused NSException *exception) {
        return @"";
    }
}

static NSString *bounded_log_tail(NSString *path, NSUInteger maxBytes,
                                  NSUInteger maxLines) {
    return bounded_log_tail_after(path, 0, maxBytes, maxLines);
}

static unsigned long long file_size_now(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && st.st_size > 0
        ? (unsigned long long)st.st_size : 0;
}

static NSString *bluetooth_failure_class(NSString *reason,
                                          NSString *combinedLogs,
                                          BluetoothRegistryProbeState registry) {
    NSString *lower = [[NSString stringWithFormat:@"%@\n%@",
                        reason ?: @"", combinedLogs ?: @""] lowercaseString];
    NSString *reasonLower = [reason.lowercaseString copy] ?: @"";
    if ([reasonLower containsString:@"btstack daemon is missing"])
        return @"btstack-daemon-missing";
    if ([reasonLower containsString:@"btstack library is missing"])
        return @"btstack-library-missing";
    if ([reasonLower containsString:@"launch daemon configuration is missing"])
        return @"btstack-launch-configuration-missing";
    /* Setup stages Showcase itself reports are named by the stage, not by
     * whatever an earlier attempt left in the logs. */
    if ([reasonLower containsString:@"launch daemon failed"])
        return @"btstack-launch-failed";
    if ([reasonLower containsString:@"did not create its control socket"])
        return @"btstack-daemon-socket-unavailable";
    if ([reasonLower containsString:@"could not be reset"] ||
        [reasonLower containsString:@"could not be restored for retry"])
        return @"apple-bluetooth-reset-failed";
    if ([reasonLower containsString:@"helper could not be started"])
        return @"bluetooth-helper-spawn-failed";
    if ([reasonLower containsString:@"no baa certificate"])
        return @"baa-certificate-unavailable";
    if ([reasonLower containsString:@"rejected its arguments"])
        return @"bluetooth-helper-arguments-invalid";
    if (registry == BluetoothRegistryProbeMissing)
        return @"supported-bluetooth-transport-not-present";
    if ([lower containsString:@"skywalk is present"] &&
        [lower containsString:@"userspace api is unavailable"])
        return @"converged-skywalk-api-unavailable";
    if ([lower containsString:@"skywalk:"] &&
        [lower containsString:@"channel create failed"])
        return @"converged-skywalk-channel-open-failed";
    if ([lower containsString:@"h4_open: ioctl failed"])
        return @"private-uart-endpoint-unavailable";
    if ([lower containsString:@"h4_open: socket failed"])
        return @"netgraph-control-socket-unavailable";
    if ([lower containsString:@"h4_open: connect failed"])
        return @"bluetooth-uart-connect-failed";
    if ([lower containsString:@"h4_open: getsockopt failed"] ||
        [lower containsString:@"h4_open: setsockopt failed"])
        return @"bluetooth-uart-configuration-failed";
    if ([lower containsString:@"btstack_event_poweron_failed"] ||
        [lower containsString:@"poweron_failed"])
        return @"controller-power-on-failed";
    if ([lower containsString:@"ioregisterforsystempower failed"])
        return @"bluetooth-power-registration-failed";
    if ([lower containsString:@"socket not available"])
        return @"btstack-daemon-socket-unavailable";
    if ([lower containsString:@"launch daemon failed"])
        return @"btstack-launch-failed";
    if ([lower containsString:@"ready sentinel"])
        return @"no-hci-events-before-timeout";
    return @"bluetooth-takeover-failed";
}

/* Classes that mean the controller itself cannot be driven on this model, as
 * opposed to a hand-off that stalled or a Showcase component that is broken.
 * A bare BTSTACK_EVENT_POWERON_FAILED is not one of them: BTstack also emits
 * it when the UART is still busy (EBUSY) or BlueTool's hand-off fails. */
static BOOL bluetooth_failure_class_is_unsupported(NSString *failureClass) {
    return [@[@"supported-bluetooth-transport-not-present",
              @"converged-skywalk-api-unavailable",
              @"converged-skywalk-channel-open-failed",
              @"private-uart-endpoint-unavailable"] containsObject:failureClass];
}

/* Classifies only this flow's last attempt: the retry helper's log when the
 * retry helper was really spawned, otherwise the first helper's log, plus the
 * BTstack daemon log written since daemonLogOffset. BTstack.log is launchd's
 * StandardOutPath and keeps every earlier session. */
static NSString *bluetooth_diagnostic_report(
    NSString *reason, BOOL retryAttempted, BOOL retrySpawned,
    unsigned long long daemonLogOffset,
    BluetoothRegistryProbeState registry, NSString **failureClassOut) {
    NSString *initial = bounded_log_tail(
        @LOG_DIR "/carplay_bt.log", 8192, 18);
    NSString *retry = retrySpawned
        ? bounded_log_tail(@LOG_DIR "/carplay_bt-retry.log", 8192, 18)
        : @"";
    NSString *daemon = bounded_log_tail_after(
        @SHOWCASE_BTSTACK_LOG_PATH, daemonLogOffset, 8192, 18);
    NSString *evidence = [NSString stringWithFormat:@"%@\n%@",
                          (retrySpawned ? retry : initial) ?: @"",
                          daemon ?: @""];
    NSString *failureClass =
        bluetooth_failure_class(reason, evidence, registry);
    if (failureClassOut) *failureClassOut = failureClass;
    NSString *registryText = registry == BluetoothRegistryProbeLegacyUART
        ? @"legacy-uart-present"
        : (registry == BluetoothRegistryProbeSkywalk
            ? @"converged-skywalk-present"
            : (registry == BluetoothRegistryProbeMissing
                ? @"supported-transport-missing" : @"unavailable"));
#ifdef SHOWCASE_ROOTLESS
    NSString *layout = @"rootless";
#else
    NSString *layout = @"rootful";
#endif

    NSMutableString *report = [NSMutableString string];
    [report appendString:@"Showcase Bluetooth compatibility report\n"];
    [report appendFormat:@"version=%s\n", APP_VERSION];
    [report appendFormat:@"device=%@\n", hardware_machine_identifier()];
    [report appendFormat:@"ios=%@\n", [UIDevice currentDevice].systemVersion];
    [report appendFormat:@"layout=%@ (diagnostic only)\n", layout];
    [report appendFormat:@"failure_class=%@\n", failureClass];
    [report appendFormat:@"stage=%@\n", reason ?: @"unknown"];
    [report appendFormat:@"euid=%u\n", geteuid()];
    [report appendFormat:@"registry=%@\n", registryText];
    [report appendFormat:@"helper=%s executable=%s\n", BT_HELPER_NAME,
        access([[[[NSBundle mainBundle] bundlePath]
            stringByAppendingPathComponent:@BT_HELPER_NAME] UTF8String],
            X_OK) == 0 ? "yes" : "no"];
    [report appendFormat:@"btdaemon=%s executable=%s\n", BTDAEMON_PATH,
        access(BTDAEMON_PATH, X_OK) == 0 ? "yes" : "no"];
    [report appendFormat:@"libbtstack=%s readable=%s\n", BTSTACK_DYLIB_PATH,
        access(BTSTACK_DYLIB_PATH, R_OK) == 0 ? "yes" : "no"];
    [report appendFormat:@"launch_plist=%s readable=%s\n", BTSTACK_PLIST,
        access(BTSTACK_PLIST, R_OK) == 0 ? "yes" : "no"];
    [report appendFormat:@"retry=%@\n",
        retrySpawned ? @"yes" : (retryAttempted ? @"setup-failed" : @"no")];
    if (initial.length)
        [report appendFormat:@"\ncarplay_bt tail:\n%@\n", initial];
    if (retry.length)
        [report appendFormat:@"\ncarplay_bt retry tail:\n%@\n", retry];
    if (daemon.length)
        [report appendFormat:@"\nBTstack daemon tail:\n%@\n", daemon];
    return report;
}

static CarPlayWLANAttachment wlan_attachment_class(void) {
    @autoreleasepool {
        NSString *tree = wlan_ioreg_snapshot(YES);
        if (!tree.length) return CarPlayWLANAttachmentUnknown;

        /*
         * Match instantiated transport services and device-tree compatibility
         * strings. Do not use the IOKitDiagnostics class table: a driver class
         * may be present with zero live instances on unrelated hardware.
         */
        NSArray<NSString *> *hsicMarkers = @[
            @"<class AppleBCMWLANBusInterfaceHSIC",
            @"<class AppleBCMWLANChipManagerHSIC",
            @"AppleBCMWLANBusInterfaceHSICShim",
            @"wlan-hsic"
        ];
        for (NSString *marker in hsicMarkers) {
            if ([tree rangeOfString:marker].location != NSNotFound)
                return CarPlayWLANAttachmentHSIC;
        }

        NSArray<NSString *> *pcieMarkers = @[
            @"<class AppleBCMWLANBusInterfacePCIe",
            @"<class AppleBCMWLANPCIe",
            @"wlan-pcie"
        ];
        for (NSString *marker in pcieMarkers) {
            if ([tree rangeOfString:marker].location != NSNotFound)
                return CarPlayWLANAttachmentPCIe;
        }
        return CarPlayWLANAttachmentUnknown;
    }
}

/* BEGIN display selector: plain C, compiled by tests/test_display_profile.py */
#define CARPLAY_MAX_WIDTH 1920
#define CARPLAY_MAX_PIXELS (1920ULL * 1080ULL)
#define CARPLAY_MAX_OPTIONS 8

typedef struct { uint16_t width, height; } CarPlayVideoSize;

typedef enum {
    CarPlayVideoCustom = 0,
    CarPlayVideoQuality,
    CarPlayVideoPerformance,
} CarPlayVideoPriority;

/* The stream is sized from the receiver's screen and capability, never from
 * jailbreak layout. One-gigabyte devices share memory bandwidth between
 * UIKit, VideoToolbox, the CarPlay service and the hotspot, so they default
 * to a 960x720-class stream; two gigabytes and above to 720p-class. */
static uint64_t carplay_default_budget(double nativeLong, double nativeShort,
                                       uint64_t memory, unsigned processors) {
    uint64_t pixelBudget = 960ULL * 720ULL;
    if (memory >= 1536ULL * 1024ULL * 1024ULL)
        pixelBudget = 1280ULL * 720ULL;
    if (memory >= 3ULL * 1024ULL * 1024ULL * 1024ULL && processors >= 4)
        pixelBudget = 1600ULL * 900ULL;
    if (memory >= 4ULL * 1024ULL * 1024ULL * 1024ULL && processors >= 6)
        pixelBudget = CARPLAY_MAX_PIXELS;
    uint64_t nativePixels = (uint64_t)nativeLong * (uint64_t)nativeShort;
    if (nativePixels > 0 && pixelBudget > nativePixels)
        pixelBudget = nativePixels;
    return pixelBudget;
}

/* Codec-friendly 16-pixel dimensions. The score rewards using the budget but
 * penalizes aspect error heavily, so the stream fills the screen unstretched. */
static CarPlayVideoSize carplay_fit(double nativeLong, double nativeShort, uint64_t pixelBudget) {
    double aspect = nativeShort > 0 ? nativeLong / nativeShort : (5.0 / 3.0);
    CarPlayVideoSize best = {800, 480};
    double bestScore = -DBL_MAX;
    uint16_t maxWidth = (uint16_t)(floor(MIN(nativeLong, (double)CARPLAY_MAX_WIDTH) / 16.0) * 16.0);
    for (uint16_t width = 640; width <= maxWidth; width = (uint16_t)(width + 16)) {
        uint16_t height = (uint16_t)(floor(((width / aspect) / 16.0) + 0.5) * 16.0);
        if (height < 360 || height > nativeShort) continue;
        uint64_t pixels = (uint64_t)width * height;
        if (pixels > pixelBudget) continue;
        double aspectError = fabs((double)width / height - aspect) / aspect;
        double score = (pixelBudget ? (double)pixels / (double)pixelBudget : 0) - aspectError * 10.0;
        if (score > bestScore) {
            bestScore = score;
            best.width = width;
            best.height = height;
        }
    }
    return best;
}

/* The resolutions offered in Settings, largest first, like the scaled
 * resolutions macOS lists for a display. Each step has about half to
 * two-thirds of the previous one's pixels and takes the size closest to the
 * screen's aspect ratio there (within 1%). The default is always listed, and
 * a size within a fifth of its pixels is left out. Returns how many. */
static unsigned carplay_resolution_options(double nativeLong, double nativeShort, CarPlayVideoSize fallback,
                                           CarPlayVideoSize out[CARPLAY_MAX_OPTIONS]) {
    double aspect = nativeShort > 0 ? nativeLong / nativeShort : (5.0 / 3.0);
    uint16_t maxWidth = (uint16_t)(floor(MIN(nativeLong, (double)CARPLAY_MAX_WIDTH) / 16.0) * 16.0);
    CarPlayVideoSize candidates[128];
    double errors[128];
    unsigned found = 0;
    for (uint16_t width = maxWidth; width >= 640 && found < 128; width = (uint16_t)(width - 16)) {
        uint16_t height = (uint16_t)(floor(((width / aspect) / 16.0) + 0.5) * 16.0);
        double error = fabs((double)width / height - aspect) / aspect;
        if (height < 360 || height > nativeShort || (uint64_t)width * height > CARPLAY_MAX_PIXELS || error > 0.01)
            continue;
        candidates[found].width = width;
        candidates[found].height = height;
        errors[found++] = error;
    }
    uint64_t fallbackPixels = (uint64_t)fallback.width * fallback.height;
    unsigned count = 0;
    uint64_t ceiling = found ? (uint64_t)candidates[0].width * candidates[0].height : 0;
    uint64_t floor_ = ceiling * 8 / 10;
    while (count < CARPLAY_MAX_OPTIONS - 1) {
        int best = -1;
        for (unsigned i = 0; i < found; i++) {
            uint64_t pixels = (uint64_t)candidates[i].width * candidates[i].height;
            if (pixels > ceiling || pixels <= floor_) continue;
            if (best < 0 || errors[i] < errors[best] - 1e-9) best = (int)i;
        }
        if (best < 0) break;
        uint64_t pixels = (uint64_t)candidates[best].width * candidates[best].height;
        if (pixels * 5 >= fallbackPixels * 6 || pixels * 5 <= fallbackPixels * 4)
            out[count++] = candidates[best];
        ceiling = pixels * 2 / 3;
        floor_ = pixels / 2;
    }
    unsigned at = 0;
    while (at < count && (uint64_t)out[at].width * out[at].height > fallbackPixels) at++;
    for (unsigned i = count; i > at; i--) out[i] = out[i - 1];
    out[at] = fallback;
    return count + 1;
}

/* Default: the hardware budget at the screen's rate. Quality: the largest
 * offered size at up to 60 fps. Performance: about half the default's pixels
 * at 30 fps, which roughly halves the bytes each frame puts on the hotspot
 * link. Custom: the chosen size and rate when they are still offered. */
static CarPlayVideoSize carplay_select_video(double nativeLong, double nativeShort, uint64_t memory,
                                             unsigned processors, uint16_t defaultFPS, uint16_t screenFPS,
                                             CarPlayVideoPriority priority, CarPlayVideoSize chosen,
                                             uint16_t chosenFPS, uint16_t *fps, uint64_t *budget) {
    uint64_t pixelBudget = carplay_default_budget(nativeLong, nativeShort, memory, processors);
    CarPlayVideoSize fallback = carplay_fit(nativeLong, nativeShort, pixelBudget);
    CarPlayVideoSize options[CARPLAY_MAX_OPTIONS];
    unsigned count = carplay_resolution_options(nativeLong, nativeShort, fallback, options);
    CarPlayVideoSize size = fallback;
    *fps = defaultFPS;
    if (priority == CarPlayVideoQuality) {
        size = options[0];
        *fps = (uint16_t)MAX(30, MIN(screenFPS, 60));
        pixelBudget = (uint64_t)size.width * size.height;
    } else if (priority == CarPlayVideoPerformance) {
        pixelBudget = MAX(640ULL * 384ULL, (pixelBudget * 9ULL) / 16ULL);
        size = carplay_fit(nativeLong, nativeShort, pixelBudget);
        *fps = MIN(defaultFPS, 30);
    } else {
        for (unsigned i = 0; i < count; i++)
            if (options[i].width == chosen.width && options[i].height == chosen.height) {
                size = chosen;
                pixelBudget = (uint64_t)size.width * size.height;
            }
        if (chosenFPS == 30 || (chosenFPS == 60 && screenFPS >= 60)) *fps = chosenFPS;
    }
    *budget = pixelBudget;
    return size;
}
/* END display selector */

/* Screen properties are initialized on the main thread at launch. The slow
 * Wi-Fi bus probe runs independently: callers never wait for ioreg. */
typedef struct {
    double nativeLong, nativeShort;
    uint64_t memory;
    unsigned processors;
    uint16_t screenFPS, defaultFPS;
    CarPlayWLANAttachment wlanAttachment;
    BOOL wlanSettled; /* the bus probe has reached its final answer */
} CarPlayDisplayHardware;

static CarPlayDisplayHardware carplay_display_hardware(void) {
    static CarPlayDisplayHardware hardware;
    static dispatch_once_t once;
    /* 0 = idle, 1 = probing, 2 = settled. An Unknown result (ioreg timed out
     * or was unreadable) goes back to idle so a later call probes again, up
     * to WLAN_PROBE_ATTEMPTS times, instead of pinning Unknown for the run. */
    enum { WLAN_PROBE_ATTEMPTS = 3 };
    static int probeState = 0;
    static int probeAttempts = 0;
    static int attachment = CarPlayWLANAttachmentUnknown;
    dispatch_once(&once, ^{
        UIScreen *screen = [UIScreen mainScreen];
        CGSize nativeSize = [screen respondsToSelector:@selector(nativeBounds)]
            ? screen.nativeBounds.size
            : CGSizeMake(screen.bounds.size.width * screen.scale,
                         screen.bounds.size.height * screen.scale);
        hardware.nativeLong = MAX(nativeSize.width, nativeSize.height);
        hardware.nativeShort = MIN(nativeSize.width, nativeSize.height);
        NSProcessInfo *process = [NSProcessInfo processInfo];
        hardware.memory = process.physicalMemory;
        hardware.processors = (unsigned)process.activeProcessorCount;
        NSInteger screenFPS = [screen respondsToSelector:@selector(maximumFramesPerSecond)]
            ? screen.maximumFramesPerSecond : 60;
        hardware.screenFPS = (uint16_t)MAX(30, MIN(screenFPS, 60));
    });
    int idle = 0;
    if (__atomic_compare_exchange_n(&probeState, &idle, 1, false,
                                    __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
        int attempt = __atomic_add_fetch(&probeAttempts, 1, __ATOMIC_ACQ_REL);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            int found = (int)wlan_attachment_class();
            __atomic_store_n(&attachment, found, __ATOMIC_RELEASE);
            BOOL settled = found != CarPlayWLANAttachmentUnknown ||
                attempt >= WLAN_PROBE_ATTEMPTS;
            __atomic_store_n(&probeState, settled ? 2 : 0, __ATOMIC_RELEASE);
        });
    }
    CarPlayDisplayHardware result = hardware;
    /* probeState is published after attachment, so a settled state implies
     * the attachment read below is the final one. */
    result.wlanSettled = __atomic_load_n(&probeState, __ATOMIC_ACQUIRE) == 2;
    result.wlanAttachment = (CarPlayWLANAttachment)__atomic_load_n(&attachment, __ATOMIC_ACQUIRE);
    /* Until the probe completes use the conservative HSIC-safe default. */
    result.defaultFPS = result.wlanAttachment == CarPlayWLANAttachmentPCIe
        ? result.screenFPS : 30;
    return result;
}

static CarPlayVideoPriority carplay_video_priority(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d boolForKey:QUALITY_VIDEO_KEY]) return CarPlayVideoQuality;
    if ([d boolForKey:SMOOTH_VIDEO_KEY]) return CarPlayVideoPerformance;
    return CarPlayVideoCustom;
}

static unsigned carplay_offered_resolutions(CarPlayVideoSize out[CARPLAY_MAX_OPTIONS], CarPlayVideoSize *fallback) {
    CarPlayDisplayHardware h = carplay_display_hardware();
    *fallback = carplay_fit(h.nativeLong, h.nativeShort,
        carplay_default_budget(h.nativeLong, h.nativeShort, h.memory, h.processors));
    return carplay_resolution_options(h.nativeLong, h.nativeShort, *fallback, out);
}

static CarPlayDisplayProfile preferred_carplay_display_profile(void) {
    CarPlayDisplayHardware h = carplay_display_hardware();
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    CarPlayVideoSize chosen = {
        (uint16_t)[d integerForKey:VIDEO_WIDTH_KEY], (uint16_t)[d integerForKey:VIDEO_HEIGHT_KEY]};
    uint16_t fps = 0;
    uint64_t budget = 0;
    CarPlayVideoSize size = carplay_select_video(h.nativeLong, h.nativeShort, h.memory, h.processors,
        h.defaultFPS, h.screenFPS, carplay_video_priority(), chosen,
        (uint16_t)[d integerForKey:VIDEO_FPS_KEY], &fps, &budget);
    CarPlayDisplayProfile profile = {
        .width = size.width,
        .height = size.height,
        .nativeLong = (uint16_t)h.nativeLong,
        .nativeShort = (uint16_t)h.nativeShort,
        .pixelBudget = budget,
        .physicalMemory = h.memory,
        .activeProcessors = h.processors,
        .framesPerSecond = fps,
        .wlanAttachment = h.wlanAttachment,
    };
    return profile;
}

/* ═══════════════════════════════════════════════════════════════
 * Dedicated radio: leave other Wi-Fi networks during CarPlay
 *
 * The receiver's single Wi-Fi radio otherwise stays joined to the home or
 * office network while it hosts the CarPlay hotspot. iOS puts the hotspot on
 * 2.4 GHz (channel 1, 6, or 11) and that network is usually on 5 GHz, so the
 * radio time-shares between two bands. Each time it serves the other network,
 * the hotspot channel goes dark: the iPhone's frames go unacknowledged and
 * queue, then arrive in bursts. Measured on an iPad4,2: with the home network
 * joined, 12% of received frames were discarded and video gaps reached 3 s;
 * hotspot only, frame delivery more than doubled and gaps fell under 1 s.
 *
 * A CarPlay head unit never joins another network. While CarPlay runs, the
 * joined network's auto-join is paused and the radio disassociates; stopping
 * CarPlay re-enables it. The network name is persisted so a session ended by
 * a crash is restored on the next launch.
 * ═══════════════════════════════════════════════════════════════ */

static void *showcase_mobilewifi_symbol(const char *name) {
    static void *handle = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi",
                        RTLD_NOW);
    });
    return handle ? dlsym(handle, name) : NULL;
}

static void *showcase_wifi_manager(void) {
    static void *manager = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *(*create)(CFAllocatorRef, int) =
            showcase_mobilewifi_symbol("WiFiManagerClientCreate");
        void (*schedule)(void *, CFRunLoopRef, CFStringRef) =
            showcase_mobilewifi_symbol("WiFiManagerClientScheduleWithRunLoop");
        if (create) manager = create(kCFAllocatorDefault, 0);
        if (manager && schedule)
            schedule(manager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    });
    return manager;
}

/* Nil means MobileWiFi could not determine the associated network. */
static NSString *showcase_current_wifi_ssid(void) {
    void *manager = showcase_wifi_manager();
    CFArrayRef (*copyDevices)(void *) = showcase_mobilewifi_symbol("WiFiManagerClientCopyDevices");
    void *(*copyCurrent)(void *) = showcase_mobilewifi_symbol("WiFiDeviceClientCopyCurrentNetwork");
    CFStringRef (*ssidOf)(void *) = showcase_mobilewifi_symbol("WiFiNetworkGetSSID");
    if (!manager || !copyDevices || !copyCurrent || !ssidOf) return nil;
    CFArrayRef devices = copyDevices(manager);
    NSString *ssid = nil;
    for (CFIndex i = 0; devices && i < CFArrayGetCount(devices); i++) {
        void *network = copyCurrent((void *)CFArrayGetValueAtIndex(devices, i));
        if (!network) continue;
        CFStringRef name = ssidOf(network);
        if (name) ssid = [(__bridge NSString *)name copy];
        CFRelease(network);
        if (ssid.length) break;
    }
    if (devices) CFRelease(devices);
    return ssid.length ? ssid : nil;
}

/* Existing Wi-Fi is the default for this build; an explicit setting persists. */
static BOOL showcase_use_existing_wifi(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id value = [defaults objectForKey:SHARED_WIFI_KEY];
    return value ? [value boolValue] : YES;
}

/* Returns the network that was left, or nil when none was joined. */
static NSString *showcase_hold_other_wifi(void) {
    void *manager = showcase_wifi_manager();
    CFArrayRef (*copyDevices)(void *) =
        showcase_mobilewifi_symbol("WiFiManagerClientCopyDevices");
    void *(*copyCurrent)(void *) =
        showcase_mobilewifi_symbol("WiFiDeviceClientCopyCurrentNetwork");
    int (*disassociate)(void *) =
        showcase_mobilewifi_symbol("WiFiDeviceClientDisassociate");
    void (*disable)(void *, void *) =
        showcase_mobilewifi_symbol("WiFiManagerClientDisableNetwork");
    CFStringRef (*ssidOf)(void *) =
        showcase_mobilewifi_symbol("WiFiNetworkGetSSID");
    if (!manager || !copyDevices || !copyCurrent || !disassociate ||
        !disable || !ssidOf) {
        ip_log("[RADIO] MobileWiFi unavailable; other Wi-Fi left joined");
        return nil;
    }
    CFArrayRef devices = copyDevices(manager);
    void *device = devices && CFArrayGetCount(devices) > 0
        ? (void *)CFArrayGetValueAtIndex(devices, 0) : NULL;
    void *network = device ? copyCurrent(device) : NULL;
    NSString *ssid = nil;
    if (network) {
        CFStringRef name = ssidOf(network);
        ssid = name ? [(__bridge NSString *)name copy] : nil;
        if (ssid.length) {
            [[NSUserDefaults standardUserDefaults] setObject:ssid
                                                      forKey:HELD_WIFI_NETWORK_KEY];
            [[NSUserDefaults standardUserDefaults] synchronize];
            disable(manager, network);
            int rc = disassociate(device);
            ip_log("[RADIO] left '%s' for the session (disassociate rc=%d)",
                   ssid.UTF8String, rc);
        }
        CFRelease(network);
    } else {
        ip_log("[RADIO] no other Wi-Fi network joined");
    }
    if (devices) CFRelease(devices);
    return ssid;
}

static void showcase_release_other_wifi(const char *reason) {
    NSString *ssid = [[NSUserDefaults standardUserDefaults]
        stringForKey:HELD_WIFI_NETWORK_KEY];
    if (!ssid.length) return;
    void *manager = showcase_wifi_manager();
    CFArrayRef (*copyNetworks)(void *) =
        showcase_mobilewifi_symbol("WiFiManagerClientCopyNetworks");
    void (*enable)(void *, void *) =
        showcase_mobilewifi_symbol("WiFiManagerClientEnableNetwork");
    CFStringRef (*ssidOf)(void *) =
        showcase_mobilewifi_symbol("WiFiNetworkGetSSID");
    BOOL restored = NO;
    if (manager && copyNetworks && enable && ssidOf) {
        CFArrayRef networks = copyNetworks(manager);
        for (CFIndex i = 0; networks && i < CFArrayGetCount(networks); i++) {
            void *network = (void *)CFArrayGetValueAtIndex(networks, i);
            CFStringRef name = ssidOf(network);
            if (name && [(__bridge NSString *)name isEqualToString:ssid]) {
                enable(manager, network);
                restored = YES;
            }
        }
        if (networks) CFRelease(networks);
    }
    ip_log("[RADIO] %s '%s' (%s)", restored ? "re-enabled" : "could not find",
           ssid.UTF8String, reason);
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:HELD_WIFI_NETWORK_KEY];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

/* ═══════════════════════════════════════════════════════════════
 * Anonymous usage
 *
 * Counts how many people use Showcase and on what. Each item below can be
 * turned off in Settings › Anonymous Usage, or all of it at once:
 *
 *   id         a random UUID made here, not derived from the device
 *   version    Showcase package version, for example 1.0~beta5-2
 *   package    rootful, rootless or taurine
 *   model      hardware model, for example iPad4,2
 *   ios        iOS version
 *   jailbreak  guessed from the jailbreak's marker file, or "unknown"
 *   language   Showcase's language
 *   country    asks the server to keep the country Cloudflare reports
 *
 * It is posted to KCS's endpoint only when the user enables sharing.
 * when it differs from the last one sent, or after 30 days. The server keeps
 * one row per id and never stores IP addresses. Failures are ignored.
 * ═══════════════════════════════════════════════════════════════ */

/* Settings key and payload key for each item, in Settings order. */
static NSArray<NSArray<NSString *> *> *usage_items(void) {
    return @[@[@"anonymousUsageModel", @"model"], @[@"anonymousUsageIOS", @"ios"],
             @[@"anonymousUsageJailbreak", @"jailbreak"], @[@"anonymousUsageVersion", @"version"],
             @[@"anonymousUsagePackage", @"package"], @[@"anonymousUsageLanguage", @"language"],
             @[@"anonymousUsageCountry", @"country"]];
}

static NSString *usage_jailbreak(void) {
    const char *markers[][2] = {
        {"/var/jb/.installed_dopamine", "dopamine"}, {"/var/jb/.palecursus_strapped", "palera1n"},
        {"/.palecursus_strapped", "palera1n"}, {"/.installed_amethyst", "amethyst"},
        {"/.installed_taurine", "taurine"}, {"/.installed_odyssey", "odyssey"},
        {"/.installed_unc0ver", "unc0ver"}, {"/.bootstrapped_electra", "chimera"},
        {"/var/checkra1n.dmg", "checkra1n"}};
    for (size_t i = 0; i < sizeof markers / sizeof markers[0]; i++)
        if (access(markers[i][0], F_OK) == 0) return @(markers[i][1]);
    return @"unknown";
}

static NSDictionary *usage_values(void) {
#if defined(SHOWCASE_ROOTLESS)
    NSString *package = @"rootless";
#elif defined(SHOWCASE_TAURINE)
    NSString *package = @"taurine";
#else
    NSString *package = @"rootful";
#endif
    NSOperatingSystemVersion os = [NSProcessInfo processInfo].operatingSystemVersion;
    return @{@"model": hardware_machine_identifier(), @"jailbreak": usage_jailbreak(),
             @"ios": [NSString stringWithFormat:@"%ld.%ld.%ld", (long)os.majorVersion,
                      (long)os.minorVersion, (long)os.patchVersion],
             @"version": @PACKAGE_VERSION, @"package": package,
             @"language": showcase_language(), @"country": @YES};
}

static void send_anonymous_usage(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:USAGE_KEY]) return;
    NSDictionary *values = usage_values();
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    for (NSArray *item in usage_items())
        if ([d boolForKey:item[0]]) payload[item[1]] = values[item[1]];
    NSMutableString *summary = [NSMutableString string];
    for (NSString *key in [payload.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [summary appendFormat:@"%@=%@;", key, payload[key]];
    NSDate *sent = [d objectForKey:USAGE_SENT_DATE_KEY];
    if ([summary isEqualToString:[d stringForKey:USAGE_SENT_KEY]] && [sent isKindOfClass:[NSDate class]] &&
        -sent.timeIntervalSinceNow < 30 * 24 * 3600) return;

    NSString *identifier = [d stringForKey:USAGE_ID_KEY];
    if (!identifier.length) {
        identifier = [NSUUID UUID].UUIDString.lowercaseString;
        [d setObject:identifier forKey:USAGE_ID_KEY];
    }
    payload[@"id"] = identifier;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:USAGE_URL]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 15;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error || ((NSHTTPURLResponse *)response).statusCode != 204) return;
            [d setObject:summary forKey:USAGE_SENT_KEY];
            [d setObject:[NSDate date] forKey:USAGE_SENT_DATE_KEY];
            [d synchronize];
        }] resume];
}

/* ═══════════════════════════════════════════════════════════════
 * Personal Hotspot control
 *
 * Showcase starts the hotspot itself instead of sending the user to Settings:
 * Mobile Internet Sharing state ON plus wifid's discovery flag is what the
 * Personal Hotspot screen does when it is open. The band is iOS's choice.
 * ═══════════════════════════════════════════════════════════════ */

static id showcase_mis_manager(void) {
    static id manager = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PreferenceBundles/WirelessModemSettings.bundle/"
               "WirelessModemSettings", RTLD_NOW);
        Class managerClass = NSClassFromString(@"MISManager");
        if (!managerClass) return;
        SEL shared = NSSelectorFromString(@"sharedManager");
        manager = [managerClass respondsToSelector:shared]
            ? ((id (*)(id, SEL))objc_msgSend)(managerClass, shared)
            : [[managerClass alloc] init];
    });
    return manager;
}

static int showcase_hotspot_state(void) {
    id manager = showcase_mis_manager();
    if (!manager) return -1;
    int state = -1, reason = -1;
    ((void (*)(id, SEL, int *, int *))objc_msgSend)(
        manager, NSSelectorFromString(@"getState:andReason:"), &state, &reason);
    return state;
}

static BOOL showcase_set_hotspot(BOOL on) {
    id manager = showcase_mis_manager();
    if (!manager) return NO;
    ((void (*)(id, SEL, int))objc_msgSend)(
        manager, NSSelectorFromString(@"setState:"),
        on ? MIS_STATE_ON : MIS_STATE_OFF);
    return YES;
}

static void showcase_set_hotspot_discovery(BOOL discoverable) {
    void (*setDiscovery)(void *, int) =
        showcase_mobilewifi_symbol("WiFiManagerClientSetMISDiscoveryState");
    void *manager = showcase_wifi_manager();
    if (setDiscovery && manager) setDiscovery(manager, discoverable ? 1 : 0);
}

static void showcase_set_wifi_power(BOOL on) {
    void (*setPower)(void *, int) =
        showcase_mobilewifi_symbol("WiFiManagerClientSetPower");
    void *manager = showcase_wifi_manager();
    if (setPower && manager) setPower(manager, on ? 1 : 0);
}

/* A power cycle cut short by suspension, jetsam or a force quit leaves the
 * marker behind: turn Wi-Fi back on. Run on bgQueue, which also runs the
 * cycle, so this never lands in the middle of one. */
static void showcase_restore_wifi_power_after_cycle(const char *reason) {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    if (![prefs boolForKey:WIFI_POWER_CYCLE_KEY]) return;
    showcase_set_wifi_power(YES);
    [prefs removeObjectForKey:WIFI_POWER_CYCLE_KEY];
    [prefs synchronize];
    ip_log("[HOTSPOT] %s: turned Wi-Fi back on after an interrupted power cycle",
           reason);
}

/* ═══════════════════════════════════════════════════════════════
 * Touch IPC
 * ═══════════════════════════════════════════════════════════════ */

static dispatch_queue_t touch_write_queue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_touch_write_queue = dispatch_queue_create(
            "com.rostane.showcase.touch-writer", DISPATCH_QUEUE_SERIAL);
    });
    return g_touch_write_queue;
}

static void send_ipc_payload(uint8_t type, const void *payload,
                             uint32_t payloadLength) {
    pthread_mutex_lock(&g_ipc_lock);
    int fd = g_touch_fd;
    uint32_t epoch = g_touch_epoch;
    pthread_mutex_unlock(&g_ipc_lock);
    if (fd < 0) return;

    NSMutableData *message =
        [NSMutableData dataWithLength:(NSUInteger)payloadLength + 5];
    uint8_t *bytes = message.mutableBytes;
    bytes[0] = payloadLength & 0xff;
    bytes[1] = (payloadLength >> 8) & 0xff;
    bytes[2] = (payloadLength >> 16) & 0xff;
    bytes[3] = (payloadLength >> 24) & 0xff;
    bytes[4] = type;
    if (payloadLength) memcpy(bytes + 5, payload, payloadLength);

    dispatch_async(touch_write_queue(), ^{
        pthread_mutex_lock(&g_ipc_lock);
        int writer = (g_touch_fd == fd && g_touch_epoch == epoch) ? dup(fd) : -1;
        pthread_mutex_unlock(&g_ipc_lock);
        if (writer < 0) return;
        const uint8_t *cursor = message.bytes;
        size_t remaining = message.length;
        while (remaining > 0) {
            ssize_t written = write(writer, cursor, remaining);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) {
                ip_log("IPC write failed type=0x%02x: %s",
                       type, strerror(errno));
                close(writer);
                return;
            }
            cursor += written;
            remaining -= (size_t)written;
        }
        close(writer);
    });
}

/* Each record keeps the UIKit sample time even though the current single
 * touch HID report has no timestamp field. Keeping it in IPC makes ordering
 * measurable and leaves the transport ready for a richer HID descriptor.
 * [phase][contact][x LE16][y LE16][timestampNs LE64] */
static void send_touch_records(NSData *records) {
    if (records.length == 0 || records.length > UINT32_MAX) return;
    send_ipc_payload(MSG_TOUCH, records.bytes, (uint32_t)records.length);
}

/* Last visibility told to the service (-1: none yet). Main thread only;
 * handleDidBecomeActive uses it to undo a 0 sent while merely Inactive. */
static int g_app_visibility_sent = -1;

static void send_app_visibility(uint8_t visible) {
    uint8_t payload = visible ? 1 : 0;
    g_app_visibility_sent = payload;
    send_ipc_payload(MSG_APP_VISIBILITY, &payload, sizeof(payload));
}

static void send_video_resync_request(void) {
    uint8_t payload = 1;
    send_ipc_payload(MSG_VIDEO_RESYNC, &payload, sizeof(payload));
}

/* Packets arrived for a stream whose AUDIO_CONFIG was lost; ask the service
 * to send that stream's config again. Payload: uint32 streamType (LE). */
static void send_audio_resync_request(uint32_t streamType) {
    send_ipc_payload(MSG_AUDIO_RESYNC, &streamType, sizeof(streamType));
}

/* ═══════════════════════════════════════════════════════════════
 * AP detection
 * ═══════════════════════════════════════════════════════════════ */

static BOOL is_ap_up(void) {
    struct ifaddrs *ifa = NULL, *cur;
    if (getifaddrs(&ifa) != 0) return NO;
    BOOL up = NO;
    for (cur = ifa; cur != NULL; cur = cur->ifa_next) {
        if (cur->ifa_name && strcmp(cur->ifa_name, AP_INTERFACE) == 0
            && (cur->ifa_flags & IFF_UP)) { up = YES; break; }
    }
    freeifaddrs(ifa);
    return up;
}

/* A portable router/shared Wi-Fi network uses the normal Wi-Fi interface
 * rather than Personal Hotspot's bridge100.  Only treat an interface as
 * usable when it is up and already has an address; this prevents falling
 * through to shared mode while Wi-Fi is merely powered on. */
static NSString *shared_wifi_interface(void) {
    struct ifaddrs *ifa = NULL, *cur;
    if (getifaddrs(&ifa) != 0) return nil;
    NSString *name = nil;
    for (cur = ifa; cur != NULL; cur = cur->ifa_next) {
        if (!cur->ifa_name || !(cur->ifa_flags & IFF_UP)) continue;
        if (strcmp(cur->ifa_name, "en0") != 0 &&
            strcmp(cur->ifa_name, "en1") != 0) continue;
        if (!cur->ifa_addr) continue;
        if (cur->ifa_addr->sa_family != AF_INET) continue;
        struct sockaddr_in *address = (struct sockaddr_in *)cur->ifa_addr;
        if (address->sin_addr.s_addr == INADDR_ANY) continue;
        name = [NSString stringWithUTF8String:cur->ifa_name];
        if ([name isEqualToString:@"en0"]) break;
    }
    freeifaddrs(ifa);
    return name;
}

/* ═══════════════════════════════════════════════════════════════
 * AWDL suppression during an active session
 *
 * AWDL is the radio Apple uses for AirDrop, Handoff and Continuity. It shares
 * the single Wi-Fi radio with the Personal Hotspot that carries CarPlay, and it
 * periodically pulls that radio onto its own social channels — 6 in the 2.4 GHz
 * band, which is where this receiver's low-latency interface was observed
 * sitting. While the radio is away, nothing is received, and the screen stream
 * arrives as a late burst afterwards. The published symptom of AWDL contention
 * is 50-200 ms stalls, which matches the residual lateness spikes measured here.
 *
 * This touches no part of pairing, iAP2, BAA or the RTSP negotiation. It is
 * applied only once a session is fully established and streaming, and undone
 * when the session ends, so the protocol phase is never affected. Bringing the
 * interface down costs AirDrop and Handoff for the duration — an acceptable
 * trade on a device dedicated to being a head unit.
 * ═══════════════════════════════════════════════════════════════ */

/* llw0 does not exist before iOS 13 — verified absent on the iOS 12 receiver
 * and present on the iOS 15 one — so every entry is probed, never assumed. */
static const char *const kAWDLInterfaces[] = { "awdl0", "llw0" };
#define AWDL_INTERFACE_COUNT (sizeof(kAWDLInterfaces) / sizeof(kAWDLInterfaces[0]))
#define AWDL_REASSERT_SECONDS  10.0

/* Only interfaces this code actually took down are brought back, so a receiver
 * where the user had already disabled AirDrop is left as it was found. */
static BOOL g_awdl_was_up[AWDL_INTERFACE_COUNT];

static BOOL interface_exists(const char *name) {
    return if_nametoindex(name) != 0;
}

/* Returns YES when the interface ended up in the requested state. */
static BOOL set_interface_up(const char *name, BOOL up) {
    if (!name || !interface_exists(name)) return NO;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return NO;

    struct ifreq request;
    memset(&request, 0, sizeof(request));
    strncpy(request.ifr_name, name, IFNAMSIZ - 1);

    BOOL ok = NO;
    if (ioctl(fd, SIOCGIFFLAGS, &request) == 0) {
        short current = request.ifr_flags;
        short wanted = up ? (current | IFF_UP) : (current & (short)~IFF_UP);
        if (wanted == current) {
            ok = YES;
        } else {
            request.ifr_flags = wanted;
            ok = (ioctl(fd, SIOCSIFFLAGS, &request) == 0);
            if (!ok)
                ip_log("AWDL: %s %s failed: %s", name,
                       up ? "up" : "down", strerror(errno));
        }
    }
    close(fd);
    return ok;
}

static BOOL interface_is_up(const char *name) {
    if (!name || !interface_exists(name)) return NO;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return NO;
    struct ifreq request;
    memset(&request, 0, sizeof(request));
    strncpy(request.ifr_name, name, IFNAMSIZ - 1);
    BOOL up = NO;
    if (ioctl(fd, SIOCGIFFLAGS, &request) == 0)
        up = (request.ifr_flags & IFF_UP) != 0;
    close(fd);
    return up;
}

/* iOS brings AWDL back on its own whenever a Continuity service wants it, so
 * the suppression is re-asserted on a slow timer rather than set once. */
static volatile int32_t g_awdl_suppressed = 0;

/* Suppression, its periodic re-assertion and the restore all run on this one
 * serial queue, so a re-assert can never land after the restore and leave
 * AWDL down, and g_awdl_was_up[] has a single writer at a time. */
static dispatch_queue_t awdl_queue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("showcase.awdl", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void awdl_suppress(BOOL logEachInterface) {
    for (size_t i = 0; i < AWDL_INTERFACE_COUNT; i++) {
        const char *name = kAWDLInterfaces[i];
        if (!interface_exists(name)) { g_awdl_was_up[i] = NO; continue; }
        if (!interface_is_up(name)) continue;   /* already down; leave it */
        g_awdl_was_up[i] = YES;
        if (set_interface_up(name, NO) && logEachInterface)
            ip_log("AWDL: %s -> down", name);
    }
}

static void awdl_restore(BOOL logEachInterface) {
    for (size_t i = 0; i < AWDL_INTERFACE_COUNT; i++) {
        if (!g_awdl_was_up[i]) continue;
        const char *name = kAWDLInterfaces[i];
        g_awdl_was_up[i] = NO;
        if (!interface_exists(name) || interface_is_up(name)) continue;
        if (set_interface_up(name, YES) && logEachInterface)
            ip_log("AWDL: %s -> up", name);
    }
}

static const char *first_existing_tool(const char *const paths[]) {
    for (int i = 0; paths[i]; i++) {
        if (access(paths[i], X_OK) == 0) return paths[i];
    }
    return NULL;
}

static const char *tcpdump_tool_path(void) {
    const char *paths[] = {
        "/var/jb/usr/sbin/tcpdump",
        "/var/jb/usr/bin/tcpdump",
        "/usr/sbin/tcpdump",
        "/usr/bin/tcpdump",
        NULL
    };
    return first_existing_tool(paths);
}

static int open_btstack_preferences_dir(void) {
    int mobile = open("/var/mobile", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (mobile < 0) return -1;
    int library = openat(mobile, "Library", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    close(mobile);
    if (library < 0) return -1;
    int preferences = openat(library, "Preferences",
                             O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    close(library);
    return preferences;
}

static void enable_btstack_hci_logging(void) {
    const char *plist =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
        "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        "<plist version=\"1.0\">\n"
        "<dict>\n"
        "    <key>Logging</key>\n"
        "    <true/>\n"
        "</dict>\n"
        "</plist>\n";
    int dir = open_btstack_preferences_dir();
    if (dir < 0) {
        ip_log("BTstack preferences directory unavailable");
        return;
    }
    NSString *tempName = [@".showcase-btstack-" stringByAppendingString:[NSUUID UUID].UUIDString];
    const char *temp = tempName.fileSystemRepresentation;
    int fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (fd < 0) {
        ip_log("BTstack logging prefs write failed: %s", strerror(errno));
        close(dir);
        return;
    }
    ssize_t want = (ssize_t)strlen(plist);
    ssize_t wrote;
    do { wrote = write(fd, plist, (size_t)want); } while (wrote < 0 && errno == EINTR);
    close(fd);
    BOOL installed = wrote == want && renameat(dir, temp, dir, BTSTACK_PREFS_NAME) == 0;
    if (!installed) unlinkat(dir, temp, 0);
    close(dir);
    ip_log("BTstack HCI logging %s at %s", installed ? "enabled" : "write failed", BTSTACK_PREFS);
}

static void disable_btstack_hci_logging(void) {
    int dir = open_btstack_preferences_dir();
    if (dir < 0) return;
    unlinkat(dir, BTSTACK_PREFS_NAME, 0);
    close(dir);
    ip_log("BTstack HCI logging disabled");
}

/* ═══════════════════════════════════════════════════════════════
 * Process spawn helpers
 * ═══════════════════════════════════════════════════════════════ */

static int run_blocking(const char *path, char *const argv[]) {
    pid_t pid;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);

    NSMutableString *cmdline = [NSMutableString stringWithUTF8String:path];
    for (int i = 1; argv[i] != NULL; i++) {
        BOOL redacted = (i > 1 &&
            (!strcmp(argv[i - 1], "--pass") || !strcmp(argv[i - 1], "-p")));
        [cmdline appendFormat:@" %s", redacted ? "******" : argv[i]];
    }
    ip_log("run_blocking: %s (uid=%u euid=%u)", [cmdline UTF8String], getuid(), geteuid());

    int err = spawn_isolated(&pid, path, &actions, argv);
    posix_spawn_file_actions_destroy(&actions);
    if (err != 0) { ip_log("  posix_spawn FAIL: %s", strerror(err)); return -1; }
    uint64_t seconds = !strcmp(argv[0], "tar") ? 15 : 8;
    int rc = wait_for_command(pid, monotonic_nanos_now() + seconds * NSEC_PER_SEC);
    if (rc < 0) ip_log("  %s failed or timed out: %s", argv[0], argv[1] ?: "");
    ip_log("  exit=%d", rc);
    return rc;
}

static int run_capture(const char *path, char *const argv[], const char *outfile) {
    if (!path || access(path, X_OK) != 0) return -1;
    pid_t pid;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 1, outfile, O_WRONLY|O_CREAT|O_TRUNC, 0644);
    posix_spawn_file_actions_adddup2(&actions, 1, 2);
    int err = spawn_isolated(&pid, path, &actions, argv);
    posix_spawn_file_actions_destroy(&actions);
    if (err != 0) return -1;
    int rc = wait_for_command(pid, monotonic_nanos_now() + 3 * NSEC_PER_SEC);
    if (rc < 0) ip_log("diagnostics command failed or timed out: %s", argv[0]);
    return rc;
}

static pid_t spawn_daemon(const char *path, char *const argv[], const char *logfile) {
    mkdir("/var/mobile/Library/Showcase", 0755);
    mkdir(LOG_DIR, 0755);

    if (access(path, X_OK) != 0) {
        ip_log("spawn_daemon: %s NOT EXECUTABLE (%s)", path, strerror(errno));
        return 0;
    }

    NSMutableString *cmdline = [NSMutableString stringWithUTF8String:path];
    for (int i = 1; argv[i] != NULL; i++) {
        BOOL redacted = (i > 1 &&
            (!strcmp(argv[i - 1], "--pass") || !strcmp(argv[i - 1], "-p")));
        [cmdline appendFormat:@" %s", redacted ? "******" : argv[i]];
    }
    ip_log("spawn_daemon: %s", [cmdline UTF8String]);

    pid_t pid = 0;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    /* O_APPEND: Clear Logs truncates a live helper's log in place, and an
     * appending writer then continues at the new end instead of leaving a
     * hole of zeros up to its old offset. */
    posix_spawn_file_actions_addopen(&actions, 1, logfile,
                                     O_WRONLY|O_CREAT|O_TRUNC|O_APPEND, 0644);
    posix_spawn_file_actions_adddup2(&actions, 1, 2);
    int err = spawn_isolated(&pid, path, &actions, argv);
    posix_spawn_file_actions_destroy(&actions);
    if (err != 0) {
        ip_log("  posix_spawn FAIL: %s", strerror(err));
        return 0;
    }
    ip_log("  pid=%d log=%s", pid, logfile);

    usleep(200000);
    if (kill(pid, 0) != 0) {
        ip_log("  CHILD ALREADY DEAD — check %s", logfile);
    } else {
        ip_log("  child still alive ✓");
    }
    return pid;
}

static pid_t check_child(pid_t pid, int *status) {
    pid_t result;
    do { result = waitpid(pid, status, WNOHANG); } while (result < 0 && errno == EINTR);
    return result;
}

static BOOL child_alive(pid_t pid) {
    int status = 0;
    return pid > 0 && check_child(pid, &status) == 0;
}

/* The start time, in microseconds, of the helper process `pid`, or 0 when
 * it is gone or is some other program. A pid alone is not an identity: once
 * a non-child exits, nothing holds its pid back from reuse. */
static uint64_t baa_broker_start_micros(pid_t pid) {
    if (pid <= 0) return 0;
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0 || size == 0) return 0;
    if (info.kp_proc.p_pid != pid ||
        strncmp(info.kp_proc.p_comm, SVC_HELPER_NAME, MAXCOMLEN) != 0) return 0;
    return (uint64_t)info.kp_proc.p_starttime.tv_sec * 1000000ULL +
           (uint64_t)info.kp_proc.p_starttime.tv_usec;
}

/* Only a broker recovered from an earlier app instance can be a non-child;
 * it is alive only while the same process (name and start time) holds its
 * pid. */
static BOOL baa_broker_alive(pid_t pid, BOOL reused, uint64_t startMicros) {
    if (!reused) return child_alive(pid);
    return startMicros != 0 && baa_broker_start_micros(pid) == startMicros;
}

/* Ends the broker `pid` at once. SIGKILL, because a normal exit unlinks the
 * shared socket path, which may belong to another broker by now. A reused
 * broker (not our child) is signalled only while its name and start time
 * still identify it, never a pid that may have passed to another process. */
static void stop_baa_broker(pid_t pid, BOOL reused, uint64_t startMicros) {
    if (!baa_broker_alive(pid, reused, startMicros)) return;
    kill(pid, SIGKILL);
    if (!reused) {
        int status;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    }
}

/* exitCode receives the helper's exit status when it exited normally before
 * the ready sentinel, and -1 for a timeout, a signal or cancellation. */
static BOOL wait_for_bt_ready_or_exit(pid_t *child, int seconds, int *exitCode) {
    pid_t pid = *child;
    int loops = seconds * 10;
    if (exitCode) *exitCode = -1;
    for (int i = 0; i < loops; i++) {
        if (flow_cancelled()) return NO;
        int status = 0;
        pid_t done = check_child(pid, &status);
        if (done == pid) {
            *child = 0;
            if (exitCode && WIFEXITED(status)) *exitCode = WEXITSTATUS(status);
            if (WIFEXITED(status) && WEXITSTATUS(status) == 62) {
                ip_log("[BT] helper exited with BTSTACK_EVENT_POWERON_FAILED (62)");
            } else if (WIFEXITED(status) && WEXITSTATUS(status) == 63) {
                ip_log("[BT] helper exited: BTstack daemon connection closed or "
                       "controller powered off (63)");
            } else if (WIFEXITED(status)) {
                ip_log("[BT] helper exited before ready sentinel exit=%d", WEXITSTATUS(status));
            } else if (WIFSIGNALED(status)) {
                ip_log("[BT] helper exited before ready sentinel signal=%d", WTERMSIG(status));
            } else {
                ip_log("[BT] helper exited before ready sentinel status=0x%x", status);
            }
            return NO;
        }
        if (done < 0) {
            ip_log("[BT] waitpid while waiting for ready sentinel failed: %s", strerror(errno));
            if (errno == ECHILD) *child = 0;
            return NO;
        }
        if (access(BT_READY_PATH, F_OK) == 0) {
            ip_log("[BT] ready sentinel observed at %s", BT_READY_PATH);
            return YES;
        }

        usleep(100000);
    }

    ip_log("[BT] ready sentinel timeout after %d seconds path=%s", seconds, BT_READY_PATH);
    return NO;
}

static BOOL wait_for_pid_alive(pid_t *child, int seconds, const char *name) {
    for (int i = 0; i <= seconds; i++) {
        if (flow_cancelled()) return NO;
        if (!child_alive(*child)) {
            *child = 0;
            ip_log("%s exited during startup wait at %d/%d sec", name, i, seconds);
            return NO;
        }
        if (i < seconds) sleep(1);
    }
    return YES;
}

static BOOL wait_for_path(const char *path, int seconds, const char *name) {
    for (int i = 0; i < seconds * 10; i++) {
        if (flow_cancelled()) return NO;
        if (access(path, F_OK) == 0) {
            ip_log("%s ready at %s", name, path);
            return YES;
        }
        usleep(100000);
    }
    ip_log("%s not ready at %s after %d sec", name, path, seconds);
    return NO;
}

/* Sleeps in 100 ms steps so a cancelled flow does not hold the serial
 * queue its teardown waits on. Returns NO once the flow is cancelled. */
static BOOL sleep_unless_cancelled(useconds_t micros) {
    while (micros > 0) {
        if (flow_cancelled()) return NO;
        useconds_t step = micros < 100000 ? micros : 100000;
        usleep(step);
        micros -= step;
    }
    return !flow_cancelled();
}

static void kill_child(pid_t pid) {
    if (!child_alive(pid)) return;
    kill(pid, SIGTERM);
    for (int i = 0; i < 20; i++) {
        usleep(100000);
        if (!child_alive(pid)) return;
    }
    kill(pid, SIGKILL);
    int status;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
}

static void signal_processes_named_except(const char *name, int sig,
                                          pid_t preservedPid, pid_t otherPreservedPid) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return;

    struct kinfo_proc *procs = malloc(len);
    if (!procs) return;
    if (sysctl(mib, 4, procs, &len, NULL, 0) != 0) {
        free(procs);
        return;
    }

    pid_t self = getpid();
    int count = (int)(len / sizeof(struct kinfo_proc));
    for (int i = 0; i < count; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        const char *comm = procs[i].kp_proc.p_comm;
        if (pid <= 0 || pid == self || pid == preservedPid ||
            pid == otherPreservedPid) continue;
        if (strcmp(comm, name) != 0) continue;
        ip_log("reap stale helper: kill -%d %s pid=%d", sig, name, pid);
        kill(pid, sig);
    }
    free(procs);
}

static void signal_processes_named(const char *name, int sig, pid_t preservedPid) {
    signal_processes_named_except(name, sig, preservedPid, 0);
}

/* Shared by the Taurine takeover and the rootful retry, so it lives outside
 * the #ifdef: both paths need to know whether a wedged process is really gone
 * before the UART can be handed over. */
static BOOL process_named_running(const char *name) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return NO;
    struct kinfo_proc *procs = malloc(len);
    if (!procs) return NO;
    BOOL found = NO;
    if (sysctl(mib, 4, procs, &len, NULL, 0) == 0) {
        int count = (int)(len / sizeof(struct kinfo_proc));
        for (int i = 0; i < count && !found; i++)
            found = procs[i].kp_proc.p_pid > 0 && !strcmp(procs[i].kp_proc.p_comm, name);
    }
    free(procs);
    return found;
}

/* The one way the controller goes back to Apple. Unloading the BTstack job is
 * not enough: a daemon still blocked in its BlueTool hand-off keeps the UART
 * busy after launchd forgets it, and bluetoothd reloaded on top of it stays
 * broken until the next takeover. Kill it and see it gone first; otherwise
 * leave the recovery guard armed (with its restore marker) to finish later. */
static BOOL hand_back_system_bluetooth(const char *reason) {
    const char *launchctl = launchctl_path();
    if (launchctl) {
        char *unloadBTstackArgv[] = { (char *)"launchctl", (char *)"unload",
                                      (char *)BTSTACK_PLIST, NULL };
        run_blocking(launchctl, unloadBTstackArgv);
    } else {
        ip_log("WARNING: launchctl not found while restoring bluetoothd");
    }
    unlink(BTSTACK_SOCKET);
    signal_processes_named("BTdaemon", SIGKILL, 0);
    for (int i = 0; i < 50 && process_named_running("BTdaemon"); i++)
        usleep(100000);
    if (process_named_running("BTdaemon")) {
        if (access(BT_GUARD_READY, F_OK) == 0) {
            int fd = open(BT_GUARD_RESTORE, O_WRONLY | O_CREAT | O_NOFOLLOW, 0600);
            if (fd >= 0) close(fd);
        }
        ip_log("[BT] BTdaemon did not exit; system Bluetooth left to the "
               "recovery guard (%s)", reason);
        return NO;
    }
    return restore_system_bluetooth(reason);
}

#if !defined(SHOWCASE_TAURINE) && !defined(SHOWCASE_ROOTLESS)
/* Taurine marks its install at the root and keeps jailbreakd in /taurine. */
static BOOL showcase_on_taurine(void) {
    return [[NSProcessInfo processInfo] operatingSystemVersion].majorVersion == 14 &&
        (access("/.installed_taurine", F_OK) == 0 || access("/taurine", F_OK) == 0);
}
#endif

/* renewalPid: a replacement BAA broker fetching its certificate beside the
 * preserved one (renewBAABroker). Killing it after it bound the shared socket
 * path would leave the live broker unreachable (403 on auth-setup). */
static void reap_stale_helpers_except(pid_t preservedPid, pid_t renewalPid) {
    const char *names[] = {
        "carplay_services",
        "carplay_bt",
        "CarDisplaySim",
        "CarPlay Simulator",
        "CarPlay Simulato",
        "BTdaemon"
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++)
        signal_processes_named_except(names[i], SIGTERM, preservedPid, renewalPid);
    usleep(700000);
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++)
        signal_processes_named_except(names[i], SIGKILL, preservedPid, renewalPid);
    if (preservedPid <= 0 && renewalPid <= 0)
        unlink(BAA_BROKER_PATH);
    unlink(SOCK_PATH);
#ifdef SHOWCASE_ROOTLESS
    unlink(BTSTACK_SOCKET);
#endif
}

static void reap_stale_helpers(pid_t preservedPid) {
    reap_stale_helpers_except(preservedPid, 0);
}

/* ═══════════════════════════════════════════════════════════════
 * Data model + persistence
 *
 *   Car        = { name }                — display label CarPlay advertises
 *   APCreds    = { ssid, password }       — global, set once, used by all cars
 *
 * NSUserDefaults schema:
 *   "cars"            => NSArray of NSDictionary { name }
 *   "selectedCarName" => NSString
 *   "apSSID"          => NSString          (the iPad's hotspot SSID)
 *   "apPassword"      => NSString          (the iPad's hotspot password)
 *
 * On first run we seed one car ("Miata"). AP creds start empty;
 * the user must set them before Start CarPlay enables.
 *
 * Migration: if loaded cars carry legacy ssid/password fields and
 * apSSID is empty, promote the first non-empty pair to global creds.
 * ═══════════════════════════════════════════════════════════════ */

@interface Car : NSObject
@property (nonatomic, copy) NSString *name;
- (NSDictionary *)toDict;
+ (Car *)fromDict:(NSDictionary *)d;
@end

@implementation Car
- (NSDictionary *)toDict { return @{ @"name": self.name ?: @"" }; }
+ (Car *)fromDict:(NSDictionary *)d {
    Car *c = [[Car alloc] init];
    c.name = d[@"name"] ?: @"";
    return c;
}
@end

/* ─── Validation ───────────────────────────────────────────────
 * iOS 26 rejects auto-joining hotspots whose SSID:
 *  - is shorter than ~6 chars (default iPad name "iPad" doesn't work)
 *  - contains an Apple device name substring (iPad/iPhone/iPod/Mac)
 *
 * Returns nil if valid, otherwise human-readable error message.
 * ────────────────────────────────────────────────────────────── */
static NSString *validateSSID(NSString *ssid) {
    if (ssid.length == 0) return L(@"Wi-Fi network is required.");
    if (ssid.length < 6) {
        return L(@"Wi-Fi name must be at least 6 characters. iOS rejects shorter names for CarPlay.");
    }
    /* An 802.11 SSID is at most 32 bytes; carplay_bt also rejects longer. */
    if ([ssid lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 32)
        return L(@"Wi-Fi name must be at most 32 bytes.");
    NSString *lower = [ssid lowercaseString];
    NSArray *forbidden = @[@"ipad", @"iphone", @"ipod"];
    for (NSString *bad in forbidden) {
        if ([lower rangeOfString:bad].location != NSNotFound) {
            return [NSString stringWithFormat:
                L(@"Wi-Fi name cannot contain \"%@\". Rename this %@ in Settings › General › About › Name."),
                bad, UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad ? @"iPad" : @"iPhone"];
        }
    }
    return nil;
}

static NSString *validateNetworkSSID(NSString *ssid) {
    if (!showcase_use_existing_wifi()) return validateSSID(ssid);
    if (!ssid.length) return L(@"Wi-Fi network is required.");
    if ([ssid lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 32)
        return L(@"Wi-Fi name must be at most 32 bytes.");
    return nil;
}

static NSString *validateNetworkPassword(NSString *password) {
    NSUInteger bytes = [password lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (showcase_use_existing_wifi()) {
        if (bytes < 8 || bytes > 63) return L(@"Wi-Fi password must be 8 to 63 UTF-8 bytes.");
    } else if (password.length < 8) {
        return L(@"Hotspot passwords must be at least 8 characters.");
    } else if (bytes > 63) {
        /* WPA2's passphrase limit; carplay_bt rejects longer arguments. */
        return L(@"Wi-Fi password must be 8 to 63 UTF-8 bytes.");
    }
    return nil;
}

@interface CarStore : NSObject
@property (nonatomic, strong) NSMutableArray<Car *> *cars;
@property (nonatomic, strong) Car *selected;
@property (nonatomic, copy)   NSString *apSSID;
@property (nonatomic, copy)   NSString *apPassword;
- (void)load;
- (void)save;
- (void)addCar:(Car *)car;
- (void)deleteCarAtIndex:(NSInteger)idx;
- (void)selectCar:(Car *)car;
- (BOOL)apReady;
- (void)setAPSSID:(NSString *)ssid password:(NSString *)pw;
- (void)selectExistingWiFi:(BOOL)shared;
@end

@implementation CarStore
- (instancetype)init {
    if ((self = [super init])) [self load];
    return self;
}
- (BOOL)apReady {
    return validateNetworkSSID(self.apSSID) == nil &&
        validateNetworkPassword(self.apPassword) == nil;
}
- (void)load {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSArray *raw = [d arrayForKey:@"cars"];
    self.cars = [NSMutableArray array];
    NSString *legacySSID = nil, *legacyPass = nil;
    for (NSDictionary *dict in raw) {
        Car *c = [Car fromDict:dict];
        [self.cars addObject:c];
        /* Migration: capture first non-empty embedded creds */
        if (!legacySSID) {
            NSString *s = dict[@"ssid"], *p = dict[@"password"];
            if (s.length > 0 && p.length > 0) { legacySSID = s; legacyPass = p; }
        }
    }
    if (self.cars.count == 0) {
        Car *miata = [[Car alloc] init];
        miata.name = @"Miata";
        [self.cars addObject:miata];
    }

    self.apSSID     = [d stringForKey:@"apSSID"]     ?: @"";
    self.apPassword = [d stringForKey:@"apPassword"] ?: @"";
    /* Promote legacy creds if global is empty */
    if (self.apSSID.length == 0 && legacySSID.length > 0) {
        self.apSSID = legacySSID;
        self.apPassword = legacyPass;
        ip_log("migrated legacy AP creds from car embedded fields");
    }
    if ([d boolForKey:@"networkCredentialsSeparated"]) {
        BOOL shared = showcase_use_existing_wifi();
        self.apSSID = [d stringForKey:shared ? @"sharedNetworkSSID" : @"hotspotNetworkSSID"] ?: @"";
        self.apPassword = [d stringForKey:shared ? @"sharedNetworkPassword" : @"hotspotNetworkPassword"] ?: @"";
    } else {
        /* Older versions had only one pair. Preserve it in both modes once,
         * then subsequent edits are independent; this avoids losing an
         * existing working hotspot configuration during migration. */
        [d setObject:self.apSSID forKey:@"sharedNetworkSSID"];
        [d setObject:self.apPassword forKey:@"sharedNetworkPassword"];
        [d setObject:self.apSSID forKey:@"hotspotNetworkSSID"];
        [d setObject:self.apPassword forKey:@"hotspotNetworkPassword"];
    }

    NSString *selName = [d stringForKey:@"selectedCarName"];
    self.selected = nil;
    for (Car *c in self.cars) {
        if ([c.name isEqualToString:selName]) { self.selected = c; break; }
    }
    if (!self.selected) self.selected = self.cars.firstObject;

    [self save]; /* persist any migration */
}
- (void)save {
    NSMutableArray *raw = [NSMutableArray array];
    for (Car *c in self.cars) [raw addObject:[c toDict]];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:raw forKey:@"cars"];
    [d setObject:(self.selected.name ?: @"") forKey:@"selectedCarName"];
    [d setObject:(self.apSSID ?: @"")        forKey:@"apSSID"];
    [d setObject:(self.apPassword ?: @"")    forKey:@"apPassword"];
    BOOL shared = showcase_use_existing_wifi();
    [d setObject:(self.apSSID ?: @"") forKey:shared ? @"sharedNetworkSSID" : @"hotspotNetworkSSID"];
    [d setObject:(self.apPassword ?: @"") forKey:shared ? @"sharedNetworkPassword" : @"hotspotNetworkPassword"];
    [d setBool:YES forKey:@"networkCredentialsSeparated"];
    [d synchronize];
}
- (void)addCar:(Car *)car {
    [self.cars addObject:car];
    if (!self.selected) self.selected = car;
    [self save];
}
- (void)deleteCarAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)self.cars.count) return;
    Car *c = self.cars[idx];
    [self.cars removeObjectAtIndex:idx];
    if (self.selected == c) self.selected = self.cars.firstObject;
    [self save];
}
- (void)selectCar:(Car *)car { self.selected = car; [self save]; }
- (void)setAPSSID:(NSString *)ssid password:(NSString *)pw {
    self.apSSID = ssid ?: @"";
    self.apPassword = pw ?: @"";
    [self save];
}
- (void)selectExistingWiFi:(BOOL)shared {
    if (shared == showcase_use_existing_wifi()) return;
    [self save];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:shared forKey:SHARED_WIFI_KEY];
    self.apSSID = [d stringForKey:shared ? @"sharedNetworkSSID" : @"hotspotNetworkSSID"] ?: @"";
    self.apPassword = [d stringForKey:shared ? @"sharedNetworkPassword" : @"hotspotNetworkPassword"] ?: @"";
    [self save];
}
@end

/* ═══════════════════════════════════════════════════════════════
 * VideoView — UIView backed by AVSampleBufferDisplayLayer
 * ═══════════════════════════════════════════════════════════════ */

@interface VideoView : UIView
@end

@implementation VideoView
+ (Class)layerClass { return [AVSampleBufferDisplayLayer class]; }
@end

/* ═══════════════════════════════════════════════════════════════
 * CarPlayAudioPlayer — one Audio Queue per negotiated CarPlay stream
 *
 * Wireless CarPlay supplies codec packets rather than an audio file.
 * Audio Queue accepts AAC/AAC-ELD/Opus packets directly and uses the system
 * codec, avoiding an extra PCM copy and keeping decoding off the IPC path.
 * ═══════════════════════════════════════════════════════════════ */

@interface CarPlayAudioPlayer : NSObject {
    AudioQueueRef _audioQueue;
    AudioConverterRef _audioConverter;
    uint32_t _streamType;
    uint64_t _formatMask;
    uint32_t _framesPerPacket;
    uint32_t _latencyMs;
    Float64 _sampleRate;
    UInt32 _channels;
    UInt32 _decodedBytesPerFrame;
    uint64_t _decodedPackets;
    NSUInteger _queuedPackets;
    NSUInteger _requiredStartPackets;
    /* Raw PCM has one frame per AudioQueue packet but many per RTP packet;
     * its latency target is sized from the first packet's frame count. */
    BOOL _sizeStartFromFirstPacket;
    volatile int32_t _outstandingBuffers;
    uint64_t _queueDrainCount;
    BOOL _started;
    BOOL _paused;
    BOOL _isPCM;
    BOOL _decodeAACToPCM;
    BOOL _haveSequence;
    uint16_t _lastSequence;
    uint64_t _lastRenderReportNanos;
}
- (instancetype)initWithStreamType:(uint32_t)streamType;
- (BOOL)configureFormat:(uint64_t)formatMask
        framesPerPacket:(uint32_t)framesPerPacket
               latency:(uint32_t)latencyMs;
- (void)enqueuePacket:(const uint8_t *)bytes
               length:(uint32_t)length
             sequence:(uint16_t)sequence;
- (void)completedBuffer:(AudioQueueBufferRef)buffer
               forQueue:(AudioQueueRef)queue;
- (void)reportPlaybackTimeForQueue:(AudioQueueRef)queue;
- (void)setPlaybackPaused:(BOOL)paused;
- (void)flushBufferedAudio;
- (void)stop;
@end

static void carplay_audio_queue_callback(void *userData, AudioQueueRef queue,
                                         AudioQueueBufferRef buffer) {
    CarPlayAudioPlayer *player =
        (__bridge CarPlayAudioPlayer *)userData;
    [player completedBuffer:buffer forQueue:queue];
}

typedef struct {
    const uint8_t *bytes;
    UInt32 length;
    UInt32 channels;
    BOOL consumed;
    AudioStreamPacketDescription packet;
} CarPlayAACInputContext;

static OSStatus carplay_aac_input_callback(
    AudioConverterRef converter,
    UInt32 *ioNumberDataPackets,
    AudioBufferList *ioData,
    AudioStreamPacketDescription **outPacketDescription,
    void *userData) {
    (void)converter;
    CarPlayAACInputContext *input =
        (CarPlayAACInputContext *)userData;
    if (!input || input->consumed || !input->bytes || input->length == 0) {
        *ioNumberDataPackets = 0;
        return noErr;
    }

    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = input->channels;
    ioData->mBuffers[0].mDataByteSize = input->length;
    ioData->mBuffers[0].mData = (void *)input->bytes;
    input->packet.mStartOffset = 0;
    input->packet.mVariableFramesInPacket = 0;
    input->packet.mDataByteSize = input->length;
    if (outPacketDescription)
        *outPacketDescription = &input->packet;
    *ioNumberDataPackets = 1;
    input->consumed = YES;
    return noErr;
}

@implementation CarPlayAudioPlayer

- (instancetype)initWithStreamType:(uint32_t)streamType {
    if ((self = [super init])) _streamType = streamType;
    return self;
}

- (BOOL)configureFormat:(uint64_t)formatMask
        framesPerPacket:(uint32_t)framesPerPacket
               latency:(uint32_t)latencyMs {
    [self stop];

    Float64 sampleRate = 0;
    UInt32 channels = 0;
    AudioFormatID formatID = 0;
    uint32_t defaultFrames = 0;
    BOOL isPCM = NO;
    switch (formatMask) {
        case 0x00000004ULL: /* PCM 8 kHz, 16-bit mono */
            sampleRate = 8000; channels = 1;
            formatID = kAudioFormatLinearPCM; defaultFrames = 1;
            isPCM = YES; break;
        case 0x00000010ULL: /* PCM 16 kHz, 16-bit mono */
            sampleRate = 16000; channels = 1;
            formatID = kAudioFormatLinearPCM; defaultFrames = 1;
            isPCM = YES; break;
        case 0x00000040ULL: /* PCM 24 kHz, 16-bit mono */
            sampleRate = 24000; channels = 1;
            formatID = kAudioFormatLinearPCM; defaultFrames = 1;
            isPCM = YES; break;
        case 0x00000800ULL: /* PCM 44.1 kHz, 16-bit stereo */
            sampleRate = 44100; channels = 2;
            formatID = kAudioFormatLinearPCM; defaultFrames = 1;
            isPCM = YES; break;
        case 0x00008000ULL: /* PCM 48 kHz, 16-bit stereo */
            sampleRate = 48000; channels = 2;
            formatID = kAudioFormatLinearPCM; defaultFrames = 1;
            isPCM = YES; break;
        case 0x00400000ULL: /* AAC-LC 44.1 kHz stereo */
            sampleRate = 44100; channels = 2;
            formatID = kAudioFormatMPEG4AAC; defaultFrames = 1024; break;
        case 0x00800000ULL: /* AAC-LC 48 kHz stereo */
            sampleRate = 48000; channels = 2;
            formatID = kAudioFormatMPEG4AAC; defaultFrames = 1024; break;
        case 0x01000000ULL: /* AAC-ELD 44.1 kHz stereo */
            sampleRate = 44100; channels = 2;
            formatID = kAudioFormatMPEG4AAC_ELD; defaultFrames = 512; break;
        case 0x02000000ULL: /* AAC-ELD 48 kHz stereo */
            sampleRate = 48000; channels = 2;
            formatID = kAudioFormatMPEG4AAC_ELD; defaultFrames = 512; break;
        case 0x04000000ULL: /* AAC-ELD 16 kHz mono */
            sampleRate = 16000; channels = 1;
            formatID = kAudioFormatMPEG4AAC_ELD; defaultFrames = 512; break;
        case 0x08000000ULL: /* AAC-ELD 24 kHz mono */
            sampleRate = 24000; channels = 1;
            formatID = kAudioFormatMPEG4AAC_ELD; defaultFrames = 512; break;
        case 0x10000000ULL: /* Opus 16 kHz mono, 20 ms */
            sampleRate = 16000; channels = 1;
            formatID = (AudioFormatID)0x6f707573U; defaultFrames = 320; break;
        case 0x20000000ULL: /* Opus 24 kHz mono, 20 ms */
            sampleRate = 24000; channels = 1;
            formatID = (AudioFormatID)0x6f707573U; defaultFrames = 480; break;
        case 0x40000000ULL: /* Opus 48 kHz mono, 20 ms */
            sampleRate = 48000; channels = 1;
            formatID = (AudioFormatID)0x6f707573U; defaultFrames = 960; break;
        default:
            ip_log("audio stream %u unsupported format=0x%llx",
                   _streamType, (unsigned long long)formatMask);
            return NO;
    }

    NSError *sessionError = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
                    mode:AVAudioSessionModeDefault
                 options:0 error:&sessionError];
    if (!sessionError) [session setActive:YES error:&sessionError];
    if (sessionError) {
        ip_log("audio session activation failed: %s",
               sessionError.localizedDescription.UTF8String);
    }

    AudioStreamBasicDescription asbd;
    memset(&asbd, 0, sizeof(asbd));
    asbd.mSampleRate = sampleRate;
    asbd.mFormatID = formatID;
    asbd.mChannelsPerFrame = channels;
    if (isPCM) {
        /* AirPlay PCM is signed, packed, 16-bit network byte order. */
        asbd.mFormatFlags =
            kLinearPCMFormatFlagIsSignedInteger |
            kLinearPCMFormatFlagIsPacked |
            kLinearPCMFormatFlagIsBigEndian;
        asbd.mBitsPerChannel = 16;
        asbd.mBytesPerFrame = channels * 2;
        asbd.mFramesPerPacket = 1;
        asbd.mBytesPerPacket = asbd.mBytesPerFrame;
    } else {
        asbd.mFramesPerPacket =
            framesPerPacket > 0 ? framesPerPacket : defaultFrames;
    }

    /*
     * MainHighAudio (type 102) is a one-second-latency UDP media stream.
     * Apple's receiver decodes its AAC access units to PCM before handing
     * them to the platform audio device. Keep MainBuffered type 103 on the
     * proven direct AudioQueue path, but mirror Apple's decode boundary for
     * type 102. The PCM meter then distinguishes encoded-data problems from
     * output routing problems in the same run.
     */
    AudioStreamBasicDescription queueASBD = asbd;
    _decodeAACToPCM =
        _streamType == 102 &&
        (formatMask == 0x00400000ULL ||
         formatMask == 0x00800000ULL);
    if (_decodeAACToPCM) {
        memset(&queueASBD, 0, sizeof(queueASBD));
        queueASBD.mSampleRate = sampleRate;
        queueASBD.mFormatID = kAudioFormatLinearPCM;
        queueASBD.mFormatFlags =
            kLinearPCMFormatFlagIsSignedInteger |
            kLinearPCMFormatFlagIsPacked;
        queueASBD.mChannelsPerFrame = channels;
        queueASBD.mBitsPerChannel = 16;
        queueASBD.mBytesPerFrame = channels * 2;
        queueASBD.mFramesPerPacket = 1;
        queueASBD.mBytesPerPacket = queueASBD.mBytesPerFrame;
        OSStatus converterStatus =
            AudioConverterNew(&asbd, &queueASBD, &_audioConverter);
        if (converterStatus != noErr || !_audioConverter) {
            ip_log("audio stream %u AAC converter create failed status=%d",
                   _streamType, (int)converterStatus);
            _audioConverter = NULL;
            return NO;
        }
    }

    OSStatus status = AudioQueueNewOutput(
        &queueASBD, carplay_audio_queue_callback, (__bridge void *)self,
        NULL, NULL, 0,
        &_audioQueue);
    if (status != noErr || !_audioQueue) {
        ip_log("audio stream %u queue create failed status=%d",
               _streamType, (int)status);
        _audioQueue = NULL;
        if (_audioConverter) {
            AudioConverterDispose(_audioConverter);
            _audioConverter = NULL;
        }
        return NO;
    }
    AudioQueueSetParameter(_audioQueue, kAudioQueueParam_Volume, 1.0f);
    _formatMask = formatMask;
    _framesPerPacket = asbd.mFramesPerPacket;
    _latencyMs = latencyMs;
    _sampleRate = sampleRate;
    _channels = channels;
    _decodedBytesPerFrame = queueASBD.mBytesPerFrame;
    _decodedPackets = 0;
    _isPCM = isPCM || _decodeAACToPCM;
    _queuedPackets = 0;
    /*
     * MainHighAudio is a jitter-buffered media stream. The sender asked for
     * one second of latency in every observed Spotify SETUP, but starting
     * after the old six-packet floor left only 139 ms at 44.1 kHz. Video
     * bursts on the shared IPC path routinely exceed that and drained the
     * queue. Other stream types retain the proven six-packet start.
     */
    _requiredStartPackets = 6;
    /* Raw PCM's framesPerPacket is 1 (one sample frame per AudioQueue
     * packet), while every RTP packet becomes one buffer; computing the
     * target from it would ask for thousands of buffers and never start. */
    _sizeStartFromFirstPacket = _streamType == 102 && latencyMs > 0 &&
        sampleRate > 0 && isPCM && !_decodeAACToPCM;
    if (_streamType == 102 && latencyMs > 0 && !_sizeStartFromFirstPacket &&
        sampleRate > 0 && _framesPerPacket > 0) {
        double requestedPackets =
            ((double)latencyMs * sampleRate) /
            (1000.0 * (double)_framesPerPacket);
        _requiredStartPackets =
            MAX((NSUInteger)6, (NSUInteger)ceil(requestedPackets));
    }
    _outstandingBuffers = 0;
    _queueDrainCount = 0;
    _started = NO;
    _paused = NO;
    _haveSequence = NO;
    _lastRenderReportNanos = 0;
    ip_log("audio stream %u configured format=0x%llx %.0fHz/%uch "
           "framesPerPacket=%u latency=%ums startPackets=%lu output=%s",
           _streamType, (unsigned long long)_formatMask, sampleRate,
           (unsigned)channels, _framesPerPacket, _latencyMs,
           (unsigned long)_requiredStartPackets,
           _decodeAACToPCM ? "decoded-pcm" : "direct");
    return YES;
}

- (void)enqueuePacket:(const uint8_t *)bytes
               length:(uint32_t)length
             sequence:(uint16_t)sequence {
    if (!_audioQueue || !bytes || length == 0) return;
    if (_haveSequence && sequence != (uint16_t)(_lastSequence + 1)) {
        ip_log("audio stream %u RTP gap expected=%u got=%u",
               _streamType, (uint16_t)(_lastSequence + 1), sequence);
    }
    _lastSequence = sequence;
    _haveSequence = YES;
    if (_sizeStartFromFirstPacket) {
        _sizeStartFromFirstPacket = NO;
        uint32_t frames = _decodedBytesPerFrame > 0
            ? length / _decodedBytesPerFrame : 0;
        if (frames > 0) {
            double requestedPackets =
                ((double)_latencyMs * _sampleRate) / (1000.0 * (double)frames);
            _requiredStartPackets =
                MAX((NSUInteger)6, (NSUInteger)ceil(requestedPackets));
        }
        ip_log("audio stream %u PCM packet frames=%u startPackets=%lu",
               _streamType, frames, (unsigned long)_requiredStartPackets);
    }

    UInt32 queueLength = _decodeAACToPCM
        ? _framesPerPacket * _decodedBytesPerFrame : length;
    AudioQueueBufferRef buffer = NULL;
    OSStatus status =
        AudioQueueAllocateBuffer(_audioQueue, queueLength, &buffer);
    if (status != noErr || !buffer) {
        ip_log("audio stream %u buffer allocation failed status=%d",
               _streamType, (int)status);
        return;
    }

    if (_decodeAACToPCM) {
        CarPlayAACInputContext input = {
            .bytes = bytes,
            .length = length,
            .channels = _channels,
            .consumed = NO
        };
        AudioBufferList output;
        memset(&output, 0, sizeof(output));
        output.mNumberBuffers = 1;
        output.mBuffers[0].mNumberChannels = _channels;
        output.mBuffers[0].mDataByteSize = queueLength;
        output.mBuffers[0].mData = buffer->mAudioData;
        UInt32 outputPackets = _framesPerPacket;
        status = AudioConverterFillComplexBuffer(
            _audioConverter, carplay_aac_input_callback, &input,
            &outputPackets, &output, NULL);
        if (status != noErr || output.mBuffers[0].mDataByteSize == 0) {
            AudioQueueFreeBuffer(_audioQueue, buffer);
            ip_log("audio stream %u AAC decode failed status=%d bytes=%u",
                   _streamType, (int)status, length);
            return;
        }
        buffer->mAudioDataByteSize =
            output.mBuffers[0].mDataByteSize;
        _decodedPackets++;
        if (_decodedPackets <= 3 || (_decodedPackets % 250) == 0) {
            const int16_t *samples =
                (const int16_t *)buffer->mAudioData;
            size_t sampleCount =
                buffer->mAudioDataByteSize / sizeof(int16_t);
            double squareSum = 0.0;
            for (size_t index = 0; index < sampleCount; index++) {
                double value = (double)samples[index] / 32768.0;
                squareSum += value * value;
            }
            double rms = sampleCount > 0
                ? sqrt(squareSum / (double)sampleCount) : 0.0;
            ip_log("audio stream %u decoded #%llu in=%u out=%u "
                   "frames=%u rms=%.6f",
                   _streamType,
                   (unsigned long long)_decodedPackets,
                   length, buffer->mAudioDataByteSize,
                   outputPackets, rms);
        }
    } else {
        memcpy(buffer->mAudioData, bytes, length);
        buffer->mAudioDataByteSize = length;
    }
    if (_isPCM) {
        status = AudioQueueEnqueueBuffer(_audioQueue, buffer, 0, NULL);
    } else {
        AudioStreamPacketDescription packet = {
            .mStartOffset = 0,
            .mVariableFramesInPacket = _framesPerPacket,
            .mDataByteSize = length
        };
        status = AudioQueueEnqueueBuffer(_audioQueue, buffer, 1, &packet);
    }
    if (status != noErr) {
        AudioQueueFreeBuffer(_audioQueue, buffer);
        ip_log("audio stream %u enqueue failed status=%d",
               _streamType, (int)status);
        return;
    }

    int32_t outstanding =
        __sync_add_and_fetch(&_outstandingBuffers, 1);
    _queuedPackets++;
    if (!_started && !_paused &&
        outstanding >= (int32_t)_requiredStartPackets) {
        UInt32 preparedFrames = 0;
        AudioQueuePrime(_audioQueue, 0, &preparedFrames);
        status = AudioQueueStart(_audioQueue, NULL);
        _started = status == noErr;
        if (_started) _paused = NO;
        ip_log("audio stream %u playback start status=%d primed=%u "
               "buffered=%d/%lu",
               _streamType, (int)status, preparedFrames, outstanding,
               (unsigned long)_requiredStartPackets);
    }
    if ((_queuedPackets % 500) == 0) {
        ip_log("audio stream %u live packets=%lu",
               _streamType, (unsigned long)_queuedPackets);
    }
}

- (void)completedBuffer:(AudioQueueBufferRef)buffer
               forQueue:(AudioQueueRef)queue {
    [self reportPlaybackTimeForQueue:queue];
    int32_t outstanding =
        __sync_sub_and_fetch(&_outstandingBuffers, 1);
    if (_started && !_paused && outstanding == 0) {
        _queueDrainCount++;
        ip_log("audio stream %u queue drained #%llu packets=%lu",
               _streamType, (unsigned long long)_queueDrainCount,
               (unsigned long)_queuedPackets);
    }
    AudioQueueFreeBuffer(queue, buffer);
}

- (void)setPlaybackPaused:(BOOL)paused {
    if (!_audioQueue) return;

    if (paused) {
        _paused = YES;
        OSStatus status = _started
            ? AudioQueuePause(_audioQueue) : noErr;
        ip_log("audio stream %u pause status=%d started=%d queued=%lu",
               _streamType, (int)status, (int)_started,
               (unsigned long)_queuedPackets);
        return;
    }

    _paused = NO;
    OSStatus status = noErr;
    UInt32 preparedFrames = 0;
    if (_started) {
        status = AudioQueueStart(_audioQueue, NULL);
    } else if (_outstandingBuffers >= (int32_t)_requiredStartPackets) {
        AudioQueuePrime(_audioQueue, 0, &preparedFrames);
        status = AudioQueueStart(_audioQueue, NULL);
        _started = status == noErr;
    }
    ip_log("audio stream %u resume status=%d started=%d queued=%lu primed=%u",
           _streamType, (int)status, (int)_started,
           (unsigned long)_queuedPackets, preparedFrames);
}

- (void)flushBufferedAudio {
    if (!_audioQueue) return;

    /*
     * AudioQueueFlush drains already-enqueued buffers, which is the opposite
     * of AirPlay's FLUSHBUFFERED transition. Reset returns those buffers
     * immediately and preserves the queue's negotiated format. Keep the
     * paused state established by SETRATEANCHORTIME rate=0; the new RTP epoch
     * will not start until the following rate=1 command.
     */
    BOOL wasPaused = _paused;
    _started = NO;
    _queuedPackets = 0;
    _haveSequence = NO;
    _lastRenderReportNanos = 0;
    OSStatus status = AudioQueueReset(_audioQueue);
    _outstandingBuffers = 0;
    if (_audioConverter) AudioConverterReset(_audioConverter);
    _paused = wasPaused;
    ip_log("audio stream %u buffered flush status=%d paused=%d",
           _streamType, (int)status, (int)_paused);
}

- (void)reportPlaybackTimeForQueue:(AudioQueueRef)queue {
    if (!queue || queue != _audioQueue || !_started) return;

    uint64_t nowNanos = monotonic_nanos_now();
    if (_lastRenderReportNanos != 0 &&
        nowNanos - _lastRenderReportNanos < 250 * NSEC_PER_MSEC) {
        return;
    }

    AudioTimeStamp audioTime;
    memset(&audioTime, 0, sizeof(audioTime));
    Boolean discontinuity = false;
    OSStatus status = AudioQueueGetCurrentTime(
        queue, NULL, &audioTime, &discontinuity);
    if (status != noErr ||
        !(audioTime.mFlags & kAudioTimeStampSampleTimeValid)) {
        return;
    }

    int64_t sampleTime = (int64_t)llround(audioTime.mSampleTime);
    uint64_t hostTicks =
        (audioTime.mFlags & kAudioTimeStampHostTimeValid)
            ? audioTime.mHostTime : mach_absolute_time();
    uint8_t payload[20] = {0};
    memcpy(payload, &_streamType, 4);
    memcpy(payload + 4, &sampleTime, 8);
    memcpy(payload + 12, &hostTicks, 8);
    send_ipc_payload(MSG_AUDIO_RENDER, payload, sizeof(payload));
    _lastRenderReportNanos = nowNanos;

    if (discontinuity) {
        ip_log("audio stream %u render clock discontinuity sample=%lld",
               _streamType, (long long)sampleTime);
    }
}

- (void)stop {
    if (_audioQueue) {
        AudioQueueStop(_audioQueue, true);
        AudioQueueDispose(_audioQueue, true);
        _audioQueue = NULL;
    }
    if (_audioConverter) {
        AudioConverterDispose(_audioConverter);
        _audioConverter = NULL;
    }
    _decodeAACToPCM = NO;
    _decodedPackets = 0;
    _sampleRate = 0;
    _latencyMs = 0;
    _requiredStartPackets = 6;
    _sizeStartFromFirstPacket = NO;
    _outstandingBuffers = 0;
    _queueDrainCount = 0;
    _started = NO;
    _paused = NO;
    _queuedPackets = 0;
    _haveSequence = NO;
    _lastRenderReportNanos = 0;
}

- (void)dealloc {
    [self stop];
}
@end

/* Full-screen pause-menu scrim. It consumes ordinary touches so CarPlay
 * receives no input until another three-finger tap dismisses it. */
@interface ControlsOverlayView : UIView <UIGestureRecognizerDelegate>
@end
@implementation ControlsOverlayView
#if SHOWCASE_MIRROR_BENCH
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    for (UIView *view = touch.view; view && view != self; view = view.superview) {
        if ([view isKindOfClass:UIControl.class]) return NO;
    }
    return YES;
}
#endif
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
@end

/* The connection screen. It stays up over the decoded picture through the
 * hand-off zoom (and between VideoConfig and the first frame), so touches on
 * its empty area must stop here rather than reach the root view controller,
 * which would forward them to a CarPlay screen nobody can see yet. Its
 * buttons still receive their own touches. */
@interface SetupOverlayView : UIView
@end
@implementation SetupOverlayView
/* The hand-off fade leaves the model opacity at 0 while the overlay is still
 * on screen (the fade only fills backwards), and UIKit skips views below 0.01
 * alpha when hit-testing. Stay the touch target until the overlay is hidden;
 * the buttons are mid-fade by then and need no taps. */
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit || self.hidden || !self.userInteractionEnabled ||
        ![self pointInside:point withEvent:event]) return hit;
    return self;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
@end

/* A bounded, scrollable compatibility report. Bluetooth failures used to
 * return the state machine to Idle with no user-visible explanation; a long
 * raw daemon log also does not belong in a UIAlertController message. */
@interface CompatibilityErrorViewController : UIViewController
@property (nonatomic, copy) NSString *errorTitle;
@property (nonatomic, copy) NSString *explanation;
@property (nonatomic, copy) NSString *diagnostic;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *explanationLabel;
@property (nonatomic, strong) UITextView *diagnosticView;
@property (nonatomic, strong) UIButton *diagnosticCopyButton;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, copy) void (^onClose)(void);
@end

@implementation CompatibilityErrorViewController

- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    root.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
    /* Presented OverFullScreen: the setup screen and its Start button stay
     * in the hierarchy behind, so keep VoiceOver inside this screen. */
    root.accessibilityViewIsModal = YES;
    self.view = root;

    self.panel = [[UIView alloc] init];
    self.panel.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    self.panel.layer.cornerRadius = 16;
    self.panel.layer.masksToBounds = YES;
    [root addSubview:self.panel];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.font =
        [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    /* One line in a fixed frame: a long localized title (the Taurine package
     * name in Japanese on a landscape iPhone) shrinks instead of truncating. */
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.7;
    [self.panel addSubview:self.titleLabel];

    self.explanationLabel = [[UILabel alloc] init];
    self.explanationLabel.textColor =
        [UIColor colorWithWhite:1.0 alpha:0.72];
    self.explanationLabel.font = [UIFont systemFontOfSize:14];
    self.explanationLabel.numberOfLines = 3;
    self.explanationLabel.textAlignment = NSTextAlignmentCenter;
    [self.panel addSubview:self.explanationLabel];

    self.diagnosticView = [[UITextView alloc] init];
    self.diagnosticView.editable = NO;
    self.diagnosticView.selectable = YES;
    self.diagnosticView.alwaysBounceVertical = YES;
    self.diagnosticView.backgroundColor =
        [UIColor colorWithWhite:0 alpha:0.38];
    self.diagnosticView.textColor =
        [UIColor colorWithWhite:1.0 alpha:0.88];
    self.diagnosticView.font =
        [UIFont fontWithName:@"Menlo-Regular" size:11] ?:
            [UIFont systemFontOfSize:11];
    self.diagnosticView.layer.cornerRadius = 8;
    self.diagnosticView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    [self.panel addSubview:self.diagnosticView];

    self.diagnosticCopyButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.diagnosticCopyButton.backgroundColor = [UIColor whiteColor];
    [self.diagnosticCopyButton setTitleColor:[UIColor blackColor]
                                    forState:UIControlStateNormal];
    [self.diagnosticCopyButton setTitle:L(@"Copy Diagnostic")
                               forState:UIControlStateNormal];
    self.diagnosticCopyButton.titleLabel.font =
        [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.diagnosticCopyButton.layer.cornerRadius = 9;
    [self.diagnosticCopyButton addTarget:self action:@selector(copyDiagnostic)
                        forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:self.diagnosticCopyButton];

    self.closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.closeButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.13];
    [self.closeButton setTitleColor:[UIColor whiteColor]
                           forState:UIControlStateNormal];
    [self.closeButton setTitle:L(@"Close") forState:UIControlStateNormal];
    self.closeButton.titleLabel.font =
        [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.closeButton.layer.cornerRadius = 9;
    [self.closeButton addTarget:self action:@selector(close)
               forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:self.closeButton];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.titleLabel.text = self.errorTitle;
    self.explanationLabel.text = self.explanation;
    self.diagnosticView.text = self.diagnostic;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size = self.view.bounds.size;
    CGFloat panelWidth = MIN(size.width - 32.0, 720.0);
    CGFloat panelHeight = MIN(size.height - 24.0, 520.0);
    self.panel.frame = CGRectMake((size.width - panelWidth) / 2.0,
                                  (size.height - panelHeight) / 2.0,
                                  panelWidth, panelHeight);
    CGFloat inset = 18.0;
    self.titleLabel.frame = CGRectMake(inset, 14, panelWidth - inset * 2, 32);
    self.explanationLabel.frame =
        CGRectMake(inset, 48, panelWidth - inset * 2, 58);
    CGFloat buttonsY = panelHeight - 56;
    self.diagnosticView.frame =
        CGRectMake(inset, 112, panelWidth - inset * 2,
                   MAX(56, buttonsY - 122));
    CGFloat gap = 12;
    CGFloat buttonWidth = (panelWidth - inset * 2 - gap) / 2.0;
    self.diagnosticCopyButton.frame =
        CGRectMake(inset, buttonsY, buttonWidth, 40);
    self.closeButton.frame =
        CGRectMake(inset + buttonWidth + gap, buttonsY, buttonWidth, 40);
}

- (void)copyDiagnostic {
    [UIPasteboard generalPasteboard].string = self.diagnostic ?: @"";
    [self.diagnosticCopyButton setTitle:L(@"Copied")
                               forState:UIControlStateNormal];
}

- (void)close {
    void (^onClose)(void) = self.onClose;
    self.onClose = nil;
    [self dismissViewControllerAnimated:YES completion:^{
        if (onClose) onClose();
    }];
}

- (BOOL)accessibilityPerformEscape {
    [self close];
    return YES;
}

@end

/* The interface-orientation names describe the content rotation, not the
 * physical device rotation. LandscapeLeft therefore places the top edge
 * (and a notch or Dynamic Island) on the right side of the display. Long
 * phone panels are used as the hardware signal so this remains independent
 * of model identifier, OS version, and jailbreak layout. */
static BOOL showcase_phone_has_landscape_cutout(void) {
    if (UI_USER_INTERFACE_IDIOM() != UIUserInterfaceIdiomPhone) return NO;
    CGSize pixels = [UIScreen mainScreen].nativeBounds.size;
    CGFloat shortEdge = MIN(pixels.width, pixels.height);
    CGFloat longEdge = MAX(pixels.width, pixels.height);
    return shortEdge > 0.0 && (longEdge / shortEdge) > 2.0;
}

/* "iPad" or "iPhone", for text that names the device running Showcase. */
static NSString *showcase_device_noun(void) {
    return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad ? @"iPad" : @"iPhone";
}

static UIInterfaceOrientationMask showcase_orientation_mask(void) {
    return showcase_phone_has_landscape_cutout()
        ? UIInterfaceOrientationMaskLandscapeLeft
        : UIInterfaceOrientationMaskLandscape;
}

static UIInterfaceOrientation showcase_preferred_orientation(void) {
    return UIInterfaceOrientationLandscapeLeft;
}

static UIImage *showcase_star_image(CGFloat side);

/* Asks for a GitHub star: the link, Copy Link and Open GitHub. Tapping
 * outside the panel closes it. */
@interface StarViewController : UIViewController
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIButton *linkButton;
/* Runs once the panel is gone, so errors held while it was up appear. */
@property (nonatomic, copy) void (^onClose)(void);
- (void)close;
@end

@implementation StarViewController {
    BOOL _closing;        /* the dismissal has started; onClose is taken */
    BOOL _closeDeferred;  /* a close waits for a running transition */
}

- (UIButton *)button:(NSString *)title filled:(BOOL)filled action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.backgroundColor = filled ? [UIColor whiteColor] : [UIColor colorWithWhite:1 alpha:0.13];
    [button setTitleColor:filled ? [UIColor blackColor] : [UIColor whiteColor] forState:UIControlStateNormal];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.layer.cornerRadius = 10;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:button];
    return button;
}

- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    root.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
    [root addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)]];
    self.view = root;

    self.panel = [[UIView alloc] init];
    self.panel.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    self.panel.layer.cornerRadius = 16;
    /* Taps on the panel itself must not close it. */
    [self.panel addGestureRecognizer:[[UITapGestureRecognizer alloc] init]];
    /* VoiceOver cannot reach the dimmed backdrop: keep its focus inside the
     * panel; the escape gesture (accessibilityPerformEscape) closes it. */
    self.panel.accessibilityViewIsModal = YES;
    [root addSubview:self.panel];

    UIImageView *star = [[UIImageView alloc] initWithImage:showcase_star_image(30)];
    star.tintColor = [UIColor whiteColor];
    star.tag = 1;
    [self.panel addSubview:star];

    UILabel *title = [[UILabel alloc] init];
    title.text = L(@"Give us a star on GitHub!");
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
    title.textAlignment = NSTextAlignmentCenter;
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.7;
    title.tag = 2;
    [self.panel addSubview:title];

    UILabel *link = [[UILabel alloc] init];
    link.text = [GITHUB_URL stringByReplacingOccurrencesOfString:@"https://" withString:@""];
    link.textColor = [UIColor colorWithWhite:1 alpha:0.72];
    link.font = [UIFont systemFontOfSize:16];
    link.textAlignment = NSTextAlignmentCenter;
    link.adjustsFontSizeToFitWidth = YES;
    link.tag = 3;
    [self.panel addSubview:link];

    self.linkButton = [self button:L(@"Copy Link") filled:NO action:@selector(copyLink)];
    [self button:L(@"Open GitHub") filled:YES action:@selector(openGitHub)].tag = 4;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size = self.view.bounds.size;
    CGFloat w = MIN(size.width - 32, 420), h = 236, inset = 20;
    self.panel.frame = CGRectMake((size.width - w) / 2, (size.height - h) / 2, w, h);
    [self.panel viewWithTag:1].frame = CGRectMake((w - 30) / 2, 22, 30, 30);
    [self.panel viewWithTag:2].frame = CGRectMake(inset, 64, w - inset * 2, 30);
    [self.panel viewWithTag:3].frame = CGRectMake(inset, 100, w - inset * 2, 24);
    CGFloat buttonW = (w - inset * 2 - 12) / 2;
    self.linkButton.frame = CGRectMake(inset, h - 70, buttonW, 48);
    [self.panel viewWithTag:4].frame = CGRectMake(inset + buttonW + 12, h - 70, buttonW, 48);
}

- (void)copyLink {
    [UIPasteboard generalPasteboard].string = GITHUB_URL;
    [self.linkButton setTitle:L(@"Copied") forState:UIControlStateNormal];
}

- (void)openGitHub {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:GITHUB_URL] options:@{} completionHandler:nil];
    [self close];
}

/* UIKit drops a dismissal asked for while the panel's own presentation (or
 * another transition) is still running, completion and all. A close that
 * arrives then — CarPlay going Active during the cross-dissolve — waits for
 * the transition, and onClose is taken only once the dismissal really starts,
 * so a close that could not run yet never loses settingsDidClose. */
- (void)close {
    if (_closing || _closeDeferred) return;
    id<UIViewControllerTransitionCoordinator> coordinator = self.transitionCoordinator;
    if (self.isBeingPresented || self.isBeingDismissed || coordinator) {
        _closeDeferred = YES;
        __weak typeof(self) weakSelf = self;
        void (^retry)(void) = ^{
            StarViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_closeDeferred = NO;
            [strongSelf close];
        };
        if (coordinator) {
            [coordinator animateAlongsideTransition:nil
                completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
                (void)context;
                dispatch_async(dispatch_get_main_queue(), retry);
            }];
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), retry);
        }
        return;
    }
    if (!self.presentingViewController) return;
    _closing = YES;
    void (^onClose)(void) = self.onClose;
    self.onClose = nil;
    [self dismissViewControllerAnimated:YES completion:^{
        if (onClose) onClose();
    }];
}

- (BOOL)accessibilityPerformEscape {
    [self close];
    return YES;
}

@end

/* ═══════════════════════════════════════════════════════════════
 * RootViewController — landscape-only touch routing
 * ═══════════════════════════════════════════════════════════════ */

@class AppDelegate;

@interface RootViewController : UIViewController
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, weak) VideoView *videoView;
@property (nonatomic, weak) AppDelegate *appDelegate;
@property (nonatomic, assign) BOOL fullscreenMode; /* iPhone Active bypass of the 1024x768 canvas */
@end

@implementation RootViewController {
    /* Touches whose DOWN reached CarPlay. Only these send MOVE/UP/CANCEL, and
     * they always do — even over the letterbox band — so CarPlay never keeps
     * a finger pressed that has already lifted. */
    NSHashTable<UITouch *> *_pressedTouches;
}
- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    root.backgroundColor = [UIColor blackColor];
    self.view = root;
    self.contentView = root;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.contentView == self.view) {
        self.contentView.frame = self.view.bounds;
        self.contentView.transform = CGAffineTransformIdentity;
        return;
    }

    if (self.fullscreenMode) {
        /* iPhone Active: drop the 1024x768 canvas; let video fill the screen. */
        self.contentView.transform = CGAffineTransformIdentity;
        self.contentView.bounds = self.view.bounds;
        self.contentView.center = CGPointMake(self.view.bounds.size.width / 2.0,
                                              self.view.bounds.size.height / 2.0);
        return;
    }

    CGSize s = self.view.bounds.size;
    CGFloat scale = MIN(s.width / PHONE_CANVAS_W, s.height / PHONE_CANVAS_H);
    self.contentView.bounds = CGRectMake(0, 0, PHONE_CANVAS_W, PHONE_CANVAS_H);
    self.contentView.center = CGPointMake(s.width / 2.0, s.height / 2.0);
    self.contentView.transform = CGAffineTransformMakeScale(scale, scale);
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return showcase_orientation_mask();
}
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return showcase_preferred_orientation();
}

- (BOOL)mapTouch:(UITouch *)touch toX:(uint16_t *)outX y:(uint16_t *)outY
           clamp:(BOOL)clamp {
    if (g_carplay_w <= 0 || g_carplay_h <= 0) return NO;
    CGPoint pt = [touch locationInView:self.videoView];
    CGSize vs = self.videoView.bounds.size;
    float vw = vs.width, vh = vs.height;
    float cw = g_carplay_w, ch = g_carplay_h;
    float va = cw / ch, vva = vw / vh;
    float rw, rh, rx, ry;
    if (va > vva) { rw = vw; rh = vw / va; rx = 0; ry = (vh - rh) / 2.0f; }
    else          { rh = vh; rw = vh * va; rx = (vw - rw) / 2.0f; ry = 0; }
    float nx = (pt.x - rx) / rw, ny = (pt.y - ry) / rh;
    if (clamp) {
        nx = fminf(fmaxf(nx, 0), 1);
        ny = fminf(fmaxf(ny, 0), 1);
    }
    if (!(nx >= 0 && nx <= 1 && ny >= 0 && ny <= 1)) return NO;
    *outX = (uint16_t)(nx * cw);
    *outY = (uint16_t)(ny * ch);
    return YES;
}
- (void)handleTouches:(NSSet<UITouch *> *)touches
                event:(UIEvent *)event
                phase:(uint8_t)phase {
    NSMutableData *records = [NSMutableData data];
    if (!_pressedTouches) _pressedTouches = [NSHashTable weakObjectsHashTable];
    for (UITouch *touch in touches) {
        BOOL down = phase == TOUCH_DOWN;
        BOOL lift = phase == TOUCH_UP || phase == TOUCH_CANCEL;
        if (!down && ![_pressedTouches containsObject:touch]) continue;
        if (lift) [_pressedTouches removeObject:touch];
        NSArray<UITouch *> *samples = nil;
        if (phase == TOUCH_MOVE) {
            samples = [event coalescedTouchesForTouch:touch];
        }
        if (samples.count == 0) samples = @[touch];

        uint8_t contact = (uint8_t)(touch.hash & 0xff);
        for (UITouch *sample in samples) {
            uint16_t x = 0, y = 0;
            if (![self mapTouch:sample toX:&x y:&y clamp:!down]) continue;
            if (down) [_pressedTouches addObject:touch];
            uint64_t timestampNs =
                (uint64_t)llround(sample.timestamp * (double)NSEC_PER_SEC);
            uint8_t record[14] = { phase, contact };
            record[2] = x & 0xff;
            record[3] = x >> 8;
            record[4] = y & 0xff;
            record[5] = y >> 8;
            memcpy(record + 6, &timestampNs, sizeof(timestampNs));
            [records appendBytes:record length:sizeof(record)];
        }
    }
    send_touch_records(records);
}
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    [self handleTouches:t event:e phase:TOUCH_DOWN];
}
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    [self handleTouches:t event:e phase:TOUCH_MOVE];
}
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    [self handleTouches:t event:e phase:TOUCH_UP];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    [self handleTouches:t event:e phase:TOUCH_CANCEL];
}
@end

/* ═══════════════════════════════════════════════════════════════
 * Shared drawing: settings glyph and connection progress
 * ═══════════════════════════════════════════════════════════════ */

/* SF Symbols do not exist on iOS 12, so the gear is drawn once as a
 * template image: a toothed ring with a round hole, tinted by the button. */
static UIImage *showcase_gear_image(CGFloat side) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGPoint c = CGPointMake(side / 2.0, side / 2.0);
    CGFloat outer = side * 0.48, body = side * 0.36, hole = side * 0.15;
    const int teeth = 8;
    UIBezierPath *gear = [UIBezierPath bezierPath];
    for (int i = 0; i < teeth; i++) {
        double mid = (2.0 * M_PI * i) / teeth;
        double half = M_PI / teeth * 0.46;
        double inHalf = M_PI / teeth * 0.62;
        CGPoint a = CGPointMake(c.x + body * cos(mid - inHalf), c.y + body * sin(mid - inHalf));
        CGPoint b = CGPointMake(c.x + outer * cos(mid - half), c.y + outer * sin(mid - half));
        CGPoint d = CGPointMake(c.x + outer * cos(mid + half), c.y + outer * sin(mid + half));
        CGPoint e = CGPointMake(c.x + body * cos(mid + inHalf), c.y + body * sin(mid + inHalf));
        if (i == 0) [gear moveToPoint:a]; else [gear addLineToPoint:a];
        [gear addLineToPoint:b];
        [gear addLineToPoint:d];
        [gear addLineToPoint:e];
        double next = (2.0 * M_PI * (i + 1)) / teeth;
        [gear addArcWithCenter:c radius:body startAngle:mid + inHalf
                    endAngle:next - inHalf clockwise:YES];
    }
    [gear closePath];
    [gear appendPath:[UIBezierPath bezierPathWithArcCenter:c radius:hole
        startAngle:0 endAngle:2.0 * M_PI clockwise:NO]];
    gear.usesEvenOddFillRule = YES;
    [[UIColor whiteColor] setFill];
    [gear fill];
    (void)ctx;
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

/* A five-pointed star, drawn like the gear as a template image. */
static UIImage *showcase_star_image(CGFloat side) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 0);
    CGPoint c = CGPointMake(side / 2.0, side * 0.53);
    CGFloat outer = side * 0.48, inner = outer * 0.42;
    UIBezierPath *star = [UIBezierPath bezierPath];
    for (int i = 0; i < 10; i++) {
        CGFloat r = i % 2 ? inner : outer;
        double angle = -M_PI_2 + i * M_PI / 5.0;
        CGPoint p = CGPointMake(c.x + r * cos(angle), c.y + r * sin(angle));
        if (i == 0) [star moveToPoint:p]; else [star addLineToPoint:p];
    }
    [star closePath];
    star.lineJoinStyle = kCGLineJoinRound;
    star.lineWidth = side * 0.06;
    [[UIColor whiteColor] set];
    [star fill];
    [star stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIView *showcase_check_badge(CGFloat side, UIColor *fill, UIColor *mark) {
    UIView *badge = [[UIView alloc] initWithFrame:CGRectMake(0, 0, side, side)];
    badge.backgroundColor = fill;
    badge.layer.cornerRadius = side / 2.0;
    badge.userInteractionEnabled = NO;
    CAShapeLayer *check = [CAShapeLayer layer];
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(side * 0.28, side * 0.52)];
    [path addLineToPoint:CGPointMake(side * 0.44, side * 0.67)];
    [path addLineToPoint:CGPointMake(side * 0.73, side * 0.35)];
    check.path = path.CGPath;
    check.strokeColor = mark.CGColor;
    check.fillColor = [UIColor clearColor].CGColor;
    check.lineWidth = MAX(1.5, side * 0.11);
    check.lineCap = kCALineCapRound;
    check.lineJoin = kCALineJoinRound;
    [badge.layer addSublayer:check];
    return badge;
}

typedef NS_ENUM(NSInteger, ConnectStep) {
    ConnectStepBluetooth = 0,
    ConnectStepServices,
    ConnectStepPhoneBluetooth,
    ConnectStepVerify,
    ConnectStepHotspotDetails,
    ConnectStepJoinWiFi,
    ConnectStepPairing,
    ConnectStepSession,
    ConnectStepVideo,
    ConnectStepCount
};

/* A vertical checklist of the connection milestones. Completed steps carry a
 * check, the step in progress a spinner, later steps a quiet dot. When the
 * screen is short it shows a segmented bar with the previous, current, and
 * next step instead of the full list. */
@interface ConnectStepsView : UIView
@property (nonatomic, copy) NSArray<NSString *> *pendingTitles;
@property (nonatomic, copy) NSArray<NSString *> *doneTitles;
@property (nonatomic, assign) NSInteger completed;   /* highest finished index */
@property (nonatomic, assign) BOOL compact;
- (CGFloat)preferredHeightForWidth:(CGFloat)width;
- (void)reload;
@end

@implementation ConnectStepsView

- (CGFloat)rowHeight { return self.compact ? 24.0 : 30.0; }

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    (void)width;
    if (self.compact) return 14.0 + 3.0 * [self rowHeight];
    return (CGFloat)self.pendingTitles.count * [self rowHeight];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self reload];
}

- (UIView *)indicatorForState:(int)state size:(CGFloat)size {
    if (state == 2) {
        return showcase_check_badge(size, [UIColor whiteColor], [UIColor blackColor]);
    }
    if (state == 1) {
        UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
        spin.transform = CGAffineTransformMakeScale(0.8, 0.8);
        [spin startAnimating];
        UIView *holder = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
        spin.center = CGPointMake(size / 2.0, size / 2.0);
        [holder addSubview:spin];
        return holder;
    }
    UIView *holder = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 6, 6)];
    dot.backgroundColor = [UIColor colorWithWhite:1 alpha:0.25];
    dot.layer.cornerRadius = 3;
    dot.center = CGPointMake(size / 2.0, size / 2.0);
    [holder addSubview:dot];
    return holder;
}

- (void)addRowForIndex:(NSInteger)index y:(CGFloat)y width:(CGFloat)width
             leftInset:(CGFloat)left {
    NSInteger count = (NSInteger)self.pendingTitles.count;
    if (index < 0 || index >= count) return;
    int state = index <= self.completed ? 2
              : (index == self.completed + 1 ? 1 : 0);
    CGFloat rowH = [self rowHeight];
    CGFloat size = self.compact ? 16.0 : 18.0;
    UIView *indicator = [self indicatorForState:state size:size];
    indicator.frame = CGRectMake(left, y + (rowH - size) / 2.0, size, size);
    [self addSubview:indicator];

    UILabel *label = [[UILabel alloc] initWithFrame:
        CGRectMake(left + size + 12, y, width - left - size - 12, rowH)];
    label.text = state == 2 ? self.doneTitles[index] : self.pendingTitles[index];
    label.font = [UIFont systemFontOfSize:(self.compact ? 14 : 16)
                                   weight:(state == 1 ? UIFontWeightMedium
                                                      : UIFontWeightRegular)];
    label.textColor = [UIColor colorWithWhite:1
        alpha:(state == 1 ? 1.0 : (state == 2 ? 0.6 : 0.3))];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.8;
    [self addSubview:label];
}

- (void)reload {
    for (UIView *v in [self.subviews copy]) [v removeFromSuperview];
    NSInteger count = (NSInteger)self.pendingTitles.count;
    if (count == 0) return;
    CGFloat W = self.bounds.size.width;
    CGFloat rowH = [self rowHeight];

    if (!self.compact) {
        /* Center a fixed-width column so labels line up under each other. */
        CGFloat column = MIN(W, 360.0);
        CGFloat left = (W - column) / 2.0;
        for (NSInteger i = 0; i < count; i++)
            [self addRowForIndex:i y:i * rowH width:left + column leftInset:left];
        return;
    }

    CGFloat column = MIN(W, 320.0);
    CGFloat left = (W - column) / 2.0;
    CGFloat gap = 4.0;
    CGFloat segment = (column - gap * (count - 1)) / count;
    for (NSInteger i = 0; i < count; i++) {
        UIView *bar = [[UIView alloc] initWithFrame:
            CGRectMake(left + i * (segment + gap), 0, segment, 4)];
        bar.layer.cornerRadius = 2;
        bar.backgroundColor = [UIColor colorWithWhite:1
            alpha:(i <= self.completed ? 0.9
                   : (i == self.completed + 1 ? 0.45 : 0.15))];
        [self addSubview:bar];
    }
    NSInteger current = MIN(self.completed + 1, count - 1);
    NSInteger first = MAX(0, MIN(current - 1, count - 3));
    for (NSInteger i = 0; i < 3; i++)
        [self addRowForIndex:first + i y:14.0 + i * rowH
                       width:left + column leftInset:left];
}

@end

/* ═══════════════════════════════════════════════════════════════
 * AppDelegate — state machine, UI, IPC
 * ═══════════════════════════════════════════════════════════════ */


@interface CarVideoView : UIView
@end

/* Covers the CarPlay picture; like SetupOverlayView, touches on its empty
 * area must stop here rather than reach the root view controller, which
 * would forward them to a CarPlay screen nobody can see. Its close button is
 * a UIControl and still receives its own touches. */
@implementation CarVideoView
+ (Class)layerClass { return [AVPlayerLayer class]; }
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
@end

#if SHOWCASE_MIRROR_BENCH
#import "screen_mirror_receiver.h"
#endif

/* ═══════════════════════════════════════════════════════════════
 * ShowcaseConnectionScene — the night-road connection scene.
 *
 * Ported from the approved prototype in design/acilis-kapanis/
 * E-birlesik.html. One layer tree draws every phase of the setup
 * screen: the parked opening screen, ignition, the connection
 * progress, the hand-off into CarPlay and the farewell back to
 * parked. Only compositor properties animate — transform, opacity
 * and strokeEnd — so the old iPad never rasterises a frame of its
 * own, and the road is driven by the container layer's `speed`
 * instead of a per-frame timer.
 *
 * Geometry is authored in "design points" relative to the centre of
 * the logo at a 1024x768 canvas; -setLayoutScale:logoCenter: scales
 * the whole tree about that point.
 * ═══════════════════════════════════════════════════════════════ */

typedef NS_ENUM(NSInteger, ShowcaseScenePhase) {
    ShowcaseScenePhaseParked = 0,
    ShowcaseScenePhasePreparing,
    ShowcaseScenePhaseChoose,
    ShowcaseScenePhaseConnecting
};

enum { kSceneSteps = 9 };
static const CGFloat kSceneTile = 88.0;
static const CGFloat kSceneLinkTop = -142.0;
static const CGFloat kSceneLinkBottom = -46.0;
static const CGFloat kSceneLinkTravel = kSceneLinkBottom - kSceneLinkTop;
static const CGFloat kSceneLinkPitch = kSceneLinkTravel / 9.0;
static const CGFloat kSceneLinkSeg = kSceneLinkPitch - 2.4;
static const CGFloat kScenePhoneTop = -210.0;
static const CGFloat kSceneArcRadius = 170.0;
static const CGFloat kSceneArcFrom = 0.3;
static const NSTimeInterval kSceneArcDuration = 3.6;
static const NSTimeInterval kSceneArcGap = kSceneArcDuration / 3.0;
static const CGFloat kSceneCycle = 3.3;
static const NSInteger kSceneLanes = 3;
static const CGFloat kSceneRoadK = 300.0;
static const CGFloat kSceneRoadUB = 480.0;
static const CGFloat kSceneRoadDNear = 1.0 / 640.0;
static const CGFloat kSceneRoadSpacing = 1.0 / 110.0;
static const CGFloat kSceneRoadDFar = kSceneRoadDNear + 3.0 * kSceneRoadSpacing;
static const CGFloat kSceneBladeKK = 88.0 / 128.0;

static UIColor *scene_color(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}
static UIColor *scene_accent(CGFloat a)      { return scene_color(0.392, 0.760, 1.000, a); }
static UIColor *scene_accent_soft(CGFloat a) { return scene_color(0.702, 0.910, 1.000, a); }
static UIColor *scene_caption(CGFloat a)     { return scene_color(0.651, 0.749, 0.871, a); }
static UIColor *scene_ink(CGFloat a)         { return scene_color(0.220, 0.282, 0.349, a); }

static CGFloat scene_clamp(CGFloat x, CGFloat lo, CGFloat hi) {
    return x < lo ? lo : (x > hi ? hi : x);
}
static CGFloat scene_smooth(CGFloat e0, CGFloat e1, CGFloat x) {
    CGFloat t = scene_clamp((x - e0) / (e1 - e0), 0, 1);
    return t * t * (3 - 2 * t);
}

/* Begin times are absolute in the layer's time base; 0 would mean "now", so
 * every delayed animation has to add the current media time itself. */
static NSTimeInterval scene_later(NSTimeInterval delay) {
    return CACurrentMediaTime() + delay;
}

typedef struct { CGFloat location, r, g, b, a; } SceneStop;

static CGGradientRef scene_gradient(const SceneStop *stops, NSUInteger count) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat locations[8], components[8 * 4];
    CGColorRef colors[8];
    for (NSUInteger i = 0; i < count; i++) {
        locations[i] = stops[i].location;
        components[i * 4 + 0] = stops[i].r;
        components[i * 4 + 1] = stops[i].g;
        components[i * 4 + 2] = stops[i].b;
        components[i * 4 + 3] = stops[i].a;
        colors[i] = CGColorCreate(space, components + i * 4);
    }
    CFArrayRef array = CFArrayCreate(NULL, (const void **)colors, count,
                                     &kCFTypeArrayCallBacks);
    CGGradientRef gradient = CGGradientCreateWithColors(space, array, locations);
    CFRelease(array);
    for (NSUInteger i = 0; i < count; i++) CGColorRelease(colors[i]);
    CGColorSpaceRelease(space);
    return gradient;
}

/* Every sprite is a one-off flat-colour gradient, so it is rasterised once at
 * 1x and stretched: there is no detail a higher scale could preserve. */
static UIImage *scene_sprite(CGSize size, void (^draw)(CGContextRef)) {
    UIGraphicsBeginImageContextWithOptions(size, NO, 1.0);
    draw(UIGraphicsGetCurrentContext());
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static UIImage *scene_radial_sprite(CGSize size, CGPoint center, CGFloat radius,
                                    CGFloat yScale, const SceneStop *stops,
                                    NSUInteger count) {
    return scene_sprite(size, ^(CGContextRef ctx) {
        CGGradientRef gradient = scene_gradient(stops, count);
        CGContextTranslateCTM(ctx, center.x, center.y);
        if (yScale != 1.0) CGContextScaleCTM(ctx, 1.0, yScale);
        CGContextDrawRadialGradient(ctx, gradient, CGPointZero, 0,
                                    CGPointZero, radius, 0);
        CGGradientRelease(gradient);
    });
}

static UIImage *scene_linear_sprite(CGSize size, CGPoint from, CGPoint to,
                                    const SceneStop *stops, NSUInteger count) {
    return scene_sprite(size, ^(CGContextRef ctx) {
        CGGradientRef gradient = scene_gradient(stops, count);
        CGContextDrawLinearGradient(ctx, gradient, from, to, 0);
        CGGradientRelease(gradient);
    });
}

static UIBezierPath *scene_blade_path(CGFloat x0, CGFloat x1, CGFloat cy, CGFloat h) {
    CGFloat length = x1 - x0, a = x0 + 0.55 * length, b = x0 + 0.86 * length;
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(x0 + 1, cy - h)];
    [path addLineToPoint:CGPointMake(a, cy - h)];
    [path addCurveToPoint:CGPointMake(x1, cy)
             controlPoint1:CGPointMake(b, cy - h)
             controlPoint2:CGPointMake(x1, cy - h * 0.38)];
    [path addCurveToPoint:CGPointMake(a, cy + h)
             controlPoint1:CGPointMake(x1, cy + h * 0.38)
             controlPoint2:CGPointMake(b, cy + h)];
    [path addLineToPoint:CGPointMake(x0 + 1, cy + h)];
    [path addQuadCurveToPoint:CGPointMake(x0, cy + h - 1)
                 controlPoint:CGPointMake(x0, cy + h)];
    [path addLineToPoint:CGPointMake(x0, cy - h + 1)];
    [path addQuadCurveToPoint:CGPointMake(x0 + 1, cy - h)
                 controlPoint:CGPointMake(x0, cy - h)];
    [path closePath];
    return path;
}

static NSArray *scene_linear_steps(NSUInteger count) {
    NSMutableArray *steps = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++)
        [steps addObject:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear]];
    return steps;
}

static CAKeyframeAnimation *scene_keyframes(NSString *keyPath, NSArray *values,
                                            NSArray *times, NSTimeInterval duration,
                                            NSTimeInterval begin, CGFloat repeats) {
    CAKeyframeAnimation *animation = [CAKeyframeAnimation animationWithKeyPath:keyPath];
    animation.values = values;
    animation.keyTimes = times;
    animation.duration = duration;
    animation.beginTime = begin;
    animation.repeatCount = repeats;
    animation.calculationMode = kCAAnimationLinear;
    animation.fillMode = kCAFillModeBackwards;
    return animation;
}

static CABasicAnimation *scene_fade(CGFloat from, CGFloat to, NSTimeInterval duration,
                                    NSTimeInterval begin) {
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"opacity"];
    animation.fromValue = @(from);
    animation.toValue = @(to);
    animation.duration = duration;
    animation.beginTime = begin;
    animation.fillMode = kCAFillModeBackwards;
    animation.timingFunction = [CAMediaTimingFunction functionWithName:
        kCAMediaTimingFunctionEaseOut];
    return animation;
}

/* ═══════════════════════════════════════════════════════════════ */

@interface ShowcaseConnectionScene : UIView

/* The overlay that gets zoomed during the hand-off, and the mark's centre
 * inside that overlay's coordinate space. */
@property (nonatomic, weak) UIView *zoomHost;
@property (nonatomic, readonly) BOOL isHandingOff;

- (void)setLayoutScale:(CGFloat)scale logoCenter:(CGPoint)center;
- (void)applyPhase:(ShowcaseScenePhase)phase progress:(NSInteger)done;
- (void)playHandoffWithCompletion:(void (^)(void))completion;
/* Abandons a hand-off that has not landed (the session ended mid-zoom): its
 * completion never runs, the zoom is undone and the scene parks. */
- (void)cancelHandoff;
- (void)playFarewellWithCompletion:(void (^)(void))completion;
- (void)restartMotion;

@end

@implementation ShowcaseConnectionScene {
    CALayer *_root;
    CGPoint _logoCenter;
    CGFloat _scale;
    BOOL _laidOut;

    CALayer *_atmos, *_roadFade, *_roadLayer, *_horizon, *_halo, *_tile, *_phone, *_link;
    CALayer *_beamLeft, *_beamRight, *_arcsLayer, *_flash;
    CALayer *_phoneGhost, *_phoneSolid;
    CAShapeLayer *_ring, *_edgeMask;
    CAGradientLayer *_edgesGradient;
    NSArray<CALayer *> *_dashes;
    NSArray<CAGradientLayer *> *_arcs;
    NSArray<CAShapeLayer *> *_segments;
    NSArray<CALayer *> *_dots;
    NSArray<CALayer *> *_blades;
    NSMutableArray<CAKeyframeAnimation *> *_bladeWinds;
    NSArray<CALayer *> *_brakes;

    ShowcaseScenePhase _phase;
    NSInteger _done;
    BOOL _ignited;
    BOOL _phoneFound;
    BOOL _reduced;
    BOOL _handingOff;
    BOOL _farewellRunning;
    /* Set once a farewell has played for the current stop; only a new phase
     * clears it, so a re-render while still Stopping cannot replay it. */
    BOOL _farewellPlayed;

    CGFloat _roadRate, _roadTarget, _roadTau;
    NSTimeInterval _roadLast;
    NSTimer *_roadTimer;

    NSUInteger _token;
    BOOL _lit[kSceneSteps];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    self.backgroundColor = UIColor.clearColor;
    _reduced = UIAccessibilityIsReduceMotionEnabled();
    [self buildLayers];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(accessibilityChanged)
        name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(restartMotion)
        name:UIApplicationWillEnterForegroundNotification object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_roadTimer invalidate];
}

- (BOOL)isHandingOff { return _handingOff; }

/* ── Layer tree ─────────────────────────────────────────────────── */

- (void)buildLayers {
    UIImage *sky = scene_radial_sprite(CGSizeMake(1040, 400), CGPointMake(520, 200), 520,
        200.0 / 520.0, (const SceneStop[]){{0, 0.392, 0.760, 1.0, 0.20},
                                           {0.45, 0.392, 0.760, 1.0, 0.07},
                                           {1, 0.392, 0.760, 1.0, 0.0}}, 3);
    UIImage *ground = scene_linear_sprite(CGSizeMake(1240, 560), CGPointZero,
        CGPointMake(0, 560), (const SceneStop[]){{0, 0.012, 0.024, 0.055, 0.0},
                                                 {0.7, 0.012, 0.024, 0.055, 0.6},
                                                 {1, 0.012, 0.024, 0.055, 0.6}}, 3);
    UIImage *beam = scene_radial_sprite(CGSizeMake(340, 580), CGPointMake(170, 371.2), 170,
        290.0 / 170.0, (const SceneStop[]){{0, 0.769, 0.933, 1.0, 0.20},
                                           {0.46, 0.392, 0.760, 1.0, 0.085},
                                           {1, 0.392, 0.760, 1.0, 0.0}}, 3);
    UIImage *dash = scene_linear_sprite(CGSizeMake(100, 10), CGPointZero,
        CGPointMake(100, 0), (const SceneStop[]){{0, 0.702, 0.910, 1.0, 1.0},
                                                 {0.5, 0.933, 0.976, 1.0, 1.0},
                                                 {1, 0.702, 0.910, 1.0, 1.0}}, 3);
    UIImage *halo = scene_radial_sprite(CGSizeMake(200, 200), CGPointMake(100, 100), 100, 1.0,
        (const SceneStop[]){{0, 0.392, 0.760, 1.0, 0.42},
                            {0.55, 0.392, 0.760, 1.0, 0.12},
                            {1, 0.392, 0.760, 1.0, 0.0}}, 3);
    UIImage *flash = scene_radial_sprite(CGSizeMake(920, 920), CGPointMake(460, 460), 460, 1.0,
        (const SceneStop[]){{0, 0.933, 0.980, 1.0, 0.96},
                            {0.38, 0.702, 0.910, 1.0, 0.60},
                            {1, 0.392, 0.760, 1.0, 0.0}}, 3);
    UIImage *phoneGlow = scene_radial_sprite(CGSizeMake(86, 96), CGPointMake(43, 48), 43,
        48.0 / 43.0, (const SceneStop[]){{0, 0.392, 0.760, 1.0, 0.30},
                                         {1, 0.392, 0.760, 1.0, 0.0}}, 2);
    UIImage *horizon = scene_linear_sprite(CGSizeMake(840, 1), CGPointZero,
        CGPointMake(840, 0), (const SceneStop[]){{0, 0.349, 0.569, 0.871, 0.0},
                                                 {0.22, 0.349, 0.569, 0.871, 0.38},
                                                 {0.78, 0.349, 0.569, 0.871, 0.38},
                                                 {1, 0.349, 0.569, 0.871, 0.0}}, 4);

    /* Everything hangs off a 1x1 layer pinned to the logo centre, so the tree
     * moves and scales as one unit with no per-view layout work. */
    _root = [CALayer layer];
    _root.anchorPoint = CGPointZero;
    _root.bounds = CGRectMake(0, 0, 1, 1);
    _root.position = CGPointZero;
    [self.layer addSublayer:_root];

    /* D · night road ------------------------------------------------ */
    _atmos = [CALayer layer];
    _atmos.frame = CGRectMake(-620, -200, 1240, 760);
    [_root addSublayer:_atmos];
    CALayer *skyLayer = [CALayer layer];
    skyLayer.frame = CGRectMake(100, 0, 1040, 400);
    skyLayer.contents = (__bridge id)sky.CGImage;
    skyLayer.contentsScale = 1.0;
    [_atmos addSublayer:skyLayer];
    CALayer *groundLayer = [CALayer layer];
    groundLayer.frame = CGRectMake(0, 200, 1240, 560);
    groundLayer.contents = (__bridge id)ground.CGImage;
    groundLayer.contentsScale = 1.0;
    [_atmos addSublayer:groundLayer];

    _edgesGradient = [CAGradientLayer layer];
    _edgesGradient.frame = CGRectMake(-620, 0, 1240, 540);
    _edgesGradient.startPoint = CGPointMake(0.5, 0);
    _edgesGradient.endPoint = CGPointMake(0.5, 520.0 / 540.0);
    _edgesGradient.colors = @[(__bridge id)scene_caption(0).CGColor,
                              (__bridge id)scene_caption(0.22).CGColor,
                              (__bridge id)scene_caption(0.5).CGColor];
    _edgesGradient.locations = @[@0, @0.15, @1];
    CAShapeLayer *edgeMask = [CAShapeLayer layer];
    edgeMask.frame = CGRectMake(0, 0, 1240, 540);
    UIBezierPath *edges = [UIBezierPath bezierPath];
    [edges moveToPoint:CGPointMake(620, 0)];
    [edges addLineToPoint:CGPointMake(620 - 975, 520)];
    [edges moveToPoint:CGPointMake(620, 0)];
    [edges addLineToPoint:CGPointMake(620 + 975, 520)];
    edgeMask.path = edges.CGPath;
    edgeMask.strokeColor = UIColor.blackColor.CGColor;
    edgeMask.fillColor = UIColor.clearColor.CGColor;
    edgeMask.lineWidth = 1.6;
    _edgesGradient.mask = edgeMask;
    _edgeMask = edgeMask;
    [_root addSublayer:_edgesGradient];

    /* The road's fades run on this outer layer, on the scene clock: the
     * inner layer's speed/timeOffset carry the distance travelled, so an
     * animation added there with an absolute begin time would never start. */
    _roadFade = [CALayer layer];
    _roadFade.anchorPoint = CGPointZero;
    _roadFade.bounds = CGRectMake(0, 0, 1, 1);
    _roadFade.position = CGPointZero;
    [_root addSublayer:_roadFade];
    _roadLayer = [CALayer layer];
    _roadLayer.anchorPoint = CGPointZero;
    _roadLayer.bounds = CGRectMake(0, 0, 1, 1);
    _roadLayer.position = CGPointZero;
    _roadLayer.speed = 0;
    [_roadFade addSublayer:_roadLayer];
    NSMutableArray *dashes = [NSMutableArray array];
    for (NSInteger side = -1; side <= 1; side += 2) {
        for (NSInteger lane = 0; lane < kSceneLanes; lane++) {
            CALayer *strip = [CALayer layer];
            strip.bounds = CGRectMake(0, 0, 100, 10);
            strip.cornerRadius = 5;
            strip.contents = (__bridge id)dash.CGImage;
            strip.contentsScale = 1.0;
            strip.opacity = 0;
            [_roadLayer addSublayer:strip];
            /* The road is frozen at local time 0 until the first speed change,
             * so a negative begin time is the exact phase offset we want. */
            [self startDashAnimation:strip side:side lane:lane
                               begin:-(lane + 0.55) / (CGFloat)kSceneLanes * kSceneCycle];
            [dashes addObject:strip];
        }
    }
    _dashes = dashes;

    for (NSInteger side = -1; side <= 1; side += 2) {
        CALayer *wrapper = [CALayer layer];
        wrapper.anchorPoint = CGPointZero;
        wrapper.bounds = CGRectMake(0, 0, 1, 1);
        wrapper.position = CGPointMake(side * 215.0, 560.0);
        wrapper.transform = CATransform3DMakeRotation(side * 21.0 * M_PI / 180.0, 0, 0, 1);
        CALayer *light = [CALayer layer];
        light.anchorPoint = CGPointMake(0.5, 1.0);
        light.bounds = CGRectMake(0, 0, 340, 580);
        light.position = CGPointZero;
        light.contents = (__bridge id)beam.CGImage;
        light.contentsScale = 1.0;
        light.opacity = 0;
        [wrapper addSublayer:light];
        [_root addSublayer:wrapper];
        if (side < 0) _beamLeft = light; else _beamRight = light;
    }

    _horizon = [CALayer layer];
    _horizon.frame = CGRectMake(-420, -0.5, 840, 1);
    _horizon.contents = (__bridge id)horizon.CGImage;
    _horizon.contentsScale = 1.0;
    _horizon.opacity = 0;
    [_root addSublayer:_horizon];

    /* C · iPhone handshake ------------------------------------------ */
    _arcsLayer = [CALayer layer];
    _arcsLayer.anchorPoint = CGPointZero;
    _arcsLayer.bounds = CGRectMake(0, 0, 1, 1);
    _arcsLayer.position = CGPointZero;
    _arcsLayer.opacity = 0;
    [_root addSublayer:_arcsLayer];
    NSMutableArray *arcLayers = [NSMutableArray array];
    for (NSInteger i = 0; i < 3; i++) {
        CAGradientLayer *arc = [CAGradientLayer layer];
        arc.frame = CGRectMake(-180, -180, 360, 360);
        arc.startPoint = CGPointMake(0, 0.5);
        arc.endPoint = CGPointMake(1, 0.5);
        arc.colors = @[(__bridge id)scene_accent(0).CGColor,
                       (__bridge id)scene_accent_soft(1).CGColor,
                       (__bridge id)scene_accent(0).CGColor];
        arc.locations = @[@(1.0 / 6.0), @0.5, @(5.0 / 6.0)];
        CAShapeLayer *mask = [CAShapeLayer layer];
        mask.frame = CGRectMake(0, 0, 360, 360);
        mask.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(180, 180)
            radius:kSceneArcRadius startAngle:-130.0 * M_PI / 180.0
            endAngle:-50.0 * M_PI / 180.0 clockwise:YES].CGPath;
        mask.strokeColor = UIColor.blackColor.CGColor;
        mask.fillColor = UIColor.clearColor.CGColor;
        mask.lineWidth = 2.6;
        mask.lineCap = kCALineCapRound;
        arc.mask = mask;
        arc.opacity = 0;
        [_arcsLayer addSublayer:arc];
        [arcLayers addObject:arc];
    }
    _arcs = arcLayers;

    _link = [CALayer layer];
    _link.frame = CGRectMake(-20, -150, 40, 110);
    _link.opacity = 0;
    [_root addSublayer:_link];
    NSMutableArray *segments = [NSMutableArray array];
    for (NSInteger i = 0; i < kSceneSteps; i++) {
        CGFloat top = kSceneLinkTop + i * kSceneLinkPitch + 150.0;
        UIBezierPath *path = [UIBezierPath bezierPath];
        [path moveToPoint:CGPointMake(20, top)];
        [path addLineToPoint:CGPointMake(20, top + kSceneLinkSeg)];
        CAShapeLayer *track = [CAShapeLayer layer];
        track.frame = CGRectMake(0, 0, 40, 110);
        track.path = path.CGPath;
        track.strokeColor = scene_color(0.349, 0.569, 0.871, 0.32).CGColor;
        track.fillColor = UIColor.clearColor.CGColor;
        track.lineWidth = 3;
        track.lineCap = kCALineCapRound;
        [_link addSublayer:track];

        CAShapeLayer *fill = [CAShapeLayer layer];
        fill.frame = track.frame;
        fill.path = path.CGPath;
        fill.strokeColor = scene_accent(1).CGColor;
        fill.fillColor = UIColor.clearColor.CGColor;
        fill.lineWidth = 3;
        fill.lineCap = kCALineCapRound;
        fill.strokeEnd = 0;
        [_link addSublayer:fill];
        [segments addObject:fill];
    }
    _segments = segments;

    NSMutableArray *dots = [NSMutableArray array];
    for (NSInteger i = 0; i < 3; i++) {
        CALayer *dot = [CALayer layer];
        dot.bounds = CGRectMake(0, 0, 5, 5);
        dot.cornerRadius = 2.5;
        dot.backgroundColor = scene_accent_soft(1).CGColor;
        dot.shadowColor = scene_accent(1).CGColor;
        dot.shadowRadius = 3;
        dot.shadowOpacity = 0.8;
        dot.shadowOffset = CGSizeZero;
        dot.position = CGPointMake(0, kSceneLinkTop);
        dot.opacity = 0;
        [_root addSublayer:dot];
        [dots addObject:dot];
    }
    _dots = dots;

    _phone = [CALayer layer];
    _phone.frame = CGRectMake(-17, kScenePhoneTop, 34, 60);
    _phone.opacity = 0;
    [_root addSublayer:_phone];
    CALayer *glow = [CALayer layer];
    glow.frame = CGRectMake(-26, -18, 86, 96);
    glow.contents = (__bridge id)phoneGlow.CGImage;
    glow.contentsScale = 1.0;
    [_phone addSublayer:glow];

    UIBezierPath *body = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(1, 1, 32, 58)
        cornerRadius:8];
    UIBezierPath *speaker = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(13, 5.5, 8, 2.6)
        cornerRadius:1.3];

    _phoneGhost = [CALayer layer];
    _phoneGhost.frame = CGRectMake(0, 0, 34, 60);
    [_phone addSublayer:_phoneGhost];
    CAShapeLayer *ghostBody = [CAShapeLayer layer];
    ghostBody.frame = CGRectMake(0, 0, 34, 60);
    ghostBody.path = body.CGPath;
    ghostBody.fillColor = UIColor.clearColor.CGColor;
    ghostBody.strokeColor = scene_caption(1).CGColor;
    ghostBody.lineWidth = 2;
    ghostBody.lineDashPattern = @[@3, @3.2];
    [_phoneGhost addSublayer:ghostBody];
    CAShapeLayer *ghostSpeaker = [CAShapeLayer layer];
    ghostSpeaker.frame = ghostBody.frame;
    ghostSpeaker.path = speaker.CGPath;
    ghostSpeaker.fillColor = scene_caption(1).CGColor;
    [_phoneGhost addSublayer:ghostSpeaker];

    _phoneSolid = [CALayer layer];
    _phoneSolid.frame = CGRectMake(0, 0, 34, 60);
    _phoneSolid.opacity = 0;
    [_phone addSublayer:_phoneSolid];
    CAShapeLayer *solidBody = [CAShapeLayer layer];
    solidBody.frame = ghostBody.frame;
    solidBody.path = body.CGPath;
    solidBody.fillColor = scene_accent(0.14).CGColor;
    solidBody.strokeColor = scene_accent(1).CGColor;
    solidBody.lineWidth = 2;
    [_phoneSolid addSublayer:solidBody];
    CAShapeLayer *solidSpeaker = [CAShapeLayer layer];
    solidSpeaker.frame = ghostBody.frame;
    solidSpeaker.path = speaker.CGPath;
    solidSpeaker.fillColor = scene_accent_soft(1).CGColor;
    [_phoneSolid addSublayer:solidSpeaker];
    CAShapeLayer *solidHome = [CAShapeLayer layer];
    solidHome.frame = ghostBody.frame;
    solidHome.path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(11.5, 52.5, 11, 1.8)
        cornerRadius:0.9].CGPath;
    solidHome.fillColor = scene_accent_soft(0.7).CGColor;
    [_phoneSolid addSublayer:solidHome];

    /* A · the logo itself ------------------------------------------- */
    _halo = [CALayer layer];
    _halo.frame = CGRectMake(-100, -100, 200, 200);
    _halo.contents = (__bridge id)halo.CGImage;
    _halo.contentsScale = 1.0;
    _halo.opacity = 0;
    [_root addSublayer:_halo];

    _ring = [CAShapeLayer layer];
    _ring.frame = CGRectMake(-40, -40, 80, 80);
    _ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0.75, 0.75, 78.5, 78.5)].CGPath;
    _ring.fillColor = UIColor.clearColor.CGColor;
    _ring.strokeColor = scene_accent_soft(1).CGColor;
    _ring.lineWidth = 1.5;
    _ring.opacity = 0;
    [_root addSublayer:_ring];

    _tile = [CALayer layer];
    _tile.frame = CGRectMake(-kSceneTile / 2, -kSceneTile / 2, kSceneTile, kSceneTile);
    _tile.backgroundColor = UIColor.whiteColor.CGColor;
    _tile.cornerRadius = 14;
    _tile.shadowColor = UIColor.blackColor.CGColor;
    _tile.shadowOpacity = 0.5;
    _tile.shadowRadius = 14;
    _tile.shadowOffset = CGSizeMake(0, 10);
    _tile.opacity = 0;
    [_root addSublayer:_tile];

    CAShapeLayer *frameInset = [CAShapeLayer layer];
    frameInset.frame = CGRectMake(0, 0, kSceneTile, kSceneTile);
    CGFloat inset = 2.5 * kSceneBladeKK;
    frameInset.path = [UIBezierPath bezierPathWithRoundedRect:
        CGRectMake(inset, inset, kSceneTile - inset * 2, kSceneTile - inset * 2)
        cornerRadius:20 * kSceneBladeKK - inset].CGPath;
    frameInset.fillColor = UIColor.clearColor.CGColor;
    frameInset.strokeColor = scene_ink(1).CGColor;
    frameInset.lineWidth = 5 * kSceneBladeKK;
    [_tile addSublayer:frameInset];

    /* The blades are drawn from the mark's own 128-unit artwork, so the vector
     * copy sits exactly where the PNG's blades do. */
    const CGFloat rawBlades[3][3] = {{30, 71.5, 41}, {32, 87.5, 63.5}, {36, 98.5, 85.5}};
    NSMutableArray *blades = [NSMutableArray array];
    for (NSInteger i = 0; i < 3; i++) {
        CGFloat x0 = -kSceneTile / 2 + rawBlades[i][0] * kSceneBladeKK;
        CGFloat x1 = -kSceneTile / 2 + rawBlades[i][1] * kSceneBladeKK;
        CGFloat cy = -kSceneTile / 2 + rawBlades[i][2] * kSceneBladeKK;
        CGFloat h = 5 * kSceneBladeKK;
        CALayer *pivot = [CALayer layer];
        pivot.anchorPoint = CGPointZero;
        pivot.bounds = CGRectMake(0, 0, 1, 1);
        pivot.position = CGPointMake(x0 + kSceneTile / 2, cy + kSceneTile / 2);
        CAShapeLayer *shape = [CAShapeLayer layer];
        shape.frame = CGRectMake(-kSceneTile / 2, -kSceneTile / 2, kSceneTile, kSceneTile);
        /* The artwork helper paints around the mark's centre; a layer draws in
         * its own bounds space, so shift it back by half the tile. */
        UIBezierPath *blade = scene_blade_path(x0, x1, cy, h);
        [blade applyTransform:CGAffineTransformMakeTranslation(kSceneTile / 2 - x0,
                                                              kSceneTile / 2 - cy)];
        shape.path = blade.CGPath;
        shape.fillColor = scene_ink(1).CGColor;
        [pivot addSublayer:shape];
        [_tile addSublayer:pivot];
        [blades addObject:pivot];
    }
    _blades = blades;

    /* The same three blades again, as light streaks that brake into place. */
    NSMutableArray *brakes = [NSMutableArray array];
    for (NSInteger i = 0; i < 3; i++) {
        CGFloat x0 = -kSceneTile / 2 + rawBlades[i][0] * kSceneBladeKK;
        CGFloat x1 = -kSceneTile / 2 + rawBlades[i][1] * kSceneBladeKK;
        CGFloat cy = -kSceneTile / 2 + rawBlades[i][2] * kSceneBladeKK;
        CGFloat width = x1 - x0, height = 2 * 5 * kSceneBladeKK;
        CALayer *pivot = [CALayer layer];
        pivot.anchorPoint = CGPointZero;
        pivot.bounds = CGRectMake(0, 0, 1, 1);
        pivot.position = CGPointMake(x0, cy);
        CAGradientLayer *streak = [CAGradientLayer layer];
        streak.frame = CGRectMake(0, -height / 2, width, height);
        streak.startPoint = CGPointMake(0, 0.5);
        streak.endPoint = CGPointMake(1, 0.5);
        streak.colors = @[(__bridge id)scene_color(0.910, 0.969, 1.000, 1).CGColor,
                          (__bridge id)scene_accent(1).CGColor,
                          (__bridge id)scene_accent(0).CGColor];
        streak.locations = @[@0, @0.35, @1];
        CAShapeLayer *mask = [CAShapeLayer layer];
        /* A mask is read in the masked layer's bounds space, not its frame. */
        mask.frame = streak.bounds;
        mask.path = scene_blade_path(0, width, height / 2, height / 2).CGPath;
        mask.fillColor = UIColor.blackColor.CGColor;
        streak.mask = mask;
        pivot.opacity = 0;
        [pivot addSublayer:streak];
        [_root addSublayer:pivot];
        [brakes addObject:pivot];
    }
    _brakes = brakes;

    _flash = [CALayer layer];
    _flash.frame = CGRectMake(-460, -460, 920, 920);
    _flash.contents = (__bridge id)flash.CGImage;
    _flash.contentsScale = 1.0;
    _flash.opacity = 0;
    [_root addSublayer:_flash];
}

/* ── Geometry ───────────────────────────────────────────────────── */

#ifdef SHOWCASE_UI_PREVIEW
/* Development-only: dump the scene's layer tree so layout/coordinate mistakes
 * can be read directly instead of guessed from a screenshot. */
static void scene_dump_layer(CALayer *layer, NSInteger depth, NSMutableString *out) {
    for (NSInteger i = 0; i < depth; i++) [out appendString:@"  "];
    [out appendFormat:@"%@ frame=%@ bounds=%@ pos=%@ anchor=%@ op=%.2f hidden=%d%@%@\n",
        NSStringFromClass(layer.class), NSStringFromCGRect(layer.frame),
        NSStringFromCGRect(layer.bounds), NSStringFromCGPoint(layer.position),
        NSStringFromCGPoint(layer.anchorPoint), layer.opacity, layer.hidden,
        [layer isKindOfClass:CAShapeLayer.class] ? @" path=" : @"",
        [layer isKindOfClass:CAShapeLayer.class]
            ? ([(CAShapeLayer *)layer path] ? @"set" : @"nil") : @""];
    for (CALayer *child in layer.sublayers) scene_dump_layer(child, depth + 1, out);
}

static void scene_dump_view(UIView *view, NSInteger depth, NSMutableString *out) {
    for (NSInteger i = 0; i < depth; i++) [out appendString:@"  "];
    [out appendFormat:@"%@ frame=%@ hidden=%d alpha=%.2f bg=%@\n",
        NSStringFromClass(view.class), NSStringFromCGRect(view.frame), view.hidden,
        view.alpha, view.backgroundColor];
    for (UIView *child in view.subviews) scene_dump_view(child, depth + 1, out);
}

- (void)dumpSceneTree {
    NSMutableString *out = [NSMutableString string];
    scene_dump_layer(_root, 0, out);
    NSMutableString *views = [NSMutableString string];
    scene_dump_view(self.window, 0, views);
    [views writeToFile:@"/tmp/scene-views.txt" atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [out writeToFile:@"/tmp/scene-layers.txt" atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
#endif

- (void)setLayoutScale:(CGFloat)scale logoCenter:(CGPoint)center {
    if (_laidOut && fabs(_scale - scale) < 0.001 &&
        CGPointEqualToPoint(_logoCenter, center)) return;
    _scale = MAX(scale, 0.2);
    _logoCenter = center;
    _root.position = center;
    _root.transform = CATransform3DMakeScale(_scale, _scale, 1);
    if (!_laidOut) {
        _laidOut = YES;
        [self enterParked];
    }
}

/* ── Road --------------------------------------------------------- */

/* One keyframe animation per strip, phased a third of a cycle apart so the
 * dashes chase each other down the road. `beginTime` carries the phase, which
 * is what lets the parked screen freeze on a chosen frame at speed 0. */
- (void)startDashAnimation:(CALayer *)strip side:(NSInteger)side lane:(NSInteger)lane
                     begin:(NSTimeInterval)begin {
    NSMutableArray *transforms = [NSMutableArray array];
    NSMutableArray *opacities = [NSMutableArray array];
    NSMutableArray *times = [NSMutableArray array];
    CGFloat angle = atan2(kSceneRoadUB, (CGFloat)side * kSceneRoadK);
    for (NSInteger i = 0; i <= 36; i++) {
        CGFloat s = i / 36.0;
        CGFloat t = 1 - (1 - s) * (1 - s);
        CGFloat d = kSceneRoadDFar - (kSceneRoadDFar - kSceneRoadDNear) * t;
        CGFloat u = 1.0 / d;
        CGFloat x = side * kSceneRoadK * u / kSceneRoadUB;
        CGFloat length = MAX(0.0085 * pow(u, 1.5), 1.2);
        CGFloat width = MAX(u / 48.0, 0.8);
        CGFloat opacity = scene_smooth(165, 235, u) * (0.35 + 0.45 * scene_smooth(240, 400, u));
        CATransform3D transform = CATransform3DIdentity;
        transform = CATransform3DTranslate(transform, x, u, 0);
        transform = CATransform3DRotate(transform, angle, 0, 0, 1);
        transform = CATransform3DScale(transform, length / 100.0, width / 10.0, 1);
        [transforms addObject:[NSValue valueWithCATransform3D:transform]];
        [opacities addObject:@(opacity)];
        [times addObject:@(t)];
    }
    CAKeyframeAnimation *transform = scene_keyframes(@"transform", transforms, times,
        kSceneCycle, begin, HUGE_VALF);
    transform.timingFunctions = scene_linear_steps(times.count);
    [strip addAnimation:transform forKey:@"road.transform"];
    CAKeyframeAnimation *opacity = scene_keyframes(@"opacity", opacities, times,
        kSceneCycle, begin, HUGE_VALF);
    opacity.timingFunctions = scene_linear_steps(times.count);
    [strip addAnimation:opacity forKey:@"road.opacity"];
}

/* Re-phases every strip so the frozen frame matches the parked design. Only
 * valid while the road is stopped: callers set speed 0 first. */
- (void)snapDashesToParkedPose {
    if (_roadLayer.speed != 0) return;
    [self phaseDashesAt:_roadLayer.timeOffset onlyMissing:NO];
}

- (void)phaseDashesAt:(NSTimeInterval)local onlyMissing:(BOOL)onlyMissing {
    for (NSUInteger i = 0; i < _dashes.count; i++) {
        if (onlyMissing && [_dashes[i] animationForKey:@"road.opacity"] &&
            [_dashes[i] animationForKey:@"road.transform"]) continue;
        NSInteger lane = (NSInteger)(i % (NSUInteger)kSceneLanes);
        NSInteger side = i < (NSUInteger)kSceneLanes ? -1 : 1;
        NSTimeInterval phase = (lane + 0.55) / (CGFloat)kSceneLanes * kSceneCycle;
        [self startDashAnimation:_dashes[i] side:side lane:lane begin:local - phase];
    }
}

/* The strips' model opacity is 0, so they exist only through their
 * animations. Backgrounding removes those; put back whatever is missing at
 * the road's current local time, moving or frozen. */
- (void)restoreDashes {
    NSTimeInterval local = [_roadLayer convertTime:CACurrentMediaTime() fromLayer:nil];
    [self phaseDashesAt:local onlyMissing:YES];
}

- (void)applyRoadSpeed:(CGFloat)speed {
    CGFloat old = _roadLayer.speed;
    if (fabs(old - speed) < 0.0005) return;
    /* Shift the clock so the container's local time is continuous across the
     * change: strips keep their phase and only the pace changes. */
    _roadLayer.timeOffset += CACurrentMediaTime() * (old - speed);
    _roadLayer.speed = speed;
}

/* Stops the easing timer and pins the road at `speed`, so a pending ease can
 * never pick the road back up after the caller froze it. */
- (void)stopRoadAtSpeed:(CGFloat)speed {
    [_roadTimer invalidate];
    _roadTimer = nil;
    _roadRate = speed;
    _roadTarget = speed;
    [self applyRoadSpeed:speed];
}

/* Ease the road from its current rate to `target` on a short-lived timer that
 * invalidates itself the moment it arrives, so a steady road costs nothing. */
- (void)setRoadTarget:(CGFloat)target tau:(CGFloat)tau {
    if (_reduced) return;
    _roadTarget = target;
    _roadTau = tau > 0 ? tau : 600;
    if (_roadTimer) return;
    _roadLast = CACurrentMediaTime();
    __weak ShowcaseConnectionScene *weakSelf = self;
    _roadTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30.0 repeats:YES
        block:^(NSTimer *timer) {
            ShowcaseConnectionScene *scene = weakSelf;
            if (!scene) { [timer invalidate]; return; }
            [scene stepRoad:timer];
        }];
    _roadTimer.tolerance = 0.01;
}

- (void)stepRoad:(NSTimer *)timer {
    NSTimeInterval now = CACurrentMediaTime();
    CGFloat dt = (CGFloat)((now - _roadLast) * 1000.0);
    _roadLast = now;
    if (dt > 64) dt = 64;
    CGFloat rate = _roadRate + (_roadTarget - _roadRate) * (1.0 - exp(-dt / _roadTau));
    if (fabs(_roadTarget - rate) < 0.004) {
        rate = _roadTarget;
        [timer invalidate];
        _roadTimer = nil;
    }
    _roadRate = rate;
    [self applyRoadSpeed:rate];
}

- (CGFloat)cruiseSpeed {
    if (_phase == ShowcaseScenePhaseConnecting)
        return 1 + 1.5 * scene_clamp((_done - 3) / 6.0, 0, 1);
    if (_phase == ShowcaseScenePhasePreparing) return 0.8;
    if (_phase == ShowcaseScenePhaseChoose) return 0.42;
    return 0.6;
}

/* ── Layer helpers ──────────────────────────────────────────────── */

- (void)resetLayer:(CALayer *)layer {
    [layer removeAllAnimations];
    layer.opacity = 0;
    layer.transform = CATransform3DIdentity;
}

- (void)fadeLayer:(CALayer *)layer from:(CGFloat)from to:(CGFloat)to
         duration:(NSTimeInterval)duration delay:(NSTimeInterval)delay {
    layer.opacity = (float)to;
    [layer addAnimation:scene_fade(from, to, duration, scene_later(delay)) forKey:@"fade"];
}

- (void)animate:(CALayer *)layer from:(NSDictionary *)from to:(NSDictionary *)to
       duration:(NSTimeInterval)duration delay:(NSTimeInterval)delay curve:(NSString *)curve {
    for (NSString *key in to) {
        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:key];
        animation.fromValue = from[key];
        animation.toValue = to[key];
        animation.duration = duration;
        animation.beginTime = scene_later(delay);
        animation.fillMode = kCAFillModeBackwards;
        if ([curve isEqualToString:@"out"])
            animation.timingFunction = [CAMediaTimingFunction functionWithName:
                kCAMediaTimingFunctionEaseOut];
        else if ([curve isEqualToString:@"in"])
            animation.timingFunction = [CAMediaTimingFunction functionWithName:
                kCAMediaTimingFunctionEaseIn];
        [layer addAnimation:animation forKey:[@"anim." stringByAppendingString:key]];
        id value = to[key];
        if ([key isEqualToString:@"opacity"]) layer.opacity = [value floatValue];
        else if ([key isEqualToString:@"transform"]) layer.transform = [value CATransform3DValue];
    }
}

- (void)stopBladeWind {
    for (CALayer *blade in _blades) [blade removeAnimationForKey:@"wind"];
    _bladeWinds = nil;
}

- (void)stopScan {
    for (CALayer *arc in _arcs) {
        [arc removeAnimationForKey:@"scan.scale"];
        [arc removeAnimationForKey:@"scan.fade"];
    }
    [_phoneGhost removeAnimationForKey:@"scan.breath"];
}

- (void)stopFlow {
    for (CALayer *dot in _dots) {
        [dot removeAnimationForKey:@"flow.travel"];
        [dot removeAnimationForKey:@"flow.fade"];
    }
}

- (void)hideAll {
    [self resetLayer:_atmos];
    [self resetLayer:_edgesGradient];
    _edgeMask.strokeEnd = 0;
    [self resetLayer:_roadFade];
    [self resetLayer:_horizon];
    [self resetLayer:_halo];
    [self resetLayer:_tile];
    [self resetLayer:_phone];
    [self resetLayer:_link];
    [self resetLayer:_ring];
    [self resetLayer:_flash];
    [self resetLayer:_arcsLayer];
    [self resetLayer:_beamLeft];
    [self resetLayer:_beamRight];
    for (CALayer *layer in _arcs) [self resetLayer:layer];
    for (CALayer *layer in _dots) [self resetLayer:layer];
    for (CALayer *layer in _brakes) [self resetLayer:layer];
    for (CALayer *pivot in _blades) [self resetLayer:pivot];
    for (CAShapeLayer *segment in _segments) {
        [segment removeAllAnimations];
        segment.strokeStart = 0;
        segment.strokeEnd = 0;
    }
    for (NSInteger i = 0; i < kSceneSteps; i++) _lit[i] = NO;
    _phoneGhost.opacity = 1;
    _phoneSolid.opacity = 0;
    _phoneFound = NO;
}

/* The opening screen and the last frame of the farewell: engine off, road dim
 * and still, headlights out, the mark lit softly. */
- (void)enterParked {
    /* Parking ends whatever ignition or restartMotion scheduled: their delayed
     * blocks (blade wind, scan, road speed) check the token, and must not
     * start the running picture on top of the parked one. */
    _token++;
    _ignited = NO;
    _phase = ShowcaseScenePhaseParked;
    _done = 0;
    _handingOff = NO;
    _farewellRunning = NO;
    [self stopBladeWind];
    [self stopScan];
    [self stopFlow];
    [self hideAll];
    [self stopRoadAtSpeed:0];
    [self snapDashesToParkedPose];
    _atmos.opacity = 0.5;
    /* The two guide lines out of the mark belong to the parked picture too. */
    _edgesGradient.opacity = 1;
    _edgeMask.strokeEnd = 1;
    _roadFade.opacity = 0.28;
    _horizon.opacity = 0.6;
    _halo.opacity = 0.55;
    _tile.opacity = 1;
    /* The mark's blades are part of the parked picture: they are what "lights
     * up" when the car starts, not what appears from nothing. */
    for (CALayer *blade in _blades) blade.opacity = 1;
    _reduced = UIAccessibilityIsReduceMotionEnabled();
    if (!_reduced) {
        /* One slow movement: the mark breathing while the car idles. */
        CAKeyframeAnimation *breath = scene_keyframes(@"opacity",
            @[@0.45, @0.75, @0.45], @[@0, @0.5, @1], 4.2, scene_later(0), HUGE_VALF);
        breath.timingFunction = [CAMediaTimingFunction functionWithName:
            kCAMediaTimingFunctionEaseInEaseOut];
        [_halo addAnimation:breath forKey:@"idle.breath"];
    }
}

/* ── Phase driving ──────────────────────────────────────────────── */

- (void)applyPhase:(ShowcaseScenePhase)phase progress:(NSInteger)done {
    _farewellPlayed = NO;
    if (!_laidOut || _handingOff || _farewellRunning) return;
    done = MAX(0, MIN(done, kSceneSteps));
    if (phase == ShowcaseScenePhaseParked) {
        if (_phase != ShowcaseScenePhaseParked || _ignited) [self enterParked];
        return;
    }
    if (phase == _phase && done == _done && _ignited) return;
    ShowcaseScenePhase from = _phase;
    BOOL cold = (from == ShowcaseScenePhaseParked) || !_ignited;
    _phase = phase;
    _done = done;
    if (!_ignited) [self igniteFromParked:cold];

    if (phase == ShowcaseScenePhaseConnecting) {
        [self stopScan];
        [self startFlow];
    } else {
        [self stopFlow];
        [self startScan];
    }
    [self setTempo];
    [self setSegments:done];
    if (done >= 3) [self setPhoneFound:YES];
    [self setRoadTarget:[self cruiseSpeed] tau:(from == phase ? 500 : 700)];
}

/* Parked → running: the blades take up the drive, the headlights flicker on,
 * the road lights up and the ghost iPhone appears overhead. */
- (void)igniteFromParked:(BOOL)fromParked {
    _ignited = YES;
    [_halo removeAnimationForKey:@"idle.breath"];
    NSUInteger token = _token;
    NSArray<CALayer *> *blades = _blades;

    _edgesGradient.opacity = 1;
    _edgeMask.strokeEnd = 1;
    if (!fromParked) {
        [self hideAll];
        _edgesGradient.opacity = 1;
        _edgeMask.strokeEnd = 1;
        if (!_reduced) {
            for (NSUInteger i = 0; i < blades.count; i++) {
                [self animate:blades[i]
                    from:@{@"transform": [NSValue valueWithCATransform3D:
                              CATransform3DMakeTranslation(-60, 0, 0)]}
                    to:@{@"transform": [NSValue valueWithCATransform3D:CATransform3DIdentity]}
                    duration:0.56 delay:0.16 + i * 0.09 curve:@"out"];
                [blades[i] addAnimation:scene_fade(0, 1, 0.56, scene_later(0.16 + i * 0.09))
                                 forKey:@"in.fade"];
                blades[i].opacity = 1;
            }
            [self fadeLayer:_tile from:0 to:1 duration:0.52 delay:0];
            [self animate:_tile
                from:@{@"transform": [NSValue valueWithCATransform3D:
                          CATransform3DMakeScale(0.86, 0.86, 1)]}
                to:@{@"transform": [NSValue valueWithCATransform3D:CATransform3DIdentity]}
                duration:0.52 delay:0 curve:@"out"];
        }
    } else if (!_reduced) {
        for (NSUInteger i = 0; i < blades.count; i++) {
            CAKeyframeAnimation *rev = scene_keyframes(@"transform",
                @[[NSValue valueWithCATransform3D:CATransform3DIdentity],
                  [NSValue valueWithCATransform3D:CATransform3DMakeTranslation(3, 0, 0)],
                  [NSValue valueWithCATransform3D:CATransform3DConcat(
                      CATransform3DMakeTranslation(3, 0, 0), CATransform3DMakeScale(1.2, 1, 1))],
                  [NSValue valueWithCATransform3D:CATransform3DIdentity]],
                @[@0, @0.35, @0.35, @1], 0.52, scene_later(i * 0.07), 1);
            rev.timingFunction = [CAMediaTimingFunction functionWithName:
                kCAMediaTimingFunctionEaseOut];
            [blades[i] addAnimation:rev forKey:@"ignite.rev"];
        }
    }

    if (_reduced) {
        _atmos.opacity = 1;
        _roadFade.opacity = 1;
        _horizon.opacity = 1;
        _halo.opacity = 1;
        _phone.opacity = 1;
        _link.opacity = 1;
        _beamLeft.opacity = 1;
        _beamRight.opacity = 1;
        _tile.opacity = 1;
        [self stopRoadAtSpeed:0];
        return;
    }

    for (NSUInteger i = 0; i < 2; i++) {
        CALayer *light = i == 0 ? _beamLeft : _beamRight;
        CAKeyframeAnimation *flicker = scene_keyframes(@"opacity",
            @[@0, @0.95, @0.18, @1, @0.78, @1],
            @[@0, @0.12, @0.2, @0.32, @0.46, @1], 0.9, scene_later(0.12 + i * 0.045), 1);
        flicker.timingFunctions = scene_linear_steps(6);
        [light addAnimation:flicker forKey:@"ignite.flicker"];
        light.opacity = 1;
    }
    [self fadeLayer:_atmos from:0.5 to:1 duration:0.9 delay:0.18];
    [self fadeLayer:_roadFade from:0.28 to:1 duration:0.7 delay:0.3];
    [self fadeLayer:_halo from:0.55 to:1 duration:0.7 delay:0.2];
    [self fadeLayer:_horizon from:0.6 to:1 duration:0.5 delay:0.2];
    [self fadeLayer:_link from:0 to:1 duration:0.5 delay:0.38];
    [self animate:_phone
        from:@{@"opacity": @0, @"transform": [NSValue valueWithCATransform3D:
            CATransform3DMakeTranslation(0, 10, 0)]}
        to:@{@"opacity": @1, @"transform": [NSValue valueWithCATransform3D:CATransform3DIdentity]}
        duration:0.6 delay:0.46 curve:@"out"];
    _phone.opacity = 1;
    _phone.transform = CATransform3DIdentity;

    [self stopRoadAtSpeed:0];
    [self setRoadTarget:[self cruiseSpeed] tau:900];
    __weak ShowcaseConnectionScene *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ShowcaseConnectionScene *scene = weakSelf;
        if (scene && scene->_token == token) [scene startBladeWind];
    });
}

/* The blades reach forward, one after another, like air flowing past. */
- (void)startBladeWind {
    _reduced = UIAccessibilityIsReduceMotionEnabled();
    if (_reduced || _bladeWinds) return;
    NSMutableArray<CAKeyframeAnimation *> *winds = [NSMutableArray array];
    for (NSUInteger i = 0; i < _blades.count; i++) {
        CAKeyframeAnimation *wind = scene_keyframes(@"transform",
            @[[NSValue valueWithCATransform3D:CATransform3DIdentity],
              [NSValue valueWithCATransform3D:CATransform3DConcat(
                  CATransform3DMakeTranslation(3, 0, 0), CATransform3DMakeScale(1.1, 1, 1))],
              [NSValue valueWithCATransform3D:CATransform3DIdentity],
              [NSValue valueWithCATransform3D:CATransform3DIdentity]],
            @[@0, @0.32, @0.7, @1], 2.6, scene_later(i * 0.18), HUGE_VALF);
        wind.timingFunctions = @[
            [CAMediaTimingFunction functionWithControlPoints:0.45 :0 :0.25 :1],
            [CAMediaTimingFunction functionWithControlPoints:0.45 :0 :0.4 :1],
            [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
        [winds addObject:wind];
        [_blades[i] addAnimation:wind forKey:@"wind"];
    }
    _bladeWinds = winds;
    [self setTempo];
}

- (void)setTempo {
    float rate = 1.0f;
    if (_phase == ShowcaseScenePhaseChoose) rate = 0.72f;
    else if (_phase == ShowcaseScenePhaseConnecting) rate = 1.9f;
    /* -animationForKey: hands back a read-only copy, so keep our own writer-side
     * objects and re-add them. The loop's local time is (now - begin) * speed,
     * so the begin time moves with the rate: the loop resumes where it was,
     * only at the new rate. A loop still waiting for its delay keeps it. */
    CFTimeInterval now = CACurrentMediaTime();
    for (NSUInteger i = 0; i < _bladeWinds.count && i < _blades.count; i++) {
        CAKeyframeAnimation *wind = _bladeWinds[i];
        if (wind.speed == rate) continue;
        if (now > wind.beginTime && wind.speed > 0) {
            CFTimeInterval local = (now - wind.beginTime) * wind.speed;
            wind.beginTime = now - local / rate;
        }
        wind.speed = rate;
        [_blades[i] addAnimation:wind forKey:@"wind"];
    }
}

/* ── Scan and flow ──────────────────────────────────────────────── */

- (void)startScan {
    _reduced = UIAccessibilityIsReduceMotionEnabled();
    if (_reduced || [_arcs.firstObject animationForKey:@"scan.scale"]) return;
    _arcsLayer.opacity = 1;
    CGFloat hit = ((150.0 / kSceneArcRadius) - kSceneArcFrom) / (1 - kSceneArcFrom) * kSceneArcDuration;
    for (NSUInteger i = 0; i < _arcs.count; i++) {
        CAGradientLayer *arc = _arcs[i];
        NSTimeInterval delay = 0.5 + i * kSceneArcGap;
        CAKeyframeAnimation *scale = scene_keyframes(@"transform",
            @[[NSValue valueWithCATransform3D:CATransform3DMakeScale(kSceneArcFrom, kSceneArcFrom, 1)],
              [NSValue valueWithCATransform3D:CATransform3DIdentity]],
            @[@0, @1], kSceneArcDuration, scene_later(delay), HUGE_VALF);
        scale.timingFunction = [CAMediaTimingFunction functionWithName:
            kCAMediaTimingFunctionLinear];
        CAKeyframeAnimation *fade = scene_keyframes(@"opacity",
            @[@0, @0.55, @0.28, @0], @[@0, @0.16, @0.84, @1],
            kSceneArcDuration, scene_later(delay), HUGE_VALF);
        fade.timingFunctions = scene_linear_steps(4);
        [arc addAnimation:scale forKey:@"scan.scale"];
        [arc addAnimation:fade forKey:@"scan.fade"];
    }
    CAKeyframeAnimation *breath = scene_keyframes(@"opacity",
        @[@0.45, @1, @0.45], @[@0, @0.5, @1], kSceneArcGap,
        scene_later(0.5 + hit - kSceneArcGap / 2.0), HUGE_VALF);
    breath.timingFunction = [CAMediaTimingFunction functionWithName:
        kCAMediaTimingFunctionEaseInEaseOut];
    [_phoneGhost addAnimation:breath forKey:@"scan.breath"];
}

- (void)startFlow {
    _reduced = UIAccessibilityIsReduceMotionEnabled();
    if (_reduced || [_dots.firstObject animationForKey:@"flow.travel"]) return;
    for (NSUInteger i = 0; i < _dots.count; i++) {
        CALayer *dot = _dots[i];
        CAKeyframeAnimation *travel = scene_keyframes(@"transform",
            @[[NSValue valueWithCATransform3D:CATransform3DIdentity],
              [NSValue valueWithCATransform3D:CATransform3DMakeTranslation(0, kSceneLinkTravel, 0)]],
            @[@0, @1], 1.05, scene_later(i * 0.35), HUGE_VALF);
        travel.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.4 :0 :0.6 :1];
        CAKeyframeAnimation *fade = scene_keyframes(@"opacity",
            @[@0, @1, @1, @0], @[@0, @0.18, @0.8, @1], 1.05, scene_later(i * 0.35), HUGE_VALF);
        fade.timingFunctions = scene_linear_steps(4);
        [dot addAnimation:travel forKey:@"flow.travel"];
        [dot addAnimation:fade forKey:@"flow.fade"];
    }
}

/* ── Real progress ──────────────────────────────────────────────── */

- (void)setSegments:(NSInteger)done {
    NSMutableArray *off = [NSMutableArray array];
    NSMutableArray *on = [NSMutableArray array];
    for (NSInteger i = kSceneSteps - 1; i >= 0; i--) {
        if (_lit[i] && i >= done) [off addObject:@(i)];
    }
    for (NSInteger i = 0; i < kSceneSteps; i++) {
        if (!_lit[i] && i < done) [on addObject:@(i)];
    }
    NSUInteger order = 0;
    for (NSNumber *index in off) {
        [self setSegment:index.integerValue on:NO delay:order * 0.035];
        order++;
    }
    order = 0;
    for (NSNumber *index in on) {
        [self setSegment:index.integerValue on:YES delay:order * 0.07];
        order++;
    }
}

- (void)setSegment:(NSInteger)index on:(BOOL)on delay:(NSTimeInterval)delay {
    CAShapeLayer *segment = _segments[index];
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
    animation.fromValue = @(segment.strokeEnd);
    animation.toValue = @(on ? 1 : 0);
    animation.duration = on ? 0.28 : 0.2;
    animation.beginTime = scene_later(delay);
    animation.fillMode = kCAFillModeBackwards;
    animation.timingFunction = [CAMediaTimingFunction functionWithName:
        on ? kCAMediaTimingFunctionEaseOut : kCAMediaTimingFunctionEaseIn];
    _lit[index] = on;
    segment.strokeEnd = on ? 1 : 0;
    [segment addAnimation:animation forKey:@"seg"];
}

- (void)setPhoneFound:(BOOL)found {
    if (found == _phoneFound) return;
    _phoneFound = found;
    [_phoneGhost removeAllAnimations];
    [_phoneSolid removeAllAnimations];
    CGFloat ghostFrom = _phoneGhost.opacity, solidFrom = _phoneSolid.opacity;
    _phoneGhost.opacity = found ? 0 : 1;
    _phoneSolid.opacity = found ? 1 : 0;
    [_phoneGhost addAnimation:scene_fade(ghostFrom, found ? 0 : 1, 0.32, scene_later(0))
                       forKey:@"phone.ghost"];
    [_phoneSolid addAnimation:scene_fade(solidFrom, found ? 1 : 0,
                                         found ? 0.52 : 0.26, scene_later(0))
                       forKey:@"phone.solid"];
    if (found) {
        _phoneSolid.transform = CATransform3DIdentity;
        CAKeyframeAnimation *pop = scene_keyframes(@"transform",
            @[[NSValue valueWithCATransform3D:CATransform3DMakeScale(1.14, 1.14, 1)],
              [NSValue valueWithCATransform3D:CATransform3DIdentity]],
            @[@0, @1], 0.52, scene_later(0), 1);
        pop.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.3 :1.4 :0.5 :1];
        [_phoneSolid addAnimation:pop forKey:@"phone.pop"];
    }
}

/* ── Hand-off into CarPlay ──────────────────────────────────────── */

- (void)playHandoffWithCompletion:(void (^)(void))completion {
    if (_handingOff) return;
    _handingOff = YES;
    _farewellPlayed = NO;
    NSUInteger token = ++_token;
    __weak ShowcaseConnectionScene *weakSelf = self;

    [self stopScan];
    [self stopFlow];
    [self stopBladeWind];
    [self setSegments:kSceneSteps];
    _phase = ShowcaseScenePhaseConnecting;
    _done = kSceneSteps;

    if (_reduced) {
        /* Reduce Motion: no zoom into the mark — a short cross-fade onto
         * CarPlay instead, reusing the hand-off's own fade key so the un-zoom
         * in -finishHandoff cleans it up. */
        UIView *host = self.zoomHost;
        if (host) {
            host.layer.opacity = 0;
            [host.layer addAnimation:scene_fade(1, 0, 0.22, scene_later(0.03))
                              forKey:@"handoff.fade"];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ShowcaseConnectionScene *scene = weakSelf;
            if (!scene || scene->_token != token) return;
            [scene finishHandoff];
            if (completion) completion();
        });
        return;
    }

    [self animate:_phone
        from:@{@"opacity": @1, @"transform": [NSValue valueWithCATransform3D:CATransform3DIdentity]}
        to:@{@"opacity": @0, @"transform": [NSValue valueWithCATransform3D:
            CATransform3DConcat(CATransform3DMakeTranslation(0, 150, 0),
                                CATransform3DMakeScale(0.45, 0.45, 1))]}
        duration:0.38 delay:0 curve:@"out"];
    _phone.opacity = 0;

    for (NSUInteger i = 0; i < _segments.count; i++) {
        CAShapeLayer *segment = _segments[i];
        CABasicAnimation *absorb = [CABasicAnimation animationWithKeyPath:@"strokeStart"];
        absorb.fromValue = @0;
        absorb.toValue = @1;
        absorb.duration = 0.16;
        absorb.beginTime = scene_later(0.06 + i * 0.026);
        absorb.fillMode = kCAFillModeBackwards;
        absorb.timingFunction = [CAMediaTimingFunction functionWithName:
            kCAMediaTimingFunctionEaseIn];
        segment.strokeStart = 1;
        [segment addAnimation:absorb forKey:@"absorb"];
    }
    [self fadeLayer:_link from:1 to:0 duration:0.3 delay:0.12];

    CAKeyframeAnimation *swallow = scene_keyframes(@"transform",
        @[[NSValue valueWithCATransform3D:CATransform3DIdentity],
          [NSValue valueWithCATransform3D:CATransform3DMakeScale(1.08, 1.08, 1)],
          [NSValue valueWithCATransform3D:CATransform3DIdentity]],
        @[@0, @0.45, @1], 0.32, scene_later(0.33), 1);
    swallow.timingFunctions = @[
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut],
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn]];
    [_tile addAnimation:swallow forKey:@"handoff.tile"];

    for (NSUInteger i = 0; i < _blades.count; i++) {
        CATransform3D stretched = CATransform3DConcat(CATransform3DMakeTranslation(4, 0, 0),
                                                      CATransform3DMakeScale(1.22, 1, 1));
        CAKeyframeAnimation *pull = scene_keyframes(@"transform",
            @[[NSValue valueWithCATransform3D:CATransform3DIdentity],
              [NSValue valueWithCATransform3D:stretched]],
            @[@0, @1], 0.3, scene_later(0.34 + i * 0.03), 1);
        pull.timingFunction = [CAMediaTimingFunction functionWithName:
            kCAMediaTimingFunctionEaseOut];
        _blades[i].transform = stretched;
        [_blades[i] addAnimation:pull forKey:@"handoff.blade"];
    }

    [self animate:_ring
        from:@{@"transform": [NSValue valueWithCATransform3D:
                  CATransform3DMakeScale(1.05, 1.05, 1)],
              @"opacity": @0.95}
        to:@{@"transform": [NSValue valueWithCATransform3D:
                  CATransform3DMakeScale(5.2, 5.2, 1)],
            @"opacity": @0}
        duration:0.7 delay:0.36 curve:@"out"];
    _ring.opacity = 0;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.32 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ShowcaseConnectionScene *scene = weakSelf;
        if (!scene || scene->_token != token) return;
        [scene setRoadTarget:7 tau:170];
        for (CALayer *light in @[scene->_beamLeft, scene->_beamRight]) {
            CAKeyframeAnimation *push = scene_keyframes(@"transform",
                @[[NSValue valueWithCATransform3D:CATransform3DIdentity],
                  [NSValue valueWithCATransform3D:CATransform3DMakeScale(1.15, 1.35, 1)]],
                @[@0, @1], 0.62, scene_later(0), 1);
            push.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.3 :0 :0.2 :1];
            light.transform = CATransform3DMakeScale(1.15, 1.35, 1);
            [light addAnimation:push forKey:@"handoff.beam"];
        }
        CAKeyframeAnimation *swell = scene_keyframes(@"transform",
            @[[NSValue valueWithCATransform3D:CATransform3DIdentity],
              [NSValue valueWithCATransform3D:CATransform3DMakeScale(1.6, 1.6, 1)]],
            @[@0, @1], 0.7, scene_later(0), 1);
        swell.timingFunction = [CAMediaTimingFunction functionWithName:
            kCAMediaTimingFunctionEaseIn];
        scene->_halo.transform = CATransform3DMakeScale(1.6, 1.6, 1);
        [scene->_halo addAnimation:swell forKey:@"handoff.halo"];

        [scene applyHostZoom];
        CAKeyframeAnimation *flashScale = scene_keyframes(@"transform",
            @[[NSValue valueWithCATransform3D:CATransform3DMakeScale(0.3, 0.3, 1)],
              [NSValue valueWithCATransform3D:CATransform3DMakeScale(1.4, 1.4, 1)]],
            @[@0, @1], 0.42, scene_later(0.3), 1);
        flashScale.timingFunction = [CAMediaTimingFunction functionWithName:
            kCAMediaTimingFunctionEaseIn];
        CAKeyframeAnimation *flashFade = scene_keyframes(@"opacity", @[@0, @0.9],
            @[@0, @1], 0.42, scene_later(0.3), 1);
        flashFade.timingFunctions = scene_linear_steps(2);
        [scene->_flash addAnimation:flashScale forKey:@"handoff.flash"];
        [scene->_flash addAnimation:flashFade forKey:@"handoff.flashFade"];
        scene->_flash.opacity = 0;
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.32 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ShowcaseConnectionScene *scene = weakSelf;
        if (!scene || scene->_token != token) return;
        [scene finishHandoff];
        if (completion) completion();
    });
}

/* The hand-off leaves the scene on its last frame (iPhone gone, link
 * absorbed, blades stretched, road at full speed). The overlay is off screen
 * from here, so park the scene underneath it: a later reconnect then ignites
 * from the parked picture instead of reusing that frame. */
- (void)finishHandoff {
    _handingOff = NO;
    [self removeHostZoom];
    [self enterParked];
}

- (void)cancelHandoff {
    if (!_handingOff) return;
    _token++;
    [self finishHandoff];
}

/* Zooms the overlay about the mark, so the flash looks like it comes out of
 * the logo rather than out of the middle of the screen.
 *
 * A layer transform is applied around the anchor point, so the translation
 * that pins the mark has to be measured from there — using the mark's
 * position in the overlay's bounds sent it towards the top-left corner
 * instead of holding it still while the scene grew around it. */
- (void)applyHostZoom {
    UIView *host = self.zoomHost;
    if (!host) return;
    const CGFloat zoom = 2.3;
    CGPoint anchor = CGPointMake(host.bounds.size.width * host.layer.anchorPoint.x,
                                 host.bounds.size.height * host.layer.anchorPoint.y);
    CGPoint pivot = CGPointMake(_logoCenter.x - anchor.x, _logoCenter.y - anchor.y);
    CATransform3D about = CATransform3DConcat(
        CATransform3DMakeTranslation((1 - zoom) * pivot.x,
                                     (1 - zoom) * pivot.y, 0),
        CATransform3DMakeScale(zoom, zoom, 1));
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"transform"];
    animation.fromValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    animation.toValue = [NSValue valueWithCATransform3D:about];
    animation.duration = 0.92;
    animation.fillMode = kCAFillModeForwards;
    animation.removedOnCompletion = NO;
    animation.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.45 :0 :0.8 :0.35];
    host.layer.transform = about;
    [host.layer addAnimation:animation forKey:@"handoff.zoom"];

    /* The fade only fills backwards, so the model value has to be its end
     * state: otherwise the zoomed overlay snaps back to full opacity for the
     * frames between the fade ending and the overlay being hidden.
     * -removeHostZoom puts it back to 1. */
    host.layer.opacity = 0;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @1;
    fade.toValue = @0;
    fade.duration = 0.38;
    fade.beginTime = scene_later(0.54);
    fade.fillMode = kCAFillModeBackwards;
    fade.timingFunction = [CAMediaTimingFunction functionWithName:
        kCAMediaTimingFunctionEaseOut];
    [host.layer addAnimation:fade forKey:@"handoff.fade"];
}

- (void)removeHostZoom {
    UIView *host = self.zoomHost;
    if (!host) return;
    [host.layer removeAnimationForKey:@"handoff.zoom"];
    [host.layer removeAnimationForKey:@"handoff.fade"];
    host.layer.transform = CATransform3DIdentity;
    host.layer.opacity = 1;
}

/* ── Farewell ───────────────────────────────────────────────────── */

- (void)playFarewellWithCompletion:(void (^)(void))completion {
    if (_farewellRunning || _farewellPlayed) return;
    _farewellRunning = YES;
    _farewellPlayed = YES;
    NSUInteger token = ++_token;
    __weak ShowcaseConnectionScene *weakSelf = self;
    _handingOff = NO;
    [self removeHostZoom];
    [self hideAll];
    [self stopBladeWind];
    [self stopScan];
    [self stopFlow];
    [self stopRoadAtSpeed:0];
    [self snapDashesToParkedPose];

    /* Start from the connected picture: headlights on, road running, the
     * iPhone found and the link complete. */
    _ignited = YES;
    /* The guide lines belong to the parked picture underneath the connected
     * one, so the farewell keeps them from its first frame. */
    _edgesGradient.opacity = 1;
    _edgeMask.strokeEnd = 1;
    _phase = ShowcaseScenePhaseConnecting;
    _done = kSceneSteps;
    _atmos.opacity = 1;
    _roadFade.opacity = 1;
    _horizon.opacity = 1;
    _halo.opacity = 1;
    _tile.opacity = 1;
    _link.opacity = 1;
    _phone.opacity = 1;
    _beamLeft.opacity = 1;
    _beamRight.opacity = 1;
    _phoneGhost.opacity = 0;
    _phoneSolid.opacity = 1;
    _phoneFound = YES;
    for (NSInteger i = 0; i < kSceneSteps; i++) {
        ((CAShapeLayer *)_segments[i]).strokeEnd = 1;
        _lit[i] = YES;
    }

    _reduced = UIAccessibilityIsReduceMotionEnabled();
    if (_reduced) {
        _phone.opacity = 0;
        _link.opacity = 0;
        _beamLeft.opacity = 0;
        _beamRight.opacity = 0;
        /* hideAll dimmed the mark; it stays lit through "See you soon". */
        for (CALayer *pivot in _blades) pivot.opacity = 1;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ShowcaseConnectionScene *scene = weakSelf;
            if (!scene || scene->_token != token) return;
            [scene enterParked];
            if (completion) completion();
        });
        return;
    }

    for (CALayer *pivot in _blades) pivot.opacity = 0.14f;
    [self setRoadTarget:1.5 tau:300];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ShowcaseConnectionScene *scene = weakSelf;
        if (scene && scene->_token == token) [scene setRoadTarget:0 tau:380];
    });

    [self fadeLayer:_link from:0 to:1 duration:0.42 delay:0.2];
    [self animate:_phone
        from:@{@"opacity": @0, @"transform": [NSValue valueWithCATransform3D:
            CATransform3DMakeTranslation(0, 6, 0)]}
        to:@{@"opacity": @1, @"transform": [NSValue valueWithCATransform3D:CATransform3DIdentity]}
        duration:0.46 delay:0.24 curve:@"out"];
    _phone.opacity = 1;

    /* The brake: three light streaks sweep in from the right and settle
     * exactly where the blades sit. */
    const NSTimeInterval land = 1.18;
    for (NSUInteger i = 0; i < _brakes.count; i++) {
        CALayer *streak = _brakes[i];
        NSTimeInterval offset = i * 0.07;
        CAKeyframeAnimation *brake = scene_keyframes(@"transform",
            @[[NSValue valueWithCATransform3D:CATransform3DConcat(
                  CATransform3DMakeTranslation(300, 0, 0), CATransform3DMakeScale(3.2, 1, 1))],
              [NSValue valueWithCATransform3D:CATransform3DConcat(
                  CATransform3DMakeTranslation(150, 0, 0), CATransform3DMakeScale(2.4, 1, 1))],
              [NSValue valueWithCATransform3D:CATransform3DConcat(
                  CATransform3DMakeTranslation(-2.5, 0, 0), CATransform3DMakeScale(0.96, 1, 1))],
              [NSValue valueWithCATransform3D:CATransform3DIdentity]],
            @[@0, @0.2, @0.86, @1], 1.0, scene_later(0.18 + offset), 1);
        brake.timingFunctions = @[
            [CAMediaTimingFunction functionWithControlPoints:0.12 :0.72 :0.22 :1],
            [CAMediaTimingFunction functionWithControlPoints:0.12 :0.72 :0.22 :1],
            [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
        CAKeyframeAnimation *brakeIn = scene_keyframes(@"opacity", @[@0, @1, @1],
            @[@0, @0.2, @1], 1.0, scene_later(0.18 + offset), 1);
        brakeIn.timingFunctions = scene_linear_steps(3);
        CAKeyframeAnimation *brakeOut = scene_keyframes(@"opacity", @[@1, @0],
            @[@0, @1], 0.32, scene_later(land + offset), 1);
        brakeOut.timingFunctions = scene_linear_steps(2);
        streak.opacity = 0;
        [streak addAnimation:brake forKey:@"brake"];
        [streak addAnimation:brakeIn forKey:@"brake.in"];
        [streak addAnimation:brakeOut forKey:@"brake.out"];
        [self fadeLayer:_blades[i] from:0.14 to:1 duration:0.32 delay:land - 0.06 + offset];
    }

    CAKeyframeAnimation *nudge = scene_keyframes(@"transform",
        @[[NSValue valueWithCATransform3D:CATransform3DIdentity],
          [NSValue valueWithCATransform3D:CATransform3DMakeTranslation(3, 0, 0)],
          [NSValue valueWithCATransform3D:CATransform3DIdentity]],
        @[@0, @0.35, @1], 0.46, scene_later(land - 0.12), 1);
    nudge.timingFunction = [CAMediaTimingFunction functionWithName:
        kCAMediaTimingFunctionEaseInEaseOut];
    [_tile addAnimation:nudge forKey:@"farewell.nudge"];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ShowcaseConnectionScene *scene = weakSelf;
        if (scene && scene->_token == token) [scene unwindForFarewell];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.65 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ShowcaseConnectionScene *scene = weakSelf;
        if (!scene || scene->_token != token) return;
        [scene enterParked];
        if (completion) completion();
    });
}

- (void)unwindForFarewell {
    for (NSUInteger i = 0; i < _segments.count; i++) {
        CAShapeLayer *segment = _segments[i];
        CABasicAnimation *unwind = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
        unwind.fromValue = @1;
        unwind.toValue = @0;
        unwind.duration = 0.17;
        unwind.beginTime = scene_later((kSceneSteps - 1 - (NSInteger)i) * 0.042);
        unwind.fillMode = kCAFillModeBackwards;
        unwind.timingFunction = [CAMediaTimingFunction functionWithName:
            kCAMediaTimingFunctionEaseIn];
        segment.strokeEnd = 0;
        _lit[i] = NO;
        [segment addAnimation:unwind forKey:@"unwind"];
    }
    [_phoneSolid removeAllAnimations];
    [_phoneGhost removeAllAnimations];
    _phoneSolid.opacity = 0;
    _phoneGhost.opacity = 1;
    [_phoneSolid addAnimation:scene_fade(1, 0, 0.3, scene_later(0.3)) forKey:@"farewell.solid"];
    [_phoneGhost addAnimation:scene_fade(0, 1, 0.3, scene_later(0.3)) forKey:@"farewell.ghost"];
    [self fadeLayer:_link from:1 to:0 duration:0.42 delay:0.4];
    [self animate:_phone
        from:@{@"opacity": @1, @"transform": [NSValue valueWithCATransform3D:CATransform3DIdentity]}
        to:@{@"opacity": @0, @"transform": [NSValue valueWithCATransform3D:
            CATransform3DMakeTranslation(0, -28, 0)]}
        duration:0.56 delay:0.4 curve:@"in"];
    _phone.opacity = 0;

    /* Ignition off: the headlights flicker out and the scene dims to park. */
    for (NSUInteger i = 0; i < 2; i++) {
        CALayer *light = i == 0 ? _beamLeft : _beamRight;
        CAKeyframeAnimation *die = scene_keyframes(@"opacity",
            @[@1, @0.3, @0.6, @0], @[@0, @0.15, @0.3, @1],
            0.56, scene_later(0.25 + i * 0.04), 1);
        die.timingFunctions = scene_linear_steps(4);
        light.opacity = 0;
        [light addAnimation:die forKey:@"farewell.beam"];
    }
    [self fadeLayer:_atmos from:1 to:0.5 duration:0.8 delay:0.3];
    [self fadeLayer:_roadFade from:1 to:0.28 duration:0.8 delay:0.3];
    [self fadeLayer:_halo from:1 to:0.55 duration:0.8 delay:0.3];
    [self fadeLayer:_horizon from:1 to:0.6 duration:0.8 delay:0.3];
}

/* ── Housekeeping ───────────────────────────────────────────────── */

/* Backgrounding strips layer animations; restart the loops on return. */
- (void)restartMotion {
    if (!_laidOut || _handingOff || _farewellRunning) return;
    if (_reduced) {
        /* No loops to restart, but the frozen dashes went with them. */
        [self restoreDashes];
        return;
    }
    if (_phase == ShowcaseScenePhaseParked) {
        [self enterParked];
        return;
    }
    [self stopBladeWind];
    [self stopScan];
    [self stopFlow];
    [self restoreDashes];
    NSUInteger token = _token;
    __weak ShowcaseConnectionScene *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ShowcaseConnectionScene *scene = weakSelf;
        if (!scene || scene->_token != token) return;
        [scene startBladeWind];
        if (scene->_phase == ShowcaseScenePhaseConnecting) [scene startFlow];
        else [scene startScan];
        [scene setRoadTarget:[scene cruiseSpeed] tau:400];
    });
}

- (void)accessibilityChanged {
    BOOL reduced = UIAccessibilityIsReduceMotionEnabled();
    if (reduced == _reduced) return;
    _reduced = reduced;
    /* The farewell and the hand-off run on their own timers and finish by
     * themselves; re-parking under them would clear their flags without
     * cancelling them and replay the connecting picture on "See you". The
     * next phase change picks up the new setting. */
    if (_farewellRunning || _handingOff) return;
    ShowcaseScenePhase phase = _phase;
    NSInteger done = _done;
    _ignited = NO;
    [self enterParked];
    if (phase != ShowcaseScenePhaseParked) [self applyPhase:phase progress:done];
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) RootViewController *vc;
@property (nonatomic, strong) VideoView *videoView;
#if SHOWCASE_MIRROR_BENCH
@property (nonatomic, weak) ShowcaseMirrorReceiver *screenMirror;
#endif
@property (nonatomic, strong) AVPlayer *carVideoPlayer;
@property (nonatomic, strong) UIView *carVideoOverlay;
@property (nonatomic, copy) NSString *carVideoItemID;
@property (nonatomic) uint32_t carVideoStreamID;
/* requestUI / setRate>0 that arrived while the app was Inactive; replayed by
 * handleDidBecomeActive for the video still loaded, dropped with it. */
@property (nonatomic) BOOL carVideoPendingShow;
@property (nonatomic) BOOL carVideoPendingPlay;
@property (nonatomic, strong)
    NSMutableDictionary<NSNumber *, CarPlayAudioPlayer *> *audioPlayers;
/* Last MSG_AUDIO_RESYNC request per streamType (CACurrentMediaTime seconds).
 * Owned by audioWorkQueue, like audioPlayers. */
@property (nonatomic, strong)
    NSMutableDictionary<NSNumber *, NSNumber *> *audioResyncRequestTimes;

/* Setup overlay */
@property (nonatomic, strong) UIView   *setupOverlay;
@property (nonatomic, strong) UILabel  *titleLabel;
@property (nonatomic, strong) UILabel  *headlineLabel;
@property (nonatomic, strong) UIButton *primaryButton;     /* Start CarPlay / Open Settings */
@property (nonatomic, strong) UIButton *secondaryButton;   /* Cancel */
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) ConnectStepsView *stepsView;
@property (nonatomic, strong) ShowcaseConnectionScene *connectionScene;
@property (nonatomic, strong) CAGradientLayer *primaryGradient;
@property (nonatomic, strong) UILabel *farewellCaption;
@property (nonatomic) BOOL showFarewell;
@property (nonatomic) BOOL sceneShowing;
/* Whether the last renderState already drew StateActive; the hand-off plays
 * only on the way into Active, never on a re-render of a running session. */
@property (nonatomic) BOOL activeRendered;
/* The farewell's two lines are staged in, so a re-render must not restart it;
 * and the parked screen behind them is faded in once the farewell is over. */
@property (nonatomic) BOOL farewellWordsRevealed;
@property (nonatomic) BOOL idleRevealPending;

/* Connection progress shown while the iPhone connects */
@property (nonatomic, assign) NSInteger connectCompleted;
@property (nonatomic, assign) BOOL firstTimePairing;
@property (nonatomic, assign) int btProgressToken;
@property (nonatomic, assign) BOOL autoStartConsumed;
/* The pending startFlow call came from auto start or a restart, not a tap. */
@property (nonatomic, assign) BOOL automaticStartRequested;
/* An automatic start waits here for the shared Wi-Fi to come up (car cold
 * boot: the iPad joins the router after the screen is already showing). */
@property (nonatomic, assign) CFAbsoluteTime autoStartNetworkDeadline;
/* Start was tapped while a dead broker was being replaced; start once the
 * new broker's preheat is ready. */
@property (nonatomic, assign) BOOL pendingUserStart;
/* The car name this session's helpers were started with. Captured once in
 * startFlow so both helpers and the screen agree, and so background reads
 * never race Settings writing Car.name. */
@property (atomic, copy) NSString *sessionCarName;

/* Hotspot automation */
@property (nonatomic, assign) BOOL hotspotManual;          /* fell back to Settings */
@property (nonatomic, assign) NSInteger hotspotAttempt;
@property (nonatomic, strong) NSTimer *hotspotWatchdog;
@property (nonatomic, strong) NSTimer *discoveryTimer;
@property (nonatomic, assign) BOOL sharedWifiSession;
@property (nonatomic, copy) NSString *sharedWifiInterface;

/* Floating chrome */
@property (nonatomic, strong) UIButton *closeButton;       /* top-right, only ACTIVE */
@property (nonatomic, strong) UIButton *settingsButton;    /* top-left, revealed with close during Active */
@property (nonatomic, strong) UIButton *starButton;        /* top-right on the setup screen */
@property (nonatomic, strong) ControlsOverlayView *controlsOverlay;

/* Three-finger tap is reserved for Showcase chrome and leaves pinch to CarPlay. */
@property (nonatomic, strong) UITapGestureRecognizer *controlsGesture;
@property (nonatomic, assign) BOOL chromeVisible;
/* The iPhone ended a running session; start again and wait for it, as a car
 * head unit does. The Stop button never sets this. */
@property (nonatomic, assign) BOOL restartAfterStop;

/* Lifecycle */
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
@property (nonatomic, strong) NSTimer *bgTaskTimer;

/* State */
@property (atomic, assign) ShowcaseState state;

/* Children */
@property (nonatomic, assign) pid_t btdaemonPid;
@property (nonatomic, assign) pid_t carplayBtPid;
@property (nonatomic, assign) pid_t carplayServicesPid;
@property (nonatomic, assign) pid_t baaBrokerPid;

/* bridge100 tcpdump capture */
@property (nonatomic, assign) pid_t tcpdumpPid;
@property (nonatomic, copy)   NSString *currentTcpdumpPath;
@property (nonatomic, strong) NSTimer *tcpdumpStopTimer;
@property (nonatomic, assign) BOOL tcpdumpMissingPromptShown;
@property (nonatomic, assign) BOOL diagnosticsEnabled;
@property (atomic, assign) BOOL helpersLoggedThisRun;
@property (nonatomic, assign) BOOL bluetoothHandedOff;
/* Set across the Wi-Fi hand-off's hand_back_system_bluetooth in every build;
 * read from the main thread while the hand-back runs on bgQueue. */
@property (atomic, assign) BOOL bluetoothHandBackInProgress;
@property (nonatomic, assign) BOOL bluetoothRetryAttempted;
/* The retry helper really ran in this flow; only then is its log evidence. */
@property (nonatomic, assign) BOOL bluetoothRetryHelperSpawned;
/* BTstack.log size when this flow's last takeover attempt began. */
@property (nonatomic, assign) unsigned long long btstackLogOffset;
@property (nonatomic, copy) NSString *pendingBluetoothErrorTitle;
@property (nonatomic, copy) NSString *pendingBluetoothErrorExplanation;
@property (nonatomic, copy) NSString *pendingBluetoothDiagnostic;
/* A Wi-Fi setup error raised while Settings was open; shown once it closes. */
@property (nonatomic, copy) NSString *pendingWifiSetupError;
/* The session's own helpers could not start; told once the screen is Idle. */
@property (nonatomic, assign) BOOL pendingServicesSetupError;

/* Networking */
@property (nonatomic, assign) int listenFd;
@property (nonatomic, assign) int clientFd;
@property (nonatomic, strong) dispatch_semaphore_t ipcDone;
@property (nonatomic, strong) dispatch_queue_t bgQueue;
@property (nonatomic, strong) dispatch_queue_t videoQueue;
/* Owns audioPlayers. Audio Queue and AVAudioSession calls can block for up to
 * a second; doing them on the IPC reader would stall the service's writes. */
@property (nonatomic, strong) dispatch_queue_t audioWorkQueue;
@property (nonatomic, strong) dispatch_source_t helperMonitor;
@property (nonatomic, strong) dispatch_queue_t diagnosticsQueue;
@property (nonatomic, assign) BOOL diagnosticsUploadInProgress;

/* BAA preheater and local signing broker */
@property (nonatomic, assign) BOOL baaReady;
@property (nonatomic, assign) BOOL baaLoading;
@property (nonatomic, assign) BOOL baaBrokerReused;
/* Identity of a reused broker (see baa_broker_start_micros); 0 otherwise. */
@property (nonatomic, assign) uint64_t baaBrokerStartMicros;
/* notAfter of the current broker's leaf certificate; 0 when unknown. */
@property (nonatomic, assign) time_t baaCertNotAfter;
/* A replacement broker is fetching its certificate beside the current one. */
@property (nonatomic, assign) BOOL baaRenewing;
/* The replacement broker's pid while baaRenewing; a session's helper reap
 * must spare it. Written on the main queue before any session can start. */
@property (nonatomic, assign) pid_t baaRenewPid;
@property (nonatomic, assign) uint64_t baaRenewNotBefore;
/* An unreachable broker found while a flow ran: replacing it then would reap
 * the session's helpers (startBAABroker), so it waits for Idle (stopFlow). */
@property (nonatomic, assign) BOOL baaReplaceDeferred;
/* Which of the two broker logs the current broker writes (see renewBAABroker). */
@property (nonatomic, assign) BOOL baaBrokerOnRenewLog;
@property (nonatomic, copy) NSString *baaError;
/* The broker helper itself could not be spawned (missing or not executable,
 * or posix_spawn failed). Internet does not help here, so Idle says so
 * instead of "Connect to the Internet". */
@property (nonatomic, assign) BOOL baaSpawnFailed;

/* AP polling */
@property (nonatomic, strong) NSTimer *apPollTimer;
@property (nonatomic, strong) dispatch_source_t awdlReassertTimer;

/* Cars */
@property (nonatomic, strong) CarStore *cars;
@end

/* Forward: defined later */
@interface WifiSetupViewController : UIViewController
@property (nonatomic, weak) AppDelegate *appDelegate;
@end

@interface SettingsViewController : UIViewController
@property (nonatomic, weak) AppDelegate *appDelegate;
@property (nonatomic, copy) NSString *initialPage;
- (void)refresh;
@end

@implementation AppDelegate

- (UIInterfaceOrientationMask)application:(UIApplication *)application
        supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    (void)application;
    (void)window;
    return showcase_orientation_mask();
}

- (UIView *)rootContentView {
    return self.vc.contentView ?: self.vc.view;
}

- (BOOL)application:(UIApplication *)app
    didFinishLaunchingWithOptions:(NSDictionary *)opts {

    self.bgQueue = dispatch_queue_create("com.reng.showcase.bg", DISPATCH_QUEUE_SERIAL);
    self.diagnosticsQueue = dispatch_queue_create("com.reng.showcase.diagnostics", DISPATCH_QUEUE_SERIAL);
    self.videoQueue = dispatch_queue_create(
        "com.reng.showcase.video", DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(self.videoQueue,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
    self.audioWorkQueue = dispatch_queue_create(
        "com.reng.showcase.audio", DISPATCH_QUEUE_SERIAL);
    self.audioPlayers = [NSMutableDictionary dictionary];
    self.audioResyncRequestTimes = [NSMutableDictionary dictionary];
    /* No crash-recovery pass is needed here: iOS re-enables AWDL by itself
     * whenever a Continuity service wants it, which is exactly why the
     * suppression below has to be re-asserted on a timer. A run killed
     * mid-session therefore heals on its own. */
    self.state = StateIdle;
    self.listenFd = -1;
    self.clientFd = -1;
    self.bgTask = UIBackgroundTaskInvalid;
    self.tcpdumpPid = 0;
    self.tcpdumpMissingPromptShown = NO;
    /* Opening Showcase is turning the car on: start and page the iPhone. */
    NSMutableDictionary *defaults = [@{
        DEDICATED_RADIO_KEY: @YES,
        AUTO_START_KEY: @YES,
        USAGE_KEY: @NO
    } mutableCopy];
    for (NSArray *item in usage_items()) defaults[item[0]] = @YES;
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
    /* Prioritize Quality becomes the default once, existing setups included. */
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    if (![prefs boolForKey:QUALITY_DEFAULT_SET_KEY]) {
        [prefs setBool:YES forKey:QUALITY_VIDEO_KEY];
        [prefs setBool:NO forKey:SMOOTH_VIDEO_KEY];
        [prefs setBool:YES forKey:QUALITY_DEFAULT_SET_KEY];
        [prefs synchronize];
    }
#ifndef SHOWCASE_SIMULATOR_TEST
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{ send_anonymous_usage(); });
    _diagnosticsEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:DIAGNOSTICS_ENABLED_KEY];
    /* Capture UIKit screen properties on main; ioreg is scheduled separately. */
    carplay_display_hardware();
    /* A session that ended without stopFlow may have left a network paused. */
    dispatch_async(self.bgQueue, ^{
        showcase_release_other_wifi("launch recovery");
        /* A session that ended without stopFlow can leave BTstack holding the
         * controller and BlueTool unloaded. Release and hand it back. */
        hand_back_system_bluetooth("launch recovery");
        showcase_restore_wifi_power_after_cycle("launch recovery");
        /* ...and the Personal Hotspot it turned on. */
        if ([[NSUserDefaults standardUserDefaults] boolForKey:HOTSPOT_OWNED_KEY]) {
            showcase_set_hotspot_discovery(NO);
            showcase_set_hotspot(NO);
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:HOTSPOT_OWNED_KEY];
            ip_log("[HOTSPOT] launch recovery turned off the hotspot Showcase started");
        }
    });
#endif
    self.cars = [[CarStore alloc] init];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.backgroundColor = [UIColor blackColor];

    self.vc = [[RootViewController alloc] init];
    self.vc.view.backgroundColor = [UIColor blackColor];
    self.vc.appDelegate = self;

    UIView *content = [self rootContentView];

    self.videoView = [[VideoView alloc] initWithFrame:content.bounds];
    self.videoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.videoView.backgroundColor = [UIColor blackColor];
    ((AVSampleBufferDisplayLayer *)self.videoView.layer).videoGravity = AVLayerVideoGravityResizeAspect;
    [content addSubview:self.videoView];
    self.vc.videoView = self.videoView;

    [self buildSetupOverlay];
    [self buildChrome];

    self.window.rootViewController = self.vc;
    [self.window makeKeyAndVisible];

    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(handleBackground)
        name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(handleForeground)
        name:UIApplicationWillEnterForegroundNotification object:nil];
    /* WillEnterForeground fires before the app is active, when modals queued
     * in the background still cannot be presented; show them once it is. */
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(handleDidBecomeActive)
        name:UIApplicationDidBecomeActiveNotification object:nil];

    [self startObservingBluetoothProgress];
    [self transitionTo:StateIdle];
#ifdef SHOWCASE_UI_PREVIEW
    [self schedulePreviewFromFile];
#endif
#ifdef SHOWCASE_SIMULATOR_TEST
    self.baaReady = YES;
    [self renderState];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        /* A preview spec drives the screen itself; don't fight it. */
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/showcase_preview"]) return;
        [self presentSettingsPage:@"hotspot"];
    });
#else
    [self startBAA];
    /* The first preheat fails when the iPad is offline at launch, for example
     * before it rejoins Wi-Fi. Retry when the network changes. */
    int networkToken = 0;
    notify_register_dispatch("com.apple.system.config.network_change", &networkToken,
                             dispatch_get_main_queue(), ^(int token) { [self networkChanged]; });
#endif
    return YES;
}

- (void)networkChanged {
    [self retryAutomaticStartWaitingForNetwork];
    static CFAbsoluteTime lastRetry = 0;
    if (self.state != StateIdle || self.baaReady || self.baaLoading || !self.baaError ||
        CFAbsoluteTimeGetCurrent() - lastRetry < 5) return;
    lastRetry = CFAbsoluteTimeGetCurrent();
    ip_log("network changed; retrying CarPlay authentication");
    [self startBAA];
}

/* Reaping stale helpers sleeps, so the broker starts off the main thread and
 * the first frame draws at once. Try Again comes here too when the broker
 * exited after a failed preheat. */
- (void)startBAA {
    if (self.baaLoading) return;
    self.baaLoading = YES;
    self.baaError = nil;
    self.baaSpawnFailed = NO;
    [self renderState];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL started = [self startBAABroker];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.baaLoading = NO;
            if (started) {
                [self preheatBAA];
                return;
            }
            self.baaError = @"The local authentication broker could not start.";
            self.baaSpawnFailed = YES;
            /* Like a failed preheat: the button offers Try Again, and a later
             * network change must not start CarPlay without a tap. */
            self.pendingUserStart = NO;
            ip_log("BAA broker failed to start");
            [self renderState];
        });
    });
}

/* A broker from an earlier launch still holds a certificate, so a relaunch
 * after iOS ends Showcase in the background needs no internet. After 12 hours
 * a replacement is fetched beside it (renewBAABroker); the old broker is kept
 * until that replacement works or its own certificate is about to expire. */
#ifndef LOCAL_PEERPID
#define LOCAL_PEERPID 0x002
#endif
#define BAA_BROKER_REUSE_SECONDS (12 * 3600)
/* A certificate this close to its notAfter is not relied on any more. */
#define BAA_CERT_EXPIRY_MARGIN_SECONDS 3600
/* After a failed renewal (no internet), the next try waits this long. */
#define BAA_RENEW_RETRY_SECONDS 300
#define BAA_BROKER_LOG LOG_DIR "/baa_broker.log"
#define BAA_BROKER_RENEW_LOG LOG_DIR "/baa_broker-renew.log"
/* Present while the current broker writes BAA_BROKER_RENEW_LOG. A broker
 * outlives Showcase, so a reused one would otherwise be assumed to write
 * BAA_BROKER_LOG and its live log would be truncated by the next renewal.
 * Kept outside LOG_DIR so Clear Logs does not drop it. */
#define BAA_BROKER_ON_RENEW_LOG_MARK "/var/mobile/Library/Showcase/baa_broker-on-renew-log"

static void baa_mark_broker_log(BOOL onRenewLog) {
    if (!onRenewLog) {
        unlink(BAA_BROKER_ON_RENEW_LOG_MARK);
        return;
    }
    int fd = open(BAA_BROKER_ON_RENEW_LOG_MARK,
                  O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd >= 0) close(fd);
    else ip_log("BAA broker log marker could not be written (%s)", strerror(errno));
}

/* One DER element at *p: its tag and contents; *p moves past it. */
static BOOL der_next(const uint8_t **p, const uint8_t *end, uint8_t *tag,
                     const uint8_t **body, size_t *length) {
    const uint8_t *q = *p;
    if (end - q < 2) return NO;
    *tag = *q++;
    size_t len = *q++;
    if (len & 0x80) {
        size_t count = len & 0x7f;
        if (count == 0 || count > 4 || (size_t)(end - q) < count) return NO;
        len = 0;
        while (count--) len = (len << 8) | *q++;
    }
    if ((size_t)(end - q) < len) return NO;
    *body = q;
    *length = len;
    *p = q + len;
    return YES;
}

/* UTCTime (YYMMDDHHMMSSZ) or GeneralizedTime (YYYYMMDDHHMMSSZ); 0 if neither. */
static time_t der_time(uint8_t tag, const uint8_t *text, size_t length) {
    size_t digits = tag == 0x17 ? 12 : (tag == 0x18 ? 14 : 0);
    if (!digits || length != digits + 1 || text[digits] != 'Z') return 0;
    int v[7];
    for (size_t i = 0; i < digits; i++)
        if (text[i] < '0' || text[i] > '9') return 0;
    for (size_t i = 0; i < digits / 2; i++)
        v[i] = (text[2 * i] - '0') * 10 + (text[2 * i + 1] - '0');
    int year, at;
    if (tag == 0x17) {
        year = v[0] < 50 ? 2000 + v[0] : 1900 + v[0];
        at = 1;
    } else {
        year = v[0] * 100 + v[1];
        at = 2;
    }
    struct tm tm;
    memset(&tm, 0, sizeof(tm));
    tm.tm_year = year - 1900;
    tm.tm_mon = v[at] - 1;
    tm.tm_mday = v[at + 1];
    tm.tm_hour = v[at + 2];
    tm.tm_min = v[at + 3];
    tm.tm_sec = v[at + 4];
    time_t t = timegm(&tm);
    return t > 0 ? t : 0;
}

/* The notAfter of a DER X.509 certificate, or 0 when it cannot be read. */
static time_t baa_certificate_not_after(const uint8_t *der, int length) {
    if (!der || length <= 0) return 0;
    const uint8_t *p = der, *end = der + length, *body = NULL;
    size_t n = 0;
    uint8_t tag = 0;
    /* Certificate, then tbsCertificate */
    if (!der_next(&p, end, &tag, &body, &n) || tag != 0x30) return 0;
    p = body; end = body + n;
    if (!der_next(&p, end, &tag, &body, &n) || tag != 0x30) return 0;
    p = body; end = body + n;
    /* [0] version (optional), serialNumber, signature, issuer, validity */
    if (!der_next(&p, end, &tag, &body, &n)) return 0;
    if (tag == 0xA0 && !der_next(&p, end, &tag, &body, &n)) return 0;
    if (tag != 0x02) return 0;
    if (!der_next(&p, end, &tag, &body, &n) || tag != 0x30) return 0;
    if (!der_next(&p, end, &tag, &body, &n) || tag != 0x30) return 0;
    if (!der_next(&p, end, &tag, &body, &n) || tag != 0x30) return 0;
    p = body; end = body + n;
    if (!der_next(&p, end, &tag, &body, &n)) return 0;   /* notBefore */
    if (!der_next(&p, end, &tag, &body, &n)) return 0;   /* notAfter */
    return der_time(tag, body, n);
}

static BOOL baa_certificate_usable(time_t notAfter) {
    return notAfter > time(NULL) + BAA_CERT_EXPIRY_MARGIN_SECONDS;
}

/* Seconds since the broker started (it fetches its certificate only then),
 * or -1 when the process cannot be looked up. */
static long baa_broker_age(pid_t pid) {
    if (pid <= 0) return -1;
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0 || size == 0) return -1;
    return (long)(time(NULL) - info.kp_proc.p_starttime.tv_sec);
}

static pid_t reusable_baa_broker(uint64_t *startMicros, time_t *notAfter) {
    *startMicros = 0;
    *notAfter = 0;
    int fd = baa_broker_connect();
    if (fd < 0) return 0;
    pid_t pid = 0;
    socklen_t length = sizeof(pid);
    if (getsockopt(fd, 0 /* SOL_LOCAL */, LOCAL_PEERPID, &pid, &length) != 0) pid = 0;
    close(fd);
    if (pid <= 0) return 0;
    uint64_t start = baa_broker_start_micros(pid);
    if (start == 0) return 0;
    long age = baa_broker_age(pid);
    if (age < 0) return 0;
    uint8_t *leaf = NULL, *intermediate = NULL;
    int leafLength = 0, intermediateLength = 0;
    int rc = baa_broker_get_certs(&leaf, &leafLength, &intermediate, &intermediateLength);
    time_t expiry = rc == 0 ? baa_certificate_not_after(leaf, leafLength) : 0;
    free(leaf);
    /* Past 12 hours it is still worth keeping while its own certificate
     * holds: replacing it needs internet, and baaBrokerStillReady renews it
     * beside the old one before the next start. */
    if (age > BAA_BROKER_REUSE_SECONDS && !baa_certificate_usable(expiry)) {
        free(intermediate);
        return 0;
    }
    free(intermediate);
    /* A broker that still holds its certificate may have lost its key. */
    static const uint8_t probe[] = "Showcase BAA reuse";
    uint8_t *signature = NULL;
    int signatureLength = 0;
    if (rc == 0) rc = baa_broker_sign(probe, (uint32_t)(sizeof(probe) - 1), &signature, &signatureLength);
    free(signature);
    if (rc != 0 || signatureLength <= 0) return 0;
    /* The process that answered must still be the one identified above. */
    if (baa_broker_start_micros(pid) != start) return 0;
    *startMicros = start;
    *notAfter = expiry;
    return pid;
}

/* Waits until the broker `pid` (a child) answers on the shared socket path
 * with a certificate and a signature; the old broker answers there until the
 * new one binds it, so the peer pid tells the two apart. */
static pid_t baa_broker_peer_pid(void) {
    int fd = baa_broker_connect();
    if (fd < 0) return 0;
    pid_t peer = 0;
    socklen_t length = sizeof(peer);
    if (getsockopt(fd, 0 /* SOL_LOCAL */, LOCAL_PEERPID, &peer, &length) != 0)
        peer = 0;
    close(fd);
    return peer;
}

static BOOL baa_renewed_broker_ready(pid_t pid, time_t *notAfter) {
    *notAfter = 0;
    uint64_t deadline = monotonic_nanos_now() + 45 * NSEC_PER_SEC;
    while (monotonic_nanos_now() + 3 * NSEC_PER_SEC <= deadline) {
        if (!child_alive(pid)) return NO;
        if (baa_broker_peer_pid() != pid) {
            usleep(500000);
            continue;
        }
        uint8_t *leaf = NULL, *intermediate = NULL, *signature = NULL;
        int leafLength = 0, intermediateLength = 0, signatureLength = 0;
        static const uint8_t probe[] = "Showcase BAA renewal";
        int rc = baa_broker_get_certs(&leaf, &leafLength,
                                      &intermediate, &intermediateLength);
        if (rc == 0) rc = baa_broker_sign(probe, (uint32_t)(sizeof(probe) - 1),
                                          &signature, &signatureLength);
        if (rc == 0 && signatureLength > 0)
            *notAfter = baa_certificate_not_after(leaf, leafLength);
        free(leaf);
        free(intermediate);
        free(signature);
        return rc == 0 && signatureLength > 0;
    }
    return NO;
}

- (BOOL)startBAABroker {
    uint64_t existingStart = 0;
    time_t existingNotAfter = 0;
    pid_t existing = reusable_baa_broker(&existingStart, &existingNotAfter);
    if (existing > 0) {
        reap_stale_helpers(existing);
        self.baaBrokerPid = existing;
        self.baaBrokerStartMicros = existingStart;
        self.baaBrokerReused = YES;
        self.baaCertNotAfter = existingNotAfter;
        self.baaBrokerOnRenewLog = access(BAA_BROKER_ON_RENEW_LOG_MARK, F_OK) == 0;
        ip_log("BAA broker pid=%d from an earlier launch reused (log=%s)", existing,
               self.baaBrokerOnRenewLog ? BAA_BROKER_RENEW_LOG : BAA_BROKER_LOG);
        return YES;
    }
    self.baaBrokerReused = NO;
    self.baaBrokerStartMicros = 0;
    self.baaCertNotAfter = 0;
    self.baaBrokerOnRenewLog = NO;
    baa_mark_broker_log(NO);
    reap_stale_helpers(0);
    NSString *helper = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@SVC_HELPER_NAME];
    char *argv[] = {
        (char *)SVC_HELPER_NAME,
        (char *)"--baa-broker",
        NULL
    };
    self.baaBrokerPid = spawn_daemon([helper UTF8String], argv, BAA_BROKER_LOG);
    if (self.baaBrokerPid <= 0) return NO;
    ip_log("BAA preheat helper pid=%d", self.baaBrokerPid);
    return YES;
}

- (void)preheatBAA {
    if (self.baaLoading || self.baaReady || self.baaBrokerPid <= 0) return;
    self.baaLoading = YES;
    self.baaError = nil;
    self.baaSpawnFailed = NO;
    [self renderState];
    ip_log("BAA preheat started before hotspot");

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int rc = -1;
        uint8_t *leaf = NULL, *intermediate = NULL;
        int leafLength = 0, intermediateLength = 0;
        uint64_t deadline = monotonic_nanos_now() + 45 * NSEC_PER_SEC;
        /* Each certificate request in baa_broker.h can use three seconds. */
        while (monotonic_nanos_now() + 3 * NSEC_PER_SEC <= deadline) {
            if (!baa_broker_alive(self.baaBrokerPid, self.baaBrokerReused,
                              self.baaBrokerStartMicros)) {
                rc = -1;
                break;
            }
            rc = baa_broker_get_certs(&leaf, &leafLength,
                                      &intermediate, &intermediateLength);
            if (rc == 0) break;
            usleep(100000);
        }
        uint8_t *signature = NULL;
        int signatureLength = 0;
        static const uint8_t probe[] = "Showcase BAA preheat";
        if (rc == 0) {
            rc = baa_broker_sign(probe, (uint32_t)(sizeof(probe) - 1),
                                 &signature, &signatureLength);
        }
        BOOL success = rc == 0 && signatureLength > 0;
        time_t notAfter = success ? baa_certificate_not_after(leaf, leafLength) : 0;
        free(leaf);
        free(intermediate);
        free(signature);
        if (success) {
            ip_log("BAA preheat helper ready: leaf=%d intermediate=%d signature=%d",
                   leafLength, intermediateLength, signatureLength);
        } else {
            ip_log("BAA preheat helper failed rc=%d", rc);
            /* The next attempt starts a fresh broker. kill_child cannot end a
             * broker reused from an earlier launch (not our child). */
            if (self.baaBrokerReused)
                stop_baa_broker(self.baaBrokerPid, YES, self.baaBrokerStartMicros);
            else
                kill_child(self.baaBrokerPid);
            self.baaBrokerPid = 0;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.baaLoading = NO;
            self.baaReady = success;
            self.baaCertNotAfter = notAfter;
            self.baaError = success ? nil :
                @"Unable to prepare CarPlay authentication. Check the internet connection.";
            [self renderState];
            [self startAutomaticallyIfRequested];
            [self resumePendingRestart];
            [self resumePendingUserStart];
        });
    });
}

static void send_car_video_reply(uint32_t streamID, NSDictionary *message) {
    if (!streamID) return;
    NSData *body = car_video_encode(@{@"streamID": @(streamID), @"message": message});
    if (body.length && body.length <= CAR_VIDEO_MAX_MESSAGE)
        send_ipc_payload(MSG_CAR_VIDEO_REPLY, body.bytes, (uint32_t)body.length);
}

static NSDictionary *car_video_time(CMTime time) {
    if (!CMTIME_IS_NUMERIC(time)) return nil;
    return @{@"value": @(time.value), @"timescale": @(time.timescale),
             @"flags": @(time.flags), @"epoch": @(time.epoch)};
}

static NSArray *car_video_ranges(NSArray<NSValue *> *ranges) {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:ranges.count];
    for (NSValue *value in ranges) {
        CMTimeRange range = value.CMTimeRangeValue;
        NSDictionary *start = car_video_time(range.start);
        NSDictionary *duration = car_video_time(range.duration);
        if (start && duration) [result addObject:@{@"start": start, @"duration": duration}];
    }
    return result;
}

static double car_video_seconds(id value) {
    if (![value isKindOfClass:[NSDictionary class]]) return NAN;
    NSNumber *ticks = value[@"value"];
    NSNumber *scale = value[@"timescale"];
    if (![ticks isKindOfClass:[NSNumber class]] ||
        ![scale isKindOfClass:[NSNumber class]] || scale.doubleValue <= 0) return NAN;
    return ticks.doubleValue / scale.doubleValue;
}

static void car_video_seek(AVPlayer *player, double seconds) {
    if (!isfinite(seconds) || seconds < 0) return;
    CMTime time = CMTimeMakeWithSeconds(seconds, 1000);
    if (CMTIME_IS_NUMERIC(time)) [player seekToTime:time];
}

static char carVideoItemStatusContext;

- (void)clearCarVideo {
    AVPlayerItem *item = self.carVideoPlayer.currentItem;
    if (item) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:nil object:item];
        [item removeObserver:self forKeyPath:@"status" context:&carVideoItemStatusContext];
    }
    [self.carVideoPlayer pause];
    [self.carVideoPlayer replaceCurrentItemWithPlayerItem:nil];
    [self.carVideoOverlay removeFromSuperview];
    self.carVideoOverlay = nil;
    self.carVideoPlayer = nil;
    self.carVideoItemID = nil;
    self.carVideoStreamID = 0;
    self.carVideoPendingShow = NO;
    self.carVideoPendingPlay = NO;
}

- (void)dismissCarVideo {
    if (self.carVideoStreamID) {
        send_car_video_reply(self.carVideoStreamID,
            @{@"type": @"playbackState", @"name": @"paused"});
    }
    [self clearCarVideo];
}

- (void)failCarVideoOnStream:(uint32_t)streamID item:(NSString *)itemID {
    NSMutableDictionary *message = [@{@"type": @"error",
        @"error": @{@"domain": @"", @"code": @(-12927)}} mutableCopy];
    if (itemID) message[@"uuid"] = itemID;
    send_car_video_reply(streamID, message);
    /* A rejected request from another channel must not stop (and silently
     * orphan) the video that channel does not own. */
    if (streamID == self.carVideoStreamID) [self clearCarVideo];
}

- (void)carVideoDidEnd:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (notification.object != self.carVideoPlayer.currentItem) return;
        if ([notification.name isEqualToString:AVPlayerItemFailedToPlayToEndTimeNotification])
            [self failCarVideoOnStream:self.carVideoStreamID item:self.carVideoItemID];
        else
            [self dismissCarVideo];
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (context != &carVideoItemStatusContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        AVPlayerItem *item = self.carVideoPlayer.currentItem;
        if (item == object && item.status == AVPlayerItemStatusFailed)
            [self failCarVideoOnStream:self.carVideoStreamID item:self.carVideoItemID];
    });
}

- (void)showCarVideo {
    UIView *content = [self rootContentView];
    if (!self.carVideoPlayer || self.carVideoOverlay || !content) return;
    UIView *overlay = [[CarVideoView alloc] initWithFrame:content.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = UIColor.blackColor;
    AVPlayerLayer *layer = (AVPlayerLayer *)overlay.layer;
    layer.player = self.carVideoPlayer;
    layer.videoGravity = AVLayerVideoGravityResizeAspect;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(overlay.bounds.size.width - 64, 12, 48, 48);
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    close.tintColor = UIColor.whiteColor;
    close.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    close.layer.cornerRadius = 24;
    close.titleLabel.font = [UIFont systemFontOfSize:28];
    [close setTitle:@"×" forState:UIControlStateNormal];
    close.accessibilityLabel = L(@"Close");
    [close addTarget:self action:@selector(dismissCarVideo) forControlEvents:UIControlEventTouchUpInside];
    [overlay addSubview:close];
    /* Below the three-finger chrome (controlsOverlay, then the close and
     * settings buttons above it), so the menu stays reachable over the video. */
    if (self.controlsOverlay.superview == content)
        [content insertSubview:overlay belowSubview:self.controlsOverlay];
    else
        [content addSubview:overlay];
    self.carVideoOverlay = overlay;
}

- (void)handleCarVideoPacket:(NSDictionary *)packet {
    NSNumber *number = packet[@"streamID"];
    if (![number isKindOfClass:[NSNumber class]]) return;
    uint32_t streamID = number.unsignedIntValue;
    NSDictionary *message = packet[@"message"];
    if (!message) {
        if (streamID == 0 || streamID == self.carVideoStreamID) [self clearCarVideo];
        return;
    }
    if (![message isKindOfClass:[NSDictionary class]] || streamID < 3) return;
    if (self.state != StateActive) return;
    /* Only showing and playing wait for the app to be frontmost: while it is
     * Inactive (Control Center, Notification Center, a system alert) the item
     * still loads, and requestUI / setRate>0 are kept and replayed by
     * handleDidBecomeActive. Stop, remove, pause and request/response act
     * at once: handleBackground does not run while Inactive, and a dropped
     * stop would leave the overlay playing while the iPhone thinks it
     * stopped. Going to the background drops the video and anything kept. */
    BOOL appActive = [UIApplication sharedApplication].applicationState ==
        UIApplicationStateActive;
    NSString *type = message[@"type"];
    if (![type isKindOfClass:[NSString class]]) return;
    if ([type isEqualToString:@"insertPlayQueueItem"]) {
        NSDictionary *item = message[@"item"];
        if (![item isKindOfClass:[NSDictionary class]]) return;
        NSString *location = item[@"Content-Location"];
        NSString *itemID = [item[@"uuid"] isKindOfClass:[NSString class]] ? item[@"uuid"] : nil;
        NSURL *url = [location isKindOfClass:[NSString class]] ? [NSURL URLWithString:location] : nil;
        NSString *scheme = url.scheme.lowercaseString;
        if ((![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) ||
            !url.host.length || url.user || url.password) {
            [self failCarVideoOnStream:streamID item:itemID];
            return;
        }
        /* A new item from another channel replaces the playing one; tell the
         * old channel its video stopped, as dismissCarVideo does. */
        if (self.carVideoStreamID != 0 && streamID != self.carVideoStreamID)
            [self dismissCarVideo];
        else
            [self clearCarVideo];
        self.carVideoPlayer = [AVPlayer playerWithURL:url];
        self.carVideoStreamID = streamID;
        self.carVideoItemID = itemID;
        AVPlayerItem *playerItem = self.carVideoPlayer.currentItem;
        [playerItem addObserver:self forKeyPath:@"status"
                       options:NSKeyValueObservingOptionInitial context:&carVideoItemStatusContext];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(carVideoDidEnd:)
                       name:AVPlayerItemDidPlayToEndTimeNotification object:playerItem];
        [center addObserver:self selector:@selector(carVideoDidEnd:)
                       name:AVPlayerItemFailedToPlayToEndTimeNotification object:playerItem];
        NSNumber *start = item[@"Start-Position-Seconds"];
        double seconds = [start isKindOfClass:[NSNumber class]] ?
            start.doubleValue : car_video_seconds(item[@"Start-Position"]);
        if (seconds > 0) car_video_seek(self.carVideoPlayer, seconds);
        return;
    }
    if ([type isEqualToString:@"requestUI"]) {
        if (appActive) [self showCarVideo];
        else if (self.carVideoPlayer) self.carVideoPendingShow = YES;
        return;
    }
    /* Each channel slot (clientTypeUUID) has its own stream ID and both can
     * be live at once: playback commands from the other channel must not act
     * on the video this one is showing. */
    BOOL otherStream = self.carVideoStreamID != 0 && streamID != self.carVideoStreamID;
    if ([type isEqualToString:@"setRate"]) {
        if (otherStream) return;
        NSNumber *rate = message[@"rate"];
        if (![rate isKindOfClass:[NSNumber class]] || !self.carVideoPlayer) return;
        if (rate.doubleValue > 0) {
            if (!appActive) {
                self.carVideoPendingPlay = YES;
                return;
            }
            [self showCarVideo];
            [self.carVideoPlayer play];
        } else {
            self.carVideoPendingPlay = NO;
            [self.carVideoPlayer pause];
        }
        return;
    }
    if ([type isEqualToString:@"stop"] || [type isEqualToString:@"removePlayQueueItem"]) {
        if (otherStream) return;
        if ([type isEqualToString:@"removePlayQueueItem"] && self.carVideoItemID) {
            NSDictionary *item = message[@"item"];
            id itemID = [item isKindOfClass:[NSDictionary class]] ? item[@"uuid"] : message[@"uuid"];
            /* An item that is not the one playing leaves the video alone. */
            if ([itemID isKindOfClass:[NSString class]] &&
                ![itemID isEqualToString:self.carVideoItemID]) return;
        }
        [self clearCarVideo];
        return;
    }
    BOOL seek = [type isEqualToString:@"seek"];
    if (seek && otherStream) {
        /* The seek cannot apply to a video this channel does not own; a plain
         * response would tell it the seek succeeded. failCarVideoOnStream
         * leaves the owner's video alone for a foreign stream. */
        if ([message[@"kind"] isEqual:@"request"])
            [self failCarVideoOnStream:streamID item:nil];
        return;
    }
    if (seek) car_video_seek(self.carVideoPlayer, car_video_seconds(message[@"time"]));
    if (![message[@"kind"] isEqual:@"request"]) return;
    NSMutableDictionary *reply = [@{@"kind": @"response", @"type": type} mutableCopy];
    reply[@"messageID"] = message[@"messageID"];
    /* Status queries from the other channel describe its own (empty) queue,
     * never the video this one is playing. */
    AVPlayer *player = otherStream ? nil : self.carVideoPlayer;
    NSString *itemID = otherStream ? nil : self.carVideoItemID;
    AVPlayerItem *item = player.currentItem;
    if ([type isEqualToString:@"playbackInfo"]) {
        BOOL ready = item.status == AVPlayerItemStatusReadyToPlay;
        BOOL playing = player.timeControlStatus == AVPlayerTimeControlStatusPlaying;
        NSMutableDictionary *info = [@{
            @"item": itemID ? @{@"uuid": itemID} : @{},
            @"rate": @(player.rate), @"readyToPlay": @(ready),
            @"playbackLikelyToKeepUp": @(item.playbackLikelyToKeepUp),
            @"playbackState": !ready ? @"loading" : (playing ? @"playing" : @"paused"),
            @"interstitialInfo": @{}, @"droppedVideoFrames": @0,
            @"totalVideoFrames": @0, @"decodedFrameCount": @0
        } mutableCopy];
        if (ready) {
            info[@"position"] = car_video_time(item.currentTime);
            info[@"duration"] = car_video_time(item.duration);
            info[@"seekableTimeRanges"] = car_video_ranges(item.seekableTimeRanges);
            info[@"loadedTimeRanges"] = car_video_ranges(item.loadedTimeRanges);
        }
        reply[@"info"] = info;
    } else if ([type isEqualToString:@"property"]) {
        id property = message[@"property"];
        reply[@"key"] = property;
        if ([property isEqual:@"hasEnabledAudio"]) reply[@"value"] = @YES;
        if ([property isEqual:@"muted"]) reply[@"value"] = @(player.muted);
        if ([property isEqual:@"loadedTimeRanges"]) reply[@"value"] = car_video_ranges(item.loadedTimeRanges);
        if ([property isEqual:@"seekableTimeRanges"]) reply[@"value"] = car_video_ranges(item.seekableTimeRanges);
    } else if (!seek) {
        return;
    }
    send_car_video_reply(streamID, reply);
}

- (void)handleBackground {
#if SHOWCASE_MIRROR_BENCH
    [self.screenMirror finish];
#endif
    [self dismissCarVideo];
    [self holdBackgroundForBluetooth];
    if (self.state != StateIdle && self.state != StateStopping) {
        ip_log("backgrounded — preserving CarPlay session");
        g_video_suspended = 1;
        g_video_needs_resync = 1;
        send_app_visibility(0);
        dispatch_async(self.videoQueue, ^{
            AVSampleBufferDisplayLayer *layer =
                (AVSampleBufferDisplayLayer *)self.videoView.layer;
            [layer flushAndRemoveImage];
        });
    }
}

/* CarPlay video is wanted only while the app is on screen and, in the Mirror
 * build, not covered by the Mirror receiver. Every path that turns the
 * iPhone's H.264 back on outside onReturnToCarPlay asks here. */
- (BOOL)carPlayCoveredByMirror {
#if SHOWCASE_MIRROR_BENCH
    ShowcaseMirrorReceiver *mirror = self.screenMirror;
    return mirror && mirror.presentingViewController && !mirror.isBeingDismissed;
#else
    return NO;
#endif
}

/* Frames dropped while CarPlay video was off (background, Mirror receiver)
 * break the H.264 chain: decode nothing until the next key frame and drop
 * whatever the layer still holds from before. */
- (void)resyncCarPlayVideo {
    g_video_needs_resync = 1;
    g_video_suspended = 0;
    dispatch_async(self.videoQueue, ^{
        AVSampleBufferDisplayLayer *layer =
            (AVSampleBufferDisplayLayer *)self.videoView.layer;
        [layer flush];
    });
}

- (void)handleForeground {
    [self endBackgroundTask];
    ip_log("foregrounded — continuing state=%ld", (long)self.state);
    if (self.state != StateIdle && self.state != StateStopping) {
        [self resyncCarPlayVideo];
        /* WillEnterForeground runs while the app is still inactive. */
#if SHOWCASE_MIRROR_BENCH
        if (![self carPlayCoveredByMirror])
#endif
        send_app_visibility(1);
        ip_log("foreground video resync requested");
    }
    dispatch_async(self.bgQueue, ^{
        showcase_restore_wifi_power_after_cycle("foreground");
    });
    if (self.state == StateAwaitingAP) [self pollAP];
    [self renderState];
    [self presentPendingBluetoothCompatibilityError];
    [self presentPendingWifiSetupError];
    [self presentPendingServicesSetupError];
}

- (void)handleDidBecomeActive {
    /* Inactive (Control Center, an alert, Siri) is not background, but a
     * visibility 0 that reached the service anyway (an older path, or Mirror
     * closing meanwhile) leaves CarPlay pulled off the car screen and no
     * frames arriving; WillEnterForeground does not run again to undo it. */
    if (self.state != StateIdle && self.state != StateStopping &&
        g_app_visibility_sent == 0 && ![self carPlayCoveredByMirror]) {
        [self resyncCarPlayVideo];
        send_app_visibility(1);
        ip_log("became active — video visibility restored");
    }
    [self replayPendingCarVideo];
    [self presentPendingBluetoothCompatibilityError];
    [self presentPendingWifiSetupError];
    [self presentPendingServicesSetupError];
}

/* Show/play requests kept while the app was Inactive. clearCarVideo drops
 * them with the video, so whatever is left belongs to the loaded one. */
- (void)replayPendingCarVideo {
    BOOL show = self.carVideoPendingShow, play = self.carVideoPendingPlay;
    self.carVideoPendingShow = NO;
    self.carVideoPendingPlay = NO;
    if (!self.carVideoPlayer || self.state != StateActive) return;
    if (show || play) [self showCarVideo];
    if (play) [self.carVideoPlayer play];
}

- (void)presentPendingWifiSetupError {
    NSString *message = self.pendingWifiSetupError;
    if (!message.length || self.vc.presentedViewController) return;
    [self showWifiSetupError:message];
}

/* failServicesSetupWith: ended the flow before CarPlay could start; without
 * this the screen would just fall back to Idle with no reason given. */
- (void)presentPendingServicesSetupError {
    if (!self.pendingServicesSetupError || self.state != StateIdle ||
        self.vc.presentedViewController ||
        [UIApplication sharedApplication].applicationState !=
            UIApplicationStateActive) {
        return;
    }
    self.pendingServicesSetupError = NO;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:L(@"CarPlay Could Not Start")
        message:L(@"Showcase's CarPlay services could not start. Try again; if it keeps happening, reinstall Showcase or send logs to KCS from Settings.")
        preferredStyle:UIAlertControllerStyleAlert];
    /* Like every other modal here, closing it releases work held meanwhile. */
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:L(@"OK") style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *action) {
        [weakSelf settingsDidClose];
    }]];
    [self.vc presentViewController:alert animated:YES completion:nil];
}

- (void)applicationWillTerminate:(UIApplication *)application {
    (void)application;
    [self endAWDLSuppression];
    showcase_release_other_wifi("app terminating");
    [self stopNetworkDumpCaptureWithReason:@"app terminating"];
    /* The BAA broker stays up so the next launch can reuse its certificate. */
}

/* Between bgPrepareBT taking the controller and the Wi-Fi hand-off giving it
 * back, a suspended app would leave system Bluetooth unloaded until it is
 * foregrounded again. Keep running until the hand-off; if the background time
 * runs short first, stop the session so stopFlow returns Bluetooth. */
#define BLUETOOTH_BACKGROUND_STOP_MARGIN 40.0

- (BOOL)holdsSystemBluetooth {
    ShowcaseState s = self.state;
    if (s == StateIdle || s == StateAwaitingAP) return NO;
    if (s == StateStopping) return YES;
    /* The hand-off marks itself done before its hand-back has finished;
     * BT_OWNED_FLAG only exists in the Taurine build. */
    return !self.bluetoothHandedOff || self.bluetoothHandBackInProgress ||
        access(BT_OWNED_FLAG, F_OK) == 0;
}

- (void)holdBackgroundForBluetooth {
    UIApplication *app = [UIApplication sharedApplication];
    if (self.bgTask != UIBackgroundTaskInvalid ||
        app.applicationState != UIApplicationStateBackground ||
        ![self holdsSystemBluetooth]) return;
    __weak typeof(self) weakSelf = self;
    self.bgTask = [app beginBackgroundTaskWithName:@"Showcase Bluetooth hand-off"
                                 expirationHandler:^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        ip_log("[BT] background time expired with Bluetooth taken; stopping");
        if (strongSelf.state != StateIdle && strongSelf.state != StateStopping)
            [strongSelf stopFlow];
        [strongSelf endBackgroundTask];
    }];
    if (self.bgTask == UIBackgroundTaskInvalid) {
        ip_log("[BT] no background time; the recovery guard covers Bluetooth");
        return;
    }
    ip_log("[BT] backgrounded with Bluetooth taken; holding background time");
    self.bgTaskTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
        target:self selector:@selector(checkBackgroundBluetooth)
        userInfo:nil repeats:YES];
}

- (void)checkBackgroundBluetooth {
    if (![self holdsSystemBluetooth]) {
        ip_log("[BT] Bluetooth returned; releasing background time");
        [self endBackgroundTask];
        return;
    }
    /* stopFlow's teardown is under way; keep the time until it is Idle. */
    if (self.state == StateStopping) return;
    if ([UIApplication sharedApplication].backgroundTimeRemaining >
        BLUETOOTH_BACKGROUND_STOP_MARGIN) return;
    ip_log("[BT] Bluetooth hand-off not finished before background time ran out; stopping");
    [self stopFlow];
}

- (void)endBackgroundTask {
    [self.bgTaskTimer invalidate];
    self.bgTaskTimer = nil;
    if (self.bgTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.bgTask];
        self.bgTask = UIBackgroundTaskInvalid;
    }
}

/* ─── UI construction ──────────────────────────────────────── */

- (void)buildSetupOverlay {
    UIView *content = [self rootContentView];
    self.setupOverlay = [[SetupOverlayView alloc] initWithFrame:content.bounds];
    self.setupOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.setupOverlay.backgroundColor = [UIColor blackColor];
    [content addSubview:self.setupOverlay];

    /* The scene paints the whole screen — road, mark, iPhone. Everything else
     * is type and buttons laid on top of it. */
    self.connectionScene = [[ShowcaseConnectionScene alloc] initWithFrame:self.setupOverlay.bounds];
    self.connectionScene.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                            UIViewAutoresizingFlexibleHeight;
    self.connectionScene.zoomHost = self.setupOverlay;
    [self.setupOverlay addSubview:self.connectionScene];

    /* Eyebrow wordmark, shown only on the parked idle screen */
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.text = @APP_NAME;
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.textColor = scene_caption(1);
    [self.setupOverlay addSubview:self.titleLabel];

    /* Headline (state-dependent) */
    self.headlineLabel = [[UILabel alloc] init];
    self.headlineLabel.textAlignment = NSTextAlignmentCenter;
    self.headlineLabel.textColor = [UIColor whiteColor];
    self.headlineLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightRegular];
    self.headlineLabel.adjustsFontSizeToFitWidth = YES;
    self.headlineLabel.minimumScaleFactor = 0.6;
    /* "Choose <car name> in CarPlay…" with a long name, or a long
     * translation, wraps onto a second line instead of being cut off. */
    self.headlineLabel.numberOfLines = 2;
    [self.setupOverlay addSubview:self.headlineLabel];

    /* Spinner, for the states that have no step list */
    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    self.spinner.hidesWhenStopped = YES;
    [self.setupOverlay addSubview:self.spinner];

    self.farewellCaption = [UILabel new];
    self.farewellCaption.text = L(@"CarPlay disconnected");
    self.farewellCaption.textColor = scene_caption(1);
    self.farewellCaption.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    self.farewellCaption.textAlignment = NSTextAlignmentCenter;
    self.farewellCaption.hidden = YES;
    [self.setupOverlay addSubview:self.farewellCaption];

    /* Connection checklist */
    self.stepsView = [[ConnectStepsView alloc] init];
    self.stepsView.userInteractionEnabled = NO;
    self.stepsView.completed = -1;
    [self.setupOverlay addSubview:self.stepsView];

    /* Primary button */
    self.primaryButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.primaryButton.backgroundColor = [UIColor clearColor];
    [self.primaryButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.primaryButton setTitleColor:[UIColor colorWithWhite:1 alpha:0.55] forState:UIControlStateHighlighted];
    self.primaryButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    self.primaryButton.layer.shadowColor = [UIColor colorWithRed:0.184 green:0.486
                                                           blue:0.941 alpha:1].CGColor;
    self.primaryButton.layer.shadowOpacity = 0.38;
    self.primaryButton.layer.shadowRadius = 16;
    self.primaryButton.layer.shadowOffset = CGSizeMake(0, 12);
    self.primaryButton.layer.borderWidth = 1;
    self.primaryButton.layer.borderColor = scene_color(0.588, 0.824, 1.0, 0.25).CGColor;
    self.primaryGradient = [CAGradientLayer layer];
    self.primaryGradient.startPoint = CGPointMake(0.5, 0);
    self.primaryGradient.endPoint = CGPointMake(0.5, 1);
    self.primaryGradient.colors = @[
        (__bridge id)[UIColor colorWithRed:0.310 green:0.690 blue:1.000 alpha:1].CGColor,
        (__bridge id)[UIColor colorWithRed:0.184 green:0.486 blue:0.941 alpha:1].CGColor];
    [self.primaryButton.layer insertSublayer:self.primaryGradient atIndex:0];
    [self.primaryButton addTarget:self action:@selector(primaryTapped)
                 forControlEvents:UIControlEventTouchUpInside];
    [self.setupOverlay addSubview:self.primaryButton];

    /* Secondary button (Cancel) */
    self.secondaryButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.secondaryButton setTitleColor:scene_color(0.839, 0.894, 0.969, 0.72)
                               forState:UIControlStateNormal];
    [self.secondaryButton setTitleColor:[UIColor colorWithWhite:1 alpha:0.95]
                               forState:UIControlStateHighlighted];
    self.secondaryButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.045];
    self.secondaryButton.layer.borderWidth = 1;
    self.secondaryButton.layer.borderColor = scene_caption(0.16).CGColor;
    self.secondaryButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    [self.secondaryButton addTarget:self action:@selector(secondaryTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.setupOverlay addSubview:self.secondaryButton];

    [self layoutSetupOverlay];
}

- (BOOL)isConnectingState {
    return self.state == StatePreparingBT ||
           self.state == StatePreparingNet ||
           self.state == StateAwaitingPhone;
}

- (BOOL)isSceneState {
    BOOL showSteps = [[NSUserDefaults standardUserDefaults] boolForKey:CONNECTION_STEPS_KEY];
    BOOL connecting = [self isConnectingState];
    BOOL animatedConnection = (connecting ||
        (self.state == StateAwaitingAP && !self.hotspotManual)) && !showSteps;
    return self.state == StateIdle || animatedConnection ||
           (self.state == StateStopping && self.showFarewell);
}

/* The headline's height in a column `width` wide: `minimum` for one line,
 * taller when its current text and font wrap onto the second line. */
- (CGFloat)headlineHeightForWidth:(CGFloat)width minimum:(CGFloat)minimum {
    UILabel *label = self.headlineLabel;
    if (label.text.length == 0) return minimum;
    CGFloat fit = ceil([label sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)].height);
    CGFloat cap = ceil(label.font.lineHeight * MAX(label.numberOfLines, 1));
    return MAX(minimum, MIN(fit, cap));
}

/* The scene screen: type hangs off the mark's centre, the mark sits where the
 * design put it and the whole night road scales around it. */
- (void)layoutSceneOverlayWidth:(CGFloat)W height:(CGFloat)H center:(CGFloat)cx
                          phone:(BOOL)phone farewell:(BOOL)farewell {
    CGFloat k = MIN(W / 1024.0, H / 768.0);
    if (phone) k *= 0.8;
    k = MAX(0.55, MIN(k, 1.15));

    BOOL idle = self.state == StateIdle;
    /* Active is the hand-off: the scene stays and the type is on its way out,
     * so it must not be re-laid-out as a live "Cancel" screen underneath.
     * While the zoom runs, Cancel stays in the picture (renderState makes it
     * untappable) so fadeOutConnectionWords can take it out with the headline
     * in 200 ms instead of it vanishing in one frame. */
    BOOL handoff = self.state == StateActive && !self.connectionScene.isHandingOff;
    BOOL bigWord = idle || farewell;
    /* Authentication is still being prepared: the disabled button alone
     * would look frozen for up to 45 s. First run (no Wi-Fi yet) shows an
     * enabled "Set Up Wi-Fi" instead, so no spinner there. */
    BOOL busy = idle && [self.cars apReady] && [self idleStartBusy];
    CGFloat spinH = 36;
    CGFloat headSize = bigWord ? (phone ? 34 : 46) : (phone ? 19 : 24);
    UIFontWeight headWeight = bigWord ? UIFontWeightLight : UIFontWeightRegular;
    CGFloat headH = ceil(headSize * (bigWord ? 1.174 : 1.333));

    CGFloat artH = 160 * k;
    CGFloat gapArt = 8 * k;
    CGFloat btnGap = MAX(20, 34 * k);
    CGFloat btnH = MAX(46, 56 * k);
    CGFloat btnW = MIN(264 * MAX(k, 0.85), W - 80);
    CGFloat secGap = MAX(16, 30 * k);
    CGFloat secH = 38;
    CGFloat colW = bigWord ? MIN(W - 40, 640) : MIN(W - (phone ? 140 : 80), 560);
    self.headlineLabel.font = [UIFont systemFontOfSize:headSize weight:headWeight];
    headH = [self headlineHeightForWidth:colW minimum:headH];

    CGFloat flow = artH + gapArt + headH;
    if (idle) flow += btnGap + btnH + (busy ? btnGap / 2 + spinH : 0);
    else if (!farewell) flow += secGap + secH;
    if (farewell) flow += 8 + 22;

    CGFloat artTop = MIN(H * 0.39, H - 24 - flow);
    artTop = MAX(16, artTop);
    CGFloat logoY = artTop + artH / 2.0;

    if (busy) {
        self.spinner.hidden = NO;
        [self.spinner startAnimating];
    } else {
        self.spinner.hidden = YES;
        [self.spinner stopAnimating];
    }
    self.titleLabel.hidden = !idle;
    self.primaryButton.hidden = !idle;
    self.secondaryButton.hidden = idle || farewell || handoff;
    self.stepsView.hidden = YES;

    CGFloat eyebrowSize = phone ? 10.5 : 12.5;
    UIFont *eyebrow = [UIFont systemFontOfSize:eyebrowSize weight:UIFontWeightSemibold];
    self.titleLabel.attributedText = [[NSAttributedString alloc]
        initWithString:[L(@"Wireless CarPlay") uppercaseString] attributes:@{
            NSFontAttributeName: eyebrow,
            NSForegroundColorAttributeName: scene_caption(1),
            NSKernAttributeName: @(eyebrowSize * 0.42)}];
    self.titleLabel.frame = CGRectMake(0, floor(artTop - 55), W, 18);

    self.headlineLabel.textColor = UIColor.whiteColor;
    CGFloat y = artTop + artH + gapArt;
    self.headlineLabel.frame = CGRectMake(floor(cx - colW / 2), floor(y), colW, headH);
    y += headH;

    if (busy) {
        y += btnGap / 2;
        self.spinner.frame = CGRectMake(floor(cx - spinH / 2), floor(y), spinH, spinH);
        y += spinH;
    }
    if (idle) {
        y += btnGap;
        self.primaryButton.titleLabel.font =
            [UIFont systemFontOfSize:(phone ? 16 : 18) weight:UIFontWeightSemibold];
        self.primaryButton.frame = CGRectMake(floor(cx - btnW / 2), floor(y), btnW, btnH);
        self.primaryButton.layer.cornerRadius = btnH / 2.0;
        self.primaryGradient.frame = self.primaryButton.bounds;
        self.primaryGradient.cornerRadius = btnH / 2.0;
        self.primaryButton.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:
            self.primaryButton.bounds cornerRadius:btnH / 2.0].CGPath;
        y += btnH;
    }

    if (!idle && !farewell) {
        y += secGap;
        [self.secondaryButton sizeToFit];
        CGFloat secW = MIN(W - 120,
            MAX(100, self.secondaryButton.bounds.size.width + 44));
        self.secondaryButton.titleLabel.font =
            [UIFont systemFontOfSize:(phone ? 14 : 15) weight:UIFontWeightRegular];
        self.secondaryButton.frame = CGRectMake(floor(cx - secW / 2), floor(y), secW, secH);
        self.secondaryButton.layer.cornerRadius = secH / 2.0;
        y += secH;
    }

    if (farewell) {
        y += 8;
        self.farewellCaption.hidden = NO;
        self.farewellCaption.frame = CGRectMake(floor(cx - colW / 2), floor(y), colW, 22);
    }

    [self.connectionScene setLayoutScale:k logoCenter:CGPointMake(cx, logoY)];
#ifdef SHOWCASE_UI_PREVIEW
    { static BOOL dumped = NO; if (!dumped) { dumped = YES;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1200 * NSEC_PER_MSEC)),
                     dispatch_get_main_queue(), ^{ [self.connectionScene dumpSceneTree]; }); } }
#endif
}

/* The checklist and hotspot screens keep the original stacked column. */
- (void)layoutLegacyOverlayWidth:(CGFloat)W height:(CGFloat)H center:(CGFloat)cx
                           phone:(BOOL)phone shortScreen:(BOOL)shortScreen {
    BOOL connecting = [self isConnectingState];
    BOOL showSteps = [[NSUserDefaults standardUserDefaults] boolForKey:CONNECTION_STEPS_KEY];

    self.titleLabel.attributedText = nil;
    self.titleLabel.text = @APP_NAME;
    self.titleLabel.textColor = UIColor.whiteColor;
    self.titleLabel.font = [UIFont systemFontOfSize:(phone ? 44 : 64) weight:UIFontWeightUltraLight];
    self.titleLabel.hidden = connecting && shortScreen;
    self.headlineLabel.font = [UIFont systemFontOfSize:(phone ? 20 : 24) weight:UIFontWeightRegular];
    self.primaryButton.titleLabel.font = [UIFont systemFontOfSize:(phone ? 16 : 18) weight:UIFontWeightSemibold];
    self.secondaryButton.titleLabel.font = [UIFont systemFontOfSize:(phone ? 14 : 15) weight:UIFontWeightRegular];
    self.stepsView.hidden = !connecting || !showSteps;

    CGFloat side = phone ? 70 : 40;
    CGFloat colW = MIN(W - side * 2, 560);
    CGFloat btnW = MIN(240, W - 80);
    CGFloat btnH = phone ? 46 : 52;

    NSMutableArray<NSArray *> *items = [NSMutableArray array];
    void (^add)(UIView *, CGFloat, CGFloat, CGFloat) =
        ^(UIView *view, CGFloat width, CGFloat height, CGFloat gapAfter) {
            if (view.hidden || height <= 0) return;
            [items addObject:@[view, @(width), @(height), @(gapAfter)]];
        };
    add(self.titleLabel, W, phone ? 54 : 78, shortScreen ? 18 : (phone ? 26 : 48));
    add(self.spinner, 36, 36, 20);
    add(self.headlineLabel, colW,
        [self headlineHeightForWidth:colW minimum:(phone ? 28 : 32)],
        connecting ? (shortScreen ? 18 : 28) : (phone ? 26 : 36));
    add(self.stepsView, colW, [self.stepsView preferredHeightForWidth:colW], shortScreen ? 14 : 28);
    add(self.primaryButton, btnW, btnH, phone ? 12 : 16);
    add(self.secondaryButton, btnW, 44, 10);

    CGFloat total = 0;
    for (NSUInteger i = 0; i < items.count; i++) {
        total += [items[i][2] doubleValue];
        if (i + 1 < items.count) total += [items[i][3] doubleValue];
    }
    CGFloat y = MAX(phone ? 14 : 40, floor((H - total) * (phone ? 0.5 : 0.46)));
    for (NSArray *item in items) {
        UIView *view = item[0];
        CGFloat width = [item[1] doubleValue], height = [item[2] doubleValue];
        view.frame = CGRectMake(floor(cx - width / 2.0), floor(y), width, height);
        y += height + [item[3] doubleValue];
    }
    self.primaryButton.layer.cornerRadius = btnH / 2.0;
    self.primaryGradient.frame = self.primaryButton.bounds;
    self.primaryGradient.cornerRadius = btnH / 2.0;
    self.primaryButton.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:
        self.primaryButton.bounds cornerRadius:btnH / 2.0].CGPath;
    [self.stepsView setNeedsLayout];
}

- (void)layoutSetupOverlay {
    CGSize s = [self rootContentView].bounds.size;
    CGFloat W = s.width, H = s.height, cx = W / 2.0;
    BOOL phone = [self isPhone];
    BOOL shortScreen = H < 560;
    BOOL farewell = self.state == StateStopping && self.showFarewell;
    /* The hand-off is still the scene. The state turns Active the moment the
     * first CarPlay frame arrives, so deciding the layout from the state alone
     * swapped the overlay to the checklist the instant the zoom began — the
     * night road disappeared and the old black screen zoomed away instead. */
    BOOL scene = [self isSceneState] ||
        (self.state == StateActive && self.connectionScene.isHandingOff);
    self.sceneShowing = scene;

    self.setupOverlay.backgroundColor = scene
        ? [UIColor colorWithRed:0.035 green:0.065 blue:0.12 alpha:1] : UIColor.blackColor;
    self.connectionScene.hidden = !scene;
    self.stepsView.compact = shortScreen;
    self.farewellCaption.hidden = !farewell || !scene;

    if (scene) {
        [self layoutSceneOverlayWidth:W height:H center:cx phone:phone farewell:farewell];
    } else {
        [self layoutLegacyOverlayWidth:W height:H center:cx phone:phone shortScreen:shortScreen];
    }
}

/* Drives the scene from the real state machine, so the nine link segments are
 * the nine things that actually finished. */
- (void)syncConnectionScene {
    if (!self.sceneShowing) return;
    if (self.state == StateStopping && self.showFarewell) {
        [self.connectionScene playFarewellWithCompletion:nil];
        return;
    }
    ShowcaseScenePhase phase = ShowcaseScenePhasePreparing;
    if (self.state == StateIdle) {
        /* The opening screen is the parked car: engine off, no iPhone in the
         * air yet. The scene only wakes when the connection actually starts. */
        phase = ShowcaseScenePhaseParked;
    } else if (self.state == StateAwaitingPhone) {
        phase = self.connectCompleted >= ConnectStepPhoneBluetooth
            ? ShowcaseScenePhaseConnecting : ShowcaseScenePhaseChoose;
    }
    NSInteger done = self.state == StateIdle ? 0 : MAX(0, self.connectCompleted + 1);
    [self.connectionScene applyPhase:phase progress:done];
}

- (void)buildChrome {
    UIView *content = [self rootContentView];
    CGFloat sz = 44;
    CGFloat margin = 18;
    CGSize bs = content.bounds.size;

    self.controlsOverlay = [[ControlsOverlayView alloc]
        initWithFrame:content.bounds];
    self.controlsOverlay.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.controlsOverlay.backgroundColor =
        [UIColor colorWithWhite:0 alpha:0.52];
    self.controlsOverlay.hidden = YES;
    [content addSubview:self.controlsOverlay];

#if SHOWCASE_MIRROR_BENCH
    UIButton *mirror = [UIButton buttonWithType:UIButtonTypeSystem];
    [mirror setTitle:L(@"Mirror iPhone Screen") forState:UIControlStateNormal];
    mirror.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    mirror.tintColor = UIColor.whiteColor;
    mirror.backgroundColor = [UIColor colorWithWhite:0 alpha:0.76];
    mirror.layer.cornerRadius = 12;
    mirror.translatesAutoresizingMaskIntoConstraints = NO;
    [mirror addTarget:self action:@selector(openScreenMirror) forControlEvents:UIControlEventTouchUpInside];
    [self.controlsOverlay addSubview:mirror];
    [NSLayoutConstraint activateConstraints:@[
        [mirror.centerXAnchor constraintEqualToAnchor:self.controlsOverlay.centerXAnchor],
        [mirror.centerYAnchor constraintEqualToAnchor:self.controlsOverlay.centerYAnchor],
        [mirror.widthAnchor constraintEqualToConstant:240],
        [mirror.heightAnchor constraintEqualToConstant:54]
    ]];
#endif

    /* Any tap on the dimmed screen returns to CarPlay. */
    UITapGestureRecognizer *dismissChrome = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(hideChrome)];
#if SHOWCASE_MIRROR_BENCH
    dismissChrome.delegate = self.controlsOverlay;
#endif
    [self.controlsOverlay addGestureRecognizer:dismissChrome];

    /* Close button, top right, only while CarPlay runs */
    self.closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.closeButton.frame = CGRectMake(bs.width - sz - margin, margin, sz, sz);
    self.closeButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    self.closeButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    self.closeButton.layer.cornerRadius = sz / 2.0;
    [self.closeButton setTitle:@"×" forState:UIControlStateNormal];
    [self.closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.closeButton.titleLabel.font = [UIFont systemFontOfSize:30 weight:UIFontWeightLight];
    self.closeButton.titleEdgeInsets = UIEdgeInsetsMake(-3, 0, 0, 0);
    self.closeButton.accessibilityLabel = L(@"Close");
    self.closeButton.hidden = YES;
    [self.closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:self.closeButton];

    /* Settings button, top left */
    self.settingsButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.settingsButton.frame = CGRectMake(margin, margin, sz, sz);
    self.settingsButton.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
    self.settingsButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    self.settingsButton.layer.cornerRadius = sz / 2.0;
    self.settingsButton.tintColor = [UIColor whiteColor];
    [self.settingsButton setImage:showcase_gear_image(22) forState:UIControlStateNormal];
    self.settingsButton.adjustsImageWhenHighlighted = YES;
    self.settingsButton.accessibilityLabel = L(@"Settings");
    [self.settingsButton addTarget:self action:@selector(settingsTapped) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:self.settingsButton];

    /* GitHub star button, top right; part of the setup screen, so it hides with it. */
    self.starButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.starButton.frame = CGRectMake(bs.width - sz - margin, margin, sz, sz);
    self.starButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    self.starButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    self.starButton.layer.cornerRadius = sz / 2.0;
    self.starButton.tintColor = [UIColor whiteColor];
    [self.starButton setImage:showcase_star_image(20) forState:UIControlStateNormal];
    self.starButton.accessibilityLabel = L(@"Give us a star on GitHub!");
    [self.starButton addTarget:self action:@selector(starTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.setupOverlay addSubview:self.starButton];

    self.controlsGesture = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(toggleChrome:)];
    self.controlsGesture.numberOfTouchesRequired = 3;
    self.controlsGesture.numberOfTapsRequired = 1;
    self.controlsGesture.cancelsTouchesInView = YES;
    self.controlsGesture.delaysTouchesBegan = NO;
    /* UIGestureRecognizer delays touch-up delivery by default while it
     * decides whether a gesture matches. That made every ordinary CarPlay
     * tap wait on the three-finger menu recognizer. */
    self.controlsGesture.delaysTouchesEnded = NO;
    self.controlsGesture.enabled = NO;
    [content addGestureRecognizer:self.controlsGesture];
}

- (BOOL)isPhone {
    return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone;
}

/* ─── State machine ────────────────────────────────────────── */

- (void)transitionTo:(ShowcaseState)s {
    @synchronized (self) {
    if (flow_cancelled() && s != StateIdle && s != StateStopping) return;
    uint32_t epoch = flow_epoch();
    ShowcaseState old = self.state;
    if (s == StateAwaitingPhone && old != StatePreparingNet) return;
    self.state = s;
    if (s == StatePreparingBT && old != s) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self holdBackgroundForBluetooth]; });
    }
    /* Auto-Lock would dim and lock the iPad mid-drive: the app goes to the
     * background, video is suspended and the Bluetooth guard ends the
     * session. Keep the screen on from the first connecting step until the
     * flow is back at Idle (Stopping keeps whatever was set). Queued inside
     * the lock, so the main queue applies transitions in order. */
    if (s != StateStopping) {
        BOOL keepAwake = s != StateIdle;
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIApplication sharedApplication].idleTimerDisabled = keepAwake;
        });
    }

    if (s == StateAwaitingPhone && old != StateAwaitingPhone) {
        ip_log("[HANDOFF] Awaiting sender; CarPlay should perform Wi-Fi association through iAP2 handoff");
        if (self.diagnosticsEnabled)
            ip_log("diagnostics active; tcpdump remains off unless requested manually");
    } else if ((s == StateStopping || s == StateIdle) && old != s) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self stopNetworkDumpCaptureWithReason:@"flow stopped"];
        });
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (epoch != flow_epoch()) return;
        if (s == StatePreparingNet)
            [self completeConnectStep:ConnectStepBluetooth];
        else if (s == StateAwaitingPhone)
            [self completeConnectStep:ConnectStepServices];
        [self renderState];
        [self refreshPresentedSettings];
    });
    }
}

/* ─── Connection progress ──────────────────────────────────── */

- (void)resetConnectProgress {
    self.connectCompleted = -1;
    self.firstTimePairing = NO;
}

- (void)completeConnectStep:(ConnectStep)step {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self completeConnectStep:step];
        });
        return;
    }
    if (step <= self.connectCompleted) return;
    self.connectCompleted = step;
    ip_log("[PROGRESS] step %ld complete", (long)step);
    if ([self isConnectingState]) [self renderState];
}

- (void)startObservingBluetoothProgress {
    int token = 0;
    uint32_t rc = notify_register_dispatch(
        SHOWCASE_BT_PROGRESS_NOTIFICATION, &token,
        dispatch_get_main_queue(), ^(int t) {
            uint64_t bits = 0;
            notify_get_state(t, &bits);
            [self applyBluetoothProgress:bits];
        });
    self.btProgressToken = rc == NOTIFY_STATUS_OK ? token : -1;
}

- (void)applyBluetoothProgress:(uint64_t)bits {
    if (![self isConnectingState] || bits == 0) return;
    ip_log("[PROGRESS] Bluetooth milestones=0x%llx", (unsigned long long)bits);
    if (bits & BT_PROGRESS_CONNECTED)
        [self completeConnectStep:ConnectStepPhoneBluetooth];
    if ((bits & BT_PROGRESS_AUTHORIZED) && (bits & BT_PROGRESS_IDENTIFIED))
        [self completeConnectStep:ConnectStepVerify];
    if (bits & BT_PROGRESS_WIFI_SENT)
        [self completeConnectStep:ConnectStepHotspotDetails];
}

- (void)updateConnectSteps {
    self.stepsView.pendingTitles = @[
        @"Bluetooth", L(@"CarPlay services"), @"iPhone", L(@"Verification"),
        self.sharedWifiSession ? L(@"Wi-Fi details") : L(@"Hotspot details"),
        @"Wi-Fi", L(@"Pairing"), @"CarPlay", L(@"Video")
    ];
    self.stepsView.doneTitles = self.stepsView.pendingTitles;
    self.stepsView.completed = self.connectCompleted;
    [self.stepsView setNeedsLayout];
}

- (void)renderState {
    /* The farewell arrives over the running CarPlay picture, so it needs to
     * know whether the overlay was off screen a moment ago. */
    BOOL wasHidden = self.setupOverlay.hidden;
    /* A session that ends mid hand-off must not leave the zoom running: its
     * completion would hide the overlay over the Stopping/Idle screen. */
    BOOL interruptedHandoff = NO;
    if (self.state != StateActive && self.connectionScene.isHandingOff) {
        interruptedHandoff = YES;
        [self.connectionScene cancelHandoff];
    }
    BOOL enteringActive = self.state == StateActive && !self.activeRendered;
    self.activeRendered = (self.state == StateActive);
    [self refreshLocalizedChrome];
    self.setupOverlay.hidden = NO;
    self.closeButton.hidden = YES;
    self.controlsGesture.enabled = (self.state == StateActive);
    if (self.state != StateActive) {
        /* Restore the 1024x768 canvas in every non-Active state. */
        if ([self isPhone] && self.vc.fullscreenMode) {
            self.vc.fullscreenMode = NO;
            [self.vc.view setNeedsLayout];
        }
        self.videoView.transform = CGAffineTransformIdentity;
        self.chromeVisible = NO;
        self.controlsOverlay.hidden = YES;
        self.controlsOverlay.alpha = 1;
        self.settingsButton.hidden = NO;
        self.settingsButton.alpha = 1.0;
        self.starButton.hidden = NO;
        self.closeButton.alpha = 1.0;
        [self restoreConnectionWords];
    }
    self.spinner.hidden = YES; [self.spinner stopAnimating];
    self.primaryButton.hidden = YES;
    self.primaryButton.enabled = YES;
    self.primaryButton.alpha = 1.0;
    self.secondaryButton.hidden = YES;
    /* Only the hand-off keeps Cancel on screen while Active, fading out; the
     * session is already live, so it must not be tappable then. */
    self.secondaryButton.userInteractionEnabled = (self.state != StateActive);

    NSString *shownCarName = self.state == StateIdle
        ? self.cars.selected.name : self.sessionCarName;
    NSString *carName = shownCarName.length ? shownCarName : L(@"your car");

    switch (self.state) {
        case StateIdle: {
            BOOL apReady = [self.cars apReady];
            self.primaryButton.hidden = NO;

            if (!apReady) {
                /* First run: Wi-Fi setup is the headline action. */
                self.headlineLabel.text = L(@"Welcome");
                [self.primaryButton setTitle:L(@"Set Up Wi-Fi") forState:UIControlStateNormal];
            } else {
                if ([self idleStartBusy]) {
                    self.headlineLabel.text = L(@"Preparing");
                    [self.primaryButton setTitle:L(@"Preparing…") forState:UIControlStateNormal];
                    self.primaryButton.enabled = NO;
                    self.primaryButton.alpha = 0.55;
                } else if (!self.baaReady && self.baaSpawnFailed) {
                    /* The broker helper could not run at all; internet is
                     * not the cause. */
                    self.headlineLabel.text = L(@"Reinstall Showcase");
                    [self.primaryButton setTitle:L(@"Try Again")
                                       forState:UIControlStateNormal];
                } else if (!self.baaReady) {
                    self.headlineLabel.text = L(@"Connect to the Internet");
                    [self.primaryButton setTitle:L(@"Try Again")
                                       forState:UIControlStateNormal];
                } else {
                    /* "Kablosuz CarPlay" is this screen's eyebrow, so the word
                     * under the mark is the product itself. */
                    self.headlineLabel.text = @APP_NAME;
                    [self.primaryButton setTitle:L(@"Start CarPlay")
                                       forState:UIControlStateNormal];
                }
            }
            break;
        }

        case StateAwaitingAP:
            if (!self.hotspotManual) {
                self.headlineLabel.text = L(@"Starting Personal Hotspot");
                self.spinner.hidden = NO;
                [self.spinner startAnimating];
            } else {
                self.headlineLabel.text = L(@"Turn On Personal Hotspot");
                [self.primaryButton setTitle:L(@"Open Settings") forState:UIControlStateNormal];
                self.primaryButton.hidden = NO;
            }
            [self.secondaryButton setTitle:L(@"Cancel") forState:UIControlStateNormal];
            self.secondaryButton.hidden = NO;
            break;

        case StatePreparingBT:
        case StatePreparingNet:
            self.headlineLabel.text = L(@"Getting Ready");
            [self updateConnectSteps];
            [self.secondaryButton setTitle:L(@"Cancel") forState:UIControlStateNormal];
            self.secondaryButton.hidden = NO;
            break;

        case StateAwaitingPhone:
            self.headlineLabel.text = self.connectCompleted >= ConnectStepPhoneBluetooth
                ? L(@"Connecting")
                : [NSString stringWithFormat:L(@"Choose %@ in CarPlay on your iPhone"), carName];
            [self updateConnectSteps];
            [self.secondaryButton setTitle:L(@"Cancel") forState:UIControlStateNormal];
            self.secondaryButton.hidden = NO;
            break;

        case StateActive:
            /* Let the scene zoom into the mark first; the overlay drops away
             * underneath the flash, onto live CarPlay. */
            if (enteringActive && self.sceneShowing &&
                !self.connectionScene.isHandingOff) {
                __weak AppDelegate *weakSelf = self;
                [self.connectionScene playHandoffWithCompletion:^{
                    AppDelegate *strongSelf = weakSelf;
                    if (!strongSelf || strongSelf.state != StateActive) return;
                    strongSelf.setupOverlay.hidden = YES;
                    /* The scene is done; recompute the overlay so a later
                     * re-render sees sceneShowing == NO. */
                    [strongSelf layoutSetupOverlay];
                }];
            } else if (!self.connectionScene.isHandingOff) {
                self.setupOverlay.hidden = YES;
            }
            /* The scene keeps the screen through the hand-off, so the type has
             * to leave on its own — the prototype drops both lines in 200 ms
             * as the iPhone falls into the mark. */
            if (enteringActive && self.connectionScene.isHandingOff)
                [self fadeOutConnectionWords];
            if ([self isPhone]) {
                self.vc.fullscreenMode = YES;
                [self.vc.view setNeedsLayout];
            }
            self.videoView.transform = CGAffineTransformIdentity;
            self.chromeVisible = NO;
            self.controlsOverlay.hidden = YES;
            self.controlsOverlay.alpha = 1;
            self.settingsButton.hidden = YES;
            /* The overlay stays up through the hand-off zoom; the star panel
             * must not open over the CarPlay session underneath it. */
            self.starButton.hidden = YES;
            self.closeButton.hidden = YES;
            /* A panel opened while connecting would otherwise dim live
             * CarPlay and swallow the driver's first tap. Its own close path
             * runs onClose (settingsDidClose), like any other dismissal. */
            if (enteringActive &&
                [self.vc.presentedViewController isKindOfClass:[StarViewController class]])
                [(StarViewController *)self.vc.presentedViewController close];
            break;

        case StateStopping:
            self.headlineLabel.text = self.showFarewell ? L(@"See you soon") : L(@"Stopping");
            if (!self.showFarewell) { self.spinner.hidden = NO; [self.spinner startAnimating]; }
            /* CarPlay owns the screen while Active, so the overlay is off
             * screen here either way — and if the stop interrupted a hand-off
             * that has not landed, scaling in also hides the un-zoom. */
            else if (wasHidden || interruptedHandoff) {
                [self animateFarewellEntrance];
                [self revealFarewellWords];
            }
            break;
    }
    if (self.state == StateIdle && [self.cars apReady] && [self idleStartBusy]) {
        self.spinner.hidden = NO;
        [self.spinner startAnimating];
    }
    [self layoutSetupOverlay];
    [self syncConnectionScene];
    if (self.idleRevealPending) {
        if (self.state == StateIdle) {
            self.idleRevealPending = NO;
            [self revealIdleScreen];
        } else if (self.state != StateStopping) {
            self.idleRevealPending = NO;
        }
    }
}

/* The scene scales in over the last CarPlay frame instead of snapping on. */
- (void)animateFarewellEntrance {
    UIView *host = self.setupOverlay;
    if (!host) return;
    if (UIAccessibilityIsReduceMotionEnabled()) {
        /* Reduce Motion: cross-fade in place, no zoom. */
        host.layer.transform = CATransform3DIdentity;
        host.alpha = 0;
        [UIView animateWithDuration:0.2 delay:0
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ host.alpha = 1; } completion:nil];
        return;
    }
    host.layer.transform = CATransform3DMakeScale(1.12, 1.12, 1);
    host.alpha = 0;
    [UIView animateWithDuration:0.52 delay:0
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        host.alpha = 1;
        host.layer.transform = CATransform3DIdentity;
    } completion:nil];
}

/* ─── Type on top of the scene ─────────────────────────────── */

/* The prototype drops the status line and Cancel out of the picture in 200 ms
 * once the iPhone starts falling into the mark; the scene carries the screen
 * from there, so the type has to leave on its own. */
- (void)fadeOutConnectionWords {
    for (UIView *view in @[self.headlineLabel, self.secondaryButton]) {
        view.alpha = 0;
        [view.layer addAnimation:scene_fade(1, 0, 0.2, scene_later(0))
                          forKey:@"handoff.words"];
    }
}

- (void)restoreConnectionWords {
    for (UIView *view in @[self.headlineLabel, self.secondaryButton]) {
        [view.layer removeAnimationForKey:@"handoff.words"];
        view.alpha = 1;
    }
    /* The farewell fades its caption out; with Reduce Motion nothing brings
     * it back, so the next farewell would show an invisible caption. */
    self.farewellCaption.alpha = 1;
}

/* Text set once at build time; re-applied on every render so an in-app
 * language change reaches the caption and the VoiceOver labels too. */
- (void)refreshLocalizedChrome {
    self.farewellCaption.text = L(@"CarPlay disconnected");
    self.settingsButton.accessibilityLabel = L(@"Settings");
    self.starButton.accessibilityLabel = L(@"Give us a star on GitHub!");
    self.closeButton.accessibilityLabel = L(@"Close");
}

/* The prototype brings the two farewell lines in after the scene has settled —
 * the headline at 0.9 s, the caption at 1.06 s — so the first frame of the
 * farewell is the night road alone. */
- (void)revealFarewellWords {
    if (self.farewellWordsRevealed) return;
    self.farewellWordsRevealed = YES;
    if (UIAccessibilityIsReduceMotionEnabled()) return;
    [self revealLabel:self.headlineLabel delay:0.9 rise:10];
    [self revealLabel:self.farewellCaption delay:1.06 rise:8];
}

- (void)revealLabel:(UILabel *)label delay:(NSTimeInterval)delay rise:(CGFloat)rise {
    label.alpha = 1;   /* model value is the resting state; the fill covers the wait */
    [label.layer addAnimation:scene_fade(0, 1, 0.52, scene_later(delay))
                       forKey:@"farewell.reveal"];
    CABasicAnimation *up = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
    up.fromValue = @(rise);
    up.toValue = @0;
    up.duration = 0.52;
    up.beginTime = scene_later(delay);
    up.fillMode = kCAFillModeBackwards;
    up.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.16 :1 :0.3 :1];
    [label.layer addAnimation:up forKey:@"farewell.rise"];
}

- (void)stopFarewellWords {
    self.farewellWordsRevealed = NO;
    for (UILabel *label in @[self.headlineLabel, self.farewellCaption]) {
        [label.layer removeAnimationForKey:@"farewell.reveal"];
        [label.layer removeAnimationForKey:@"farewell.rise"];
        label.alpha = 1;
    }
}

/* The farewell is over: its words go out, then the parked screen's word and
 * button rise in, so handing the screen back never reads as a cut. */
- (void)finishFarewellWithCompletion:(void (^)(void))completion {
    /* Stopped while connecting: no farewell ran, so there is nothing to see out
     * and the screen goes straight back to the parked picture. */
    if (!self.showFarewell) {
        [self transitionTo:StateIdle];
        if (completion) completion();
        return;
    }
    [self stopFarewellWords];
    [UIView animateWithDuration:0.26 delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self.headlineLabel.alpha = 0;
        self.farewellCaption.alpha = 0;
    } completion:^(BOOL finished) {
        self.idleRevealPending = YES;
        self.showFarewell = NO;
        [self transitionTo:StateIdle];
        if (completion) completion();
    }];
}

- (void)revealIdleScreen {
    NSArray<UIView *> *views = @[self.titleLabel, self.headlineLabel, self.primaryButton];
    /* renderState has already dimmed a disabled ("Preparing…") button; keep
     * that resting value instead of revealing it as if it were tappable. */
    CGFloat (^restingAlpha)(UIView *) = ^CGFloat(UIView *view) {
        return (view == self.primaryButton && !self.primaryButton.enabled) ? 0.55 : 1;
    };
    for (UIView *view in views) {
        [view.layer removeAnimationForKey:@"idle.reveal"];
        [view.layer removeAnimationForKey:@"idle.rise"];
        view.alpha = restingAlpha(view);
    }
    if (UIAccessibilityIsReduceMotionEnabled()) return;
    for (NSUInteger i = 0; i < views.count; i++) {
        UIView *view = views[i];
        NSTimeInterval delay = i * 0.09;
        [view.layer addAnimation:scene_fade(0, restingAlpha(view), 0.52, scene_later(delay))
                          forKey:@"idle.reveal"];
        CABasicAnimation *up = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
        up.fromValue = @8;
        up.toValue = @0;
        up.duration = 0.52;
        up.beginTime = scene_later(delay);
        up.fillMode = kCAFillModeBackwards;
        up.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.16 :1 :0.3 :1];
        [view.layer addAnimation:up forKey:@"idle.rise"];
    }
}

- (void)primaryTapped {
    /* Only VoiceOver can reach the button under a modal; a start from there
     * would run behind the screen the user is reading. */
    if (self.vc.presentedViewController) return;
    switch (self.state) {
        case StateIdle:
            if ([self.cars apReady]) [self attemptStart];
            else                     [self showWifiSetup];
            break;
        case StateAwaitingAP:
            [self openHotspotSettings];
            break;
        default:
            break;
    }
}

- (void)secondaryTapped {
    if (self.state == StateAwaitingAP || self.state == StatePreparingBT ||
        self.state == StatePreparingNet || self.state == StateAwaitingPhone) {
        [self stopFlow];
    }
}

- (void)closeTapped { [self stopFlow]; }
- (void)settingsTapped { [self presentSettingsPage:nil]; }

- (void)starTapped {
    if (self.state == StateActive || self.vc.presentedViewController) return;
    StarViewController *star = [[StarViewController alloc] init];
    __weak typeof(self) weakSelf = self;
    star.onClose = ^{ [weakSelf settingsDidClose]; };
    star.modalPresentationStyle = UIModalPresentationOverFullScreen;
    star.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [self.vc presentViewController:star animated:YES completion:nil];
}

- (void)presentSettingsPage:(NSString *)page {
    if ([self.vc.presentedViewController isKindOfClass:[SettingsViewController class]])
        return;
    SettingsViewController *settings = [[SettingsViewController alloc] init];
    settings.appDelegate = self;
    settings.initialPage = page;
    settings.modalPresentationStyle = UIModalPresentationOverFullScreen;
    settings.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    UIViewController *presenter = self.vc.presentedViewController ?: self.vc;
    [presenter presentViewController:settings animated:YES completion:nil];
}

- (void)refreshPresentedSettings {
    UIViewController *presented = self.vc.presentedViewController;
    if ([presented isKindOfClass:[SettingsViewController class]])
        [(SettingsViewController *)presented refresh];
}

/* Every modal Showcase presents over the main screen (Settings, the star
 * panel, Wi-Fi Setup, the Bluetooth compatibility error) ends here, so errors held while it was up are shown. */
- (void)settingsDidClose {
    if (self.state == StateActive && self.chromeVisible) [self hideChrome];
    [self renderState];
    [self presentPendingBluetoothCompatibilityError];
    [self presentPendingWifiSetupError];
    [self presentPendingServicesSetupError];
    [self resumePendingRestart];
    [self startAutomaticallyIfRequested];
}

- (void)toggleChrome:(UITapGestureRecognizer *)gesture {
    if (self.state != StateActive ||
        gesture.state != UIGestureRecognizerStateRecognized) return;
    if (self.chromeVisible) {
        [self hideChrome];
        return;
    }
    [self showChrome];
}

#if SHOWCASE_MIRROR_BENCH
- (void)openScreenMirror {
    if (self.state != StateActive || self.vc.presentedViewController ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    [self hideChrome];
    [self dismissCarVideo];
    /* CarPlay is hidden under the Mirror receiver: stop the iPhone's H.264
     * the same way backgrounding does. onReturnToCarPlay turns it back on,
     * and if the app is backgrounded meanwhile handleForeground does. */
    send_app_visibility(0);
    ShowcaseMirrorReceiver *receiver = [ShowcaseMirrorReceiver new];
    receiver.modalPresentationStyle = UIModalPresentationFullScreen;
    __weak typeof(self) weakSelf = self;
    receiver.onReturnToCarPlay = ^{
        if (weakSelf.state == StateActive &&
            UIApplication.sharedApplication.applicationState != UIApplicationStateBackground) {
            /* Same resume as handleForeground: the frames skipped under the
             * receiver are gone, so wait for a key frame. */
            [weakSelf resyncCarPlayVideo];
            send_app_visibility(1);
        }
        [weakSelf resumePendingRestart];
    };
    self.screenMirror = receiver;
    [self.vc presentViewController:receiver animated:YES completion:nil];
}
#endif

- (void)showChrome {
    if (self.state != StateActive || self.chromeVisible) return;
    self.chromeVisible = YES;
    self.controlsOverlay.alpha = 0;
    self.controlsOverlay.hidden = NO;
    self.settingsButton.hidden = NO;
    self.closeButton.hidden = NO;
    [UIView animateWithDuration:0.18 animations:^{
        self.controlsOverlay.alpha = 1;
        self.settingsButton.alpha = 1;
        self.closeButton.alpha = 1;
    }];
}
- (void)hideChrome {
    self.chromeVisible = NO;
    [UIView animateWithDuration:0.18 animations:^{
        self.controlsOverlay.alpha = 0;
        self.settingsButton.alpha = 0;
        self.closeButton.alpha = 0;
    } completion:^(BOOL d) {
        /* A showChrome during the fade runs before this; it wins. */
        if (self.state == StateActive && !self.chromeVisible) {
            self.controlsOverlay.hidden = YES;
            self.settingsButton.hidden = YES;
            self.closeButton.hidden = YES;
        }
    }];
}

#ifdef SHOWCASE_UI_PREVIEW
/* Development-only: never compiled into packages. Watches
 * /tmp/showcase_preview for a page name, or "steps:N", and shows that screen
 * in place so screens can be captured without a phone or a relaunch. */
- (void)schedulePreviewFromFile {
    static NSString *lastSpec = nil;
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        NSString *spec = [[NSString stringWithContentsOfFile:@"/tmp/showcase_preview"
            encoding:NSUTF8StringEncoding error:NULL]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!spec.length || [spec isEqualToString:lastSpec]) return;
        lastSpec = spec;
        /* "scene:<name>[:<n>][@<ms>]" drives the connection scene and captures
         * mid-animation; the value after @ is the delay before the snapshot. */
        NSInteger captureDelay = 1200;
        NSRange at = [spec rangeOfString:@"@" options:NSBackwardsSearch];
        if (at.location != NSNotFound) {
            captureDelay = [[spec substringFromIndex:at.location + 1] integerValue];
            spec = [spec substringToIndex:at.location];
        }
        void (^apply)(void) = ^{
            if ([spec hasPrefix:@"scene:"]) {
                NSString *name = [spec substringFromIndex:6];
                NSInteger n = 0;
                NSRange colon = [name rangeOfString:@":"];
                if (colon.location != NSNotFound) {
                    n = [[name substringFromIndex:colon.location + 1] integerValue];
                    name = [name substringToIndex:colon.location];
                }
                self.showFarewell = NO;
                if ([name isEqualToString:@"idle"]) {
                    self.state = StateIdle;
                    self.connectCompleted = -1;
                } else if ([name isEqualToString:@"preparing"]) {
                    self.state = StatePreparingBT;
                    self.connectCompleted = n > 0 ? n - 1 : 1;
                } else if ([name isEqualToString:@"choose"]) {
                    self.state = StateAwaitingPhone;
                    self.connectCompleted = 1;
                } else if ([name isEqualToString:@"connecting"]) {
                    self.state = StateAwaitingPhone;
                    self.connectCompleted = n > 0 ? n - 1 : 5;
                } else if ([name isEqualToString:@"connecting9"]) {
                    self.state = StateAwaitingPhone;
                    self.connectCompleted = 8;
                } else if ([name isEqualToString:@"active"]) {
                    self.state = StateAwaitingPhone;
                    self.connectCompleted = 8;
                    [self renderState];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(900 * NSEC_PER_MSEC)),
                                  dispatch_get_main_queue(), ^{
                        self.state = StateActive;
                        [self renderState];
                    });
                    return;
                } else if ([name isEqualToString:@"farewell"]) {
                    self.state = StateAwaitingPhone;
                    self.connectCompleted = 8;
                    [self renderState];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(700 * NSEC_PER_MSEC)),
                                  dispatch_get_main_queue(), ^{
                        self.state = StateStopping;
                        self.showFarewell = YES;
                        [self renderState];
                    });
                    return;
                } else if ([name isEqualToString:@"closing"]) {
                    /* The real close path: connect all the way through the
                     * hand-off, then stop. Unlike "farewell" the overlay is
                     * already off screen when the farewell starts, which is
                     * what the device actually does. */
                    self.state = StateAwaitingPhone;
                    self.connectCompleted = 8;
                    [self renderState];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(900 * NSEC_PER_MSEC)),
                                  dispatch_get_main_queue(), ^{
                        self.state = StateActive;
                        [self renderState];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                      (int64_t)(1500 * NSEC_PER_MSEC)),
                                      dispatch_get_main_queue(), ^{
                            self.state = StateStopping;
                            self.showFarewell = YES;
                            [self renderState];
                            /* The farewell runs 2.75 s before the parked
                             * screen takes over, exactly as stopFlow times it. */
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                          (int64_t)(2750 * NSEC_PER_MSEC)),
                                          dispatch_get_main_queue(), ^{
                                [self finishFarewellWithCompletion:nil];
                            });
                        });
                    });
                    return;
                }
                [self renderState];
            } else if ([spec hasPrefix:@"steps:"]) {
                NSInteger n = [[spec substringFromIndex:6] integerValue];
                self.state = n < 1 ? StatePreparingBT : StateAwaitingPhone;
                self.connectCompleted = n - 1;
                self.firstTimePairing = n >= 6;
                [self renderState];
            } else if ([spec isEqualToString:@"home"]) {
                self.state = StateIdle;
                [self renderState];
            } else {
                self.state = StateIdle;
                [self renderState];
                [self presentSettingsPage:[spec isEqualToString:@"root"] ? nil : spec];
            }
        };
        void (^snapshot)(void) = ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                           (int64_t)(captureDelay * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{
                UIGraphicsBeginImageContextWithOptions(self.window.bounds.size, YES, 0);
                [self.window drawViewHierarchyInRect:self.window.bounds afterScreenUpdates:YES];
                UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
                [UIImagePNGRepresentation(image) writeToFile:@"/tmp/showcase_preview.png"
                                                  atomically:YES];
            });
        };
        if (self.vc.presentedViewController)
            [self.vc dismissViewControllerAnimated:NO completion:^{ apply(); snapshot(); }];
        else {
            apply();
            snapshot();
        }
    }];
}
#endif

/* ─── Action helpers ───────────────────────────────────────── */

/* "Start CarPlay automatically" runs once per launch, as soon as the
 * authentication certificate is ready, so a car-mounted screen needs no tap. */
- (void)startAutomaticallyIfRequested {
    /* Authentication may come later, after a retry; wait for it. */
    if (self.autoStartConsumed || !self.baaReady) return;
    /* A modal opened during preheat only defers the request: settingsDidClose
     * asks again, like the network wait does. */
    if (self.state == StateIdle && self.vc.presentedViewController) {
        ip_log("auto start deferred until the open panel closes");
        return;
    }
    /* The broker may have exited while a panel deferred this start; carplay_bt
     * would then fail with "No BAA cert". Like a tap (attemptStart), verify
     * it first. A dead broker is replaced and its preheat asks again; a
     * renewal held here asks again when it ends (resumeStartsAfterBAARenewal). */
    if (self.state == StateIdle && [self.cars apReady] && self.cars.cars.count > 0 &&
        [[NSUserDefaults standardUserDefaults] boolForKey:AUTO_START_KEY] &&
        ![self baaBrokerStillReady]) {
        ip_log("auto start held until the BAA broker is ready again");
        return;
    }
    self.autoStartConsumed = YES;
    if (![[NSUserDefaults standardUserDefaults] boolForKey:AUTO_START_KEY]) return;
    if (self.state != StateIdle || !self.baaReady || ![self.cars apReady] ||
        self.cars.cars.count == 0 || self.vc.presentedViewController) {
        ip_log("auto start skipped: state=%ld baa=%d ap=%d presented=%d",
               (long)self.state, self.baaReady, [self.cars apReady],
               self.vc.presentedViewController != nil);
        return;
    }
    ip_log("auto start: starting CarPlay on launch");
    self.automaticStartRequested = YES;
    [self startFlow];
}

#define AUTO_START_NETWORK_WAIT_SECONDS 60
#define AUTO_START_NETWORK_POLL_SECONDS 5

/* A missing Wi-Fi interface or an unreadable network name is usually just the
 * iPad still joining the router. Keep an automatic start alive for a while
 * instead of consuming it with an alert. */
- (void)waitForNetworkBeforeAutomaticStart {
    if (self.autoStartNetworkDeadline > 0) return;
    self.autoStartNetworkDeadline =
        CFAbsoluteTimeGetCurrent() + AUTO_START_NETWORK_WAIT_SECONDS;
    ip_log("[WIFI] automatic start waits up to %d s for the shared network",
           AUTO_START_NETWORK_WAIT_SECONDS);
    [self pollAutomaticStartWaitingForNetwork];
}

- (void)pollAutomaticStartWaitingForNetwork {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)AUTO_START_NETWORK_POLL_SECONDS * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        if (self.autoStartNetworkDeadline <= 0) return;
        [self retryAutomaticStartWaitingForNetwork];
        if (self.autoStartNetworkDeadline > 0)
            [self pollAutomaticStartWaitingForNetwork];
    });
}

- (void)retryAutomaticStartWaitingForNetwork {
    if (self.autoStartNetworkDeadline <= 0) return;
    if (self.state != StateIdle) {
        self.autoStartNetworkDeadline = 0;
        return;
    }
    BOOL expired = CFAbsoluteTimeGetCurrent() >= self.autoStartNetworkDeadline;
    NSString *networkError = nil;
    if (showcase_use_existing_wifi()) {
        if (!shared_wifi_interface())
            networkError = L(@"Connect this device to the Wi-Fi network first.");
        else if (!showcase_current_wifi_ssid())
            networkError = L(@"Could not read the connected Wi-Fi name. Check Wi-Fi in Settings and try again.");
    }
    if (networkError) {
        if (!expired) return;
        /* Last attempt: a network that is still missing is only reported
         * (deferred while a modal is up), never started into. */
        self.autoStartNetworkDeadline = 0;
        ip_log("[WIFI] shared network still unavailable; giving up automatic start");
        [self showWifiSetupError:networkError];
        return;
    }
    /* The deadline bounds only the network wait. With the network up, the
     * request waits for Settings/Wi-Fi Setup to close (their unsaved values
     * and session locks) and for authentication that really works. */
    if (self.vc.presentedViewController || self.baaLoading) return;
    if (!self.baaReady) {
        if (!expired) return;   /* a network change may still retry the broker */
        self.autoStartNetworkDeadline = 0;
        ip_log("[WIFI] shared network is up but authentication is not ready; "
               "automatic start dropped");
        return;
    }
    /* A dead or expired broker is replaced; the next poll sees it loading. */
    if (![self baaBrokerStillReady]) return;
    ip_log("[WIFI] shared network is up; resuming automatic start");
    self.automaticStartRequested = YES;
    [self startFlow];
}

/* Idle shows "Preparing…" (disabled button, spinner) while a start cannot
 * go yet: the certificate is being fetched, a broker renewal runs, or a tap
 * is held until one of them ends. Otherwise the tap would look ignored for
 * up to 45 s before the connection suddenly starts on its own. */
- (BOOL)idleStartBusy {
    return self.baaLoading || self.baaRenewing || self.pendingUserStart;
}

- (void)resumePendingUserStart {
    if (!self.pendingUserStart) return;
    if (!self.baaReady) {
        /* The preheat failed; the button now offers Try Again instead. */
        if (!self.baaLoading) {
            self.pendingUserStart = NO;
            if (self.state == StateIdle) [self renderState];
        }
        return;
    }
    if (self.state != StateIdle || self.vc.presentedViewController) {
        self.pendingUserStart = NO;
        if (self.state == StateIdle) [self renderState];
        return;
    }
    self.pendingUserStart = NO;
    ip_log("BAA broker replaced; continuing the requested start");
    [self startFlow];
}

/* The broker can exit after a successful preheat (idle key probe failing,
 * jetsam, a crash); baaReady would still say YES and every session would then
 * fail authentication until relaunch. Verify before relying on it, and start a
 * fresh broker when it is gone. */
- (BOOL)baaBrokerStillReady {
    if (!self.baaReady) return NO;
    if (baa_broker_alive(self.baaBrokerPid, self.baaBrokerReused,
                              self.baaBrokerStartMicros)) {
        /* The broker never renews its certificate, so an app left running
         * for days would otherwise fail every session's authentication. The
         * same age limit as a reused broker at launch applies. Renewal needs
         * internet, so the working broker stays until its replacement is
         * ready, or until its own certificate really runs out. */
        if (baa_broker_age(self.baaBrokerPid) <= BAA_BROKER_REUSE_SECONDS) return YES;
        /* No session may start while a renewal runs: the replacement binds
         * the shared socket path on its own once its certificate arrives,
         * and a helper that read the old broker's certificate would then
         * sign with the new broker's key (iAP2 / auth-setup rejected). The
         * callers keep their start pending; the renewal's end resumes it
         * (resumeStartsAfterBAARenewal), on the old broker if it failed.
         * Renew beside the old broker only while its certificate still
         * works: otherwise it is replaced outright below, and startBAA's
         * helper reap would kill a renewal spawned here a moment earlier. */
        if (baa_certificate_usable(self.baaCertNotAfter)) {
            [self renewBAABroker];
            if (self.baaRenewing)
                ip_log("BAA broker renewal in progress; start held until it ends");
            return !self.baaRenewing;
        }
        /* A renewal started while the certificate was still good is left to
         * finish; its end resumes the held start, which lands back here and
         * replaces the broker if the renewal did not. */
        if (self.baaRenewing) {
            ip_log("BAA broker renewal in progress; start held until it ends");
            return NO;
        }
        ip_log("BAA broker pid=%d is older than %d s and its certificate "
               "expires at %ld; replacing it",
               self.baaBrokerPid, BAA_BROKER_REUSE_SECONDS,
               (long)self.baaCertNotAfter);
        stop_baa_broker(self.baaBrokerPid, self.baaBrokerReused,
                        self.baaBrokerStartMicros);
    } else {
        ip_log("BAA broker pid=%d is gone after preheat; starting a fresh one",
               self.baaBrokerPid);
    }
    self.baaReady = NO;
    self.baaBrokerPid = 0;
    self.baaBrokerReused = NO;
    self.baaBrokerStartMicros = 0;
    self.baaCertNotAfter = 0;
    [self startBAA];
    return NO;
}

/* Fetches a fresh certificate in a second broker while the current one keeps
 * serving. The new broker binds the shared socket path only after its
 * certificate arrived, so until then every client still reaches the old one;
 * a renewal that fails (no internet) changes nothing. Only once the new
 * broker answers on the path is the old one killed (SIGKILL: its normal exit
 * would unlink the path the new broker now owns). */
- (void)renewBAABroker {
    if (self.baaRenewing || self.baaLoading ||
        monotonic_nanos_now() < self.baaRenewNotBefore) return;
    self.baaRenewing = YES;
    if (self.state == StateIdle) [self renderState];
    pid_t oldPid = self.baaBrokerPid;
    /* The live broker keeps writing its own log; never truncate it. */
    BOOL renewLog = !self.baaBrokerOnRenewLog;
    NSString *helper = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@SVC_HELPER_NAME];
    ip_log("BAA broker pid=%d renewal started beside it", oldPid);
    /* Spawned here, not on the background queue: every caller may go
     * straight to startFlow, whose helper reap must already know this pid
     * (baaRenewPid) so it spares the replacement. */
    char *argv[] = { (char *)SVC_HELPER_NAME, (char *)"--baa-broker", NULL };
    pid_t newPid = spawn_daemon([helper UTF8String], argv,
                                renewLog ? BAA_BROKER_RENEW_LOG : BAA_BROKER_LOG);
    self.baaRenewPid = newPid > 0 ? newPid : 0;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        time_t notAfter = 0;
        BOOL ready = newPid > 0 && baa_renewed_broker_ready(newPid, &notAfter);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.baaRenewPid = 0;
            BOOL adopt = ready && self.baaBrokerPid == oldPid && self.baaReady &&
                !self.baaLoading && child_alive(newPid);
            if (!adopt) {
                self.baaRenewNotBefore = monotonic_nanos_now() +
                    (uint64_t)BAA_RENEW_RETRY_SECONDS * NSEC_PER_SEC;
                ip_log("BAA broker renewal failed (ready=%d); keeping pid=%d "
                       "until its certificate expires at %ld",
                       ready, self.baaBrokerPid, (long)self.baaCertNotAfter);
                /* baaRenewing stays set until the discard knows which broker
                 * answers on the path: a session started in between would
                 * have its helpers reaped by the broker's replacement. */
                [self discardRenewedBAABroker:newPid];
                return;
            }
            self.baaRenewing = NO;
            stop_baa_broker(oldPid, self.baaBrokerReused, self.baaBrokerStartMicros);
            self.baaBrokerPid = newPid;
            self.baaBrokerReused = NO;
            self.baaBrokerStartMicros = 0;
            self.baaCertNotAfter = notAfter;
            self.baaBrokerOnRenewLog = renewLog;
            baa_mark_broker_log(renewLog);
            self.baaRenewNotBefore = 0;
            ip_log("BAA broker renewed: pid=%d replaced pid=%d", newPid, oldPid);
            [self resumeStartsAfterBAARenewal];
        });
    });
}

/* A replacement killed after it bound the path (the broker changing
 * meanwhile, or anything else that ended it; a session's helper reap spares
 * it through baaRenewPid) leaves the path pointing at nothing; then
 * the current broker is unreachable and must not be trusted any more. */
- (void)discardRenewedBAABroker:(pid_t)newPid {
    pid_t current = self.baaBrokerPid;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (newPid > 0 && newPid != current) kill_child(newPid);
        pid_t peer = baa_broker_peer_pid();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.baaRenewing = NO;
            if (self.baaBrokerPid == current && peer != current &&
                self.baaReady && !self.baaLoading) {
                ip_log("BAA broker pid=%d no longer answers on its socket (peer=%d)",
                       current, peer);
                /* Clients reach a broker only through the path, so a preheat
                 * of this one would fail for its full 45 s and blame the
                 * internet. Replace it; a start held for the renewal (or an
                 * automatic start waiting for the network) stays pending and
                 * resumes once the fresh broker is ready. */
                [self replaceUnreachableBAABroker];
            }
            /* Only now is it known which broker answers on the path. */
            [self resumeStartsAfterBAARenewal];
        });
    });
}

/* The current broker is alive but no longer owns the shared socket path. */
- (void)replaceUnreachableBAABroker {
    if (self.state != StateIdle) {
        /* startBAABroker reaps every helper: replacing the broker now would
         * kill this session's carplay_services, carplay_bt and BTdaemon
         * behind stopFlow's back. Stop trusting it; stopFlow replaces it. */
        ip_log("BAA broker pid=%d unreachable during a session; replacement "
               "deferred until Idle", self.baaBrokerPid);
        self.baaReady = NO;
        self.baaReplaceDeferred = YES;
        return;
    }
    self.baaReplaceDeferred = NO;
    stop_baa_broker(self.baaBrokerPid, self.baaBrokerReused, self.baaBrokerStartMicros);
    self.baaReady = NO;
    self.baaBrokerPid = 0;
    self.baaBrokerReused = NO;
    self.baaBrokerStartMicros = 0;
    self.baaCertNotAfter = 0;
    [self renderState];
    [self startBAA];
}

/* Prepares authentication when it is not ready. A live broker is preheated
 * only while it answers on the shared path (a broker that lost the path to a
 * discarded renewal never will); otherwise a fresh one is started. Not used by
 * startBAA: a freshly spawned broker binds the path only after its
 * certificate arrives, which is what its preheat waits for. */
- (void)prepareBAA {
    if (self.baaLoading) return;
    if (baa_broker_alive(self.baaBrokerPid, self.baaBrokerReused,
                         self.baaBrokerStartMicros)) {
        pid_t peer = baa_broker_peer_pid();
        if (peer == self.baaBrokerPid) {
            [self preheatBAA];
            return;
        }
        ip_log("BAA broker pid=%d does not answer on its socket (peer=%d); "
               "starting a fresh one", self.baaBrokerPid, peer);
        [self replaceUnreachableBAABroker];
        return;
    }
    [self startBAA];
}

/* Starts held by baaBrokerStillReady while a renewal ran. The automatic
 * start's network wait polls on its own; a broker lost to a failed renewal is
 * restarted for it in discardRenewedBAABroker. */
- (void)resumeStartsAfterBAARenewal {
    if (self.baaRenewing) return;
    /* An automatic start held while the renewal ran (still unconsumed). */
    [self startAutomaticallyIfRequested];
    [self resumePendingRestart];
    [self resumePendingUserStart];
    /* Clears the "Preparing…" screen when nothing started (a started flow
     * renders through transitionTo:). */
    if (self.state == StateIdle) [self renderState];
}

- (void)attemptStart {
    /* Should never be reachable when AP not ready (button is disabled) — defensive */
    if (![self.cars apReady]) { [self showWifiSetup]; return; }
    if (self.cars.cars.count == 0) return;
    if (self.baaReady && ![self baaBrokerStillReady]) {
        /* The tap owns this start now; no automatic wait may race it. */
        self.autoStartNetworkDeadline = 0;
        self.pendingUserStart = YES;
        [self renderState];
        return;
    }
    if (!self.baaReady) {
        [self prepareBAA];
        return;
    }
    [self startFlow];
}

- (void)startFlow {
    BOOL automatic = self.automaticStartRequested;
    self.automaticStartRequested = NO;
    if (self.state != StateIdle) return;
    self.restartAfterStop = NO;
    self.pendingUserStart = NO;
    /* Delayed starts (the network wait, a pending restart) reach here after
     * Settings may have switched to a Wi-Fi mode with no saved network or
     * removed the last car; starting then hands the helpers an empty SSID. */
    if (![self.cars apReady] || self.cars.cars.count == 0) {
        self.autoStartNetworkDeadline = 0;
        ip_log("startFlow skipped: ap=%d cars=%lu automatic=%d",
               [self.cars apReady], (unsigned long)self.cars.cars.count, automatic);
        /* A held tap was just dropped; leave the "Preparing…" screen. */
        [self renderState];
        if (![self.cars apReady] && !self.vc.presentedViewController)
            [self showWifiSetup];
        return;
    }
    /* A Bluetooth failure that could not be shown (app in the background)
     * belongs to the session that ended; it must not surface later as if this
     * new session had failed. */
    if (self.pendingBluetoothDiagnostic.length)
        ip_log("[BT-COMPAT] discarding an unshown failure from the previous session");
    self.pendingBluetoothErrorTitle = nil;
    self.pendingBluetoothErrorExplanation = nil;
    self.pendingBluetoothDiagnostic = nil;
    self.pendingServicesSetupError = NO;
    /* A tap, or the final retry, ends any wait for the network. */
    if (!automatic) self.autoStartNetworkDeadline = 0;
    self.sessionCarName = self.cars.selected.name;
    ip_log("startFlow: car='%s' ssid='%s'",
           [self.sessionCarName UTF8String],
           [self.cars.apSSID UTF8String]);
    self.sharedWifiSession = showcase_use_existing_wifi();
    self.sharedWifiInterface = nil;
    if (self.sharedWifiSession) {
        NSString *interface = shared_wifi_interface();
        NSString *connectedSSID = showcase_current_wifi_ssid();
        NSString *error = nil;
        if (!interface) error = L(@"Connect this device to the Wi-Fi network first.");
        else if (!connectedSSID) error = L(@"Could not read the connected Wi-Fi name. Check Wi-Fi in Settings and try again.");
        else if (![connectedSSID isEqualToString:self.cars.apSSID]) {
            error = [NSString stringWithFormat:L(@"This device is connected to “%@”, but Showcase is configured for “%@”. Connect both devices to the same network and update Wi-Fi settings."),
                     connectedSSID, self.cars.apSSID];
        }
        if (error) {
            ip_log("[WIFI] shared network not ready: %s", error.UTF8String);
            if (automatic && (!interface || !connectedSSID)) {
                [self waitForNetworkBeforeAutomaticStart];
                return;
            }
            self.autoStartNetworkDeadline = 0;
            [self showWifiSetupError:error];
            return;
        }
        self.autoStartNetworkDeadline = 0;
        self.sharedWifiInterface = interface;
    } else {
        /* The iPhone is told to join the saved name; if the hotspot is called
         * something else it can never associate and the flow would hang. */
        NSString *deviceName = hotspot_name();
        if (deviceName && ![deviceName isEqualToString:self.cars.apSSID]) {
            ip_log("[HOTSPOT] hotspot is named '%s' but Showcase sends '%s'",
                   deviceName.UTF8String, self.cars.apSSID.UTF8String);
            [self showWifiSetupError:[self hotspotNameMismatchMessage:deviceName]];
            return;
        }
    }
    __atomic_add_fetch(&g_flow_epoch, 1, __ATOMIC_ACQ_REL);
    __atomic_store_n(&g_flow_cancelled, false, __ATOMIC_RELEASE);
    self.bluetoothHandedOff = NO;
    [self resetConnectProgress];
    if (self.sharedWifiSession) {
        ip_log("[WIFI] using existing shared Wi-Fi network; Personal Hotspot is not required");
        /* A previous interrupted hotspot-mode session may have left a stale
         * held-network marker.  The user is intentionally using that network
         * now, so never restore/disable it as part of this session. */
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:HELD_WIFI_NETWORK_KEY];
        [[NSUserDefaults standardUserDefaults] synchronize];
    } else if ([[NSUserDefaults standardUserDefaults] boolForKey:DEDICATED_RADIO_KEY]) {
        dispatch_async(self.bgQueue, ^{ if (!flow_cancelled()) showcase_hold_other_wifi(); });
    }
    /* HOTSPOT_OWNED_KEY is kept: a session killed while it owned the
     * hotspot left it on, and attempt 0 must still treat it as Showcase's. */
    self.hotspotManual = NO;
    self.hotspotAttempt = 0;
    [self.apPollTimer invalidate];
    self.apPollTimer = nil;
    [self transitionTo:StateAwaitingAP];
    if (self.sharedWifiSession) {
        /* The iPad is already associated with the portable router.  Do not
         * touch Mobile Internet Sharing or disconnect that association. */
        [self transitionTo:StatePreparingBT];
        dispatch_async(self.bgQueue, ^{ [self bgPrepareBT]; });
    } else {
        [self startHotspotAttempt];
    }
}

/* ─── Hotspot automation ───────────────────────────────────── */

/* Showcase turns on Personal Hotspot itself. Attempt 1 repeats after a
 * Wi-Fi power cycle, which clears an access point wifid could not start.
 * After that the user turns the hotspot on in Settings. */
- (void)startHotspotAttempt {
    if (self.sharedWifiSession) return;
    NSInteger attempt = self.hotspotAttempt;
    dispatch_async(self.bgQueue, ^{
        if (self.state != StateAwaitingAP) return;
        int state = showcase_hotspot_state();
        if (state < 0) {
            ip_log("[HOTSPOT] Mobile Internet Sharing unavailable; manual setup");
            dispatch_async(dispatch_get_main_queue(), ^{ [self fallBackToManualHotspot]; });
            return;
        }
        if (attempt == 0) {
            /* Turn the hotspot off at stop only if Showcase turned it on,
             * in this session or in one that ended without stopFlow. */
            BOOL previouslyOwned = [[NSUserDefaults standardUserDefaults]
                                       boolForKey:HOTSPOT_OWNED_KEY];
            [[NSUserDefaults standardUserDefaults]
                setBool:(previouslyOwned || state != MIS_STATE_ON)
                 forKey:HOTSPOT_OWNED_KEY];
        }
        if (state == MIS_STATE_ON && !is_ap_up()) {
            /* On but not advertising: start it fresh. */
            showcase_set_hotspot(NO);
            if (!sleep_unless_cancelled(1000000)) return;
        }
        if (attempt == 1) {
            /* Attempt 0's access point may have come up after the last poll;
             * a power cycle would tear down the one pollAP is about to use. */
            if (self.state != StateAwaitingAP) return;
            if (is_ap_up()) {
                ip_log("[HOTSPOT] %s came up late; skipping the Wi-Fi power cycle",
                       AP_INTERFACE);
            } else {
                /* Never leave Wi-Fi off, even when the user cancels or
                 * leaves the app: the state is AwaitingAP, so nothing else
                 * keeps a backgrounded app running through the cycle, and
                 * the marker covers a process that dies inside it. */
                UIApplication *app = [UIApplication sharedApplication];
                __block UIBackgroundTaskIdentifier cycleTask =
                    [app beginBackgroundTaskWithName:@"Showcase Wi-Fi power cycle"
                                   expirationHandler:^{
                    showcase_set_wifi_power(YES);
                    [app endBackgroundTask:cycleTask];
                    cycleTask = UIBackgroundTaskInvalid;
                }];
                NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
                [prefs setBool:YES forKey:WIFI_POWER_CYCLE_KEY];
                [prefs synchronize];
                showcase_set_wifi_power(NO);
                BOOL powerCycled = sleep_unless_cancelled(3000000);
                showcase_set_wifi_power(YES);
                [prefs removeObjectForKey:WIFI_POWER_CYCLE_KEY];
                [prefs synchronize];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (cycleTask == UIBackgroundTaskInvalid) return;
                    [app endBackgroundTask:cycleTask];
                    cycleTask = UIBackgroundTaskInvalid;
                });
                if (!powerCycled || !sleep_unless_cancelled(6000000)) return;
                /* pollAP advanced on the access point the cycle just removed
                 * (bgPrepareBT is queued behind this block): bring it back,
                 * or carplay_bt sends an SSID nobody advertises. */
                if (self.state != StateAwaitingAP) {
                    if (flow_cancelled() || ![[NSUserDefaults standardUserDefaults]
                                                 boolForKey:HOTSPOT_OWNED_KEY]) return;
                    ip_log("[HOTSPOT] flow advanced during the power cycle; restarting the hotspot");
                    showcase_set_hotspot(YES);
                    if (!sleep_unless_cancelled(800000)) return;
                    showcase_set_hotspot_discovery(YES);
                    return;
                }
            }
        }
        if (self.state != StateAwaitingAP) return;
        showcase_set_hotspot(YES);
        if (!sleep_unless_cancelled(800000)) return;
        showcase_set_hotspot_discovery(YES);
        ip_log("[HOTSPOT] attempt %ld: hotspot requested", (long)attempt);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.state != StateAwaitingAP) return;
            [self renderState];
            [self.apPollTimer invalidate];
            self.apPollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                target:self selector:@selector(pollAP) userInfo:nil repeats:YES];
            [self.hotspotWatchdog invalidate];
            self.hotspotWatchdog = [NSTimer scheduledTimerWithTimeInterval:15.0
                target:self selector:@selector(hotspotAttemptTimedOut)
                userInfo:nil repeats:NO];
            [self startDiscoveryKeepalive];
        });
    });
}

- (void)hotspotAttemptTimedOut {
    self.hotspotWatchdog = nil;
    if (self.state != StateAwaitingAP || self.hotspotManual) return;
    /* The access point may have come up since the last 1 s poll. */
    [self pollAP];
    if (self.state != StateAwaitingAP) return;
    ip_log("[HOTSPOT] attempt %ld did not bring up %s", (long)self.hotspotAttempt,
           AP_INTERFACE);
    self.hotspotAttempt += 1;
    if (self.hotspotAttempt <= 1) {
        [self startHotspotAttempt];
    } else {
        [self fallBackToManualHotspot];
    }
}

- (void)fallBackToManualHotspot {
    if (self.state != StateAwaitingAP) return;
    self.hotspotManual = YES;
    [self renderState];
    if (!self.apPollTimer) {
        self.apPollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
            target:self selector:@selector(pollAP) userInfo:nil repeats:YES];
    }
}

/* wifid withdraws a discoverable hotspot that has no clients after a short
 * time. Keep it discoverable until the iPhone has joined and video runs. */
- (void)startDiscoveryKeepalive {
    [self.discoveryTimer invalidate];
    self.discoveryTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
        target:self selector:@selector(refreshDiscovery) userInfo:nil repeats:YES];
}

- (void)refreshDiscovery {
    if (self.sharedWifiSession) return;
    BOOL connecting = self.state == StateAwaitingAP || [self isConnectingState];
    if (!connecting) {
        [self.discoveryTimer invalidate];
        self.discoveryTimer = nil;
        return;
    }
    showcase_set_hotspot_discovery(YES);
}

- (void)beginAWDLSuppression {
    dispatch_sync(awdl_queue(), ^{
        if (__sync_bool_compare_and_swap(&g_awdl_suppressed, 0, 1)) {
            awdl_suppress(YES);
            ip_log("AWDL suppressed for the duration of the session");
        }
    });
    if (self.awdlReassertTimer) return;
    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, awdl_queue());
    if (!timer) return;
    dispatch_source_set_timer(
        timer,
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(AWDL_REASSERT_SECONDS * NSEC_PER_SEC)),
        (uint64_t)(AWDL_REASSERT_SECONDS * NSEC_PER_SEC),
        (uint64_t)(NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        if (g_awdl_suppressed) awdl_suppress(NO);
    });
    dispatch_resume(timer);
    self.awdlReassertTimer = timer;
}

- (void)endAWDLSuppression {
    if (self.awdlReassertTimer) {
        dispatch_source_cancel(self.awdlReassertTimer);
        self.awdlReassertTimer = nil;
    }
    /* A re-assert already running finishes before this restore runs, and a
     * later one sees the flag cleared. */
    dispatch_sync(awdl_queue(), ^{
        if (__sync_bool_compare_and_swap(&g_awdl_suppressed, 1, 0)) {
            awdl_restore(YES);
            ip_log("AWDL restored");
        }
    });
}

- (void)showWifiSetupError:(NSString *)message {
    if (self.vc.presentedViewController) {
        self.pendingWifiSetupError = message;
        return;
    }
    self.pendingWifiSetupError = nil;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"Wi-Fi Setup")
        message:message preferredStyle:UIAlertControllerStyleAlert];
    /* Like every other modal here, closing it releases work held meanwhile. */
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:L(@"OK") style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *action) {
        [weakSelf settingsDidClose];
    }]];
    [self.vc presentViewController:alert animated:YES completion:nil];
}

- (NSString *)hotspotNameMismatchMessage:(NSString *)actualName {
    return [NSString stringWithFormat:L(@"This %1$@'s hotspot is called \u201c%2$@\u201d. Your iPhone joins the name you enter here, so it has to match. To use \u201c%3$@\u201d, rename the %1$@ in Settings > General > About > Name."),
            showcase_device_noun(), actualName, self.cars.apSSID];
}

- (void)pollAP {
    if (self.state != StateAwaitingAP) {
        [self.apPollTimer invalidate]; self.apPollTimer = nil;
        return;
    }
    if (!self.sharedWifiSession && is_ap_up()) {
        NSString *conf = [NSString stringWithContentsOfFile:@"/var/run/hostapd.conf"
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
        NSString *channel = @"unknown";
        NSString *liveSSID = nil, *livePassphrase = nil;
        for (NSString *line in [conf componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"channel="]) channel = [line substringFromIndex:8];
            else if ([line hasPrefix:@"ssid="]) liveSSID = [line substringFromIndex:5];
            else if ([line hasPrefix:@"wpa_passphrase="])
                livePassphrase = [line substringFromIndex:15];
        }
        /* carplay_bt hands the saved name and password to the iPhone. If the
         * running hotspot uses different ones the iPhone can never join and
         * the flow waits forever, so stop here with an actionable error. */
        NSString *mismatch = nil;
        if (liveSSID.length && ![liveSSID isEqualToString:self.cars.apSSID]) {
            ip_log("[HOTSPOT] running hotspot is '%s' but Showcase sends '%s'",
                   liveSSID.UTF8String, self.cars.apSSID.UTF8String);
            mismatch = [self hotspotNameMismatchMessage:liveSSID];
        } else if (livePassphrase.length &&
                   ![livePassphrase isEqualToString:self.cars.apPassword]) {
            ip_log("[HOTSPOT] running hotspot password differs from the saved one");
            mismatch = L(@"The Personal Hotspot password is different from the one saved in Showcase. Update the hotspot details and try again.");
        }
        if (mismatch) {
            [self.apPollTimer invalidate]; self.apPollTimer = nil;
            [self.hotspotWatchdog invalidate]; self.hotspotWatchdog = nil;
            [self failWith:@"hotspot credentials do not match the saved Wi-Fi details"];
            [self showWifiSetupError:mismatch];
            return;
        }
        ip_log("Wi-Fi network detected (%s); advancing", self.sharedWifiSession
               ? "shared router" : channel.UTF8String);
        [self.apPollTimer invalidate]; self.apPollTimer = nil;
        [self.hotspotWatchdog invalidate]; self.hotspotWatchdog = nil;
        [self transitionTo:StatePreparingBT];
        dispatch_async(self.bgQueue, ^{ [self bgPrepareBT]; });
    }
}

- (void)bgPrepareBT {
    if (flow_cancelled()) return;
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *btPath = [bundlePath stringByAppendingPathComponent:@BT_HELPER_NAME];
    NSString *carName = self.sessionCarName;
    ip_log("bgPrepareBT: euid=%u, name='%s' ssid='%s'",
           geteuid(), [carName UTF8String], [self.cars.apSSID UTF8String]);
    self.bluetoothRetryAttempted = NO;
    self.bluetoothRetryHelperSpawned = NO;
    /* Failure classification reads only what this flow writes. */
    self.btstackLogOffset = file_size_now(SHOWCASE_BTSTACK_LOG_PATH);
    unlink(LOG_DIR "/carplay_bt.log");
    unlink(LOG_DIR "/carplay_bt-retry.log");

    if (geteuid() != 0) {
        [self failBluetoothWithReason:
            @"The Showcase executable is not running as root (setuid setup failed)."
                             unsupported:NO];
        return;
    }
    if (access([btPath fileSystemRepresentation], X_OK) != 0) {
        [self failBluetoothWithReason:
            @"The bundled Bluetooth helper is missing or is not executable."
                             unsupported:NO];
        return;
    }
    if (access(BTDAEMON_PATH, X_OK) != 0) {
        [self failBluetoothWithReason:
            @"The BTstack daemon is missing or is not executable."
                             unsupported:NO];
        return;
    }
    if (access(BTSTACK_DYLIB_PATH, R_OK) != 0) {
        [self failBluetoothWithReason:
            @"The bundled BTstack library is missing or is not readable."
                             unsupported:NO];
        return;
    }
    if (access(BTSTACK_PLIST, R_OK) != 0) {
        [self failBluetoothWithReason:
            @"The BTstack launch daemon configuration is missing or unreadable."
                             unsupported:NO];
        return;
    }
    /* carplay_bt rejects these with exit 2 only after the controller has
     * been taken; check the same limits before touching Apple's Bluetooth. */
    NSUInteger ssidBytes =
        [self.cars.apSSID lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    NSUInteger passBytes =
        [self.cars.apPassword lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (ssidBytes == 0 || ssidBytes > 32 || passBytes < 8 || passBytes > 63) {
        [self failBluetoothWithReason:
            @"The saved Wi-Fi name or password is outside the Bluetooth helper's "
             "limits (name 1-32 bytes, password 8-63 bytes)."
                             unsupported:NO];
        return;
    }
#if !defined(SHOWCASE_TAURINE) && !defined(SHOWCASE_ROOTLESS)
    /* This package unloads bluetoothd before loading BTstack; on iOS 14
     * (Taurine) that order stalls launchd until a reboot (see the Taurine
     * branch below). Refuse before touching any launchd job; the failure
     * path shows the "Install Showcase for Taurine" message. */
    if (showcase_on_taurine()) {
        [self failBluetoothWithReason:
            @"This rootful package cannot take over Bluetooth on Taurine (iOS 14)."
                             unsupported:NO];
        return;
    }
#endif

    BluetoothRegistryProbeState registry = bluetooth_registry_probe();
    ip_log("[BT-COMPAT] registry probe=%s",
           registry == BluetoothRegistryProbeLegacyUART
               ? "legacy-uart-present"
               : (registry == BluetoothRegistryProbeSkywalk
                   ? "converged-skywalk-present"
                   : (registry == BluetoothRegistryProbeMissing
                       ? "supported-transport-missing" : "unavailable")));
    if (registry == BluetoothRegistryProbeMissing) {
        [self failBluetoothWithReason:
            @"The Bluetooth transport required by Showcase is not present in IOKit."
                             unsupported:YES];
        return;
    }
    if (registry == BluetoothRegistryProbeUnavailable) {
        /* A missing ioreg utility must not create a false rejection. The
         * controller takeover below is the authoritative runtime probe. */
        ip_log("[BT-COMPAT] static probe unavailable; continuing to runtime HCI probe");
    }

    if (self.diagnosticsEnabled) {
        enable_btstack_hci_logging();
    } else {
        disable_btstack_hci_logging();
    }
    self.helpersLoggedThisRun = self.diagnosticsEnabled;
    unlink(BT_READY_PATH);

    reap_stale_helpers_except(self.baaBrokerPid, self.baaRenewPid);

    const char *launchctl = launchctl_path();
    if (!launchctl) {
        [self failBluetoothWithReason:@"launchctl was not found."
                             unsupported:NO];
        return;
    }
    ip_log("launchctl path: %s", launchctl);
    if (!start_bluetooth_guard()) {
        [self failBluetoothWithReason:@"Bluetooth crash recovery could not start."
                             unsupported:NO];
        return;
    }
    if (flow_cancelled()) return;
#ifdef SHOWCASE_TAURINE
    /* 1. Start the bundled BTstack daemon while launchd still spawns jobs.
     * On iOS 14 (Taurine) unloading bluetoothd leaves the unload "in
     * progress" while mediaserverd and others retry the vanished Bluetooth
     * services; launchd then stops spawning anything, so an on-demand
     * BTdaemon would hang in xpcproxy and never answer. The daemon only
     * touches the UART when a client powers it on. */
    if (![self startBTstackDaemon:launchctl]) return;
    if (flow_cancelled()) return;

    /* 2. Release the UART: bluetoothd holds it (EBUSY) even with Bluetooth
     * off, and BlueTool owns it on iOS 14 and newer. */
    if (![self stopSystemBluetooth:launchctl]) return;
#else
    /* 1. Unload bluetoothd */
    NSString *guardProblem = bluetooth_guard_problem();
    if (guardProblem) {
        [self failBluetoothWithReason:guardProblem unsupported:NO];
        return;
    }
    char *unloadArgv[] = { (char*)"launchctl", (char*)"unload",
                           (char*)BLUETOOTHD_PLIST, NULL };
    int rc = run_blocking(launchctl, unloadArgv);
    if (rc != 0) ip_log("  WARNING: launchctl unload returned %d", rc);
    if (flow_cancelled()) return;
#ifdef SHOWCASE_ROOTLESS
    char *unloadBlueToolArgv[] = { (char*)"launchctl", (char*)"unload",
                                   (char*)BLUETOOL_PLIST, NULL };
    rc = run_blocking(launchctl, unloadBlueToolArgv);
    if (rc != 0) ip_log("  WARNING: BlueTool unload returned %d", rc);
    if (flow_cancelled()) return;
#endif
    sleep(2);

    if (flow_cancelled()) return;

    /* 2. Start bundled BTstack through launchd so the advertised socket exists. */
    char *unloadBTstackArgv[] = { (char*)"launchctl", (char*)"unload",
                                  (char*)BTSTACK_PLIST, NULL };
    run_blocking(launchctl, unloadBTstackArgv);
    unlink(BTSTACK_SOCKET);
    if (flow_cancelled()) return;

    char *loadBTstackArgv[] = { (char*)"launchctl", (char*)"load",
                                (char*)BTSTACK_PLIST, NULL };
    /* The sleep above is where a backgrounded flow is suspended. */
    guardProblem = bluetooth_guard_problem();
    if (guardProblem) {
        [self failBluetoothWithReason:guardProblem unsupported:NO];
        return;
    }
    rc = run_blocking(launchctl, loadBTstackArgv);
    if (rc != 0) {
        [self failBluetoothWithReason:
            @"The BTstack launch daemon failed to load."
                             unsupported:NO];
        return;
    }
    if (!wait_for_path(BTSTACK_SOCKET, 8, "BTstack socket")) {
        [self failBluetoothWithReason:
            @"The BTstack daemon did not create its control socket."
                             unsupported:NO];
        return;
    }
    self.btdaemonPid = 0;
#endif

    if (flow_cancelled()) return;

    /* 3. Spawn carplay_bt with car name + global AP creds */
    char nameBuf[64], ssidBuf[128], passBuf[128];
    snprintf(nameBuf, sizeof(nameBuf), "%s", [carName UTF8String]);
    snprintf(ssidBuf, sizeof(ssidBuf), "%s", [self.cars.apSSID UTF8String]);
    snprintf(passBuf, sizeof(passBuf), "%s", [self.cars.apPassword UTF8String]);
    char *btArgv[] = {
        (char*)BT_HELPER_NAME,
        (char*)"--name", nameBuf,
        (char*)"--ssid", ssidBuf,
        (char*)"--pass", passBuf,
        NULL
    };
    self.carplayBtPid = spawn_daemon([btPath UTF8String], btArgv,
                                     LOG_DIR "/carplay_bt.log");
    if (self.carplayBtPid <= 0) {
        [self failBluetoothWithReason:
            @"The Bluetooth helper could not be started."
                             unsupported:NO];
        return;
    }
    pid_t btChild = self.carplayBtPid;
    int btExit = -1;
    BOOL ready = wait_for_bt_ready_or_exit(&btChild, BT_READY_SECONDS, &btExit);
    self.carplayBtPid = btChild;
    if (!ready) {
        if (flow_cancelled()) return;
        /* These exits do not depend on the controller, so resetting Apple's
         * Bluetooth and running the helper again would fail the same way. */
        if (btExit == 2) {
            [self failBluetoothWithReason:
                @"The Bluetooth helper rejected its arguments (car name or Wi-Fi details)."
                                 unsupported:NO];
            return;
        }
        if (btExit == 1 && [bounded_log_tail(@LOG_DIR "/carplay_bt.log", 8192, 40)
                containsString:@"FATAL: No BAA cert"]) {
            [self failBluetoothWithReason:
                @"The Bluetooth helper received no BAA certificate from the broker."
                                 unsupported:NO];
            return;
        }
        /* On some rootless boots BlueTool releases the controller after its
         * launchd job has already exited. BTstack then accepts a client and
         * its power command, but emits no HCI events. A complete daemon/client
         * restart is deterministic and preserves pairing data. */
        ip_log("[BT] first controller takeover produced no events; "
               "performing one clean retry");
        self.bluetoothRetryAttempted = YES;
        kill_child(self.carplayBtPid);
        self.carplayBtPid = 0;
#ifdef SHOWCASE_TAURINE
        /* The stalled BTdaemon still holds the UART. bluetoothd loaded on a
         * busy UART stays broken, and load_bluetooth_job (here and in
         * restore_system_bluetooth) would count it as healthy, so the daemon
         * has to be gone first — the same order resetSystemBluetoothForRetry
         * and hand_back_system_bluetooth take. */
        char *unloadBTstackRetryArgv[] = { (char*)"launchctl", (char*)"unload",
                                           (char*)BTSTACK_PLIST, NULL };
        run_blocking(launchctl, unloadBTstackRetryArgv);
        unlink(BTSTACK_SOCKET);
        signal_processes_named("BTdaemon", SIGKILL, 0);
        for (int i = 0; i < 50 && process_named_running("BTdaemon"); i++) {
            if (flow_cancelled()) return;
            usleep(100000);
        }
        if (process_named_running("BTdaemon")) {
            if (access(BT_GUARD_READY, F_OK) == 0) {
                int fd = open(BT_GUARD_RESTORE, O_WRONLY | O_CREAT | O_NOFOLLOW, 0600);
                if (fd >= 0) close(fd);
            }
            ip_log("[BT] retry: BTdaemon did not exit; system Bluetooth "
                   "left to the recovery guard");
            [self failBluetoothWithReason:
                @"Apple Bluetooth could not be restored for retry."
                             unsupported:NO];
            return;
        }
        /* Bring Apple's Bluetooth back first so launchd can spawn the
         * daemon again. Some devices ship no BlueTool job at all
         * (restore_system_bluetooth and the recovery guard skip it too). */
        BOOL hasBlueTool = !(access(BLUETOOL_PLIST, F_OK) != 0 && errno == ENOENT);
        if ((hasBlueTool &&
             !load_bluetooth_job(launchctl, BLUETOOL_PLIST, BLUETOOL_LABEL)) ||
            !load_bluetooth_job(launchctl, BLUETOOTHD_PLIST, BLUETOOTHD_LABEL)) {
            [self failBluetoothWithReason:@"Apple Bluetooth could not be restored for retry."
                             unsupported:NO];
            return;
        }
        unlink(BT_OWNED_FLAG);
        if (flow_cancelled()) return;
        sleep(2);
        if (flow_cancelled()) return;
        self.btstackLogOffset = file_size_now(SHOWCASE_BTSTACK_LOG_PATH);
        if (![self startBTstackDaemon:launchctl] ||
            ![self stopSystemBluetooth:launchctl] || flow_cancelled()) return;
        unlink(BT_READY_PATH);
        unlink(LOG_DIR "/carplay_bt-retry.log");
        self.carplayBtPid = spawn_daemon([btPath UTF8String], btArgv,
                                         LOG_DIR "/carplay_bt-retry.log");
        self.bluetoothRetryHelperSpawned = self.carplayBtPid > 0;
#else
        /* A takeover that stalls inside the daemon's BlueTool hand-off leaves
         * Apple's Bluetooth half unloaded: the daemon stopped BlueTool but
         * never brought it back, and bluetoothd is still gone. Reloading only
         * the BTstack job walks straight into the same wedge — which is what
         * this retry used to do, so it failed identically to the first try.
         * The retry has to hand the UART back to Apple, wait for the stale
         * processes to really disappear, and then take it over again. */
        guardProblem = bluetooth_guard_problem();
        if (guardProblem) {
            [self failBluetoothWithReason:guardProblem unsupported:NO];
            return;
        }
        if (![self resetSystemBluetoothForRetry:launchctl]) {
            guardProblem = bluetooth_guard_problem();
            [self failBluetoothWithReason:guardProblem ?:
                @"Apple Bluetooth could not be reset before the retry."
                             unsupported:NO];
            return;
        }
        if (flow_cancelled()) return;
        run_blocking(launchctl, unloadBTstackArgv);
        unlink(BTSTACK_SOCKET);
        sleep(2);
        if (flow_cancelled()) return;
        guardProblem = bluetooth_guard_problem();
        if (guardProblem) {
            [self failBluetoothWithReason:guardProblem unsupported:NO];
            return;
        }
        self.btstackLogOffset = file_size_now(SHOWCASE_BTSTACK_LOG_PATH);
        rc = run_blocking(launchctl, loadBTstackArgv);
        if (rc != 0) {
            [self failBluetoothWithReason:
                @"The BTstack launch daemon failed to load."
                                 unsupported:NO];
            return;
        }
        if (!wait_for_path(BTSTACK_SOCKET, 8, "BTstack retry socket")) {
            [self failBluetoothWithReason:
                @"The BTstack daemon did not create its control socket."
                                 unsupported:NO];
            return;
        }
        unlink(BT_READY_PATH);
        unlink(LOG_DIR "/carplay_bt-retry.log");
        self.carplayBtPid =
            spawn_daemon([btPath UTF8String], btArgv,
                         LOG_DIR "/carplay_bt-retry.log");
        self.bluetoothRetryHelperSpawned = self.carplayBtPid > 0;
#endif
        /* Both retry paths: a helper that never ran is not an HCI stall. */
        if (self.carplayBtPid <= 0) {
            [self failBluetoothWithReason:
                @"The Bluetooth helper could not be started."
                                 unsupported:NO];
            return;
        }
        btChild = self.carplayBtPid;
        btExit = -1;
        ready = btChild > 0 &&
            wait_for_bt_ready_or_exit(&btChild, BT_RETRY_READY_SECONDS, &btExit);
        self.carplayBtPid = btChild;
        if (!ready) {
            if (flow_cancelled()) return;
            /* A stalled hand-off says nothing about the hardware, so this is a
             * setup failure unless the helper and daemon logs show the
             * controller itself refusing; failBluetoothWithReason classifies
             * those from the logs. */
            NSString *reason = btExit == 62
                ? @"Bluetooth takeover failed after one clean retry; the "
                   "controller reported a power-on failure."
                : btExit == 63
                ? @"Bluetooth takeover failed after one clean retry; the "
                   "BTstack daemon stopped (connection closed or controller "
                   "powered off)."
                : (btExit >= 0
                    ? [NSString stringWithFormat:
                        @"Bluetooth takeover failed after one clean retry; the "
                         "helper exited with status %d.", btExit]
                    : @"Bluetooth takeover failed after one clean retry; no HCI "
                       "controller-ready event was received.");
            [self failBluetoothWithReason:reason unsupported:NO];
            return;
        }
    }

    if (flow_cancelled()) return;
    [self transitionTo:StatePreparingNet];
    [self bgPrepareNet];
}

#ifdef SHOWCASE_TAURINE
- (BOOL)startBTstackDaemon:(const char *)launchctl {
    char *unloadBTstackArgv[] = { (char*)"launchctl", (char*)"unload",
                                  (char*)BTSTACK_PLIST, NULL };
    char *loadBTstackArgv[] = { (char*)"launchctl", (char*)"load",
                                (char*)BTSTACK_PLIST, NULL };
    char *startBTstackArgv[] = { (char*)"launchctl", (char*)"start",
                                 (char*)"ch.ringwald.BTstack", NULL };
    run_blocking(launchctl, unloadBTstackArgv);
    if (flow_cancelled()) return NO;
    signal_processes_named("BTdaemon", SIGKILL, 0);
    unlink(BTSTACK_SOCKET);
    if (run_blocking(launchctl, loadBTstackArgv) != 0) {
        [self failBluetoothWithReason:
            @"The BTstack launch daemon failed to load."
                             unsupported:NO];
        return NO;
    }
    if (!wait_for_path(BTSTACK_SOCKET, 8, "BTstack socket")) {
        [self failBluetoothWithReason:
            @"The BTstack daemon did not create its control socket."
                             unsupported:NO];
        return NO;
    }
    run_blocking(launchctl, startBTstackArgv);
    for (int i = 0; i < 50 && !flow_cancelled() && !process_named_running("BTdaemon"); i++)
        usleep(100000);
    if (flow_cancelled()) return NO;
    if (!process_named_running("BTdaemon")) {
        [self failBluetoothWithReason:
            @"The BTstack daemon did not start."
                             unsupported:NO];
        return NO;
    }
    ip_log("[BT] BTdaemon running before system Bluetooth stops");
    self.btdaemonPid = 0;
    return YES;
}

- (BOOL)stopSystemBluetooth:(const char *)launchctl {
    if (flow_cancelled()) return NO;
    NSString *guardProblem = bluetooth_guard_problem();
    if (guardProblem) {
        [self failBluetoothWithReason:guardProblem unsupported:NO];
        return NO;
    }
    int flag = open(BT_OWNED_FLAG, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (flag < 0) {
        [self failBluetoothWithReason:@"Bluetooth ownership marker could not be created."
                         unsupported:NO];
        return NO;
    }
    close(flag);
    char *unloadArgv[] = { (char*)"launchctl", (char*)"unload",
                           (char*)BLUETOOTHD_PLIST, NULL };
    int rc = run_blocking(launchctl, unloadArgv);
    if (rc != 0) ip_log("  WARNING: launchctl unload returned %d", rc);
    if (flow_cancelled()) return NO;
    char *unloadBlueToolArgv[] = { (char*)"launchctl", (char*)"unload",
                                   (char*)BLUETOOL_PLIST, NULL };
    rc = run_blocking(launchctl, unloadBlueToolArgv);
    if (rc != 0) ip_log("  WARNING: BlueTool unload returned %d", rc);
    if (flow_cancelled()) return NO;
    /* An unload can stay in progress; make sure the UART is free. */
    signal_processes_named("bluetoothd", SIGKILL, 0);
    signal_processes_named("BlueTool", SIGKILL, 0);
    sleep(2);
    return !flow_cancelled();
}
#endif

/* Apple's Bluetooth is left half unloaded when the daemon's iphone_on() stalls
 * after "unload BTServer": BlueTool is down and never comes back, bluetoothd is
 * still gone, and the controller is owned by nobody. Restarting the daemon
 * alone cannot fix that. This puts launchd's Bluetooth jobs back, lets them
 * settle, and then releases the UART again the way the first takeover does —
 * so the retry starts from a complete state instead of the broken one.
 *
 * Only the retry calls this; a healthy start never pays for it. */
- (BOOL)resetSystemBluetoothForRetry:(const char *)launchctl {
    char *unloadBlueToolArgv[] = { (char*)"launchctl", (char*)"unload",
                                   (char*)BLUETOOL_PLIST, NULL };
    char *unloadBluetoothdArgv[] = { (char*)"launchctl", (char*)"unload",
                                     (char*)BLUETOOTHD_PLIST, NULL };
    char *unloadBTstackArgv[] = { (char*)"launchctl", (char*)"unload",
                                  (char*)BTSTACK_PLIST, NULL };
    /* Some devices ship no BlueTool job at all (restore_system_bluetooth and
     * the recovery guard skip it too); only bluetoothd is managed there. */
    BOOL hasBlueTool = !(access(BLUETOOL_PLIST, F_OK) != 0 && errno == ENOENT);
    /* Whatever is stuck is holding the UART, so it has to go first: a daemon
     * still blocked in its BlueTool pipe keeps the port busy even after its
     * launchd job is unloaded. Unload its job so launchd does not respawn it,
     * and see it really gone (as hand_back_system_bluetooth does) before
     * Apple's jobs are reloaded: bluetoothd started on a busy UART stays
     * broken, and load_bluetooth_job would later count it as healthy. */
    run_blocking(launchctl, unloadBTstackArgv);
    unlink(BTSTACK_SOCKET);
    signal_processes_named("BTdaemon", SIGKILL, 0);
    for (int i = 0; i < 50 && process_named_running("BTdaemon"); i++) {
        if (flow_cancelled()) return NO;
        usleep(100000);
    }
    if (process_named_running("BTdaemon")) {
        if (access(BT_GUARD_READY, F_OK) == 0) {
            int fd = open(BT_GUARD_RESTORE, O_WRONLY | O_CREAT | O_NOFOLLOW, 0600);
            if (fd >= 0) close(fd);
        }
        ip_log("[BT] retry reset: BTdaemon did not exit; system Bluetooth "
               "left to the recovery guard");
        return NO;
    }
    if (hasBlueTool) run_blocking(launchctl, unloadBlueToolArgv);
    run_blocking(launchctl, unloadBluetoothdArgv);
    if (flow_cancelled()) return NO;
    /* An unload can stay "in progress" while the process is still alive. */
    if (hasBlueTool) signal_processes_named("BlueTool", SIGKILL, 0);
    signal_processes_named("bluetoothd", SIGKILL, 0);
    for (int i = 0; i < 50; i++) {
        if (flow_cancelled()) return NO;
        if (!process_named_running("BlueTool") &&
            !process_named_running("bluetoothd")) break;
        usleep(100000);
    }
    if (process_named_running("BlueTool") ||
        process_named_running("bluetoothd")) {
        ip_log("[BT] retry reset: Apple Bluetooth processes did not exit");
        return NO;
    }
    if ((hasBlueTool &&
         !load_bluetooth_job(launchctl, BLUETOOL_PLIST, BLUETOOL_LABEL)) ||
        !load_bluetooth_job(launchctl, BLUETOOTHD_PLIST, BLUETOOTHD_LABEL)) {
        ip_log("[BT] retry reset: Apple Bluetooth jobs could not be reloaded");
        return NO;
    }
    sleep(2);
    if (flow_cancelled()) return NO;
    /* Apple's Bluetooth is back; take it again only under an armed guard. */
    NSString *guardProblem = bluetooth_guard_problem();
    if (guardProblem) {
        ip_log("[BT] retry reset: %s", [guardProblem UTF8String]);
        return NO;
    }
    int rc = run_blocking(launchctl, unloadBluetoothdArgv);
    if (rc != 0) ip_log("  WARNING: retry bluetoothd unload returned %d", rc);
    signal_processes_named("bluetoothd", SIGKILL, 0);
#ifdef SHOWCASE_ROOTLESS
    /* The rootless daemon never touches BlueTool, so the first takeover
     * unloads it explicitly; the retry has to release it the same way or the
     * reloaded BlueTool keeps the UART and the second takeover stalls too. */
    if (hasBlueTool) {
        rc = run_blocking(launchctl, unloadBlueToolArgv);
        if (rc != 0) ip_log("  WARNING: retry BlueTool unload returned %d", rc);
        signal_processes_named("BlueTool", SIGKILL, 0);
    }
#endif
    for (int i = 0; i < 50; i++) {
        if (flow_cancelled()) return NO;
        if (!process_named_running("bluetoothd")
#ifdef SHOWCASE_ROOTLESS
            && !process_named_running("BlueTool")
#endif
            ) break;
        usleep(100000);
    }
    if (process_named_running("bluetoothd")
#ifdef SHOWCASE_ROOTLESS
        || process_named_running("BlueTool")
#endif
        ) {
        ip_log("[BT] retry reset: Apple Bluetooth did not release the UART");
        return NO;
    }
    sleep(2);
    ip_log("[BT] retry reset: Apple Bluetooth released, taking over again");
    return !flow_cancelled();
}

- (void)bgPrepareNet {
    if (flow_cancelled()) return;
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *svcPath = [bundlePath stringByAppendingPathComponent:@SVC_HELPER_NAME];
    NSString *carName = self.sessionCarName;
    ip_log("bgPrepareNet");

    self.ipcDone = dispatch_semaphore_create(0);
    if (![self startIPCListener]) { self.ipcDone = nil; [self failServicesSetupWith:@"IPC listener failed"]; return; }
    if (flow_cancelled()) return;

    char nameBuf[64];
    char widthBuf[16], heightBuf[16], fpsBuf[16], receiveBufferBuf[16];
    CarPlayVideoPriority priority = carplay_video_priority();
    BOOL receiverAudio = [[NSUserDefaults standardUserDefaults]
        boolForKey:RECEIVER_AUDIO_KEY];
    BOOL rightHandDrive = [[NSUserDefaults standardUserDefaults]
        boolForKey:RIGHT_HAND_DRIVE_KEY];
    CarPlayDisplayProfile display =
        preferred_carplay_display_profile();
    uint16_t displayWidth = display.width;
    uint16_t displayHeight = display.height;
    /*
     * The TCP receive window bounds how much screen data the iPhone may have
     * in flight, and so how large a burst reaches this radio at once.
     *
     * HSIC-attached Broadcom chips post a small pool of host receive buffers
     * across a USB-class bus. A burst larger than that pool is acknowledged
     * over the air and then discarded inside the chip ("Rx Out Of Buffers"),
     * so the 802.11 layer never retries it and TCP must recover the hole.
     * Measured on an iPad4,2 with a CarPlay-shaped stream (30 fps, 40 KB
     * frames, 200 KB keyframes): 2 MiB window 6-7% of frames discarded,
     * 512 KiB 2-4%, 256 KiB 2-3%, 128 KiB 0.4-0.8%, 64 KiB 0.2% but with
     * window-limited delivery. The same test on a PCIe iPhone9,3 discarded
     * nothing at any window. The old 2 MiB "headroom" also let seconds of
     * video queue in flight (smoothed RTT 1.4-2.5 s in July captures), which
     * is what made the sender's screen sink skip frames.
     *
     * Apple's receiver sizes this socket at 110% of a 160 KiB frame. Use that
     * everywhere, and 128 KiB on HSIC where the bus is the bottleneck.
     */
    int screenReceiveBuffer =
        display.wlanAttachment == CarPlayWLANAttachmentHSIC
            ? 128 * 1024
            : (110 * 160 * 1024) / 100;
    snprintf(nameBuf, sizeof(nameBuf), "%s", [carName UTF8String]);
    snprintf(widthBuf, sizeof(widthBuf), "%u", displayWidth);
    snprintf(heightBuf, sizeof(heightBuf), "%u", displayHeight);
    snprintf(fpsBuf, sizeof(fpsBuf), "%u", display.framesPerSecond);
    snprintf(receiveBufferBuf, sizeof(receiveBufferBuf), "%d",
             screenReceiveBuffer);
    ip_log("display profile: native=%ux%u memory=%lluMB cores=%lu "
           "budget=%llu pixels selected=%ux%u@%u wlan=%s rcvbuf=%d "
           "priority=%s audio=%s dock=%s",
           display.nativeLong, display.nativeShort,
           (unsigned long long)(display.physicalMemory / (1024ULL * 1024ULL)),
           (unsigned long)display.activeProcessors,
           (unsigned long long)display.pixelBudget,
           displayWidth, displayHeight, display.framesPerSecond,
           carplay_wlan_attachment_name(display.wlanAttachment),
           screenReceiveBuffer,
           priority == CarPlayVideoQuality ? "quality"
               : (priority == CarPlayVideoPerformance ? "performance" : "custom"),
           receiverAudio ? "receiver" : "sender",
           rightHandDrive ? "right" : "left");
    char *svcArgv[] = {
        (char*)SVC_HELPER_NAME,
        (char*)"--name", nameBuf,
        (char*)"--width", widthBuf,
        (char*)"--height", heightBuf,
        (char*)"--fps", fpsBuf,
        (char*)"--screen-rcvbuf", receiveBufferBuf,
        (char*)"--audio", (char*)(receiverAudio ? "receiver" : "sender"),
        self.sharedWifiSession ? (char*)"--wifi-interface" : (char*)"--hotspot-wifi",
        self.sharedWifiSession ? (char*)[self.sharedWifiInterface UTF8String] : (char*)"bridge100",
        rightHandDrive ? (char*)"--right-hand-drive" : NULL,
        NULL
    };
    /*
     * The service log is the only record of encrypted RTSP negotiation and
     * transport arrival. Keep it for every run; spawn_daemon truncates the
     * file at launch, so this has bounded storage cost and cannot silently
     * erase the evidence needed to diagnose a failed session.
     */
    self.carplayServicesPid = spawn_daemon(
        [svcPath UTF8String], svcArgv, LOG_DIR "/carplay_services.log");
    if (self.carplayServicesPid <= 0) { [self failServicesSetupWith:@"carplay_services failed to start"]; return; }
    pid_t servicesChild = self.carplayServicesPid;
    BOOL servicesAlive = wait_for_pid_alive(&servicesChild, 4, "carplay_services");
    self.carplayServicesPid = servicesChild;
    if (!servicesAlive) {
        [self failServicesSetupWith:@"carplay_services exited during setup"];
        return;
    }

    /* A paired phone can resume quickly enough to deliver video while the
     * helper-alive check above is still running. Do not overwrite Active
     * with the older setup state when that happens. */
    [self transitionTo:StateAwaitingPhone];
    if (!flow_cancelled()) [self monitorFlowHelpers];
}

- (void)monitorFlowHelpers {
    uint32_t epoch = flow_epoch();
    dispatch_source_t monitor = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.bgQueue);
    if (!monitor) return;
    self.helperMonitor = monitor;
    dispatch_source_set_timer(monitor, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(monitor, ^{
        if (flow_cancelled() || epoch != flow_epoch()) return;
        BOOL servicesExited = self.carplayServicesPid > 0 && !child_alive(self.carplayServicesPid);
        BOOL bluetoothExited = self.carplayBtPid > 0 && !child_alive(self.carplayBtPid);
        if (servicesExited) self.carplayServicesPid = 0;
        if (bluetoothExited) self.carplayBtPid = 0;
        if (!servicesExited && !bluetoothExited) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (flow_cancelled() || epoch != flow_epoch()) return;
            if (!servicesExited && self.state == StateActive) {
                /* The session survives on Wi-Fi, but the Bluetooth helper
                 * no longer owns the controller: give it back to iOS now,
                 * as completeBluetoothHandoff would, instead of leaving
                 * bluetoothd unloaded until the session ends. */
                [self handBackBluetoothAfterHelperExit];
                return;
            }
            ip_log("[SESSION] %s helper exited", servicesExited ? "services" : "Bluetooth");
            if (self.state == StateActive) self.restartAfterStop = YES;
            [self stopFlow];
        });
    });
    dispatch_resume(monitor);
}

- (void)handBackBluetoothAfterHelperExit {
    uint32_t epoch = flow_epoch();
    dispatch_async(self.bgQueue, ^{
        if (flow_cancelled() || epoch != flow_epoch() ||
            self.bluetoothHandedOff || self.state != StateActive) {
            return;
        }
        ip_log("[SESSION] Bluetooth helper exited during Active session; handing Bluetooth back");
        self.bluetoothHandBackInProgress = YES;
        self.bluetoothHandedOff = YES;
        BOOL restored = hand_back_system_bluetooth("Bluetooth helper exited during session");
        self.bluetoothHandBackInProgress = NO;
        ip_log("[SESSION] System Bluetooth %s",
               restored ? "restored" : "left to the recovery guard");
    });
}

- (void)completeBluetoothHandoff {
    /* A hand-off queued by a session that has since stopped must not tear
     * down, or mark as handed off, the session started after it. */
    uint32_t epoch = flow_epoch();
    dispatch_async(self.bgQueue, ^{
        if (flow_cancelled() || epoch != flow_epoch() ||
            self.bluetoothHandedOff ||
            self.state == StateStopping || self.state == StateIdle) {
            return;
        }

        /*
         * The controller has completed Bluetooth discovery and moved the
         * CarPlay session onto Wi-Fi. Own teardown here, outside BTstack's
         * callback and signal contexts. Leaving BTstack active forces the
         * combo radio to arbitrate 2.4 GHz airtime while the H.264 TCP stream
         * is running, which turns individual Wi-Fi losses into visible
         * head-of-line stalls.
         */
        ip_log("[HANDOFF] Wi-Fi session established; stopping Bluetooth helper");
        kill_child(self.carplayBtPid);
        self.carplayBtPid = 0;

        self.bluetoothHandBackInProgress = YES;
        self.bluetoothHandedOff = YES;
        /* The session now runs over Wi-Fi alone. Leaving bluetoothd unloaded
         * would keep launchd and mediaserverd busy for the whole session,
         * about one core of a two-core receiver. */
        BOOL restored = hand_back_system_bluetooth("Wi-Fi handoff complete");
        self.bluetoothHandBackInProgress = NO;
        ip_log("[HANDOFF] Bluetooth transport stopped (system Bluetooth %s)",
               restored ? "restored" : "left to the recovery guard");
    });
}

/* shutdown() on a listening AF_UNIX socket is not portable to Darwin.
 * A local connection wakes accept; cancellation makes the loop discard it. */
static void wake_ipc_listener(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return;
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCK_PATH, sizeof(addr.sun_path) - 1);
    (void)connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    close(fd);
}

- (void)stopFlow {
    if (![NSThread isMainThread]) {
        uint32_t epoch = flow_epoch();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (epoch == flow_epoch()) [self stopFlow];
        });
        return;
    }
    if (self.state == StateStopping || self.state == StateIdle) {
        /* The session's own restart paths only stop an Active or connecting
         * flow, so a stop arriving here is an explicit one (the car's power
         * going off, the user): it cancels any start still waiting for the
         * teardown, the broker preheat or a closing modal. */
        if (self.restartAfterStop || self.pendingUserStart || self.automaticStartRequested)
            ip_log("[SESSION] stop requested; cancelling the pending restart");
        self.restartAfterStop = NO;
        self.pendingUserStart = NO;
        self.automaticStartRequested = NO;
        self.autoStartNetworkDeadline = 0;
        return;
    }
    self.showFarewell = self.state == StateActive && !self.restartAfterStop &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    BOOL farewell = self.showFarewell;   /* read once; the teardown runs off the main thread */
    uint64_t farewellEnd = monotonic_nanos_now() + (farewell ? 2750 * NSEC_PER_MSEC : 0);
#if SHOWCASE_MIRROR_BENCH
    [self.screenMirror finish];
#endif
    [self clearCarVideo];
    @synchronized (self) {
        __atomic_store_n(&g_flow_cancelled, true, __ATOMIC_RELEASE);
        __atomic_add_fetch(&g_flow_epoch, 1, __ATOMIC_ACQ_REL);
    }
    [self endAWDLSuppression];
    [self stopNetworkDumpCaptureWithReason:@"user cancelled / stopping flow"];
    /* Background time, if held, ends in checkBackgroundBluetooth once the
     * teardown below has handed Bluetooth back. */
    [self.apPollTimer invalidate]; self.apPollTimer = nil;
    [self.hotspotWatchdog invalidate]; self.hotspotWatchdog = nil;
    [self.discoveryTimer invalidate]; self.discoveryTimer = nil;
    [self transitionTo:StateStopping];
    dispatch_async(self.bgQueue, ^{
        pthread_mutex_lock(&g_ipc_lock);
        if (self.clientFd >= 0) shutdown(self.clientFd, SHUT_RDWR);
        BOOL wakeListener = self.listenFd >= 0;
        g_touch_fd = -1;
        ++g_touch_epoch;
        pthread_mutex_unlock(&g_ipc_lock);
        if (wakeListener) wake_ipc_listener();
        g_carplay_w = 0; g_carplay_h = 0;
        g_video_suspended = 0;
        g_video_needs_resync = 0;

        if (self.helperMonitor) {
            dispatch_source_cancel(self.helperMonitor);
            self.helperMonitor = nil;
        }
        kill_child(self.carplayServicesPid); self.carplayServicesPid = 0;
        kill_child(self.carplayBtPid);       self.carplayBtPid = 0;
        if (self.ipcDone) {
            dispatch_semaphore_wait(self.ipcDone, DISPATCH_TIME_FOREVER);
            self.ipcDone = nil;
        }
        unlink(SOCK_PATH);
        self.btdaemonPid = 0;
        self.bluetoothHandedOff = NO;

        hand_back_system_bluetooth("CarPlay stopped");
        if ([[NSUserDefaults standardUserDefaults] boolForKey:HOTSPOT_OWNED_KEY]) {
            showcase_set_hotspot_discovery(NO);
            showcase_set_hotspot(NO);
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:HOTSPOT_OWNED_KEY];
            ip_log("[HOTSPOT] turned off the hotspot Showcase started");
        }
        if (!self.sharedWifiSession)
            showcase_release_other_wifi("CarPlay stopped");

        /* The farewell is meant to arrive over the last CarPlay frame, so the
         * wipe waits for the hand-back instead of blanking the picture the
         * scene is scaling in over. Without a farewell there is nothing to
         * hold it for. */
        if (!farewell) {
            dispatch_async(dispatch_get_main_queue(), ^{
                AVSampleBufferDisplayLayer *layer = (AVSampleBufferDisplayLayer *)self.videoView.layer;
                [layer flushAndRemoveImage];
            });
        }

        uint64_t now = monotonic_nanos_now();
        int64_t remaining = farewellEnd > now ? (int64_t)(farewellEnd - now) : 0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, remaining), dispatch_get_main_queue(), ^{
            if (farewell) {
                AVSampleBufferDisplayLayer *layer = (AVSampleBufferDisplayLayer *)self.videoView.layer;
                [layer flushAndRemoveImage];
            }
            [self finishFarewellWithCompletion:^{
                [self presentPendingBluetoothCompatibilityError];
                [self presentPendingServicesSetupError];
                /* Its preheat resumes a pending restart once it is ready. */
                if (self.baaReplaceDeferred && self.state == StateIdle &&
                    !self.baaReady) {
                    self.baaReplaceDeferred = NO;
                    [self prepareBAA];
                }
                [self resumePendingRestart];
            }];
        });
    });
}

- (void)resumePendingRestart {
    /* A broker restarted here keeps restartAfterStop set; its preheat comes
     * back through this method once the certificate is ready again. */
    if (self.restartAfterStop && self.state == StateIdle && self.baaReady &&
        !self.vc.presentedViewController && [self baaBrokerStillReady]) {
        self.automaticStartRequested = YES;
        [self startFlow];
    }
}

- (void)failBluetoothWithReason:(NSString *)reason
                    unsupported:(BOOL)unsupported {
    uint32_t epoch = flow_epoch();
    if (flow_cancelled()) return;
    BluetoothRegistryProbeState registry = bluetooth_registry_probe();
    NSString *failureClass = nil;
    NSString *report = bluetooth_diagnostic_report(
        reason, self.bluetoothRetryAttempted,
        self.bluetoothRetryHelperSpawned, self.btstackLogOffset,
        registry, &failureClass);
    ip_log("[BT-COMPAT] failure class=%s reason=%s\n%s",
           [failureClass UTF8String], [reason UTF8String],
           [report UTF8String]);
    /* Once the clean retry helper has really run too, a failure its own logs
     * pin on the controller (no skywalk API, UART ioctl refused) is a hardware
     * limit; reinstalling would not help. A retry whose reset or daemon setup
     * failed proves nothing about the hardware. */
    if (!unsupported && self.bluetoothRetryHelperSpawned &&
        bluetooth_failure_class_is_unsupported(failureClass)) {
        unsupported = YES;
    }

    /* Only raw flags here: L() is not safe off the main thread, so the text
     * is built in the main-queue block below. */
    BOOL taurine = NO;
#if !defined(SHOWCASE_TAURINE) && !defined(SHOWCASE_ROOTLESS)
    /* Taurine on iOS 14 needs its own package's Bluetooth takeover. */
    taurine = showcase_on_taurine();
#endif
    dispatch_async(dispatch_get_main_queue(), ^{
        if (flow_cancelled() || epoch != flow_epoch()) return;
        NSString *title = unsupported
            ? L(@"Bluetooth Hardware Not Supported")
            : L(@"Bluetooth Setup Failed");
        NSString *explanation = unsupported
            ? L(@"Showcase could not take over this device's Bluetooth controller. "
              "Tell the developer or community that this model is not yet supported "
              "and include the diagnostic below.")
            : L(@"Showcase's Bluetooth components are incomplete or could not start. "
              "Copy the diagnostic below before reinstalling or reporting the problem.");
        if (taurine) {
            title = L(@"Install Showcase for Taurine");
            explanation =
                L(@"This device runs Taurine, which needs a different Bluetooth setup. "
                 "Install Showcase for Taurine from the same repository; it replaces this package.");
        }
        self.pendingBluetoothErrorTitle = title;
        self.pendingBluetoothErrorExplanation = explanation;
        self.pendingBluetoothDiagnostic = report;
        [self stopFlow];
    });
}

- (void)presentPendingBluetoothCompatibilityError {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentPendingBluetoothCompatibilityError];
        });
        return;
    }
    if (!self.pendingBluetoothDiagnostic.length ||
        [UIApplication sharedApplication].applicationState !=
            UIApplicationStateActive ||
        self.vc.presentedViewController) {
        return;
    }

    CompatibilityErrorViewController *error =
        [[CompatibilityErrorViewController alloc] init];
    error.errorTitle = self.pendingBluetoothErrorTitle;
    error.explanation = self.pendingBluetoothErrorExplanation;
    error.diagnostic = self.pendingBluetoothDiagnostic;
    __weak typeof(self) weakSelf = self;
    error.onClose = ^{ [weakSelf settingsDidClose]; };
    error.modalPresentationStyle = UIModalPresentationOverFullScreen;
    error.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;

    self.pendingBluetoothErrorTitle = nil;
    self.pendingBluetoothErrorExplanation = nil;
    self.pendingBluetoothDiagnostic = nil;
    [self.vc presentViewController:error animated:YES completion:nil];
}

- (void)failWith:(NSString *)reason {
    if (flow_cancelled()) return;
    ip_log("FAIL: %s", [reason UTF8String]);
    [self stopFlow];
}

/* A setup failure of Showcase's own helpers (IPC socket, carplay_services).
 * Unlike the Bluetooth and hotspot failures it has no screen of its own, so
 * the reason is kept for presentPendingServicesSetupError once the stop has
 * returned to Idle. The flag is set on the main thread, for this flow only. */
- (void)failServicesSetupWith:(NSString *)reason {
    uint32_t epoch = flow_epoch();
    if (flow_cancelled()) return;
    ip_log("FAIL: %s", [reason UTF8String]);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (flow_cancelled() || epoch != flow_epoch()) return;
        self.pendingServicesSetupError = YES;
        [self stopFlow];
    });
}

- (void)openHotspotSettings {
    NSURL *u = [NSURL URLWithString:@"App-Prefs:root=INTERNET_TETHERING"];
    UIApplication *a = [UIApplication sharedApplication];
    if ([a canOpenURL:u]) {
        [a openURL:u options:@{} completionHandler:nil];
    } else {
        u = [NSURL URLWithString:@"prefs:root=INTERNET_TETHERING"];
        [a openURL:u options:@{} completionHandler:nil];
    }
}

/* ─── Wi-Fi setup ───────────────────────────────────────────────
 * Two-step flow surfaced through WifiSetupViewController.
 *   Step 1: instructional content asking the user to rename the iPad
 *           in iOS Settings (the iPad's name IS the hotspot SSID).
 *   Step 2: a focused credentials prompt for the SSID and password.
 * ─────────────────────────────────────────────────────────────── */

- (void)showWifiSetup {
    if (showcase_use_existing_wifi()) {
        [self promptForCredentialsFromController:self.vc];
        return;
    }
    WifiSetupViewController *vc = [[WifiSetupViewController alloc] init];
    vc.appDelegate = self;
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
    [self.vc presentViewController:vc animated:YES completion:nil];
}

/* iOS names Personal Hotspot after the device. The iPhone is told to join the
 * name entered here, so a different name leaves it unable to connect. */
static NSString *gestalt_string(CFStringRef key) {
    void *gestalt = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
    CFTypeRef (*copy)(CFStringRef) = gestalt ? dlsym(gestalt, "MGCopyAnswer") : NULL;
    CFTypeRef value = copy ? copy(key) : NULL;
    NSString *string = value && CFGetTypeID(value) == CFStringGetTypeID() ?
        [(__bridge NSString *)value copy] : nil;
    if (value) CFRelease(value);
    return string.length ? string : nil;
}

/* Without access, iOS 16 and later answer with the model ("iPad"). */
static NSString *hotspot_name(void) {
    NSString *name = gestalt_string(CFSTR("UserAssignedDeviceName"));
    return [name isEqualToString:gestalt_string(CFSTR("DeviceName"))] ? nil : name;
}

- (void)saveSSID:(NSString *)ssid password:(NSString *)pass host:(UIViewController *)host {
    [self.cars setAPSSID:ssid password:pass];
    /* Wi-Fi Setup and the shared-mode alert are modals over the main screen:
     * like every other one they end in settingsDidClose, so a restart or an
     * error held while they were up is released. */
    if ([host isKindOfClass:[WifiSetupViewController class]])
        [host dismissViewControllerAnimated:YES completion:^{ [self settingsDidClose]; }];
    else [self settingsDidClose];
}

/* Called by WifiSetupViewController when the user taps "Set credentials".
 * This is a focused alert prompt for SSID + password. */
- (void)promptForCredentialsFromController:(UIViewController *)host {
    [self promptForCredentialsFromController:host ssid:nil password:nil];
}

/* ssid/password refill the form after a rejected entry, so what the user typed
 * is not replaced by the saved values. */
- (void)promptForCredentialsFromController:(UIViewController *)host
                                      ssid:(NSString *)typedSSID
                                  password:(NSString *)typedPassword {
    BOOL shared = showcase_use_existing_wifi();
    NSString *deviceName = shared ? nil : hotspot_name();
    NSString *currentSSID = typedSSID ?: (self.cars.apSSID.length ? self.cars.apSSID :
        ((shared ? showcase_current_wifi_ssid() : deviceName) ?: @""));
    NSString *currentPass = typedPassword ?: (self.cars.apPassword ?: @"");

    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:shared ? L(@"Wi-Fi details") : L(@"Hotspot Details")
                         message:shared ? L(@"Enter the portable router's Wi-Fi name and password. Connect both devices to that network.") : nil
                  preferredStyle:UIAlertControllerStyleAlert];

    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = L(@"Name");
        tf.text = currentSSID;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = L(@"Password");
        tf.text = currentPass;
        tf.secureTextEntry = YES;
    }];

    __weak UIViewController *weakHost = host;
    [ac addAction:[UIAlertAction actionWithTitle:L(@"Save") style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_a) {
            NSString *ssid = ac.textFields[0].text ?: @"";
            NSString *pass = ac.textFields[1].text ?: @"";
            NSString *err = validateNetworkSSID(ssid);
            if (!err) err = validateNetworkPassword(pass);
            if (err) {
                UIAlertController *e = [UIAlertController
                    alertControllerWithTitle:L(@"Try Again")
                                     message:err
                              preferredStyle:UIAlertControllerStyleAlert];
                [e addAction:[UIAlertAction actionWithTitle:L(@"OK")
                    style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *_b) {
                        [self promptForCredentialsFromController:weakHost
                                                            ssid:ssid
                                                        password:pass];
                    }]];
                [weakHost presentViewController:e animated:YES completion:nil];
                return;
            }
            if (deviceName && ![ssid isEqualToString:deviceName]) {
                UIAlertController *m = [UIAlertController
                    alertControllerWithTitle:L(@"Different Name")
                                     message:[NSString stringWithFormat:
                        L(@"This %1$@'s hotspot is called \u201c%2$@\u201d. Your iPhone joins the name you enter here, so it has to match. To use \u201c%3$@\u201d, rename the %1$@ in Settings > General > About > Name."),
                        showcase_device_noun(), deviceName, ssid]
                              preferredStyle:UIAlertControllerStyleAlert];
                /* A device name Showcase cannot send (too short, or still
                 * containing "iPad") is not offered; the message already says
                 * to rename the device. */
                if (!validateSSID(deviceName)) {
                    [m addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:L(@"Use \u201c%@\u201d"), deviceName]
                        style:UIAlertActionStyleDefault handler:^(UIAlertAction *_b) {
                            [self saveSSID:deviceName password:pass host:weakHost];
                        }]];
                }
                [m addAction:[UIAlertAction actionWithTitle:L(@"Keep") style:UIAlertActionStyleCancel
                    handler:^(UIAlertAction *_b) { [self saveSSID:ssid password:pass host:weakHost]; }]];
                [weakHost presentViewController:m animated:YES completion:nil];
                return;
            }
            [self saveSSID:ssid password:pass host:weakHost];
        }]];
    /* Over Wi-Fi Setup, Cancel returns to that modal, which closes through
     * settingsDidClose itself; in shared mode the alert is the whole modal. */
    BOOL overWifiSetup = [host isKindOfClass:[WifiSetupViewController class]];
    [ac addAction:[UIAlertAction actionWithTitle:L(@"Cancel")
        style:UIAlertActionStyleCancel handler:^(UIAlertAction *_a) {
            if (!overWifiSetup) [self settingsDidClose];
        }]];

    [host presentViewController:ac animated:YES completion:nil];
}

/* ─── bridge100 tcpdump capture ────────────────────────────── */

- (UIViewController *)topPresenter {
    UIViewController *p = self.vc ?: self.window.rootViewController;
    while (p.presentedViewController) p = p.presentedViewController;
    return p ?: self.window.rootViewController;
}

- (void)presentAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:L(@"OK")
        style:UIAlertActionStyleDefault handler:nil]];
    [[self topPresenter] presentViewController:ac animated:YES completion:nil];
}

- (void)presentExportSavedAlertForPath:(NSString *)path reason:(NSString *)reason {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *msg = [NSString stringWithFormat:L(@"%@\n\nSaved to:\n%@"),
                         reason ?: L(@"The share sheet could not be shown."), path ?: @"(unknown)"];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:L(@"Export Saved")
            message:msg preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:L(@"Copy Path")
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                if (path.length) [UIPasteboard generalPasteboard].string = path;
            }]];
        [ac addAction:[UIAlertAction actionWithTitle:L(@"OK")
            style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *presenter = [self topPresenter];
        if ([presenter isKindOfClass:[UIAlertController class]] && presenter.presentingViewController) {
            presenter = presenter.presentingViewController;
        }
        [presenter presentViewController:ac animated:YES completion:nil];
    });
}

- (void)presentShareForURL:(NSURL *)url {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *path = url.path;
        NSFileManager *fm = [NSFileManager defaultManager];
        if (!url || ![fm fileExistsAtPath:path] || ![fm isReadableFileAtPath:path]) {
            ip_log("[SHARE] file missing/unreadable path=%s", path ? [path UTF8String] : "(nil)");
            [self presentAlertWithTitle:L(@"File Missing") message:L(@"The export file could not be found or read.")];
            return;
        }

        UIActivityViewController *avc =
            [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                              applicationActivities:nil];
        avc.excludedActivityTypes = @[ UIActivityTypeAirDrop ];

        UIViewController *presenter = [self topPresenter];
        if (!presenter) {
            ip_log("[SHARE] share failed: no presenter path=%s", [path UTF8String]);
            [self presentExportSavedAlertForPath:path reason:L(@"The share sheet could not be shown.")];
            return;
        }
        if ([presenter isKindOfClass:[UIAlertController class]]) {
            ip_log("[SHARE] share delayed: top presenter is alert");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self presentShareForURL:url];
            });
            return;
        }

        if (avc.popoverPresentationController) {
            UIView *source = presenter.view ?: self.vc.contentView ?: self.vc.view;
            if (!source || CGRectIsEmpty(source.bounds)) {
                ip_log("[SHARE] share failed: no stable source view path=%s", [path UTF8String]);
                [self presentExportSavedAlertForPath:path reason:L(@"The export was created, but the share sheet had no valid presentation view.")];
                return;
            }
            avc.popoverPresentationController.sourceView = source;
            avc.popoverPresentationController.sourceRect =
                CGRectMake(CGRectGetMidX(source.bounds), CGRectGetMidY(source.bounds), 1, 1);
            avc.popoverPresentationController.permittedArrowDirections = 0;
        }

        ip_log("[SHARE] presenting share sheet path=%s airdrop=excluded", [path UTF8String]);
        [presenter presentViewController:avc animated:YES completion:nil];
    });
}

- (void)applyDiagnosticsEnabled:(BOOL)enabled {
    _diagnosticsEnabled = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:DIAGNOSTICS_ENABLED_KEY];
    [[NSUserDefaults standardUserDefaults] synchronize];
    ip_log("diagnostics %s", enabled ? "enabled" : "disabled");

    if (enabled) {
        enable_btstack_hci_logging();
    } else {
        [self stopNetworkDumpCaptureWithReason:@"diagnostics disabled"];
        disable_btstack_hci_logging();
    }
}

- (void)clearLogsAndDumps {
    /* Helpers hold their logs open while a session runs; deleting them would
     * lose that session's logs and leave the BT error report empty. */
    if (self.state != StateIdle) {
        ip_log("clear logs refused: session state=%ld", (long)self.state);
        return;
    }
    [self stopNetworkDumpCaptureWithReason:@"clearing logs and dumps"];

    ip_log_close();

    NSFileManager *fm = [NSFileManager defaultManager];
    /* The BAA broker outlives sessions and keeps its log open in Idle: an
     * unlinked log would hide its later output from Send Logs until it
     * restarts. Its logs are truncated in place; everything else goes. */
    for (NSString *name in [fm contentsOfDirectoryAtPath:@LOG_DIR error:nil]) {
        NSString *path = [@LOG_DIR stringByAppendingPathComponent:name];
        if ([name hasPrefix:@"baa_broker"] && [name hasSuffix:@".log"]) {
            int fd = open(path.fileSystemRepresentation,
                          O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC);
            if (fd >= 0) {
                close(fd);
                continue;
            }
        }
        [fm removeItemAtPath:path error:nil];
    }
    NSArray<NSString *> *paths = @[
        @TCPDUMP_DIR,
        @"/var/mobile/Library/Showcase/diagnostics",
        @"/tmp/hci_dump.pklg",
        @SHOWCASE_BTSTACK_LOG_PATH
    ];
    for (NSString *path in paths) {
        [fm removeItemAtPath:path error:nil];
    }
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"latestTcpdumpPath"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"hasEverStartedTcpdump"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    ip_log_open();
    ip_log("logs and dumps cleared");
}

- (NSString *)timestampStringForFilename {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    return [fmt stringFromDate:[NSDate date]];
}

- (NSString *)latestNetworkDumpPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *stored = [[NSUserDefaults standardUserDefaults] stringForKey:@"latestTcpdumpPath"];
    if (stored.length > 0 && [fm fileExistsAtPath:stored]) return stored;

    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:@TCPDUMP_DIR error:nil];
    NSString *best = nil;
    NSDate *bestDate = nil;
    for (NSString *f in files) {
        if (![f hasSuffix:@".pcap"]) continue;
        NSString *path = [@TCPDUMP_DIR stringByAppendingPathComponent:f];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        NSDate *mtime = attrs[NSFileModificationDate];
        if (!best || [mtime compare:bestDate] == NSOrderedDescending) {
            best = path;
            bestDate = mtime;
        }
    }
    if (best) {
        [[NSUserDefaults standardUserDefaults] setObject:best forKey:@"latestTcpdumpPath"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    return best;
}

/* sharedWifiSession/sharedWifiInterface describe the last started session and
 * are never cleared, so in Idle they may be stale (e.g. the user switched from
 * Existing Wi-Fi to Personal Hotspot). Outside a session, decide from the
 * current setting and a fresh interface lookup instead. */
- (BOOL)networkCaptureUsesSharedWifi {
    if (self.state == StateIdle) return showcase_use_existing_wifi();
    return self.sharedWifiSession;
}

- (BOOL)spawnTcpdumpAtPath:(NSString *)pcapPath useSelfTimeout:(BOOL)useSelfTimeout {
    const char *tcpdump = tcpdump_tool_path();
    if (!tcpdump) return NO;
    NSString *captureName = @AP_INTERFACE;
    if ([self networkCaptureUsesSharedWifi]) {
        captureName = (self.state == StateIdle)
            ? shared_wifi_interface()
            : (self.sharedWifiInterface ?: shared_wifi_interface());
    }
    if (!captureName.length) {
        ip_log("tcpdump: no active shared Wi-Fi interface");
        return NO;
    }
    const char *captureInterface = captureName.UTF8String;

    mkdir("/var/mobile/Library/Showcase", 0755);
    mkdir(TCPDUMP_DIR, 0755);

    pid_t pid = 0;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 1, TCPDUMP_LOG, O_WRONLY|O_CREAT|O_APPEND, 0644);
    posix_spawn_file_actions_adddup2(&actions, 1, 2);

    /* Diagnostics must not become part of the performance problem. Full
     * screen packets plus -U forced hundreds of pcap writes per second on
     * older flash. A 256-byte snap length retains Ethernet/IP/TCP/UDP
     * headers and enough protocol prefix for flow, ACK, retransmission, and
     * RTP timing analysis. The larger capture buffer is flushed normally
     * when SIGINT stops tcpdump. */
    char *argvTimed[] = {
        (char*)"tcpdump", (char*)"-i", (char*)captureInterface,
        (char*)"-B", (char*)"4096", (char*)"-s", (char*)"256",
        (char*)"-G", (char*)"300", (char*)"-W", (char*)"1",
        (char*)"-w", (char*)[pcapPath UTF8String], NULL
    };
    char *argvPlain[] = {
        (char*)"tcpdump", (char*)"-i", (char*)captureInterface,
        (char*)"-B", (char*)"4096", (char*)"-s", (char*)"256",
        (char*)"-w", (char*)[pcapPath UTF8String], NULL
    };

    char **argv = useSelfTimeout ? argvPlain : argvTimed;
    ip_log("tcpdump spawn: %s -i %s -B 4096 -s 256 %s-w %s",
           tcpdump, captureInterface, useSelfTimeout ? "" : "-G 300 -W 1 ",
           [pcapPath UTF8String]);

    int err = spawn_isolated(&pid, tcpdump, &actions, argv);
    posix_spawn_file_actions_destroy(&actions);
    if (err != 0) {
        ip_log("tcpdump posix_spawn FAIL: %s", strerror(err));
        return NO;
    }

    usleep(250000);
    int status = 0;
    pid_t done = waitpid(pid, &status, WNOHANG);
    if (done == pid) {
        ip_log("tcpdump exited immediately status=%d", status);
        return NO;
    }

    self.tcpdumpPid = pid;
    self.currentTcpdumpPath = pcapPath;
    [[NSUserDefaults standardUserDefaults] setObject:pcapPath forKey:@"latestTcpdumpPath"];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"hasEverStartedTcpdump"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    ip_log("tcpdump running pid=%d path=%s", pid, [pcapPath UTF8String]);
    return YES;
}

- (void)promptInstallTcpdumpIfNeeded {
    if (self.tcpdumpMissingPromptShown) return;
    self.tcpdumpMissingPromptShown = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:L(@"Network Dump Unavailable")
            message:L(@"tcpdump is not installed. Install the package named tcpdump in Sileo, then reopen Showcase. CarPlay can still run; only the network dump is disabled.")
            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:L(@"Open Sileo")
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                NSURL *u = [NSURL URLWithString:@"sileo://package/tcpdump"];
                [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
            }]];
        [ac addAction:[UIAlertAction actionWithTitle:L(@"OK")
            style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *p = self.vc.presentedViewController ?: self.vc;
        [p presentViewController:ac animated:YES completion:nil];
    });
}

typedef NS_ENUM(NSInteger, NetworkDumpResult) {
    NetworkDumpStarted,       /* running now (or already was) */
    NetworkDumpDisabled,      /* diagnostics are off */
    NetworkDumpToolMissing,   /* tcpdump is not installed */
    NetworkDumpFailed         /* installed, but no interface / spawn failed / exited */
};

- (NetworkDumpResult)startNetworkDumpCapture {
    if (!self.diagnosticsEnabled) {
        ip_log("tcpdump not started; diagnostics disabled");
        return NetworkDumpDisabled;
    }
    if (child_alive(self.tcpdumpPid)) return NetworkDumpStarted;

    const char *tcpdump = tcpdump_tool_path();
    if (!tcpdump) {
        ip_log("tcpdump missing; cannot capture Wi-Fi");
        [self promptInstallTcpdumpIfNeeded];
        return NetworkDumpToolMissing;
    }

    if (![self networkCaptureUsesSharedWifi] && !is_ap_up()) {
        ip_log("tcpdump warning: %s is not up yet; capture may exit", AP_INTERFACE);
    }

    NSString *stamp = [self timestampStringForFilename];
    NSString *path = [NSString stringWithFormat:@"%s/showcase_wifi_%@.pcap", TCPDUMP_DIR, stamp];

    /* First try tcpdump's own 5-minute rotation stop, so the child exits even
     * if the app crashes. Older builds that dislike -G/-W fall back to an app
     * timer below. */
    if (![self spawnTcpdumpAtPath:path useSelfTimeout:NO]) {
        ip_log("tcpdump timed mode failed; retrying plain mode with app timer");
        if (![self spawnTcpdumpAtPath:path useSelfTimeout:YES]) {
            /* tcpdump is installed (checked above): the interface is missing
             * (Personal Hotspot off, no shared Wi-Fi) or it would not run. */
            ip_log("tcpdump could not start a capture");
            return NetworkDumpFailed;
        }
    }

    [self.tcpdumpStopTimer invalidate];
    self.tcpdumpStopTimer = [NSTimer scheduledTimerWithTimeInterval:TCPDUMP_MAX_SECONDS
        target:self selector:@selector(tcpdumpTimedOut) userInfo:nil repeats:NO];
    return NetworkDumpStarted;
}

- (void)tcpdumpTimedOut {
    [self stopNetworkDumpCaptureWithReason:@"5 minute limit reached"];
}

- (void)stopNetworkDumpCaptureWithReason:(NSString *)reason {
    [self.tcpdumpStopTimer invalidate]; self.tcpdumpStopTimer = nil;
    pid_t pid = self.tcpdumpPid;
    if (!child_alive(pid)) {
        self.tcpdumpPid = 0;
        return;
    }

    ip_log("stopping tcpdump pid=%d reason=%s", pid, [reason UTF8String]);
    kill(pid, SIGINT); /* lets tcpdump flush pcap footer/stats */
    for (int i = 0; i < 30; i++) {
        int status = 0;
        pid_t done = check_child(pid, &status);
        if (done != 0) {
            ip_log("tcpdump stopped status=%d", status);
            self.tcpdumpPid = 0;
            return;
        }
        usleep(100000);
    }
    kill(pid, SIGTERM);
    usleep(300000);
    kill_child(pid);
    self.tcpdumpPid = 0;
}

/* Copies one file into the archive work tree while the whole archive stays
 * under DIAGNOSTICS_ARCHIVE_MAX_BYTES. A log that does not fit in what is left
 * contributes its newest bytes; any other file is skipped whole, since a
 * truncated capture or plist is unreadable. */
- (void)copyPath:(NSString *)src toDiagnosticsDir:(NSString *)dir name:(NSString *)name
          budget:(unsigned long long *)budget {
    int fd = open(src.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        return;
    }
    NSString *fileName = name ?: [src lastPathComponent];
    unsigned long long available = *budget > DIAGNOSTICS_TAR_ENTRY_OVERHEAD
        ? *budget - DIAGNOSTICS_TAR_ENTRY_OVERHEAD : 0;
    unsigned long long length = (unsigned long long)st.st_size;
    if (length > available) {
        if (![fileName hasSuffix:@".log"] || available == 0 ||
            lseek(fd, (off_t)(length - available), SEEK_SET) < 0) {
            close(fd);
            ip_log("diagnostics skipped %s: %llu bytes, %llu left",
                   [src UTF8String], length, available);
            return;
        }
        ip_log("diagnostics kept the last %llu of %llu bytes of %s",
               available, length, [src UTF8String]);
        length = available;
    }
    NSFileHandle *file = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    NSData *contents;
    @try {
        contents = [file readDataOfLength:(NSUInteger)length];
    } @catch (__unused NSException *exception) {
        return;
    }
    if (contents.length > length) return;
    NSString *dst = [dir stringByAppendingPathComponent:fileName];
    if (![contents writeToFile:dst atomically:YES]) {
        ip_log("diagnostics copy failed: %s -> %s", [src UTF8String], [dst UTF8String]);
        return;
    }
    *budget -= MIN(*budget, contents.length + DIAGNOSTICS_TAR_ENTRY_OVERHEAD);
}

- (void)copyLogDirectoryToDiagnosticsDir:(NSString *)dir budget:(unsigned long long *)budget {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:@LOG_DIR error:nil];
    NSString *logsDir = [dir stringByAppendingPathComponent:@"logs"];
    [fm createDirectoryAtPath:logsDir withIntermediateDirectories:YES attributes:nil error:nil];
    /* app.log goes first: it is the one log every report needs. */
    NSString *appLog = [@APP_LOG lastPathComponent];
    if ([files containsObject:appLog]) {
        [self copyPath:@APP_LOG toDiagnosticsDir:logsDir name:appLog budget:budget];
    }
    /* Then the rotated part, which holds the start of a long-running launch. */
    NSString *previousLog = [@APP_LOG_PREVIOUS lastPathComponent];
    if ([files containsObject:previousLog]) {
        [self copyPath:@APP_LOG_PREVIOUS toDiagnosticsDir:logsDir
                  name:previousLog budget:budget];
    }
    for (NSString *name in files) {
        if (![name hasSuffix:@".log"] || [name isEqualToString:appLog] ||
            [name isEqualToString:previousLog]) continue;
        [self copyPath:[@LOG_DIR stringByAppendingPathComponent:name]
      toDiagnosticsDir:logsDir
                  name:name
                budget:budget];
    }
}

- (NSString *)diagnosticsSessionSnapshotWithHelperLogs:(BOOL)helpersLogged {
    return [NSString stringWithFormat:
        @"state=%ld\nselected_car=%@\nhotspot_ssid=%@\nlatest_tcpdump=%@\n"
         "diagnostics_enabled=%@\nhelpers_full_logging_this_run=%@\n",
        (long)self.state, self.cars.selected.name ?: @"", self.cars.apSSID ?: @"",
        [self latestNetworkDumpPath] ?: @"(none)", self.diagnosticsEnabled ? @"yes" : @"no",
        helpersLogged ? @"yes" : @"no"];
}

- (NSString *)createDiagnosticsArchiveWithSnapshot:(NSString *)snapshot
                                         helperLogs:(BOOL)helpersLogged {
    char scratchPath[] = "/tmp/showcase-diagnostics.XXXXXX";
    if (!mkdtemp(scratchPath)) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *base = @(scratchPath);
    NSString *work = [base stringByAppendingPathComponent:@"work"];
    NSString *archive = [base stringByAppendingPathComponent:@"ShowcaseDiagnostics.tar"];
    NSString *commandsDir = [work stringByAppendingPathComponent:@"commands"];
    if (![fm createDirectoryAtPath:commandsDir withIntermediateDirectories:YES attributes:nil error:nil]) {
        [fm removeItemAtPath:base error:nil];
        return nil;
    }

    const char *tarPaths[] = {
        "/var/jb/usr/bin/tar", "/var/jb/bin/tar", "/usr/bin/tar", "/bin/tar", NULL
    };
    const char *dpkgPaths[] = {
        "/var/jb/usr/bin/dpkg", "/var/jb/bin/dpkg", "/usr/bin/dpkg", "/bin/dpkg", NULL
    };
    const char *dpkgQueryPaths[] = {
        "/var/jb/usr/bin/dpkg-query", "/var/jb/bin/dpkg-query",
        "/usr/bin/dpkg-query", "/bin/dpkg-query", NULL
    };
    const char *unamePaths[] = {
        "/var/jb/usr/bin/uname", "/usr/bin/uname", "/bin/uname", NULL
    };
    const char *ifconfigPaths[] = {
        "/var/jb/sbin/ifconfig", "/sbin/ifconfig", "/usr/sbin/ifconfig", NULL
    };
    const char *lsPaths[] = {
        "/var/jb/bin/ls", "/bin/ls", "/usr/bin/ls", NULL
    };

    const char *tarPath = first_existing_tool(tarPaths);
    const char *launchctl = launchctl_path();
    const char *dpkgPath = first_existing_tool(dpkgPaths);
    const char *dpkgQueryPath = first_existing_tool(dpkgQueryPaths);
    const char *unamePath = first_existing_tool(unamePaths);
    const char *ifconfigPath = first_existing_tool(ifconfigPaths);
    const char *lsPath = first_existing_tool(lsPaths);

    NSMutableString *env = [NSMutableString string];
    [env appendFormat:@"Showcase diagnostics\n"];
    [env appendFormat:@"version=%s\n", APP_VERSION];
#ifdef SHOWCASE_ROOTLESS
    [env appendString:@"layout=rootless\n"];
#else
    [env appendString:@"layout=rootful\n"];
#endif
    [env appendFormat:@"uid=%u\n", getuid()];
    [env appendFormat:@"euid=%u\n", geteuid()];
    [env appendFormat:@"bundle=%@\n", [[NSBundle mainBundle] bundlePath]];
    [env appendString:snapshot];
    [env appendFormat:@"launchctl=%s\n", launchctl ?: "(missing)"];
    [env appendFormat:@"tar=%s\n", tarPath ?: "(missing)"];
    [env appendFormat:@"dpkg=%s\n", dpkgPath ?: "(missing)"];
    [env appendFormat:@"dpkg_query=%s\n", dpkgQueryPath ?: "(missing)"];
    [env appendFormat:@"btdaemon=%s\n", BTDAEMON_PATH];
    [env appendFormat:@"btstack_plist=%s\n", BTSTACK_PLIST];
    [env appendFormat:@"btstack_socket=%s exists=%s\n",
                      BTSTACK_SOCKET, access(BTSTACK_SOCKET, F_OK) == 0 ? "yes" : "no"];
    [env appendFormat:@"hci_dump=/tmp/hci_dump.pklg exists=%s\n",
                      access("/tmp/hci_dump.pklg", F_OK) == 0 ? "yes" : "no"];
    [env appendFormat:@"tcpdump=%s\n", tcpdump_tool_path() ?: "(missing)"];
    [env appendFormat:@"bt_ready_sentinel=%s exists=%s\n",
                      BT_READY_PATH, access(BT_READY_PATH, F_OK) == 0 ? "yes" : "no"];
    [env writeToFile:[work stringByAppendingPathComponent:@"environment.txt"]
          atomically:YES encoding:NSUTF8StringEncoding error:nil];

    if (!helpersLogged) {
        NSString *warning = @"Diagnostics were enabled after this run or were disabled when helpers launched. Helper logs may be missing or limited. Reproduce once with diagnostics enabled before pressing Start.\n";
        [warning writeToFile:[work stringByAppendingPathComponent:@"WARNING.txt"]
                  atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    /* Small configuration files first, then the logs, the binary HCI
     * capture last: whatever no longer fits is trimmed or left out instead of
     * pushing the archive past the upload limit. */
    unsigned long long budget =
        DIAGNOSTICS_ARCHIVE_MAX_BYTES - DIAGNOSTICS_ARCHIVE_RESERVE_BYTES;
    [self copyPath:[NSString stringWithUTF8String:BTSTACK_PREFS]
  toDiagnosticsDir:work name:@"ch.ringwald.btstack.plist" budget:&budget];
    [self copyPath:[NSString stringWithUTF8String:BTSTACK_PLIST]
  toDiagnosticsDir:work name:@"BTstack-launchdaemon.plist" budget:&budget];
    [self copyPath:[[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Info.plist"]
  toDiagnosticsDir:work name:@"Showcase-Info.plist" budget:&budget];
    [self copyLogDirectoryToDiagnosticsDir:work budget:&budget];
    [self copyPath:@SHOWCASE_BTSTACK_LOG_PATH toDiagnosticsDir:work name:@"BTstack.log"
            budget:&budget];
    [self copyPath:@TCPDUMP_LOG toDiagnosticsDir:work name:@"tcpdump.log" budget:&budget];
    [self copyPath:@"/tmp/hci_dump.pklg" toDiagnosticsDir:work name:@"hci_dump.pklg"
            budget:&budget];

    if (unamePath) {
        char *argv[] = { (char*)"uname", (char*)"-a", NULL };
        run_capture(unamePath, argv, [[commandsDir stringByAppendingPathComponent:@"uname-a.txt"] UTF8String]);
    }
    if (ifconfigPath) {
        char *argv[] = { (char*)"ifconfig", (char*)"-a", NULL };
        run_capture(ifconfigPath, argv, [[commandsDir stringByAppendingPathComponent:@"ifconfig-a.txt"] UTF8String]);
    }
    if (dpkgPath) {
        char *argv2[] = { (char*)"dpkg", (char*)"-l", NULL };
        run_capture(dpkgPath, argv2, [[commandsDir stringByAppendingPathComponent:@"dpkg-l.txt"] UTF8String]);
    }
    if (dpkgQueryPath) {
        char *argv1[] = { (char*)"dpkg-query", (char*)"-s", (char*)"com.rostane.showcase", NULL };
        run_capture(dpkgQueryPath, argv1, [[commandsDir stringByAppendingPathComponent:@"dpkg-showcase.txt"] UTF8String]);
        char *argv2[] = { (char*)"dpkg-query", (char*)"-W", NULL };
        run_capture(dpkgQueryPath, argv2, [[commandsDir stringByAppendingPathComponent:@"dpkg-query-W.txt"] UTF8String]);
    }
    if (lsPath) {
        char *argv1[] = { (char*)"ls", (char*)"-la", (char*)"/tmp", NULL };
        run_capture(lsPath, argv1, [[commandsDir stringByAppendingPathComponent:@"ls-tmp.txt"] UTF8String]);
        char *argv2[] = { (char*)"ls", (char*)"-la", (char*)BTDAEMON_PATH, NULL };
        run_capture(lsPath, argv2, [[commandsDir stringByAppendingPathComponent:@"ls-btdaemon.txt"] UTF8String]);
        char *argv3[] = { (char*)"ls", (char*)"-la", (char*)[[[NSBundle mainBundle] bundlePath] UTF8String], NULL };
        run_capture(lsPath, argv3, [[commandsDir stringByAppendingPathComponent:@"ls-app.txt"] UTF8String]);
    }

    if (!tarPath) {
        ip_log("diagnostics export failed: tar not found");
        [fm removeItemAtPath:base error:nil];
        return nil;
    }

    char *tarArgv[] = {
        (char*)"tar", (char*)"-cf", (char*)[archive UTF8String],
        (char*)"-C", (char*)[work UTF8String], (char*)".", NULL
    };
    int rc = run_blocking(tarPath, tarArgv);
    ip_log("diagnostics tar rc=%d path=%s", rc, [archive UTF8String]);
    NSNumber *size = [fm attributesOfItemAtPath:archive error:nil][NSFileSize];
    if (rc != 0 || !size || size.unsignedLongLongValue > DIAGNOSTICS_ARCHIVE_MAX_BYTES) {
        if (rc == 0 && size) ip_log("diagnostics archive exceeds upload limit");
        [fm removeItemAtPath:base error:nil];
        return nil;
    }
    [fm removeItemAtPath:work error:nil];
    return archive;
}

/* ─── IPC listener ─────────────────────────────────────────── */

- (BOOL)startIPCListener {
    unlink(SOCK_PATH);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    /* Darwin's AF_UNIX default (~8 KB) is far below one H.264 key frame, so
     * the service's bounded writes would time out on any short reader pause.
     * Accepted connections inherit these sizes from the listener. */
    int bufferBytes = 512 * 1024;
    if (setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferBytes, sizeof(bufferBytes)) != 0 ||
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufferBytes, sizeof(bufferBytes)) != 0)
        ip_log("IPC socket buffers: %s", strerror(errno));
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCK_PATH, sizeof(addr.sun_path) - 1);
    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        ip_log("bind: %s", strerror(errno));
        close(fd); return NO;
    }
    /* Both the app and its service helper run as root. Do not expose video,
     * audio, or touch IPC to unrelated local processes. Apply permissions
     * before listening, and fail closed if either operation fails. */
    if (chmod(SOCK_PATH, 0600) != 0 || listen(fd, 1) != 0) {
        ip_log("IPC socket setup: %s", strerror(errno));
        close(fd);
        unlink(SOCK_PATH);
        return NO;
    }
    self.listenFd = fd;
    ip_log("IPC listening on %s", SOCK_PATH);
    dispatch_async(dispatch_get_global_queue(0, 0), ^{ [self ipcAcceptLoop]; });
    return YES;
}

- (void)ipcAcceptLoop {
    uint32_t epoch = flow_epoch();
    int listener = self.listenFd;
    BOOL reconnected = NO;
    while (!flow_cancelled() && epoch == flow_epoch()) {
        int c = accept(listener, NULL, NULL);
        if (c < 0) {
            int err = errno;
            if (err == EINTR || err == ECONNABORTED) continue;
            /* Descriptor or buffer pressure passes; closing the listener
             * would refuse every reconnect of the still-running service. */
            if (err == EMFILE || err == ENFILE || err == ENOBUFS || err == ENOMEM) {
                usleep(100000);
                continue;
            }
            /* stopFlow closing the listener also lands here. */
            if (flow_cancelled() || epoch != flow_epoch()) break;
            ip_log("IPC accept failed: %s; ending the session", strerror(err));
            dispatch_async(dispatch_get_main_queue(), ^{
                if (flow_cancelled() || epoch != flow_epoch()) return;
                [self stopFlow];
            });
            break;
        }
        pthread_mutex_lock(&g_ipc_lock);
        if (flow_cancelled() || epoch != flow_epoch()) {
            pthread_mutex_unlock(&g_ipc_lock);
            close(c);
            break;
        }
        int noSigPipe = 1;
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE,
                   &noSigPipe, sizeof(noSigPipe));
        /* Matches the service's send buffer: an IDR frame must fit while the
         * reader is briefly busy with AudioQueue work. */
        int ipcBuffer = 512 * 1024;
        setsockopt(c, SOL_SOCKET, SO_RCVBUF, &ipcBuffer, sizeof(ipcBuffer));
        ip_log(reconnected ? "services reconnected" : "services connected");
        /* Frames lost while the service was reconnecting break the H.264
         * chain; the service repeats VIDEO_CONFIG, and the next key frame
         * restarts the picture. */
        if (reconnected) g_video_needs_resync = 1;
        self.clientFd = c;
        ++g_touch_epoch;
        g_touch_fd = c;
        pthread_mutex_unlock(&g_ipc_lock);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (flow_cancelled() || epoch != flow_epoch()) return;
            /* Inactive (Control Center, alerts, Siri) is still on screen;
             * only the background hides CarPlay. */
            BOOL visible = [UIApplication sharedApplication].applicationState !=
                UIApplicationStateBackground;
#if SHOWCASE_MIRROR_BENCH
            /* A reconnect must not undo openScreenMirror's visibility 0. */
            visible = visible && ![self carPlayCoveredByMirror];
#endif
            send_app_visibility(visible);
        });
        [self ipcHandleConnection:c];
        pthread_mutex_lock(&g_ipc_lock);
        g_touch_fd = -1;
        ++g_touch_epoch;
        close(c);
        self.clientFd = -1;
        pthread_mutex_unlock(&g_ipc_lock);
        ip_log("services disconnected");
        /* The service also drops the connection, without exiting, when a
         * write to the app stalls, and then connects again. Only its exit
         * ends the session; monitorFlowHelpers notices that. */
        pid_t servicesPid = self.carplayServicesPid;
        if (servicesPid > 0 && child_alive(servicesPid)) {
            ip_log("services still running; waiting for it to reconnect");
            reconnected = YES;
            continue;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (epoch == flow_epoch()) [self endAWDLSuppression];
        });
        /* CarPlay services exits when the iPhone ends the session or leaves
         * Wi-Fi, and when it fails while connecting. */
        if (self.state != StateIdle && self.state != StateStopping) {
            BOOL wasActive = self.state == StateActive;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (flow_cancelled() || epoch != flow_epoch()) return;
                if (wasActive) {
                    ip_log("[SESSION] iPhone ended the session; waiting for it again");
                    self.restartAfterStop = YES;
                }
                [self stopFlow];
            });
            break;
        }
    }
    pthread_mutex_lock(&g_ipc_lock);
    if (self.listenFd == listener) self.listenFd = -1;
    close(listener);
    pthread_mutex_unlock(&g_ipc_lock);
    [self stopAllAudioPlayers];
    dispatch_semaphore_signal(self.ipcDone);
}

static bool read_exact(int fd, uint8_t *buf, size_t len) {
    size_t got = 0;
    while (got < len) {
        ssize_t n = read(fd, buf + got, len - got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        got += n;
    }
    return true;
}

/* carplay_services forwards a screen frame of up to SCREEN_MAX_BODY_BYTES
 * (16 MiB) behind a 56-byte header; the app accepts the same. */
#define IPC_MAX_FRAME_BYTES (16u * 1024u * 1024u + 56u)

/* Reads and throws away `len` bytes, keeping the stream framed. */
static bool skip_exact(int fd, size_t len) {
    uint8_t scratch[16384];
    while (len > 0) {
        size_t chunk = len < sizeof(scratch) ? len : sizeof(scratch);
        if (!read_exact(fd, scratch, chunk)) return false;
        len -= chunk;
    }
    return true;
}

/* A bounded, little-endian IPC frame. The caller owns the returned payload.
 * An oversized frame is skipped, not treated as the session ending. */
static bool read_ipc_frame(int fd, uint8_t *type, uint32_t *length, uint8_t **body) {
    uint8_t hdr[5];
    uint32_t len;
    *body = NULL;
    for (;;) {
        if (!read_exact(fd, hdr, sizeof(hdr))) return false;
        len = (uint32_t)hdr[0] | ((uint32_t)hdr[1] << 8) |
              ((uint32_t)hdr[2] << 16) | ((uint32_t)hdr[3] << 24);
        if (len == 0) return false;
        if (len <= IPC_MAX_FRAME_BYTES) break;
        ip_log("IPC frame type=%u of %u bytes exceeds %u; skipped",
               hdr[4], len, IPC_MAX_FRAME_BYTES);
        if (!skip_exact(fd, len)) return false;
        if (hdr[4] == MSG_VIDEO_FRAME) {
            /* The frames after it reference it: wait for a key frame. */
            g_video_needs_resync = 1;
            send_video_resync_request();
        }
    }
    uint8_t *payload = malloc(len);
    if (!payload) { ip_log("IPC payload allocation failed (%u bytes)", len); return false; }
    if (!read_exact(fd, payload, len)) { free(payload); return false; }
    *type = hdr[4];
    *length = len;
    *body = payload;
    return true;
}

- (void)ipcHandleConnection:(int)fd {
    CMFormatDescriptionRef fmtDesc = NULL;
    bool gotFirstFrame = false;
    uint64_t receivedFrameCount = 0;
    uint64_t lateFrameCount = 0;      /* slot already passed on arrival */
    uint64_t lateFrameCountAtReport = 0;
    double   latenessSumMs = 0;       /* magnitude is the metric, not count */
    double   latenessMaxMs = 0;
    uint64_t previousSenderTimestamp = 0;
    bool decodeOnlyCatchupActive = false;

    while (1) {
        uint8_t type, *payload;
        uint32_t len;
        if (!read_ipc_frame(fd, &type, &len, &payload)) break;

        if (type == MSG_VIDEO_CONFIG) {
            if (len < 9) { free(payload); continue; }
            float w, h;
            memcpy(&w, payload, 4); memcpy(&h, payload + 4, 4);
            g_carplay_w = w; g_carplay_h = h;
            ip_log("VideoConfig: %.0fx%.0f", w, h);

            const uint8_t *avcc = payload + 8;
            size_t avccLen = len - 8;
            if (avccLen >= 7) {
                size_t off = 5;
                const uint8_t *ps[2] = {NULL, NULL};
                size_t psSize[2] = {0, 0};
                int nSPS = avcc[off] & 0x1F; off++;
                if (nSPS > 0 && off + 2 <= avccLen) {
                    uint16_t sLen = (avcc[off]<<8) | avcc[off+1]; off += 2;
                    if (off + sLen <= avccLen) { ps[0] = avcc + off; psSize[0] = sLen; off += sLen; }
                }
                if (off < avccLen) {
                    int nPPS = avcc[off]; off++;
                    if (nPPS > 0 && off + 2 <= avccLen) {
                        uint16_t pLen = (avcc[off]<<8) | avcc[off+1]; off += 2;
                        if (off + pLen <= avccLen) { ps[1] = avcc + off; psSize[1] = pLen; }
                    }
                }
                if (ps[0] && ps[1]) {
                    if (fmtDesc) { CFRelease(fmtDesc); fmtDesc = NULL; }
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, ps, psSize, 4, &fmtDesc);
                    /* A new parameter set means a new stream; the previous
                     * sender-timeline offset no longer describes it. */
                    video_clock_reset();
                    dispatch_async(self.videoQueue, ^{
                        AVSampleBufferDisplayLayer *layer = (AVSampleBufferDisplayLayer *)self.videoView.layer;
                        [layer flush];
                        if (g_video_respect_timestamps)
                            video_install_timebase(layer);
                        else
                            layer.controlTimebase = NULL;
                    });
                    gotFirstFrame = false;
                    g_video_needs_resync = 1;
                    previousSenderTimestamp = 0;
                }
            }
            free(payload);

        } else if (type == MSG_VIDEO_FRAME) {
            if (!fmtDesc || len <= VIDEO_FRAME_METADATA_SIZE) {
                free(payload);
                continue;
            }
            uint64_t senderTimestamp = 0;
            memcpy(&senderTimestamp, payload, sizeof(senderTimestamp));
            BOOL isIDR = payload[8] != 0;
            uint32_t serviceSequence = 0;
            uint64_t serviceArrivalNanos = 0;
            uint32_t arrivalGapMicros = 0;
            uint32_t tcpPendingBytes = 0;
            uint32_t tcpReceiveWindow = 0;
            uint32_t tcpSmoothedRTT = 0;
            uint32_t tcpCurrentRTT = 0;
            uint32_t tcpFlags = 0;
            uint32_t decryptMicros = 0;
            memcpy(&serviceSequence, payload + 12, sizeof(serviceSequence));
            memcpy(&serviceArrivalNanos, payload + 16,
                   sizeof(serviceArrivalNanos));
            memcpy(&arrivalGapMicros, payload + 24,
                   sizeof(arrivalGapMicros));
            memcpy(&tcpPendingBytes, payload + 28,
                   sizeof(tcpPendingBytes));
            memcpy(&tcpReceiveWindow, payload + 32,
                   sizeof(tcpReceiveWindow));
            memcpy(&tcpSmoothedRTT, payload + 36,
                   sizeof(tcpSmoothedRTT));
            memcpy(&tcpCurrentRTT, payload + 40,
                   sizeof(tcpCurrentRTT));
            memcpy(&tcpFlags, payload + 44, sizeof(tcpFlags));
            memcpy(&decryptMicros, payload + 48, sizeof(decryptMicros));
            uint64_t appReadNanos = monotonic_nanos_now();
            double serviceToAppMs = serviceArrivalNanos > 0 &&
                appReadNanos >= serviceArrivalNanos
                ? (double)(appReadNanos - serviceArrivalNanos) / 1000000.0
                : -1.0;
            double senderSeconds =
                (double)senderTimestamp / 4294967296.0;
            double senderDeltaMs = NAN;
            if (previousSenderTimestamp != 0 &&
                senderTimestamp >= previousSenderTimestamp) {
                senderDeltaMs =
                    (double)(senderTimestamp - previousSenderTimestamp) /
                    4294967.296;
            }
            previousSenderTimestamp = senderTimestamp;
            double hostAtRead = video_host_now();
            double presentationAgeMs = NAN;
            if (senderTimestamp != 0 && g_video_timing_offset_valid) {
                presentationAgeMs =
                    (hostAtRead -
                     (senderSeconds + g_video_sender_to_host_offset)) * 1000.0;
            }
            if (arrivalGapMicros > 50000 || serviceSequence % 300 == 0 ||
                serviceToAppMs > 20.0) {
                ip_log("[VIDEO-TL] seq=%u gap=%.1fms serviceToApp=%.2fms "
                       "decrypt=%.2fms pending=%u rcvWnd=%u srtt=%ums "
                       "rtt=%ums tcpFlags=0x%x sender=%.6fs "
                       "senderDelta=%.1fms host=%.6fs ptsAge=%.1fms "
                       "timing=%d idr=%d",
                       serviceSequence,
                       (double)arrivalGapMicros / 1000.0, serviceToAppMs,
                       (double)decryptMicros / 1000.0, tcpPendingBytes,
                       tcpReceiveWindow, tcpSmoothedRTT, tcpCurrentRTT,
                       tcpFlags, senderSeconds, senderDeltaMs, hostAtRead,
                       presentationAgeMs,
                       (int)g_video_timing_offset_valid, isIDR ? 1 : 0);
            }
            const uint8_t *frameBytes =
                payload + VIDEO_FRAME_METADATA_SIZE;
            size_t frameLength = len - VIDEO_FRAME_METADATA_SIZE;

            if (g_video_suspended) {
                free(payload);
                continue;
            }

            if (g_video_needs_resync) {
                if (!isIDR) {
                    free(payload);
                    continue;
                }
                g_video_needs_resync = 0;
                decodeOnlyCatchupActive = false;
                ip_log("video resynchronized on IDR frame age=%.1fms",
                       presentationAgeMs);
            }

            /*
             * TCP preserves the H.264 dependency chain but can release it
             * hundreds of milliseconds late after a missing segment. Do not
             * flush that valid chain or request another large IDR over the
             * same congested path. AVSampleBufferDisplayLayer documents that
             * DoNotDisplay still decodes the sample, so feed stale frames to
             * the decoder without presenting them. The last current image
             * remains visible until the chain catches up.
             */
            double staleThresholdMs =
                MAX(VIDEO_STALE_RECOVERY_MIN_MS,
                    (double)g_video_target_latency_ms * 2.0);
            BOOL decodeOnlyCatchup =
                g_video_timing_offset_valid &&
                isfinite(presentationAgeMs) &&
                presentationAgeMs > staleThresholdMs &&
                isfinite(senderDeltaMs) &&
                senderDeltaMs <= 100.0;
            if (decodeOnlyCatchup && !decodeOnlyCatchupActive) {
                decodeOnlyCatchupActive = true;
                ip_log("video decode-only catch-up started seq=%u age=%.1fms "
                       "arrivalGap=%.1fms senderDelta=%.1fms",
                       serviceSequence, presentationAgeMs,
                       (double)arrivalGapMicros / 1000.0, senderDeltaMs);
            } else if (!decodeOnlyCatchup && decodeOnlyCatchupActive) {
                decodeOnlyCatchupActive = false;
                ip_log("video decode-only catch-up complete seq=%u age=%.1fms",
                       serviceSequence, presentationAgeMs);
            }

            if (!gotFirstFrame) {
                gotFirstFrame = true;
                /* A reconnect of the service within the same session must
                 * not replay the connection steps. */
                if (self.state != StateActive) {
                    [self completeConnectStep:ConnectStepVideo];
                    [self transitionTo:StateActive];
                }
                ip_log("first video frame");
                /* Deferred to here on purpose: pairing, iAP2 handoff and the
                 * whole RTSP negotiation have already completed, so radio
                 * suppression cannot influence them. */
                uint32_t epoch = flow_epoch();
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!flow_cancelled() && epoch == flow_epoch()) [self beginAWDLSuppression];
                });
            }

            CMBlockBufferRef block = NULL;
            OSStatus st = CMBlockBufferCreateWithMemoryBlock(
                NULL, NULL, frameLength, kCFAllocatorDefault, NULL, 0,
                frameLength,
                kCMBlockBufferAssureMemoryNowFlag, &block);
            if (st == noErr) {
                CMBlockBufferReplaceDataBytes(frameBytes, block, 0,
                                              frameLength);
            }
            free(payload); payload = NULL;
            if (st != noErr || !block) continue;

            /* Schedule on the sender's timeline when it says its timestamps are
             * authoritative. A frame whose slot has already passed is still
             * enqueued, just immediately: dropping it would break the H.264
             * reference chain and corrupt every frame up to the next IDR. */
            BOOL scheduled = (g_video_respect_timestamps && senderTimestamp != 0);
            double displayHost = 0.0;
            if (scheduled) {
                bool missedSlot = false;
                double latenessSeconds = 0.0;
                displayHost = video_clock_schedule(senderTimestamp,
                                                   video_host_now(),
                                                   &missedSlot,
                                                   &latenessSeconds);
                if (missedSlot) {
                    lateFrameCount++;
                    double latenessMs = latenessSeconds * 1000.0;
                    latenessSumMs += latenessMs;
                    if (latenessMs > latenessMaxMs) latenessMaxMs = latenessMs;
                }
            }

            CMSampleTimingInfo timing;
            /* Follow the sender's real cadence — it drops to 30 Hz on
             * link-limited receivers, and a hardcoded 1/60 would retire each
             * frame half an interval early. */
            timing.duration = scheduled
                ? CMTimeMakeWithSeconds(g_video_frame_interval, 1000000)
                : CMTimeMake(1, 60);
            timing.presentationTimeStamp = scheduled
                ? CMTimeMakeWithSeconds(displayHost, 1000000)
                : kCMTimeInvalid;
            timing.decodeTimeStamp = kCMTimeInvalid;

            CMSampleBufferRef sample = NULL;
            const size_t sz = frameLength;
            st = CMSampleBufferCreateReady(NULL, block, fmtDesc, 1,
                                           1, &timing, 1, &sz, &sample);
            CFRelease(block);
            if (st != noErr || !sample) continue;

            CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sample, true);
            if (att && CFArrayGetCount(att) > 0) {
                CFMutableDictionaryRef d = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(att, 0);
                CFDictionarySetValue(d, kCMSampleAttachmentKey_NotSync,
                                     isIDR ? kCFBooleanFalse : kCFBooleanTrue);
                if (decodeOnlyCatchup)
                    CFDictionarySetValue(
                        d, kCMSampleAttachmentKey_DoNotDisplay,
                        kCFBooleanTrue);
                /* DisplayImmediately overrides the timebase, so it is only
                 * correct on the unscheduled path. */
                if (!scheduled)
                    CFDictionarySetValue(
                        d, kCMSampleAttachmentKey_DisplayImmediately,
                        kCFBooleanTrue);
            }

            uint64_t frameNumber = ++receivedFrameCount;
            uint64_t lateSoFar = lateFrameCount;
            uint64_t lateSinceReport = lateFrameCount - lateFrameCountAtReport;
            double lateMeanMs = lateSinceReport
                ? (latenessSumMs / (double)lateSinceReport) : 0.0;
            double lateMaxMs = latenessMaxMs;
            if (frameNumber % 300 == 0) {
                lateFrameCountAtReport = lateFrameCount;
                latenessSumMs = 0;
                latenessMaxMs = 0;
            }
            double clockOffset = g_video_clock_offset;
            double budgetMs = g_video_budget_seconds * 1000.0;
            BOOL scheduledFrame = scheduled;
            CFAbsoluteTime receivedAt = CFAbsoluteTimeGetCurrent();
            dispatch_async(self.videoQueue, ^{
                AVSampleBufferDisplayLayer *layer =
                    (AVSampleBufferDisplayLayer *)self.videoView.layer;
                if (layer.status ==
                    AVQueuedSampleBufferRenderingStatusFailed) {
                    ip_log("video renderer failed: %@",
                           layer.error.localizedDescription ?: @"unknown");
                    g_video_needs_resync = 1;
                    [layer flushAndRemoveImage];
                    send_video_resync_request();
                    CFRelease(sample);
                    return;
                }
                /* The timing message can arrive after the parameter sets, so
                 * confirm the timebase on the first scheduled frame too. */
                if (scheduledFrame && !layer.controlTimebase)
                    video_install_timebase(layer);
                [layer enqueueSampleBuffer:sample];
                if (frameNumber % 300 == 0) {
                    double queueDelayMs =
                        (CFAbsoluteTimeGetCurrent() - receivedAt) * 1000.0;
                    ip_log("video live #%llu: IPC→enqueue %.1fms ready=%d status=%ld "
                           "mode=%s late=%llu(+%llu/300 mean %.1fms max %.1fms) "
                           "budget=%.1fms offset=%.3fs",
                           frameNumber, queueDelayMs,
                           layer.readyForMoreMediaData,
                           (long)layer.status,
                           scheduledFrame ? "scheduled" : "immediate",
                           lateSoFar, lateSinceReport, lateMeanMs, lateMaxMs,
                           budgetMs, clockOffset);
                }
                CFRelease(sample);
            });
            continue;
        } else if (type == MSG_VIDEO_TIMING) {
            if (len >= sizeof(uint32_t)) {
                uint32_t latencyMs = 0;
                memcpy(&latencyMs, payload, sizeof(latencyMs));
                if (latencyMs >= 20 && latencyMs <= 500)
                    g_video_target_latency_ms = latencyMs;

                int32_t respect = g_video_respect_timestamps;
                if (len >= 5) respect = payload[4] ? 1 : 0;
                int32_t offsetValid = 0;
                double senderToHostOffset = 0.0;
                if (len >= 14) {
                    memcpy(&senderToHostOffset, payload + 5,
                           sizeof(senderToHostOffset));
                    offsetValid = payload[13] ? 1 : 0;
                }
                if (offsetValid != g_video_timing_offset_valid ||
                    (offsetValid &&
                     fabs(senderToHostOffset -
                          g_video_sender_to_host_offset) > 0.000001)) {
                    g_video_sender_to_host_offset = senderToHostOffset;
                    g_video_timing_offset_valid = offsetValid;
                    video_clock_reset();
                }
                if (respect != g_video_respect_timestamps) {
                    g_video_respect_timestamps = respect;
                    video_clock_reset();
                    dispatch_async(self.videoQueue, ^{
                        AVSampleBufferDisplayLayer *layer =
                            (AVSampleBufferDisplayLayer *)self.videoView.layer;
                        if (respect) video_install_timebase(layer);
                        else layer.controlTimebase = NULL;
                    });
                }
                ip_log("screen presentation: latency=%u ms respectTimestamps=%d "
                       "timingOffset=%s%.3fms (%s)",
                       g_video_target_latency_ms,
                       (int)g_video_respect_timestamps,
                       g_video_timing_offset_valid ? "" : "unavailable/",
                       g_video_sender_to_host_offset * 1000.0,
                       g_video_respect_timestamps
                           ? (g_video_timing_offset_valid
                               ? "frames scheduled with synchronized NTP"
                               : "frames scheduled with arrival-clock fallback")
                           : "frames displayed on arrival");
            }
            free(payload);
        } else if (type == MSG_AUDIO_CONFIG) {
            if (len >= 20) {
                uint32_t streamType = 0;
                uint64_t formatMask = 0;
                uint32_t framesPerPacket = 0;
                uint32_t latencyMs = 0;
                memcpy(&streamType, payload, 4);
                memcpy(&formatMask, payload + 4, 8);
                memcpy(&framesPerPacket, payload + 12, 4);
                memcpy(&latencyMs, payload + 16, 4);
                ip_log("AudioConfig: stream=%u format=0x%llx "
                       "framesPerPacket=%u latency=%ums",
                       streamType, (unsigned long long)formatMask,
                       framesPerPacket, latencyMs);
                dispatch_async(self.audioWorkQueue, ^{
                    NSNumber *key = @(streamType);
                    CarPlayAudioPlayer *player = self.audioPlayers[key];
                    if (!player) {
                        player = [[CarPlayAudioPlayer alloc]
                            initWithStreamType:streamType];
                        self.audioPlayers[key] = player;
                    }
                    [player configureFormat:formatMask
                            framesPerPacket:framesPerPacket
                                   latency:latencyMs];
                });
            }
            free(payload);
        } else if (type == MSG_AUDIO_PACKET) {
            if (len > 12) {
                uint32_t streamType = 0;
                uint16_t sequence = 0;
                memcpy(&streamType, payload, 4);
                memcpy(&sequence, payload + 4, 2);
                uint8_t *packet = payload;
                uint32_t packetLength = len;
                payload = NULL;
                dispatch_async(self.audioWorkQueue, ^{
                    NSNumber *key = @(streamType);
                    CarPlayAudioPlayer *player = self.audioPlayers[key];
                    if (player) {
                        [player enqueuePacket:packet + 12
                                       length:packetLength - 12
                                     sequence:sequence];
                    } else {
                        /* AUDIO_CONFIG never reached us (or was lost on a
                         * failed write): re-request it at most once per
                         * second per stream instead of dropping silently. */
                        CFTimeInterval now = CACurrentMediaTime();
                        NSNumber *last = self.audioResyncRequestTimes[key];
                        if (!last || now - last.doubleValue >= 1.0) {
                            self.audioResyncRequestTimes[key] = @(now);
                            ip_log("AudioPacket for stream=%u with no player; "
                                   "requesting config", streamType);
                            send_audio_resync_request(streamType);
                        }
                    }
                    free(packet);
                });
            }
            free(payload);
        } else if (type == MSG_AUDIO_CONTROL) {
            if (len >= 5) {
                uint32_t streamType = 0;
                memcpy(&streamType, payload, 4);
                uint8_t action = payload[4];
                dispatch_async(self.audioWorkQueue, ^{
                    CarPlayAudioPlayer *player =
                        self.audioPlayers[@(streamType)];
                    if (action == AUDIO_CONTROL_PAUSE) {
                        [player setPlaybackPaused:YES];
                    } else if (action == AUDIO_CONTROL_RESUME) {
                        [player setPlaybackPaused:NO];
                    } else if (action == AUDIO_CONTROL_FLUSH) {
                        [player flushBufferedAudio];
                    } else if (action == AUDIO_CONTROL_STOP) {
                        [player stop];
                        [self.audioPlayers removeObjectForKey:@(streamType)];
                        ip_log("audio stream %u stopped by sender teardown",
                               streamType);
                    } else {
                        ip_log("audio stream %u unknown control=%u",
                               streamType, action);
                    }
                });
            }
            free(payload);
        } else if (type == MSG_CAR_VIDEO_COMMAND) {
            NSDictionary *packet = car_video_decode([NSData dataWithBytesNoCopy:payload
                length:len freeWhenDone:YES]);
            uint32_t epoch = flow_epoch();
            if (packet) dispatch_async(dispatch_get_main_queue(), ^{
                if (epoch == flow_epoch() && !flow_cancelled())
                    [self handleCarVideoPacket:packet];
            });
        } else if (type == MSG_BT_HANDOFF) {
            ip_log("[HANDOFF] services requested app-owned Bluetooth teardown");
            [self completeBluetoothHandoff];
            free(payload);
        } else if (type == MSG_STATUS) {
            if (len >= 1) {
                uint8_t code = payload[0];
                ip_log("MSG_STATUS code=0x%02X", code);
                switch (code) {
                    case STATUS_IPHONE_CONNECTED:
                        [self completeConnectStep:ConnectStepJoinWiFi];
                        break;
                    case STATUS_PAIR_SETUP_STARTED: {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (self.firstTimePairing) return;
                            self.firstTimePairing = YES;
                            if ([self isConnectingState]) [self renderState];
                        });
                        [self completeConnectStep:ConnectStepJoinWiFi];
                        break;
                    }
                    case STATUS_PAIR_SETUP_COMPLETE:
                    case STATUS_AUTH_COMPLETE:
                        [self completeConnectStep:ConnectStepJoinWiFi];
                        break;
                    case STATUS_PAIR_VERIFY_COMPLETE:
                    case STATUS_SESSION_SETUP:
                        [self completeConnectStep:ConnectStepPairing];
                        break;
                    case STATUS_STREAM_SETUP:
                        [self completeConnectStep:ConnectStepSession];
                        break;
#if SHOWCASE_MIRROR_BENCH
                    case STATUS_HOST_UI_REQUESTED: {
                        uint32_t epoch = flow_epoch();
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (epoch == flow_epoch() && !flow_cancelled())
                                [self openScreenMirror];
                        });
                        break;
                    }
#endif
                }
            }
            free(payload);
        } else {
            free(payload);
        }
    }
    if (fmtDesc) CFRelease(fmtDesc);
    /* Audio players and the car video outlive a reconnect of the same
     * session. The service re-sends AUDIO_CONFIG for every active stream on
     * each new IPC connection, after a failed send and on MSG_AUDIO_RESYNC,
     * so configureFormat may arrive again for an existing player.
     * ipcAcceptLoop stops the players and stopFlow clears the car video when
     * the session ends. */
}

- (void)stopAllAudioPlayers {
    dispatch_async(self.audioWorkQueue, ^{
        for (CarPlayAudioPlayer *player in self.audioPlayers.allValues) {
            [player stop];
        }
        [self.audioPlayers removeAllObjects];
    });
}

@end

/* ═══════════════════════════════════════════════════════════════
 * SettingsViewController: one full-screen settings window
 *
 * Every page lives inside this one controller. Narrow screens push pages
 * with a back button; wide screens (iPad landscape) keep the section list in
 * a sidebar and show the selected page beside it. Nothing is stacked as a
 * second window except system share sheets.
 * ═══════════════════════════════════════════════════════════════ */

typedef void (^ShowcaseAction)(void);

static UIEdgeInsets showcase_safe_insets(UIView *view) {
    SEL selector = NSSelectorFromString(@"safeAreaInsets");
    if (view && [view respondsToSelector:selector]) {
        NSValue *value = [view valueForKey:@"safeAreaInsets"];
        if (value) return [value UIEdgeInsetsValue];
    }
    return UIEdgeInsetsZero;
}

/* Rows are controls, and a scroll view refuses to scroll from a control by
 * default. Allow it for everything except switches, whose thumb drags. */
@interface SettingsScrollView : UIScrollView
@end
@implementation SettingsScrollView
- (BOOL)touchesShouldCancelInContentView:(UIView *)view {
    return ![view isKindOfClass:[UISwitch class]];
}
@end

@interface SettingsRow : UIControl
@property (nonatomic, copy) ShowcaseAction action;
@end
@implementation SettingsRow
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self addTarget:self action:@selector(fire)
       forControlEvents:UIControlEventTouchUpInside];
        /* A custom UIControl is not an accessibility element by default, so
         * the label, value and Selected/NotEnabled traits set on the row
         * would be ignored and VoiceOver would read its labels one by one. */
        self.isAccessibilityElement = YES;
    }
    return self;
}
- (void)fire { if (self.action && self.enabled) self.action(); }
- (UIAccessibilityTraits)accessibilityTraits {
    UIAccessibilityTraits traits = [super accessibilityTraits];
    if (!self.enabled) traits |= UIAccessibilityTraitNotEnabled;
    return traits;
}
- (BOOL)accessibilityActivate {
    if (!self.action || !self.enabled || !self.userInteractionEnabled) return NO;
    [self fire];
    return YES;
}
/* As one element the row hides buttons inside it (a car's Edit); offer them
 * as VoiceOver actions instead, while the row itself can be used. */
- (NSArray<UIAccessibilityCustomAction *> *)accessibilityCustomActions {
    if (!self.userInteractionEnabled) return nil;
    NSMutableArray<UIAccessibilityCustomAction *> *actions = [NSMutableArray array];
    for (UIView *view in self.subviews) {
        if (![view isKindOfClass:[UIButton class]]) continue;
        UIButton *button = (UIButton *)view;
        NSString *name = button.accessibilityLabel ?: [button titleForState:UIControlStateNormal];
        if (!button.enabled || button.hidden || !name.length) continue;
        [actions addObject:[[UIAccessibilityCustomAction alloc] initWithName:name
            target:self selector:@selector(performSubviewAction:)]];
    }
    return actions.count ? actions : nil;
}
- (BOOL)performSubviewAction:(UIAccessibilityCustomAction *)action {
    if (!self.userInteractionEnabled) return NO;
    for (UIView *view in self.subviews) {
        if (![view isKindOfClass:[UIButton class]]) continue;
        UIButton *button = (UIButton *)view;
        NSString *name = button.accessibilityLabel ?: [button titleForState:UIControlStateNormal];
        if (!button.enabled || button.hidden || ![name isEqualToString:action.name]) continue;
        [button sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    }
    return NO;
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = (highlighted && self.action && self.enabled)
        ? [UIColor colorWithWhite:1 alpha:0.08] : [UIColor clearColor];
}
@end

@interface SettingsSwitch : UISwitch
@property (nonatomic, copy) void (^changed)(BOOL on);
@end
@implementation SettingsSwitch
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self addTarget:self action:@selector(fire)
       forControlEvents:UIControlEventValueChanged];
    }
    return self;
}
- (void)fire { if (self.changed) self.changed(self.on); }
@end

@interface SettingsSegments : UISegmentedControl
@property (nonatomic, copy) void (^changed)(NSInteger index);
@end
@implementation SettingsSegments
- (instancetype)initWithItems:(NSArray *)items {
    if ((self = [super initWithItems:items])) {
        [self addTarget:self action:@selector(fire)
       forControlEvents:UIControlEventValueChanged];
        if ([self respondsToSelector:@selector(setSelectedSegmentTintColor:)]) {
            [self setValue:[UIColor whiteColor] forKey:@"selectedSegmentTintColor"];
            [self setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor blackColor]}
                                forState:UIControlStateSelected];
            [self setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]}
                                forState:UIControlStateNormal];
        }
    }
    return self;
}
- (void)fire { if (self.changed) self.changed(self.selectedSegmentIndex); }
@end

/* A rounded group of rows with hairline separators, as in iOS Settings but
 * drawn for Showcase's black canvas. */
@interface SettingsCard : UIView
@property (nonatomic, assign) CGFloat contentHeight;
- (void)addRow:(UIView *)row height:(CGFloat)height;
@end
@implementation SettingsCard
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
        self.layer.cornerRadius = 14;
        self.clipsToBounds = YES;
    }
    return self;
}
- (void)addRow:(UIView *)row height:(CGFloat)height {
    CGFloat W = self.bounds.size.width;
    if (self.contentHeight > 0) {
        CGFloat px = 1.0 / [UIScreen mainScreen].scale;
        UIView *line = [[UIView alloc] initWithFrame:
            CGRectMake(16, self.contentHeight, W - 16, px)];
        line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
        [self addSubview:line];
    }
    row.frame = CGRectMake(0, self.contentHeight, W, height);
    [self addSubview:row];
    self.contentHeight += height;
    CGRect f = self.frame;
    f.size.height = self.contentHeight;
    self.frame = f;
}
@end

/* Where CarPlay sound comes out: this device on the left, the CarPlay
 * sender on the right. The active one is bright and carries sound waves.
 * Tapping a device selects it. */
@interface SoundRouteView : UIView
@property (nonatomic, assign) BOOL receiverActive;
@property (nonatomic, copy) void (^selected)(BOOL receiver);
- (void)setReceiverActive:(BOOL)active animated:(BOOL)animated;
@end

@interface SoundRouteView ()
@property (nonatomic, strong) UIView *senderGroup;
@property (nonatomic, strong) UIView *receiverGroup;
@property (nonatomic, strong) UIView *senderWaves;
@property (nonatomic, strong) UIView *receiverWaves;
@end

@implementation SoundRouteView

- (UIView *)deviceOutlineWithSize:(CGSize)size {
    UIView *outline = [[UIView alloc] initWithFrame:
        CGRectMake(0, 0, size.width, size.height)];
    outline.layer.borderColor = [UIColor whiteColor].CGColor;
    outline.layer.borderWidth = 2;
    outline.layer.cornerRadius = MIN(size.width, size.height) * 0.18;
    UIView *screen = [[UIView alloc] initWithFrame:
        CGRectInset(outline.bounds, 5, 7)];
    screen.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    screen.layer.cornerRadius = 3;
    [outline addSubview:screen];
    return outline;
}

- (UIView *)wavesView {
    UIView *waves = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 26, 30)];
    for (int i = 0; i < 3; i++) {
        CAShapeLayer *arc = [CAShapeLayer layer];
        CGFloat r = 7 + i * 6;
        arc.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(0, 15)
            radius:r startAngle:-M_PI / 4 endAngle:M_PI / 4 clockwise:YES].CGPath;
        arc.strokeColor = [UIColor colorWithWhite:1 alpha:1.0 - i * 0.25].CGColor;
        arc.fillColor = [UIColor clearColor].CGColor;
        arc.lineWidth = 2;
        arc.lineCap = kCALineCapRound;
        [waves.layer addSublayer:arc];
    }
    return waves;
}

- (UIView *)groupWithOutline:(CGSize)size title:(NSString *)title
                       waves:(UIView **)wavesOut action:(SEL)action {
    UIView *group = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 140, 124)];
    UIView *outline = [self deviceOutlineWithSize:size];
    outline.frame = CGRectMake((140 - size.width) / 2.0, 92 - size.height,
                               size.width, size.height);
    [group addSubview:outline];
    UIView *waves = [self wavesView];
    waves.frame = CGRectMake(CGRectGetMaxX(outline.frame) + 6,
                             CGRectGetMidY(outline.frame) - 15, 26, 30);
    [group addSubview:waves];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 100, 140, 22)];
    label.text = title;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.8;
    [group addSubview:label];
    [group addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:action]];
    group.accessibilityLabel = title;
    group.isAccessibilityElement = YES;
    group.accessibilityTraits = UIAccessibilityTraitButton;
    *wavesOut = waves;
    return group;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        BOOL pad = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad;
        UIView *senderWaves = nil, *receiverWaves = nil;
        self.receiverGroup = [self groupWithOutline:
            (pad ? CGSizeMake(68, 86) : CGSizeMake(34, 62))
            title:[NSString stringWithFormat:L(@"This %@"), showcase_device_noun()]
            waves:&receiverWaves action:@selector(receiverTapped)];
        self.senderGroup = [self groupWithOutline:CGSizeMake(34, 62)
                                            title:L(@"CarPlay sender")
                                            waves:&senderWaves action:@selector(senderTapped)];
        self.senderWaves = senderWaves;
        self.receiverWaves = receiverWaves;
        [self addSubview:self.receiverGroup];
        [self addSubview:self.senderGroup];
        [self applyState];
    }
    return self;
}

- (void)receiverTapped { if (self.selected && !self.receiverActive) self.selected(YES); }
- (void)senderTapped { if (self.selected && self.receiverActive) self.selected(NO); }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width;
    CGFloat spacing = MIN(60.0, W / 8.0);
    CGFloat x = (W - (140 * 2 + spacing)) / 2.0;
    self.receiverGroup.frame = CGRectMake(x, 0, 140, 124);
    self.senderGroup.frame = CGRectMake(x + 140 + spacing, 0, 140, 124);
}

- (void)applyState {
    BOOL r = self.receiverActive;
    self.senderGroup.alpha = r ? 0.3 : 1.0;
    self.receiverGroup.alpha = r ? 1.0 : 0.3;
    self.senderWaves.hidden = r;
    self.receiverWaves.hidden = !r;
    self.receiverGroup.accessibilityTraits = UIAccessibilityTraitButton | (r ? UIAccessibilityTraitSelected : 0);
    self.senderGroup.accessibilityTraits = UIAccessibilityTraitButton | (r ? 0 : UIAccessibilityTraitSelected);
}

- (void)setReceiverActive:(BOOL)active animated:(BOOL)animated {
    _receiverActive = active;
    if (!animated) { [self applyState]; return; }
    [UIView transitionWithView:self duration:0.25
        options:UIViewAnimationOptionTransitionCrossDissolve
        animations:^{ [self applyState]; } completion:nil];
}

@end

/* Builds one page top to bottom inside a fixed-width column. */
@interface SettingsPageBuilder : NSObject
@property (nonatomic, weak) UIView *container;
@property (nonatomic, assign) CGFloat width;
@property (nonatomic, assign) CGFloat y;
@end
@implementation SettingsPageBuilder
- (CGFloat)heightOfText:(NSString *)text font:(UIFont *)font width:(CGFloat)w {
    if (!text.length) return 0;
    CGRect r = [text boundingRectWithSize:CGSizeMake(w, CGFLOAT_MAX)
        options:NSStringDrawingUsesLineFragmentOrigin
        attributes:@{ NSFontAttributeName: font } context:nil];
    return ceil(r.size.height);
}
- (UILabel *)labelText:(NSString *)text font:(UIFont *)font alpha:(CGFloat)alpha
                 inset:(CGFloat)inset gapAfter:(CGFloat)gap color:(UIColor *)color {
    CGFloat w = self.width - inset * 2;
    CGFloat h = [self heightOfText:text font:font width:w];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(inset, self.y, w, h)];
    l.text = text;
    l.font = font;
    l.numberOfLines = 0;
    l.textColor = color ?: [UIColor colorWithWhite:1 alpha:alpha];
    [self.container addSubview:l];
    self.y += h + gap;
    return l;
}
- (UILabel *)message:(NSString *)text color:(UIColor *)color {
    return [self labelText:text font:[UIFont systemFontOfSize:14 weight:UIFontWeightMedium]
                     alpha:1 inset:16 gapAfter:20 color:color];
}
- (SettingsCard *)card:(void (^)(SettingsCard *card))fill {
    SettingsCard *card = [[SettingsCard alloc] initWithFrame:
        CGRectMake(0, self.y, self.width, 0)];
    fill(card);
    [self.container addSubview:card];
    self.y += card.contentHeight + 12;
    return card;
}
- (void)place:(UIView *)view height:(CGFloat)height gapAfter:(CGFloat)gap {
    view.frame = CGRectMake(0, self.y, self.width, height);
    [self.container addSubview:view];
    self.y += height + gap;
}
- (void)gap:(CGFloat)gap { self.y += gap; }
@end

@interface SettingsViewController () <UITextFieldDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *stack;
@property (nonatomic, strong) SettingsScrollView *sidebarScroll;
@property (nonatomic, strong) SettingsScrollView *detailScroll;
@property (nonatomic, strong) UIView *header;
@property (nonatomic, assign) BOOL wide;
@property (nonatomic, assign) CGSize renderedSize;
@property (nonatomic, assign) CGFloat keyboardOverlap;
@property (nonatomic, weak) UITextField *activeField;

/* page state */
@property (nonatomic, strong) Car *editingCar;
@property (nonatomic, weak) UITextField *carNameField;
@property (nonatomic, weak) UITextField *ssidField;
@property (nonatomic, weak) UITextField *passwordField;
@property (nonatomic, copy) NSString *pageMessage;
@property (nonatomic, assign) BOOL pageMessageIsError;
/* A log upload outlives navigation; its result belongs to the logs page
 * only, so it waits here until that page is shown. */
@property (nonatomic, copy) NSString *pendingLogsMessage;
@property (nonatomic, assign) BOOL pendingLogsMessageIsError;
@property (nonatomic, assign) BOOL confirmingDestructive;
/* Bumped on every change of confirmingDestructive, so a queued
 * armDestructiveConfirmation timeout only ends the confirmation it armed. */
@property (nonatomic, assign) NSUInteger confirmationToken;
@property (nonatomic, assign) BOOL passwordVisible;
@property (nonatomic, weak) SoundRouteView *soundRoute;
@property (nonatomic, copy) NSString *draftCarName;
@property (nonatomic, copy) NSString *draftSSID;
@property (nonatomic, assign) BOOL sharedSSIDEdited;
@property (nonatomic, copy) NSString *draftPassword;
@property (nonatomic, strong) NSMutableDictionary *wifiDrafts;
@property (nonatomic, assign) CGFloat fieldTitleWidth;
@end

static NSDictionary<NSString *, NSString *> *g_settings_hardware_info = nil;
static BOOL g_settings_hardware_loading = NO;

@implementation SettingsViewController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return showcase_orientation_mask();
}
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return showcase_preferred_orientation();
}
- (BOOL)prefersStatusBarHidden { return YES; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    /* Presented OverFullScreen: the setup screen and its Start button stay
     * in the hierarchy behind, so keep VoiceOver inside this screen. */
    self.view.accessibilityViewIsModal = YES;
    self.stack = [NSMutableArray array];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(keyboardWillChange:)
        name:UIKeyboardWillChangeFrameNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(keyboardWillHide:)
        name:UIKeyboardWillHideNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!CGSizeEqualToSize(self.renderedSize, self.view.bounds.size)) {
        BOOL wasEmpty = self.stack.count == 0;
        self.renderedSize = self.view.bounds.size;
        self.wide = self.view.bounds.size.width >= 900 &&
                    self.view.bounds.size.height >= 600;
        if (wasEmpty) {
            if (self.initialPage.length) {
                if (!self.wide) [self.stack addObject:@"root"];
                [self.stack addObject:self.initialPage];
            } else {
                [self.stack addObject:self.wide ? @"cars" : @"root"];
            }
        } else if (self.wide && [self.stack.firstObject isEqualToString:@"root"]) {
            [self.stack removeObjectAtIndex:0];
            if (self.stack.count == 0) [self.stack addObject:@"cars"];
        } else if (!self.wide && ![self.stack.firstObject isEqualToString:@"root"]) {
            [self.stack insertObject:@"root" atIndex:0];
        }
        [self render];
    }
}

- (AppDelegate *)app { return self.appDelegate; }

- (BOOL)sessionRunning {
    ShowcaseState s = self.appDelegate.state;
    return s != StateIdle;
}

- (NSString *)titleForPage:(NSString *)page {
    if ([page isEqualToString:@"root"]) return L(@"Settings");
    if ([page isEqualToString:@"cars"]) return L(@"Cars");
    if ([page isEqualToString:@"car"]) return self.editingCar ? L(@"Edit Car") : L(@"New Car");
    if ([page isEqualToString:@"hotspot"]) return showcase_use_existing_wifi() ? L(@"Wi-Fi Setup") : L(@"Hotspot");
    if ([page isEqualToString:@"sound"]) return L(@"Sound");
    if ([page isEqualToString:@"display"]) return L(@"Display");
    if ([page isEqualToString:@"resolution"]) return L(@"Resolution");
    if ([page isEqualToString:@"language"]) return L(@"Language");
    if ([page isEqualToString:@"logs"]) return L(@"Troubleshooting");
    if ([page isEqualToString:@"usage"]) return L(@"Anonymous Usage");
    if ([page isEqualToString:@"about"]) return L(@"About");
    return L(@"Settings");
}

/* ─── navigation ─── */

- (void)clearDrafts {
    self.draftCarName = nil;
    self.draftSSID = nil;
    self.sharedSSIDEdited = NO;
    self.draftPassword = nil;
    self.wifiDrafts = nil;
    self.carNameField = nil;
    self.ssidField = nil;
    self.passwordField = nil;
}

- (void)push:(NSString *)page {
    [self clearDrafts];
    self.pageMessage = nil;
    self.confirmingDestructive = NO;
    [self.view endEditing:YES];
    [self.stack addObject:page];
    [self render];
}

- (void)pop {
    if (self.stack.count <= 1) return;
    [self clearDrafts];
    self.pageMessage = nil;
    self.confirmingDestructive = NO;
    [self.view endEditing:YES];
    [self.stack removeLastObject];
    [self render];
}

- (void)selectSection:(NSString *)page {
    [self clearDrafts];
    self.pageMessage = nil;
    self.confirmingDestructive = NO;
    [self.view endEditing:YES];
    if (self.wide) {
        [self.stack removeAllObjects];
        [self.stack addObject:page];
        [self render];
    } else {
        [self push:page];
    }
}

- (void)close {
    [self.view endEditing:YES];
    AppDelegate *app = self.appDelegate;
    [self dismissViewControllerAnimated:YES completion:^{
        [app settingsDidClose];
    }];
}

- (BOOL)accessibilityPerformEscape {
    [self close];
    return YES;
}

- (void)refresh {
    if (!self.isViewLoaded || self.stack.count == 0) return;
    if (self.activeField.isFirstResponder) {
        /* Pages locked during a session drop the keyboard so the lock shows. */
        NSString *page = self.stack.lastObject;
        if (!(self.sessionRunning && ([page isEqualToString:@"hotspot"] ||
                                      [page isEqualToString:@"car"]))) return;
        [self.view endEditing:YES];
    }
    [self render];
}

/* ─── rendering ─── */

- (UIButton *)headerButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.tintColor = [UIColor whiteColor];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)render {
    UIEdgeInsets safe = showcase_safe_insets(self.view);
    CGFloat W = self.view.bounds.size.width;
    CGFloat H = self.view.bounds.size.height;
    BOOL phone = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone;
    CGFloat left = MAX(safe.left, phone ? 12 : 20);
    CGFloat right = MAX(safe.right, phone ? 12 : 20);
    CGFloat headerH = phone ? 56 : 68;

    /* Rebuilding replaces every field; keep what the user has typed. */
    if (self.carNameField) self.draftCarName = self.carNameField.text;
    if (self.ssidField) self.draftSSID = self.ssidField.text;
    if (self.passwordField) self.draftPassword = self.passwordField.text;
    CGPoint previousOffset = self.detailScroll.contentOffset;
    NSString *previousPage = objc_getAssociatedObject(self.detailScroll, "page");
    [self.header removeFromSuperview];
    [self.sidebarScroll removeFromSuperview];
    [self.detailScroll removeFromSuperview];
    self.sidebarScroll = nil;

    NSString *page = self.stack.lastObject;
    CGFloat sidebarW = self.wide ? 320 : 0;
    self.fieldTitleWidth = 0;

    /* Header */
    self.header = [[UIView alloc] initWithFrame:CGRectMake(0, safe.top, W, headerH)];
    [self.view addSubview:self.header];

    CGFloat closeSz = 44;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(W - right - closeSz, (headerH - closeSz) / 2.0, closeSz, closeSz);
    close.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    close.layer.cornerRadius = closeSz / 2.0;
    [close setTitle:@"×" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightLight];
    close.titleEdgeInsets = UIEdgeInsetsMake(-2, 0, 0, 0);
    close.accessibilityLabel = L(@"Close");
    [close addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [self.header addSubview:close];

    CGFloat detailX = self.wide ? left + sidebarW : 0;
    CGFloat detailW = W - detailX;
    CGFloat headerInset = self.wide ? 90 : MAX(left, right) + 52;
    UILabel *title = [[UILabel alloc] initWithFrame:
        CGRectMake(detailX + headerInset, 0, MAX(0, detailW - 2 * headerInset), headerH)];
    title.text = [self titleForPage:page];
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.75;
    [self.header addSubview:title];

    if (self.wide) {
        UILabel *settingsTitle = [[UILabel alloc] initWithFrame:
            CGRectMake(left + 16, 0, sidebarW - 16, headerH)];
        settingsTitle.text = L(@"Settings");
        settingsTitle.textColor = [UIColor whiteColor];
        settingsTitle.font = [UIFont systemFontOfSize:30 weight:UIFontWeightLight];
        [self.header addSubview:settingsTitle];
    }
    if (self.stack.count > 1) {
        NSString *previous = [self titleForPage:self.stack[self.stack.count - 2]];
        UIButton *back = [self headerButtonWithTitle:
            [NSString stringWithFormat:@"‹  %@", previous] action:@selector(pop)];
        if (!self.wide) {
            [back setTitle:@"‹" forState:UIControlStateNormal];
            back.accessibilityLabel = previous;
        }
        back.frame = CGRectMake((self.wide ? detailX + 8 : left), 0, self.wide ? 80 : 44, headerH);
        back.titleLabel.adjustsFontSizeToFitWidth = YES;
        back.titleLabel.minimumScaleFactor = 0.7;
        [self.header addSubview:back];
    }

    CGFloat top = safe.top + headerH;
    CGFloat bottomPad = MAX(safe.bottom, 16);

    /* Sidebar */
    if (self.wide) {
        self.sidebarScroll = [[SettingsScrollView alloc] initWithFrame:
            CGRectMake(left, top, sidebarW, H - top)];
        self.sidebarScroll.delaysContentTouches = NO;
        self.sidebarScroll.alwaysBounceVertical = YES;
        self.sidebarScroll.showsVerticalScrollIndicator = NO;
        [self.view addSubview:self.sidebarScroll];
        SettingsPageBuilder *b = [[SettingsPageBuilder alloc] init];
        b.container = self.sidebarScroll;
        b.width = sidebarW - 16;
        b.y = 12;
        [self buildRoot:b selected:self.stack.firstObject];
        self.sidebarScroll.contentSize = CGSizeMake(sidebarW, b.y + bottomPad);
    }

    /* Detail */
    self.detailScroll = [[SettingsScrollView alloc] initWithFrame:
        CGRectMake(detailX, top, detailW, H - top)];
    self.detailScroll.delaysContentTouches = NO;
    self.detailScroll.alwaysBounceVertical = YES;
    self.detailScroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:self.detailScroll];

    CGFloat innerLeft = self.wide ? 24 : left;
    CGFloat innerRight = right;
    CGFloat colW = MIN(detailW - innerLeft - innerRight, 600);
    UIView *column = [[UIView alloc] initWithFrame:
        CGRectMake(innerLeft + floor((detailW - innerLeft - innerRight - colW) / 2.0), 0, colW, 0)];
    [self.detailScroll addSubview:column];

    SettingsPageBuilder *b = [[SettingsPageBuilder alloc] init];
    b.container = column;
    b.width = colW;
    b.y = 12;
    if ([page isEqualToString:@"root"]) [self buildRoot:b selected:nil];
    else if ([page isEqualToString:@"cars"]) [self buildCars:b];
    else if ([page isEqualToString:@"car"]) [self buildCar:b];
    else if ([page isEqualToString:@"hotspot"]) [self buildHotspot:b];
    else if ([page isEqualToString:@"sound"]) [self buildSound:b];
    else if ([page isEqualToString:@"display"]) [self buildDisplay:b];
    else if ([page isEqualToString:@"resolution"]) [self buildResolution:b];
    else if ([page isEqualToString:@"language"]) [self buildLanguage:b];
    else if ([page isEqualToString:@"logs"]) [self buildLogs:b];
    else if ([page isEqualToString:@"usage"]) [self buildUsage:b];
    else if ([page isEqualToString:@"about"]) [self buildAbout:b];
    CGRect cf = column.frame;
    cf.size.height = b.y;
    column.frame = cf;
    self.detailScroll.contentSize = CGSizeMake(detailW, b.y + bottomPad);
    self.detailScroll.contentInset = UIEdgeInsetsMake(0, 0, self.keyboardOverlap, 0);
    objc_setAssociatedObject(self.detailScroll, "page", page, OBJC_ASSOCIATION_COPY);
    if ([previousPage isEqualToString:page]) {
        CGFloat maxY = MAX(0, self.detailScroll.contentSize.height -
                              self.detailScroll.bounds.size.height + self.keyboardOverlap);
        self.detailScroll.contentOffset = CGPointMake(0, MIN(previousOffset.y, maxY));
    }
}

/* ─── row factories ─── */

- (UILabel *)rowTitle:(NSString *)text frame:(CGRect)frame {
    UILabel *l = [[UILabel alloc] initWithFrame:frame];
    l.text = text;
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    return l;
}

- (SettingsRow *)navRow:(NSString *)title value:(NSString *)value
                  width:(CGFloat)w selected:(BOOL)selected
                 action:(ShowcaseAction)action {
    SettingsRow *row = [[SettingsRow alloc] initWithFrame:CGRectMake(0, 0, w, 52)];
    row.action = action;
    row.accessibilityLabel = title;
    row.accessibilityValue = value;
    row.accessibilityTraits |= UIAccessibilityTraitButton;
    if (selected) {
        UIView *bg = [[UIView alloc] initWithFrame:row.bounds];
        bg.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
        bg.userInteractionEnabled = NO;
        [row addSubview:bg];
    }
    /* The title keeps its full width; the value takes what is left. */
    UILabel *titleLabel = [self rowTitle:title frame:CGRectZero];
    CGFloat titleW = MIN(ceil([titleLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, 52)].width),
                         w - 16 - 34 - 40);
    titleLabel.frame = CGRectMake(16, 0, titleW, 52);
    [row addSubview:titleLabel];
    CGFloat valueX = 16 + titleW + 12;
    CGFloat valueW = MAX(0, w - 30 - valueX);
    UILabel *v = [[UILabel alloc] initWithFrame:
        CGRectMake(valueX, 0, valueW, 52)];
    v.text = value;
    v.textAlignment = NSTextAlignmentRight;
    v.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    v.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
    v.lineBreakMode = NSLineBreakByTruncatingTail;
    [row addSubview:v];
    UILabel *chevron = [[UILabel alloc] initWithFrame:CGRectMake(w - 26, 0, 14, 52)];
    chevron.text = @"›";
    chevron.textColor = [UIColor colorWithWhite:1 alpha:0.35];
    chevron.font = [UIFont systemFontOfSize:24 weight:UIFontWeightLight];
    [row addSubview:chevron];
    return row;
}

- (SettingsRow *)actionRow:(NSString *)title color:(UIColor *)color
                     width:(CGFloat)w enabled:(BOOL)enabled
                    action:(ShowcaseAction)action {
    SettingsRow *row = [[SettingsRow alloc] initWithFrame:CGRectMake(0, 0, w, 52)];
    row.action = action;
    row.accessibilityLabel = title;
    row.accessibilityTraits |= UIAccessibilityTraitButton;
    row.enabled = enabled;
    UILabel *l = [self rowTitle:title frame:CGRectMake(16, 0, w - 32, 52)];
    l.textColor = enabled ? (color ?: [UIColor whiteColor])
                          : [UIColor colorWithWhite:1 alpha:0.3];
    [row addSubview:l];
    return row;
}

- (UIView *)valueRow:(NSString *)title value:(NSString *)value width:(CGFloat)w {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 48)];
    [row addSubview:[self rowTitle:title frame:CGRectMake(16, 0, w * 0.45, 48)]];
    UILabel *v = [[UILabel alloc] initWithFrame:
        CGRectMake(w * 0.45, 0, w * 0.55 - 16, 48)];
    v.text = value;
    v.textAlignment = NSTextAlignmentRight;
    v.textColor = [UIColor colorWithWhite:1 alpha:0.5];
    v.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
    v.adjustsFontSizeToFitWidth = YES;
    v.minimumScaleFactor = 0.75;
    [row addSubview:v];
    return row;
}

- (CGFloat)switchRowHeightWithSubtitle:(NSString *)subtitle width:(CGFloat)w {
    if (!subtitle.length) return 52;
    CGRect r = [subtitle boundingRectWithSize:CGSizeMake(w - 16 - 84, CGFLOAT_MAX)
        options:NSStringDrawingUsesLineFragmentOrigin
        attributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:13] }
        context:nil];
    return 40 + ceil(r.size.height) + 12;
}

- (UIView *)switchRow:(NSString *)title subtitle:(NSString *)subtitle
                   on:(BOOL)on width:(CGFloat)w
              changed:(void (^)(BOOL on))changed {
    CGFloat h = [self switchRowHeightWithSubtitle:subtitle width:w];
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    CGFloat textW = w - 16 - 84;
    [row addSubview:[self rowTitle:title
        frame:CGRectMake(16, subtitle.length ? 10 : 0, textW, subtitle.length ? 26 : h)]];
    if (subtitle.length) {
        UILabel *s = [[UILabel alloc] initWithFrame:CGRectMake(16, 38, textW, h - 50)];
        s.text = subtitle;
        s.numberOfLines = 0;
        s.textColor = [UIColor colorWithWhite:1 alpha:0.45];
        s.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        [row addSubview:s];
    }
    SettingsSwitch *sw = [[SettingsSwitch alloc] init];
    sw.accessibilityLabel = title;
    sw.accessibilityHint = subtitle;
    sw.on = on;
    sw.changed = changed;
    CGSize ss = sw.intrinsicContentSize;
    if (ss.width <= 0) ss = CGSizeMake(51, 31);
    sw.frame = CGRectMake(w - 16 - ss.width,
        subtitle.length ? 13 : (h - ss.height) / 2.0, ss.width, ss.height);
    [row addSubview:sw];
    return row;
}

- (SettingsRow *)choiceRow:(NSString *)title value:(NSString *)value checked:(BOOL)checked
                     width:(CGFloat)w action:(ShowcaseAction)action {
    SettingsRow *row = [[SettingsRow alloc] initWithFrame:CGRectMake(0, 0, w, 52)];
    row.action = action;
    row.accessibilityLabel = title;
    row.accessibilityValue = value;
    row.accessibilityTraits |= UIAccessibilityTraitButton;
    UILabel *choiceTitle = [self rowTitle:title frame:CGRectMake(16, 0, value.length ? w * 0.5 : w - 64, 52)];
    choiceTitle.adjustsFontSizeToFitWidth = YES;
    choiceTitle.minimumScaleFactor = 0.75;
    [row addSubview:choiceTitle];
    UILabel *v = [[UILabel alloc] initWithFrame:CGRectMake(w * 0.5, 0, w * 0.5 - 52, 52)];
    v.text = value;
    v.textAlignment = NSTextAlignmentRight;
    v.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    v.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
    [row addSubview:v];
    UILabel *check = [[UILabel alloc] initWithFrame:CGRectMake(w - 40, 0, 24, 52)];
    check.text = checked ? @"✓" : @"";
    check.textColor = [UIColor whiteColor];
    check.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
    [row addSubview:check];
    if (checked) row.accessibilityTraits |= UIAccessibilityTraitSelected;
    return row;
}

- (UIView *)segmentRow:(NSString *)title items:(NSArray<NSString *> *)items selected:(NSInteger)selected
                 width:(CGFloat)w enabled:(BOOL)enabled changed:(void (^)(NSInteger index))changed {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 52)];
    [row addSubview:[self rowTitle:title frame:CGRectMake(16, 0, w * 0.5, 52)]];
    SettingsSegments *segments = [[SettingsSegments alloc] initWithItems:items];
    segments.selectedSegmentIndex = MIN(selected, (NSInteger)items.count - 1);
    segments.tintColor = [UIColor whiteColor];
    segments.enabled = enabled;
    segments.changed = changed;
    CGFloat segmentW = 56.0 * items.count;
    segments.frame = CGRectMake(w - 16 - segmentW, 11, segmentW, 30);
    [row addSubview:segments];
    row.alpha = enabled ? 1 : 0.35;
    return row;
}

/* Field titles share one column: the widest title, at least 100 points. */
- (CGFloat)titleWidthFor:(NSArray<NSString *> *)titles {
    CGFloat widest = 100;
    UIFont *font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    for (NSString *title in titles)
        widest = MAX(widest, ceil([title sizeWithAttributes:@{NSFontAttributeName: font}].width) + 8);
    return widest;
}

- (UITextField *)fieldRowInCard:(SettingsCard *)card title:(NSString *)title
                           text:(NSString *)text placeholder:(NSString *)placeholder
                         secure:(BOOL)secure trailing:(UIView *)trailing {
    CGFloat w = card.bounds.size.width;
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 52)];
    CGFloat fieldX = 16;
    if (title.length) {
        CGFloat titleW = self.fieldTitleWidth ?: [self titleWidthFor:@[title]];
        [row addSubview:[self rowTitle:title frame:CGRectMake(16, 0, titleW, 52)]];
        fieldX = 16 + titleW + 4;
    }
    CGFloat trailingW = trailing ? trailing.bounds.size.width + 8 : 0;
    UITextField *field = [[UITextField alloc] initWithFrame:
        CGRectMake(fieldX, 0, w - fieldX - 16 - trailingW, 52)];
    field.text = text;
    field.accessibilityLabel = title.length ? title : placeholder;
    field.textColor = [UIColor whiteColor];
    field.tintColor = [UIColor whiteColor];
    field.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    field.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:placeholder ?: @""
            attributes:@{ NSForegroundColorAttributeName:
                              [UIColor colorWithWhite:1 alpha:0.3] }];
    field.secureTextEntry = secure;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.keyboardAppearance = UIKeyboardAppearanceDark;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.delegate = self;
    [row addSubview:field];
    if (trailing) {
        trailing.frame = CGRectMake(w - 16 - trailing.bounds.size.width,
            (52 - trailing.bounds.size.height) / 2.0,
            trailing.bounds.size.width, trailing.bounds.size.height);
        [row addSubview:trailing];
    }
    [card addRow:row height:52];
    return field;
}

- (UIButton *)pillButton:(NSString *)title action:(SEL)action width:(CGFloat)w {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, w, 50);
    b.backgroundColor = [UIColor colorWithRed:0.23 green:0.51 blue:0.96 alpha:1];
    b.layer.cornerRadius = 25;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b setTitleColor:[UIColor colorWithWhite:1 alpha:0.55] forState:UIControlStateHighlighted];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)placePill:(UIButton *)pill builder:(SettingsPageBuilder *)b {
    UIView *holder = [[UIView alloc] init];
    [b place:holder height:50 gapAfter:20];
    pill.frame = CGRectMake(0, 0, b.width, 50);
    [holder addSubview:pill];
}

- (void)showPageMessage:(SettingsPageBuilder *)b {
    if (!self.pageMessage.length) return;
    [b message:self.pageMessage
         color:self.pageMessageIsError
            ? [UIColor colorWithRed:1.0 green:0.42 blue:0.38 alpha:1]
            : [UIColor colorWithRed:0.45 green:0.86 blue:0.55 alpha:1]];
}

- (void)setMessage:(NSString *)message error:(BOOL)error {
    self.pageMessage = message;
    self.pageMessageIsError = error;
    [self render];
}

- (UIColor *)destructiveColor {
    return [UIColor colorWithRed:1.0 green:0.38 blue:0.35 alpha:1];
}

- (void)setConfirmingDestructive:(BOOL)confirmingDestructive {
    _confirmingDestructive = confirmingDestructive;
    self.confirmationToken++;
}

- (void)armDestructiveConfirmation {
    self.confirmingDestructive = YES;
    NSUInteger token = self.confirmationToken;
    [self render];
    __weak SettingsViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        /* Leaving the page and arming again within the timeout must not let
         * this older timer close the newer confirmation. */
        if (!weakSelf.confirmingDestructive ||
            weakSelf.confirmationToken != token) return;
        weakSelf.confirmingDestructive = NO;
        [weakSelf render];
    });
}

/* ─── pages ─── */

- (void)buildRoot:(SettingsPageBuilder *)b selected:(NSString *)selected {
    AppDelegate *app = self.appDelegate;
    CGFloat w = b.width;
    __weak SettingsViewController *weakSelf = self;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    BOOL receiverAudio = [d boolForKey:RECEIVER_AUDIO_KEY];

    [b card:^(SettingsCard *card) {
        [card addRow:[self navRow:L(@"Cars") value:app.cars.selected.name ?: @""
            width:w selected:[selected isEqualToString:@"cars"]
            action:^{ [weakSelf selectSection:@"cars"]; }] height:52];
        [card addRow:[self navRow:L(@"Wi-Fi Setup")
            value:app.cars.apSSID.length ? app.cars.apSSID : L(@"Not set")
            width:w selected:[selected isEqualToString:@"hotspot"]
            action:^{ [weakSelf selectSection:@"hotspot"]; }] height:52];
    }];
    [b card:^(SettingsCard *card) {
        [card addRow:[self navRow:L(@"Sound")
            value:receiverAudio
                ? [NSString stringWithFormat:L(@"This %@"), showcase_device_noun()]
                : L(@"CarPlay sender")
            width:w selected:[selected isEqualToString:@"sound"]
            action:^{ [weakSelf selectSection:@"sound"]; }] height:52];
        [card addRow:[self navRow:L(@"Display") value:@""
            width:w selected:[selected isEqualToString:@"display"]
            action:^{ [weakSelf selectSection:@"display"]; }] height:52];
        [card addRow:[self navRow:L(@"Language") value:showcase_language_name(showcase_language())
            width:w selected:[selected isEqualToString:@"language"]
            action:^{ [weakSelf selectSection:@"language"]; }] height:52];
    }];
    [b card:^(SettingsCard *card) {
        [card addRow:[self navRow:L(@"Troubleshooting")
            value:app.diagnosticsEnabled ? L(@"Logging on") : @""
            width:w selected:[selected isEqualToString:@"logs"]
            action:^{ [weakSelf selectSection:@"logs"]; }] height:52];
        [card addRow:[self navRow:L(@"Anonymous Usage")
            value:[[NSUserDefaults standardUserDefaults] boolForKey:USAGE_KEY] ? L(@"On") : L(@"Off")
            width:w selected:[selected isEqualToString:@"usage"]
            action:^{ [weakSelf selectSection:@"usage"]; }] height:52];
        [card addRow:[self navRow:L(@"About") value:@""
            width:w selected:[selected isEqualToString:@"about"]
            action:^{ [weakSelf selectSection:@"about"]; }] height:52];
    }];
    if (self.sessionRunning) {
        [b card:^(SettingsCard *card) {
            [card addRow:[self actionRow:L(@"Stop CarPlay") color:[self destructiveColor]
                width:w enabled:YES action:^{
                    AppDelegate *strongApp = weakSelf.appDelegate;
                    [weakSelf close];
                    [strongApp stopFlow];
                }] height:52];
        }];
    }
}

- (void)buildCars:(SettingsPageBuilder *)b {
    AppDelegate *app = self.appDelegate;
    CGFloat w = b.width;
    __weak SettingsViewController *weakSelf = self;
    [b card:^(SettingsCard *card) {
        for (Car *car in app.cars.cars) {
            BOOL isSelected = car == app.cars.selected;
            SettingsRow *row = [[SettingsRow alloc] initWithFrame:CGRectMake(0, 0, w, 52)];
            row.action = ^{
                if (weakSelf.sessionRunning) return;
                [app.cars selectCar:car];
                [app renderState];
                [weakSelf render];
            };
            [row addSubview:[self rowTitle:car.name frame:CGRectMake(16, 0, w - 130, 52)]];
            row.accessibilityLabel = car.name;
            row.accessibilityTraits |= UIAccessibilityTraitButton |
                (isSelected ? UIAccessibilityTraitSelected : 0);
            if (isSelected) {
                UIView *check = showcase_check_badge(22, [UIColor whiteColor], [UIColor blackColor]);
                check.frame = CGRectMake(w - 104, 15, 22, 22);
                [row addSubview:check];
            }
            UIButton *edit = [UIButton buttonWithType:UIButtonTypeSystem];
            edit.frame = CGRectMake(w - 70, 8, 60, 36);
            [edit setTitle:L(@"Edit") forState:UIControlStateNormal];
            edit.tintColor = [UIColor colorWithWhite:1 alpha:0.6];
            edit.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
            objc_setAssociatedObject(edit, "car", car, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [edit addTarget:self action:@selector(editCarTapped:)
           forControlEvents:UIControlEventTouchUpInside];
            [row addSubview:edit];
            /* The helpers got the car name at launch; see lockForSession. */
            [self lockForSession:row];
            [card addRow:row height:52];
        }
    }];
    [b card:^(SettingsCard *card) {
        UIView *add = [self actionRow:L(@"Add Car") color:nil width:w enabled:YES action:^{
            if (weakSelf.sessionRunning) return;
            weakSelf.editingCar = nil;
            [weakSelf push:@"car"];
        }];
        [self lockForSession:add];
        [card addRow:add height:52];
    }];
    if (self.sessionRunning)
        [b message:L(@"Stop CarPlay to change these settings.") color:nil];
}

- (void)editCarTapped:(UIButton *)sender {
    self.editingCar = objc_getAssociatedObject(sender, "car");
    [self push:@"car"];
}

- (void)buildCar:(SettingsPageBuilder *)b {
    AppDelegate *app = self.appDelegate;
    CGFloat w = b.width;
    __weak SettingsViewController *weakSelf = self;
    Car *car = self.editingCar;
    [b card:^(SettingsCard *card) {
        self.carNameField = [self fieldRowInCard:card title:L(@"Name")
            text:self.draftCarName ?: car.name placeholder:@"Miata"
            secure:NO trailing:nil];
        self.carNameField.autocapitalizationType = UITextAutocapitalizationTypeWords;
        self.carNameField.returnKeyType = UIReturnKeyDone;
        self.carNameField.enabled = !self.sessionRunning;
    }];
    [b gap:8];
    [self showPageMessage:b];
    if (self.sessionRunning)
        [b message:L(@"Stop CarPlay to change these settings.") color:nil];
    UIButton *save = [self pillButton:L(@"Save") action:@selector(saveCar) width:w];
    save.enabled = !self.sessionRunning;
    save.alpha = self.sessionRunning ? 0.5 : 1.0;
    [self placePill:save builder:b];

    if (car && car != app.cars.selected) {
        [b card:^(SettingsCard *card) {
            UIView *use = [self actionRow:L(@"Use This Car") color:nil width:w enabled:YES action:^{
                if (weakSelf.sessionRunning) return;
                [app.cars selectCar:car];
                [app renderState];
                [weakSelf pop];
            }];
            [self lockForSession:use];
            [card addRow:use height:52];
        }];
    }
    if (car && app.cars.cars.count > 1) {
        [b card:^(SettingsCard *card) {
            UIView *deleteRow = [self actionRow:
                self.confirmingDestructive ? L(@"Tap Again to Delete") : L(@"Delete Car")
                color:[self destructiveColor] width:w enabled:YES action:^{
                    if (weakSelf.sessionRunning) return;
                    if (!weakSelf.confirmingDestructive) {
                        [weakSelf armDestructiveConfirmation];
                        return;
                    }
                    weakSelf.confirmingDestructive = NO;
                    NSInteger index = [app.cars.cars indexOfObject:car];
                    if (index != NSNotFound) [app.cars deleteCarAtIndex:index];
                    [app renderState];
                    [weakSelf pop];
                }];
            [self lockForSession:deleteRow];
            [card addRow:deleteRow height:52];
        }];
    }
}

- (void)saveCar {
    /* The running helpers keep the name they were started with. */
    if (self.sessionRunning) return;
    AppDelegate *app = self.appDelegate;
    NSString *name = [self.carNameField.text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *error = nil;
    if (name.length == 0) error = L(@"Enter a name for the car.");
    else if ([name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 31)
        error = L(@"Use a shorter name. CarPlay allows up to 31 bytes (fewer characters for non-Latin letters).");
    else {
        for (Car *other in app.cars.cars) {
            if (other != self.editingCar &&
                [other.name caseInsensitiveCompare:name] == NSOrderedSame) {
                error = L(@"Another car already uses this name.");
                break;
            }
        }
    }
    if (error) { [self setMessage:error error:YES]; return; }
    [self.view endEditing:YES];
    if (self.editingCar) {
        BOOL wasSelected = self.editingCar == app.cars.selected;
        self.editingCar.name = name;
        if (wasSelected) [app.cars selectCar:self.editingCar];
        else [app.cars save];
    } else {
        Car *car = [[Car alloc] init];
        car.name = name;
        [app.cars addCar:car];
        [app.cars selectCar:car];
    }
    [app renderState];
    [self pop];
}

- (void)selectWiFiMode:(BOOL)shared {
    if (self.sessionRunning || shared == showcase_use_existing_wifi()) return;
    if (!self.wifiDrafts) self.wifiDrafts = [NSMutableDictionary dictionary];
    NSString *oldKey = showcase_use_existing_wifi() ? @"shared" : @"hotspot";
    self.wifiDrafts[oldKey] = @[(self.ssidField.text ?: @""), (self.passwordField.text ?: @"")];
    [self.view endEditing:YES];
    /* An automatic start still waiting for the old mode's network must not
     * fire into the new mode's (possibly unsaved) credentials. */
    if (self.appDelegate.autoStartNetworkDeadline > 0) {
        ip_log("[WIFI] Wi-Fi mode changed; automatic start wait cancelled");
        self.appDelegate.autoStartNetworkDeadline = 0;
    }
    [self.appDelegate.cars selectExistingWiFi:shared];
    NSArray *draft = self.wifiDrafts[shared ? @"shared" : @"hotspot"];
    self.draftSSID = draft.count ? draft[0] : nil;
    self.draftPassword = draft.count > 1 ? draft[1] : nil;
    self.ssidField = nil;
    self.passwordField = nil;
    self.pageMessage = nil;
    [self.appDelegate renderState];
    [self render];
}

- (void)buildHotspot:(SettingsPageBuilder *)b {
    AppDelegate *app = self.appDelegate;
    CGFloat w = b.width;
    BOOL shared = showcase_use_existing_wifi();
    __weak SettingsViewController *weakSelf = self;
    [b card:^(SettingsCard *card) {
        SettingsRow *existing = [self choiceRow:L(@"Existing Wi-Fi network") value:@""
            checked:shared width:w action:^{
                [weakSelf selectWiFiMode:YES];
            }];
        SettingsRow *hotspot = [self choiceRow:L(@"Personal Hotspot") value:@""
            checked:!shared width:w action:^{
                [weakSelf selectWiFiMode:NO];
            }];
        existing.enabled = !self.sessionRunning;
        hotspot.enabled = !self.sessionRunning;
        existing.alpha = self.sessionRunning ? 0.5 : 1.0;
        hotspot.alpha = self.sessionRunning ? 0.5 : 1.0;
        [card addRow:existing height:52];
        [card addRow:hotspot height:52];
    }];
    if (shared) [b message:L(@"Enter the portable router's Wi-Fi name and password. Connect both devices to that network.") color:nil];
    if (self.sessionRunning) [b message:L(@"Stop CarPlay to change Wi-Fi settings.") color:nil];
    UIButton *show = [UIButton buttonWithType:UIButtonTypeSystem];
    [show setTitle:self.passwordVisible ? L(@"Hide") : L(@"Show") forState:UIControlStateNormal];
    show.tintColor = [UIColor colorWithWhite:1 alpha:0.6];
    show.titleLabel.font = [UIFont systemFontOfSize:15];
    /* Wide enough for either word, so the field does not move on toggle. */
    NSDictionary *font = @{NSFontAttributeName: show.titleLabel.font};
    CGFloat showW = MAX([L(@"Hide") sizeWithAttributes:font].width, [L(@"Show") sizeWithAttributes:font].width);
    show.frame = CGRectMake(0, 0, MAX(52, ceil(showW) + 12), 44);
    self.fieldTitleWidth = [self titleWidthFor:@[L(@"Name"), L(@"Password")]];
    [show addTarget:self action:@selector(togglePasswordVisible)
   forControlEvents:UIControlEventTouchUpInside];
    NSString *ssid = self.draftSSID ?: app.cars.apSSID;
    NSString *password = self.draftPassword ?: app.cars.apPassword;
    NSString *connectedSSID = shared ? showcase_current_wifi_ssid() : nil;
    if (shared && !ssid.length && !app.cars.apSSID.length &&
        !self.sharedSSIDEdited && connectedSSID.length) ssid = connectedSSID;
    if (connectedSSID.length && ![connectedSSID isEqualToString:ssid]) {
        [b message:[NSString stringWithFormat:L(@"Connected to “%@”. To use this network, enter its name and password below, then tap Save."), connectedSSID] color:nil];
    }
    [b card:^(SettingsCard *card) {
        self.ssidField = [self fieldRowInCard:card title:L(@"Name") text:ssid
            placeholder:(connectedSSID.length ? connectedSSID : @"Carplay-Receiver") secure:NO trailing:nil];
        [self.ssidField addTarget:self action:@selector(wifiNameEdited:) forControlEvents:UIControlEventEditingChanged];
        self.ssidField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.ssidField.returnKeyType = UIReturnKeyNext;
        self.ssidField.enabled = !self.sessionRunning;
        self.passwordField = [self fieldRowInCard:card title:L(@"Password") text:password
            placeholder:L(@"8 characters or more") secure:!self.passwordVisible trailing:show];
        self.passwordField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.passwordField.returnKeyType = UIReturnKeyDone;
        self.passwordField.enabled = !self.sessionRunning;
    }];
    [b gap:8];
    [self showPageMessage:b];
    UIButton *save = [self pillButton:L(@"Save") action:@selector(saveHotspot) width:w];
    save.enabled = !self.sessionRunning;
    save.alpha = self.sessionRunning ? 0.5 : 1.0;
    [self placePill:save builder:b];

    if (!shared) [b card:^(SettingsCard *card) {
        [card addRow:[self actionRow:[NSString stringWithFormat:L(@"Rename This %@"), showcase_device_noun()]
            color:nil width:w enabled:YES action:^{
            NSURL *u = [NSURL URLWithString:@"App-Prefs:root=General&path=About"];
            UIApplication *a = [UIApplication sharedApplication];
            if (![a canOpenURL:u]) u = [NSURL URLWithString:@"prefs:root=General&path=About"];
            [a openURL:u options:@{} completionHandler:nil];
        }] height:52];
    }];
}

- (void)togglePasswordVisible {
    self.passwordVisible = !self.passwordVisible;
    [self render];
}

- (void)saveHotspot {
    if (self.sessionRunning) return;
    AppDelegate *app = self.appDelegate;
    NSString *ssid = [self.ssidField.text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    NSString *pass = self.passwordField.text ?: @"";
    NSString *error = validateNetworkSSID(ssid);
    if (!error) error = validateNetworkPassword(pass);
    [self.view endEditing:YES];
    if (error) { [self setMessage:error error:YES]; return; }
    [app.cars setAPSSID:ssid password:pass];
    [app renderState];
    NSString *deviceName = showcase_use_existing_wifi() ? nil : hotspot_name();
    if (deviceName && ![deviceName isEqualToString:ssid]) {
        [self setMessage:[NSString stringWithFormat:
            L(@"Saved, but this %1$@'s hotspot is called \u201c%2$@\u201d. Your iPhone can't join until the names match."),
            showcase_device_noun(), deviceName] error:YES];
        return;
    }
    [self setMessage:L(@"Saved.") error:NO];
}

/* These settings reach the helpers only as launch arguments, so a change made
 * while CarPlay runs would silently wait for the next start. Lock them the way
 * the Wi-Fi page does. */
- (void)lockForSession:(UIView *)row {
    if (!self.sessionRunning) return;
    row.userInteractionEnabled = NO;
    row.alpha = MIN(row.alpha, 0.5);
    row.accessibilityTraits |= UIAccessibilityTraitNotEnabled;
}

- (void)buildSound:(SettingsPageBuilder *)b {
    CGFloat w = b.width;
    __weak SettingsViewController *weakSelf = self;
    BOOL receiverAudio = [[NSUserDefaults standardUserDefaults] boolForKey:RECEIVER_AUDIO_KEY];
    void (^choose)(BOOL) = ^(BOOL on) {
        [[NSUserDefaults standardUserDefaults] setBool:on forKey:RECEIVER_AUDIO_KEY];
        [[NSUserDefaults standardUserDefaults] synchronize];
        ip_log("settings: receiver audio %s", on ? "on" : "off");
        [weakSelf.soundRoute setReceiverActive:on animated:YES];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf render]; });
    };

    [b gap:16];
    SoundRouteView *route = [[SoundRouteView alloc] initWithFrame:CGRectMake(0, 0, w, 124)];
    [route setReceiverActive:receiverAudio animated:NO];
    route.selected = choose;
    [self lockForSession:route];
    [b place:route height:124 gapAfter:28];
    self.soundRoute = route;

    [b card:^(SettingsCard *card) {
        UIView *row = [self switchRow:[NSString stringWithFormat:L(@"Play Sound on This %@"), showcase_device_noun()]
            subtitle:nil on:receiverAudio width:w changed:choose];
        [self lockForSession:row];
        [card addRow:row height:row.bounds.size.height];
    }];
    if (self.sessionRunning)
        [b message:L(@"Stop CarPlay to change these settings.") color:nil];
}

- (NSString *)sizeText:(CarPlayVideoSize)size {
    return [NSString stringWithFormat:@"%u × %u", size.width, size.height];
}

- (NSString *)videoDescription {
    CarPlayDisplayProfile profile = preferred_carplay_display_profile();
    return [NSString stringWithFormat:L(@"%u × %u at %u fps"),
        profile.width, profile.height, profile.framesPerSecond];
}

- (void)buildDisplay:(SettingsPageBuilder *)b {
    CGFloat w = b.width;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    __weak SettingsViewController *weakSelf = self;
    void (^setter)(NSString *, BOOL) = ^(NSString *key, BOOL on) {
        [[NSUserDefaults standardUserDefaults] setBool:on forKey:key];
        [[NSUserDefaults standardUserDefaults] synchronize];
        ip_log("settings: %s=%d", key.UTF8String, on ? 1 : 0);
    };
    /* At most one priority is on; either one sets resolution and rate. */
    void (^prioritize)(NSString *, NSString *, BOOL) = ^(NSString *key, NSString *other, BOOL on) {
        setter(key, on);
        if (on) setter(other, NO);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf render]; });
    };
    CarPlayVideoPriority priority = carplay_video_priority();
    CarPlayDisplayProfile profile = preferred_carplay_display_profile();
    BOOL custom = priority == CarPlayVideoCustom;
    CarPlayDisplayHardware hardware = carplay_display_hardware();

    [b card:^(SettingsCard *card) {
        UIView *dock = [self switchRow:L(@"Dock on the Right") subtitle:nil
            on:[d boolForKey:RIGHT_HAND_DRIVE_KEY] width:w
            changed:^(BOOL on) { setter(RIGHT_HAND_DRIVE_KEY, on); }];
        [self lockForSession:dock];
        [card addRow:dock height:dock.bounds.size.height];
    }];
    [b card:^(SettingsCard *card) {
        UIView *quality = [self switchRow:L(@"Prioritize Quality") subtitle:nil
            on:priority == CarPlayVideoQuality width:w
            changed:^(BOOL on) { prioritize(QUALITY_VIDEO_KEY, SMOOTH_VIDEO_KEY, on); }];
        [self lockForSession:quality];
        [card addRow:quality height:quality.bounds.size.height];
        UIView *performance = [self switchRow:L(@"Prioritize Performance") subtitle:nil
            on:priority == CarPlayVideoPerformance width:w
            changed:^(BOOL on) { prioritize(SMOOTH_VIDEO_KEY, QUALITY_VIDEO_KEY, on); }];
        [self lockForSession:performance];
        [card addRow:performance height:performance.bounds.size.height];
    }];
    [b card:^(SettingsCard *card) {
        CarPlayVideoSize size = {profile.width, profile.height};
        SettingsRow *resolution = [self navRow:L(@"Resolution") value:[self sizeText:size]
            width:w selected:NO action:^{ [weakSelf push:@"resolution"]; }];
        resolution.enabled = custom;
        resolution.alpha = custom ? 1 : 0.35;
        [self lockForSession:resolution];
        [card addRow:resolution height:52];
        NSArray *rates = hardware.screenFPS >= 60 ? @[@"30", @"60"] : @[@"30"];
        UIView *rate = [self segmentRow:L(@"Frame Rate") items:rates
            selected:profile.framesPerSecond >= 60 ? 1 : 0 width:w enabled:custom
            changed:^(NSInteger index) {
                [[NSUserDefaults standardUserDefaults] setInteger:index ? 60 : 30 forKey:VIDEO_FPS_KEY];
                [[NSUserDefaults standardUserDefaults] synchronize];
                ip_log("settings: %s=%d", VIDEO_FPS_KEY.UTF8String, index ? 60 : 30);
            }];
        [self lockForSession:rate];
        [card addRow:rate height:52];
    }];
    if (!showcase_use_existing_wifi()) [b card:^(SettingsCard *card) {
        UIView *radio = [self switchRow:L(@"Dedicate Wi-Fi to CarPlay") subtitle:nil
            on:[d boolForKey:DEDICATED_RADIO_KEY] width:w
            changed:^(BOOL on) { setter(DEDICATED_RADIO_KEY, on); }];
        [self lockForSession:radio];
        [card addRow:radio height:radio.bounds.size.height];
    }];
    if (self.sessionRunning)
        [b message:L(@"Stop CarPlay to change these settings.") color:nil];
    [b card:^(SettingsCard *card) {
        UIView *autoStart = [self switchRow:L(@"Start CarPlay Automatically") subtitle:nil
            on:[d boolForKey:AUTO_START_KEY] width:w
            changed:^(BOOL on) { setter(AUTO_START_KEY, on); }];
        [card addRow:autoStart height:autoStart.bounds.size.height];
    }];
}

/* Each item shows the value Showcase would send next to its switch. */
- (void)buildUsage:(SettingsPageBuilder *)b {
    CGFloat w = b.width;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    __weak SettingsViewController *weakSelf = self;
    BOOL enabled = [d boolForKey:USAGE_KEY];
    [b message:L(@"Usage data goes to Kerem Cloud Services only when you enable sharing. Each item can be turned off.") color:nil];
    void (^set)(NSString *, BOOL) = ^(NSString *key, BOOL on) {
        [[NSUserDefaults standardUserDefaults] setBool:on forKey:key];
        [[NSUserDefaults standardUserDefaults] synchronize];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{ send_anonymous_usage(); });
    };
    [b card:^(SettingsCard *card) {
        UIView *row = [self switchRow:L(@"Share Anonymous Usage") subtitle:nil on:enabled width:w
            changed:^(BOOL on) {
                set(USAGE_KEY, on);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ [weakSelf render]; });
            }];
        [card addRow:row height:row.bounds.size.height];
    }];
    NSDictionary *values = usage_values();
    NSDictionary *titles = @{@"model": L(@"Device Model"), @"ios": L(@"iOS Version"),
        @"jailbreak": L(@"Jailbreak"), @"version": L(@"Showcase Version"), @"package": L(@"Package"),
        @"language": L(@"Language"), @"country": L(@"Country")};
    [b card:^(SettingsCard *card) {
        for (NSArray<NSString *> *item in usage_items()) {
            NSString *key = item[0], *field = item[1];
            UIView *row = [self switchRow:titles[field] subtitle:nil on:[d boolForKey:key] width:w
                changed:^(BOOL on) { set(key, on); }];
            NSString *value = [field isEqualToString:@"language"] ? showcase_language_name(values[field])
                : [values[field] isKindOfClass:[NSString class]] ? values[field] : @"";
            /* The title keeps its width; the value takes the rest before the switch. */
            UILabel *title = row.subviews.firstObject;
            CGFloat titleW = ceil([title sizeThatFits:CGSizeMake(CGFLOAT_MAX, 52)].width);
            CGFloat valueX = 16 + titleW + 12;
            UILabel *label = [[UILabel alloc] initWithFrame:
                CGRectMake(valueX, 0, MAX(0, w - 16 - 51 - 12 - valueX), 52)];
            label.text = value;
            label.textAlignment = NSTextAlignmentRight;
            label.textColor = [UIColor colorWithWhite:1 alpha:0.45];
            label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
            label.adjustsFontSizeToFitWidth = YES;
            label.minimumScaleFactor = 0.75;
            [row addSubview:label];
            row.userInteractionEnabled = enabled;
            row.alpha = enabled ? 1 : 0.35;
            [card addRow:row height:row.bounds.size.height];
        }
    }];
    [b card:^(SettingsCard *card) {
        [card addRow:[self actionRow:L(@"View Source") color:nil width:w enabled:YES action:^{
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:
                GITHUB_URL @"/blob/main/telemetry/worker.js"] options:@{} completionHandler:nil];
        }] height:52];
    }];
}

- (void)buildResolution:(SettingsPageBuilder *)b {
    CGFloat w = b.width;
    __weak SettingsViewController *weakSelf = self;
    CarPlayVideoSize options[CARPLAY_MAX_OPTIONS], fallback;
    unsigned count = carplay_offered_resolutions(options, &fallback);
    CarPlayDisplayProfile profile = preferred_carplay_display_profile();
    NSMutableArray<NSValue *> *sizes = [NSMutableArray array];
    for (unsigned i = 0; i < count; i++)
        [sizes addObject:[NSValue valueWithBytes:&options[i] objCType:@encode(CarPlayVideoSize)]];
    [b card:^(SettingsCard *card) {
        for (NSValue *value in sizes) {
            CarPlayVideoSize size;
            [value getValue:&size];
            BOOL isDefault = size.width == fallback.width && size.height == fallback.height;
            BOOL checked = size.width == profile.width && size.height == profile.height;
            [card addRow:[self choiceRow:[self sizeText:size] value:isDefault ? L(@"Default") : @""
                checked:checked width:w action:^{
                    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
                    /* The default follows the hardware; only another size is kept. */
                    if (isDefault) {
                        [d removeObjectForKey:VIDEO_WIDTH_KEY];
                        [d removeObjectForKey:VIDEO_HEIGHT_KEY];
                    } else {
                        [d setInteger:size.width forKey:VIDEO_WIDTH_KEY];
                        [d setInteger:size.height forKey:VIDEO_HEIGHT_KEY];
                    }
                    [d synchronize];
                    ip_log("settings: resolution=%ux%u", size.width, size.height);
                    [weakSelf pop];
                }] height:52];
        }
    }];
}

- (void)buildLanguage:(SettingsPageBuilder *)b {
    CGFloat w = b.width;
    __weak SettingsViewController *weakSelf = self;
    NSString *chosen = showcase_chosen_language();
    void (^choose)(NSString *) = ^(NSString *language) {
        showcase_set_language(language);
        ip_log("settings: language=%s", language ? language.UTF8String : "device");
        [weakSelf.appDelegate renderState];
        [weakSelf render];
    };
    [b card:^(SettingsCard *card) {
        [card addRow:[self choiceRow:L(@"Device Language") value:showcase_language_name(showcase_device_language())
            checked:chosen == nil width:w action:^{ choose(nil); }] height:52];
    }];
    [b card:^(SettingsCard *card) {
        for (NSString *language in showcase_languages())
            [card addRow:[self choiceRow:showcase_language_name(language) value:@""
                checked:[chosen isEqualToString:language] width:w
                action:^{ choose(language); }] height:52];
    }];
}

- (void)buildLogs:(SettingsPageBuilder *)b {
    AppDelegate *app = self.appDelegate;
    if (self.pendingLogsMessage) {
        self.pageMessage = self.pendingLogsMessage;
        self.pageMessageIsError = self.pendingLogsMessageIsError;
        self.pendingLogsMessage = nil;
    }
    CGFloat w = b.width;
    __weak SettingsViewController *weakSelf = self;
    BOOL logging = app.diagnosticsEnabled;
    BOOL capturing = child_alive(app.tcpdumpPid);
    BOOL haveTcpdump = tcpdump_tool_path() != NULL;
    NSString *lastCapture = capturing ? nil : [app latestNetworkDumpPath];

    [b card:^(SettingsCard *card) {
        UIView *steps = [self switchRow:L(@"Show Connection Steps") subtitle:nil
            on:[[NSUserDefaults standardUserDefaults] boolForKey:CONNECTION_STEPS_KEY]
            width:w changed:^(BOOL on) {
                [[NSUserDefaults standardUserDefaults] setBool:on forKey:CONNECTION_STEPS_KEY];
                [app renderState];
            }];
        [card addRow:steps height:steps.bounds.size.height];
        UIView *row = [self switchRow:L(@"Detailed Logging") subtitle:nil
            on:logging width:w changed:^(BOOL on) {
                [app applyDiagnosticsEnabled:on];
                weakSelf.pageMessage = nil;
                [weakSelf render];
            }];
        [card addRow:row height:row.bounds.size.height];
    }];
    [b card:^(SettingsCard *card) {
        [card addRow:[self actionRow:app.diagnosticsUploadInProgress ? L(@"Preparing Logs…") : L(@"Send Logs to KCS")
            color:nil width:w enabled:!app.diagnosticsUploadInProgress action:^{
                [weakSelf sendLogs];
            }] height:52];
        if (!haveTcpdump) {
            [card addRow:[self actionRow:L(@"Install tcpdump")
                color:nil width:w enabled:YES action:^{
                    NSURL *u = [NSURL URLWithString:@"sileo://package/tcpdump"];
                    [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
                }] height:52];
        } else if (capturing) {
            [card addRow:[self actionRow:L(@"Stop and Send Network Capture")
                color:nil width:w enabled:YES action:^{
                    [app stopNetworkDumpCaptureWithReason:@"user requested export"];
                    NSString *dump = [app latestNetworkDumpPath];
                    weakSelf.pageMessage = nil;
                    [weakSelf render];
                    if (dump) [app presentShareForURL:[NSURL fileURLWithPath:dump]];
                }] height:52];
        } else {
            [card addRow:[self actionRow:L(@"Start Network Capture")
                color:nil width:w enabled:logging action:^{
                    switch ([app startNetworkDumpCapture]) {
                    case NetworkDumpStarted:
                        [weakSelf setMessage:L(@"Capturing") error:NO];
                        break;
                    case NetworkDumpToolMissing:
                        [weakSelf setMessage:L(@"tcpdump is not installed. Install the package named tcpdump in Sileo, then reopen Showcase. CarPlay can still run; only the network dump is disabled.") error:YES];
                        break;
                    case NetworkDumpFailed:
                        [weakSelf setMessage:L(@"Network capture could not start. Turn on Personal Hotspot or join the Wi-Fi network first, then try again.") error:YES];
                        break;
                    case NetworkDumpDisabled:
                        [weakSelf render];
                        break;
                    }
                }] height:52];
            if (lastCapture) {
                [card addRow:[self actionRow:L(@"Send Last Network Capture")
                    color:nil width:w enabled:YES action:^{
                        [app presentShareForURL:[NSURL fileURLWithPath:lastCapture]];
                    }] height:52];
            }
        }
    }];
    [self showPageMessage:b];

    [b card:^(SettingsCard *card) {
        [card addRow:[self actionRow:
            self.confirmingDestructive ? L(@"Tap Again to Clear") : L(@"Clear Logs and Captures")
            color:[self destructiveColor] width:w
            enabled:!app.diagnosticsUploadInProgress && !self.sessionRunning action:^{
                if (app.diagnosticsUploadInProgress || weakSelf.sessionRunning) return;
                if (!weakSelf.confirmingDestructive) {
                    [weakSelf armDestructiveConfirmation];
                    return;
                }
                weakSelf.confirmingDestructive = NO;
                [app clearLogsAndDumps];
                [weakSelf setMessage:L(@"Cleared") error:NO];
            }] height:52];
    }];
}

- (void)sendLogs {
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:L(@"Send Logs to KCS")
        message:L(@"The diagnostics archive may contain Wi-Fi names, device details and Bluetooth captures. Send it to Kerem Cloud Services?")
        preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:L(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    __weak SettingsViewController *weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:L(@"Send") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf uploadLogs];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

/* Shows an upload result on the logs page; on any other page it is kept
 * for the logs page instead of landing above an unrelated Save button. */
- (void)setLogsMessage:(NSString *)message error:(BOOL)error {
    if ([self.stack.lastObject isEqualToString:@"logs"]) {
        self.pendingLogsMessage = nil;
        [self setMessage:message error:error];
        return;
    }
    self.pendingLogsMessage = message;
    self.pendingLogsMessageIsError = error;
}

- (void)uploadLogs {
    AppDelegate *app = self.appDelegate;
    if (!app || app.diagnosticsUploadInProgress) return;
    app.diagnosticsUploadInProgress = YES;
    BOOL helpersLogged = app.helpersLoggedThisRun;
    NSString *snapshot = [app diagnosticsSessionSnapshotWithHelperLogs:helpersLogged];
    self.pageMessage = nil;
    self.pendingLogsMessage = nil;
    [self render];
    __weak SettingsViewController *weakSelf = self;
    dispatch_async(app.diagnosticsQueue, ^{
        NSString *archive = [app createDiagnosticsArchiveWithSnapshot:snapshot helperLogs:helpersLogged];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!archive) {
                app.diagnosticsUploadInProgress = NO;
                [weakSelf setLogsMessage:L(@"Could not create the log archive") error:YES];
                [app refreshPresentedSettings];
                return;
            }
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:LOGS_URL]];
            request.HTTPMethod = @"POST";
            request.timeoutInterval = 45;
            [request setValue:@"application/x-tar" forHTTPHeaderField:@"Content-Type"];
            [[[NSURLSession sharedSession] uploadTaskWithRequest:request
                fromFile:[NSURL fileURLWithPath:archive]
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                    [[NSFileManager defaultManager] removeItemAtPath:archive.stringByDeletingLastPathComponent
                                                               error:nil];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        app.diagnosticsUploadInProgress = NO;
                        BOOL sent = !error && [response isKindOfClass:[NSHTTPURLResponse class]] &&
                            [(NSHTTPURLResponse *)response statusCode] == 201;
                        [weakSelf setLogsMessage:sent ? L(@"Logs sent to KCS") : L(@"Could not send logs")
                                           error:!sent];
                        [app refreshPresentedSettings];
                    });
                }] resume];
        });
    });
}

- (void)loadHardwareInfo {
    if (g_settings_hardware_info || g_settings_hardware_loading) return;
    g_settings_hardware_loading = YES;
    __weak SettingsViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BluetoothRegistryProbeState bt = bluetooth_registry_probe();
        CarPlayDisplayHardware hardware = carplay_display_hardware();
        /* Unknown before the bus probe settles is only "not yet": wait for
         * the probe (and its retries) instead of caching Unknown for the
         * run. Each call re-arms a retry; the About page shows Checking…
         * meanwhile. Bounded by the probe's own attempts and timeouts. */
        for (int waited = 0;
             hardware.wlanAttachment == CarPlayWLANAttachmentUnknown &&
             !hardware.wlanSettled && waited < 80;
             waited++) {
            usleep(250 * 1000);
            hardware = carplay_display_hardware();
        }
        /* Raw codes only: the cache outlives a language change, and L() is
         * not safe off the main thread (showcase_set_language reloads the
         * bundle there). buildAbout translates them. */
        NSString *bluetooth = bt == BluetoothRegistryProbeSkywalk ? @"Skywalk"
            : (bt == BluetoothRegistryProbeLegacyUART ? @"UART"
               : (bt == BluetoothRegistryProbeMissing ? @"missing" : @"unknown"));
        NSString *wifi = hardware.wlanAttachment == CarPlayWLANAttachmentHSIC ? @"HSIC"
            : (hardware.wlanAttachment == CarPlayWLANAttachmentPCIe ? @"PCIe" : @"unknown");
        NSDictionary *info = @{ @"bluetooth": bluetooth, @"wifi": wifi };
        dispatch_async(dispatch_get_main_queue(), ^{
            g_settings_hardware_info = info;
            g_settings_hardware_loading = NO;
            if ([weakSelf.stack.lastObject isEqualToString:@"about"]) [weakSelf render];
        });
    });
}

/* The hardware cache holds raw codes; only the bus names are shown as is. */
static NSString *settings_hardware_label(NSString *code) {
    if (!code) return nil;
    if ([code isEqualToString:@"missing"]) return L(@"Not supported");
    if ([code isEqualToString:@"unknown"]) return L(@"Unknown");
    return code;
}

- (void)buildAbout:(SettingsPageBuilder *)b {
    CGFloat w = b.width;
    [b gap:8];
    UILabel *mark = [[UILabel alloc] init];
    mark.text = @APP_NAME;
    mark.textAlignment = NSTextAlignmentCenter;
    mark.textColor = [UIColor whiteColor];
    mark.font = [UIFont systemFontOfSize:44 weight:UIFontWeightUltraLight];
    [b place:mark height:54 gapAfter:2];
    UILabel *by = [[UILabel alloc] init];
    by.text = [NSString stringWithFormat:L(@"by %s\u2003\u2003%s"), APP_AUTHOR, APP_VERSION];
    by.textAlignment = NSTextAlignmentCenter;
    by.textColor = [UIColor colorWithWhite:1 alpha:0.5];
    by.font = [UIFont systemFontOfSize:14];
    [b place:by height:20 gapAfter:24];
    [b message:L(@"KCS edition. Original Showcase by Amine Rostane. Licensed under GPL-3.0.") color:nil];

    [self loadHardwareInfo];
    NSDictionary *hw = g_settings_hardware_info;
    NSString *checking = L(@"Checking…");
#ifdef SHOWCASE_ROOTLESS
    NSString *package = @"Rootless";
#else
    NSString *package = @"Rootful";
#endif
    [b card:^(SettingsCard *card) {
        [card addRow:[self valueRow:L(@"Model") value:hardware_machine_identifier() width:w] height:48];
        [card addRow:[self valueRow:@"iOS" value:[UIDevice currentDevice].systemVersion width:w] height:48];
        [card addRow:[self valueRow:L(@"Package") value:package width:w] height:48];
        [card addRow:[self valueRow:@"Bluetooth" value:settings_hardware_label(hw[@"bluetooth"]) ?: checking width:w] height:48];
        [card addRow:[self valueRow:L(@"Wi-Fi Bus") value:settings_hardware_label(hw[@"wifi"]) ?: checking width:w] height:48];
        [card addRow:[self valueRow:L(@"CarPlay Video") value:hw ? [self videoDescription] : checking width:w] height:48];
    }];
}

/* ─── keyboard ─── */

- (void)wifiNameEdited:(UITextField *)field {
    (void)field;
    if (showcase_use_existing_wifi()) self.sharedSSIDEdited = YES;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.ssidField) {
        [self.passwordField becomeFirstResponder];
        return NO;
    }
    [textField resignFirstResponder];
    if (textField == self.carNameField) [self saveCar];
    else if (textField == self.passwordField) [self saveHotspot];
    return NO;
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    self.activeField = textField;
    [self revealActiveField];
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (self.activeField == textField) self.activeField = nil;
}

- (void)revealActiveField {
    if (!self.activeField || !self.detailScroll) return;
    CGRect r = [self.activeField convertRect:self.activeField.bounds toView:self.detailScroll];
    [self.detailScroll scrollRectToVisible:CGRectInset(r, 0, -24) animated:YES];
}

- (void)keyboardWillChange:(NSNotification *)note {
    CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect local = [self.view convertRect:end fromView:nil];
    CGFloat overlap = MAX(0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(local));
    self.keyboardOverlap = overlap;
    self.detailScroll.contentInset = UIEdgeInsetsMake(0, 0, overlap, 0);
    self.detailScroll.scrollIndicatorInsets = self.detailScroll.contentInset;
    [self revealActiveField];
}

- (void)keyboardWillHide:(NSNotification *)note {
    (void)note;
    self.keyboardOverlap = 0;
    self.detailScroll.contentInset = UIEdgeInsetsZero;
    self.detailScroll.scrollIndicatorInsets = UIEdgeInsetsZero;
}

@end

/* ═══════════════════════════════════════════════════════════════
 * WifiSetupViewController — sleek two-step setup modal
 *
 * Step 1: rename the device (the hotspot carries its name), with a name
 *         to copy and a link to Settings › General › About.
 * Step 2: enter the hotspot details.
 * ═══════════════════════════════════════════════════════════════ */

@interface WifiSetupViewController ()
@property (nonatomic, weak) UILabel *pillHintLabel;
@property (nonatomic, weak) UIView  *pillView;
@property (nonatomic, strong) UIView *contentView;
@end

@implementation WifiSetupViewController

- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    root.backgroundColor = [UIColor blackColor];
    /* Presented OverFullScreen: the setup screen and its Start button stay
     * in the hierarchy behind, so keep VoiceOver inside this screen. */
    root.accessibilityViewIsModal = YES;
    self.view = root;
    self.contentView = root;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.contentView == self.view) {
        self.contentView.frame = self.view.bounds;
        self.contentView.transform = CGAffineTransformIdentity;
        return;
    }

    CGSize s = self.view.bounds.size;
    CGFloat scale = MIN(s.width / PHONE_CANVAS_W, s.height / PHONE_CANVAS_H);
    self.contentView.bounds = CGRectMake(0, 0, PHONE_CANVAS_W, PHONE_CANVAS_H);
    self.contentView.center = CGPointMake(s.width / 2.0, s.height / 2.0);
    self.contentView.transform = CGAffineTransformMakeScale(scale, scale);
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return showcase_orientation_mask();
}
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return showcase_preferred_orientation();
}
- (BOOL)prefersStatusBarHidden { return YES; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    [self buildUI];
}

- (void)buildUI {
    UIView *root = self.contentView ?: self.view;
    CGFloat W = root.bounds.size.width;
    CGFloat H = root.bounds.size.height;
    BOOL phone = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone);

    /* ── Close button (top-right) ── */
    CGFloat closeSz = phone ? 34 : 40;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(W - closeSz - (phone ? 14 : 22),
                             phone ? 14 : 22, closeSz, closeSz);
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    close.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    close.layer.cornerRadius = closeSz / 2.0;
    [close setTitle:@"×" forState:UIControlStateNormal];
    close.accessibilityLabel = L(@"Close");
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightLight];
    close.titleEdgeInsets = UIEdgeInsetsMake(-2, 0, 0, 0);
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:close];

    UIScrollView *scroll = nil;
    if (phone) {
        scroll = [[UIScrollView alloc] initWithFrame:root.bounds];
        scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        scroll.backgroundColor = [UIColor blackColor];
        scroll.alwaysBounceVertical = YES;
        scroll.showsVerticalScrollIndicator = NO;
        [root insertSubview:scroll belowSubview:close];
        root = scroll;
    }

    UILabel *title = [[UILabel alloc] init];
    title.text = L(@"Wi-Fi Setup");
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:(phone ? 34 : 44) weight:UIFontWeightUltraLight];
    title.frame = CGRectMake(0, phone ? 28 : 72, W, phone ? 44 : 56);
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [root addSubview:title];

    CGFloat colW = phone ? MIN(560, W - 56) : MIN(620, W - 120);
    CGFloat colX = (W - colW) / 2.0;
    CGFloat y = phone ? 104 : 168;

    /* Step 1: the hotspot is named after the device. */
    [root addSubview:[self headlineLabel:[NSString stringWithFormat:L(@"1.  Rename This %@"), showcase_device_noun()]
                                    rect:CGRectMake(colX, y, colW, 30)]];
    y += 46;
    [root addSubview:[self buildCopyPillWithText:@"Carplay-Receiver" rect:CGRectMake(colX, y, colW, 56)]];
    y += 72;
    [root addSubview:[self primaryButton:L(@"Open Settings") rect:CGRectMake(colX, y, colW, 50)
                                  action:@selector(openSettingsTapped)]];
    y += 82;

    /* Step 2 */
    [root addSubview:[self headlineLabel:L(@"2.  Enter Hotspot Details") rect:CGRectMake(colX, y, colW, 30)]];
    y += 46;
    [root addSubview:[self primaryButton:L(@"Enter Details") rect:CGRectMake(colX, y, colW, 50)
                                  action:@selector(credsTapped)]];

    if (scroll) {
        scroll.contentSize = CGSizeMake(W, y + 74);
    }
}

/* ─── helpers ─── */

- (UILabel *)headlineLabel:(NSString *)text rect:(CGRect)rect {
    UILabel *l = [[UILabel alloc] initWithFrame:rect];
    l.text = text;
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold];
    return l;
}

- (UIButton *)primaryButton:(NSString *)title rect:(CGRect)rect action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = rect;
    b.backgroundColor = [UIColor whiteColor];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [b setTitleColor:[UIColor colorWithWhite:0 alpha:0.45] forState:UIControlStateHighlighted];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    b.layer.cornerRadius = rect.size.height / 2.0;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIView *)buildCopyPillWithText:(NSString *)text rect:(CGRect)rect {
    UIView *container = [[UIView alloc] initWithFrame:rect];
    container.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    container.layer.cornerRadius = 14;
    container.layer.borderWidth = 1;
    container.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;

    UILabel *txt = [[UILabel alloc] init];
    txt.text = text;
    txt.textColor = [UIColor whiteColor];
    UIFont *mono = [UIFont fontWithName:@"Menlo-Regular" size:18];
    if (!mono) mono = [UIFont systemFontOfSize:18 weight:UIFontWeightRegular];
    txt.font = mono;
    txt.frame = CGRectMake(20, 0, rect.size.width - 130, rect.size.height);
    [container addSubview:txt];

    UILabel *hint = [[UILabel alloc] init];
    hint.text = L(@"Copy");
    hint.textColor = [UIColor whiteColor];
    hint.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    hint.textAlignment = NSTextAlignmentRight;
    hint.frame = CGRectMake(rect.size.width - 110, 0, 90, rect.size.height);
    [container addSubview:hint];
    self.pillHintLabel = hint;
    self.pillView = container;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(copyExampleTapped:)];
    [container addGestureRecognizer:tap];
    /* VoiceOver reads the pill as one button: "Copy, Carplay-Receiver". */
    container.isAccessibilityElement = YES;
    container.accessibilityTraits = UIAccessibilityTraitButton;
    container.accessibilityLabel =
        [NSString stringWithFormat:@"%@, %@", L(@"Copy"), text];

    return container;
}

- (void)copyExampleTapped:(UITapGestureRecognizer *)gr {
    [UIPasteboard generalPasteboard].string = @"Carplay-Receiver";
    self.pillHintLabel.text = L(@"Copied");
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, L(@"Copied"));
    UIView *pill = self.pillView;
    [UIView animateWithDuration:0.12 animations:^{
        pill.transform = CGAffineTransformMakeScale(1.02, 1.02);
        pill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    } completion:^(BOOL d) {
        [UIView animateWithDuration:0.18 animations:^{
            pill.transform = CGAffineTransformIdentity;
        }];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([self.pillHintLabel.text isEqualToString:L(@"Copied")]) {
            self.pillHintLabel.text = L(@"Copy");
            [UIView animateWithDuration:0.25 animations:^{
                pill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
            }];
        }
    });
}

- (void)openSettingsTapped {
    NSURL *u = [NSURL URLWithString:@"App-Prefs:root=General&path=About"];
    UIApplication *app = [UIApplication sharedApplication];
    if (![app canOpenURL:u]) u = [NSURL URLWithString:@"prefs:root=General&path=About"];
    [app openURL:u options:@{} completionHandler:nil];
}

- (void)credsTapped {
    [self.appDelegate promptForCredentialsFromController:self];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:^{
        [self.appDelegate settingsDidClose];
    }];
}

- (BOOL)accessibilityPerformEscape {
    [self closeTapped];
    return YES;
}

@end

/* ═══════════════════════════════════════════════════════════════ */

int main(int argc, char *argv[]) {
    signal(SIGPIPE, SIG_IGN);

    /* Privilege escalation (binary is chmod 4755 root) */
#ifndef SHOWCASE_SIMULATOR_TEST
    setuid(0); setgid(0);
#endif

    ip_log_open();
    ip_log("main: ruid=%u euid=%u argc=%d", getuid(), geteuid(), argc);
    ip_log("bundle: %s", [[[NSBundle mainBundle] bundlePath] UTF8String]);
#ifdef SHOWCASE_ROOTLESS
    ip_log("build: %s rootless", APP_VERSION);
#else
    ip_log("build: %s rootful", APP_VERSION);
#endif

    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass([AppDelegate class]));
    }
}
