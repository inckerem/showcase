#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <notify.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <errno.h>
#import <time.h>
#import <unistd.h>
#import "../autopower/PowerState.h"

/* This executable is a separate launchd job: it is never loaded into SpringBoard. */
typedef mach_port_t io_service_t;
extern CFMutableDictionaryRef IOServiceMatching(const char *name);
extern io_service_t IOServiceGetMatchingService(mach_port_t port, CFDictionaryRef matching);
extern CFTypeRef IORegistryEntryCreateCFProperty(io_service_t entry, CFStringRef key, CFAllocatorRef allocator, uint32_t options);
extern kern_return_t IOObjectRelease(mach_port_t object);
extern CFTypeRef IOPSCopyPowerSourcesInfo(void);
extern CFStringRef IOPSGetProvidingPowerSourceType(CFTypeRef snapshot);
extern CFRunLoopSourceRef IOPSNotificationCreateRunLoopSource(void (*callback)(void *), void *context);

static const char *kState = "tr.net.kcs.showcase.power.state";
static const char *kStopRequest = "tr.net.kcs.showcase.power.stop-request";
static const char *kPhase = "tr.net.kcs.showcase.power.phase";
static const char *kStop = "tr.net.kcs.showcase.power.stop";
static const char *kStart = "tr.net.kcs.showcase.power.start";
static const char *kStopped = "tr.net.kcs.showcase.power.stopped";
static const char *kRefresh = "tr.net.kcs.showcase.power.refresh";
static NSString *const kBundle = @"com.rostane.showcase";
#ifndef SHOWCASE_DAEMON_PROOF_DIR
#define SHOWCASE_DAEMON_PROOF_DIR @"/var/lib/showcase-power"
#endif
#ifndef SHOWCASE_DAEMON_EXPECTED_UID
#define SHOWCASE_DAEMON_EXPECTED_UID 0
#endif
#define kProofDir SHOWCASE_DAEMON_PROOF_DIR
static int stateToken = -1, requestToken = -1, phaseToken = -1;
static PowerState power = { -1, 0 };
static PowerEvent pending;
static double deadline;
static uint64_t nonce;
static uint64_t recoveredPowerState, recoveredStopRequest, recoveredPhase;
static BOOL waitingForUnlock;
static BOOL launchPending, stopAckRetryScheduled;
static dispatch_source_t pollTimer;
static uint64_t pollInterval;
static int lastLoggedPower = -2;
static uint64_t desiredPollInterval(void) {
    /* Notification delivery varies by device. Bound fallback detection to 1s. */
    return 1;
}
static void updatePollTimer(void) {
    if (!pollTimer) return;
    uint64_t seconds = desiredPollInterval();
    if (seconds == pollInterval) return;
    pollInterval = seconds;
    dispatch_source_set_timer(pollTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                              seconds * NSEC_PER_SEC, NSEC_PER_SEC / 20);
}
static BOOL saveRecovery(uint64_t phase, uint64_t request) {
#if defined(SHOWCASE_POWER_TEST) && !defined(SHOWCASE_POWER_TEST_INTEGRATION)
    (void)phase; (void)request;
    return YES;
#else
    struct stat dir;
    if (lstat(kProofDir.fileSystemRepresentation, &dir) || !S_ISDIR(dir.st_mode) ||
        dir.st_uid != SHOWCASE_DAEMON_EXPECTED_UID || (dir.st_mode & 0022)) return NO;
    NSString *path = [kProofDir stringByAppendingPathComponent:@"state.plist"];
    return [@{ @"phase": @(phase), @"request": @(request) } writeToFile:path atomically:YES];
#endif
}
static BOOL loadRecovery(uint64_t *phase, uint64_t *request) {
    NSString *path = [kProofDir stringByAppendingPathComponent:@"state.plist"];
    struct stat file;
    if (lstat(path.fileSystemRepresentation, &file) || !S_ISREG(file.st_mode) ||
        file.st_uid != SHOWCASE_DAEMON_EXPECTED_UID || (file.st_mode & 0022)) return NO;
    NSDictionary *values = [NSDictionary dictionaryWithContentsOfFile:path];
    NSNumber *p = values[@"phase"], *r = values[@"request"];
    if (![p isKindOfClass:[NSNumber class]] || ![r isKindOfClass:[NSNumber class]]) return NO;
    *phase = p.unsignedLongLongValue; *request = r.unsignedLongLongValue;
    return *phase <= 5;
}
static BOOL serviceEnabled(void) {
#if defined(SHOWCASE_POWER_TEST)
    return YES;
#else
    return access("/var/lib/showcase-power/enabled", F_OK) == 0;
#endif
}

#if defined(SHOWCASE_POWER_TEST)
extern double testMonotonicSeconds(void);
extern int testReadPower(void);
extern void testConnected(void);
extern void testDisconnected(void);
#endif
#if defined(SHOWCASE_POWER_TEST_INTEGRATION)
extern void *testSbSymbol(const char *name);
#endif
static double monotonicSeconds(void) {
#if defined(SHOWCASE_POWER_TEST)
    return testMonotonicSeconds();
#else
    struct timespec ts;
    return clock_gettime(CLOCK_MONOTONIC, &ts) == 0 ? ts.tv_sec + ts.tv_nsec / 1e9 : 0;
#endif
}
static int readPower(void) {
#if defined(SHOWCASE_POWER_TEST)
    return testReadPower();
#else
    io_service_t service = IOServiceGetMatchingService(0, IOServiceMatching("IOPMPowerSource"));
    if (service) {
        CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("ExternalConnected"), kCFAllocatorDefault, 0);
        IOObjectRelease(service);
        if (value) {
            int result = -1;
            if (CFGetTypeID(value) == CFBooleanGetTypeID()) result = CFBooleanGetValue(value) ? 1 : 0;
            CFRelease(value);
            if (result >= 0) return result;
        }
    }
    CFTypeRef snapshot = IOPSCopyPowerSourcesInfo();
    if (!snapshot) return -1;
    CFStringRef type = IOPSGetProvidingPowerSourceType(snapshot);
    int result = type && CFEqual(type, CFSTR("AC Power")) ? 1 :
                 type && CFEqual(type, CFSTR("Battery Power")) ? 0 : -1;
    CFRelease(snapshot);
    return result;
#endif
}
static void publishPower(int value) {
    if (stateToken >= 0) notify_set_state(stateToken, value < 0 ? 0 : (uint64_t)value + 1);
}
static __attribute__((unused)) void *sbServices(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY); });
    return handle;
}
static void *sbSymbol(const char *name) {
#if defined(SHOWCASE_POWER_TEST_INTEGRATION)
    return testSbSymbol(name);
#else
    void *handle = sbServices();
    return handle ? dlsym(handle, name) : NULL;
#endif
}
static mach_port_t sbPort(void) {
    mach_port_t (*fn)(void) = sbSymbol("SBSSpringBoardServerPort");
    return fn ? fn() : MACH_PORT_NULL;
}
static BOOL lockState(BOOL *locked) {
    void (*fn)(mach_port_t, BOOL *, BOOL *) = sbSymbol("SBGetScreenLockStatus");
    mach_port_t port = sbPort();
    if (!fn || !port) return NO;
    BOOL passcodeRequired = YES;
    *locked = YES;
    fn(port, locked, &passcodeRequired);
    return YES;
}
static BOOL noPasscodeConfigured(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ dlopen("/System/Library/PrivateFrameworks/ManagedConfiguration.framework/ManagedConfiguration", RTLD_LAZY); });
    Class cls = NSClassFromString(@"MCProfileConnection");
    SEL shared = NSSelectorFromString(@"sharedConnection"), check = NSSelectorFromString(@"isPasscodeSet");
    if (!cls || ![cls respondsToSelector:shared]) return NO;
    id object = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
    return object && [object respondsToSelector:check] && !((BOOL (*)(id, SEL))objc_msgSend)(object, check);
}
static void pressHome(void) {
    void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!handle) return;
    CFTypeRef (*clientCreate)(CFAllocatorRef) = dlsym(handle, "IOHIDEventSystemClientCreate");
    CFTypeRef (*eventCreate)(CFAllocatorRef, uint64_t, uint16_t, uint16_t, Boolean, uint32_t) = dlsym(handle, "IOHIDEventCreateKeyboardEvent");
    void (*send)(CFTypeRef, CFTypeRef) = dlsym(handle, "IOHIDEventSystemClientDispatchEvent");
    void (*setSender)(CFTypeRef, uint64_t) = dlsym(handle, "IOHIDEventSetSenderID");
    if (!clientCreate || !eventCreate || !send) return;
    CFTypeRef client = clientCreate(kCFAllocatorDefault);
    if (!client) return;
    for (int down = 1; down >= 0; down--) {
        CFTypeRef event = eventCreate(kCFAllocatorDefault, mach_absolute_time(), 0x0c, 0x40, down, 0);
        if (event) { if (setSender) setSender(event, 0xDEFACEDBEEFFECE5ULL); send(client, event); CFRelease(event); }
    }
    CFRelease(client);
}
static void launchIfUnlocked(unsigned long generation, unsigned int tries);
static void retryLaunch(unsigned long generation, unsigned int tries) {
    if (tries >= 12) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        launchIfUnlocked(generation, tries + 1);
    });
}
static void launchIfUnlocked(unsigned long generation, unsigned int tries) {
    if (!launchPending || generation != power.generation || !serviceEnabled()) return;
    int now = readPower();
    if (now < 0) { retryLaunch(generation, tries); return; }
    if (now != 1) { launchPending = NO; waitingForUnlock = NO; return; }
    BOOL locked = YES;
    if (!lockState(&locked) || locked) {
        waitingForUnlock = YES;
        if (tries == 0) NSLog(@"[ShowcasePower] waiting for unlock");
        retryLaunch(generation, tries);
        return;
    }
    waitingForUnlock = NO;
    CFStringRef (*front)(void) = sbSymbol("SBSCopyFrontmostApplicationDisplayIdentifier");
    CFStringRef current = front ? front() : NULL;
    BOOL foreground = current && CFEqual(current, (__bridge CFStringRef)kBundle);
    if (current) CFRelease(current);
    if (foreground) {
        if (notify_post(kStart) != NOTIFY_STATUS_OK) { retryLaunch(generation, tries); return; }
        saveRecovery(5, 0);
        if (phaseToken >= 0) notify_set_state(phaseToken, 5);
        launchPending = NO;
        return;
    }
    int (*launch)(CFStringRef, Boolean) = sbSymbol("SBSLaunchApplicationWithIdentifier");
    if (!launch) { NSLog(@"[ShowcasePower] app launch unavailable"); return; }
    int result = launch((__bridge CFStringRef)kBundle, false);
    NSLog(@"[ShowcasePower] app launch result=%d", result);
    if (result) { retryLaunch(generation, tries); return; }
    if (notify_post(kStart) != NOTIFY_STATUS_OK) { retryLaunch(generation, tries); return; }
    saveRecovery(5, 0);
    if (phaseToken >= 0) notify_set_state(phaseToken, 5);
    launchPending = NO;
}
static void continueWake(unsigned long generation, unsigned int tries) {
    if (!launchPending || !serviceEnabled() || generation != power.generation) return;
    int now = readPower();
    if (now < 0) {
        if (tries < 12) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ continueWake(generation, tries + 1); });
        return;
    }
    if (now != 1) { launchPending = NO; return; }
    BOOL locked = YES;
    if (lockState(&locked) && locked && noPasscodeConfigured()) pressHome();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_main_queue(), ^{
        launchIfUnlocked(generation, 0);
    });
}
static void onConnected(void) {
#if defined(SHOWCASE_POWER_TEST) && !defined(SHOWCASE_POWER_TEST_INTEGRATION)
    testConnected();
    return;
#endif
    if (!serviceEnabled()) return;
    NSLog(@"[ShowcasePower] power connected after debounce");
    launchPending = YES;
    void (*undim)(void) = sbSymbol("SBSUndimScreen");
    if (undim) undim();
    unsigned long generation = power.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
        continueWake(generation, 0);
    });
}
static void onDisconnected(void) {
#if defined(SHOWCASE_POWER_TEST) && !defined(SHOWCASE_POWER_TEST_INTEGRATION)
    testDisconnected();
    return;
#endif
    if (!serviceEnabled()) return;
    NSLog(@"[ShowcasePower] power disconnected after debounce");
    waitingForUnlock = NO;
    launchPending = NO;
    arc4random_buf(&nonce, sizeof(nonce));
    if (!nonce) nonce = 1;
    if (requestToken < 0 || notify_set_state(requestToken, nonce) != NOTIFY_STATUS_OK || notify_post(kStop) != NOTIFY_STATUS_OK) {
        nonce = 0;
        if (requestToken >= 0) notify_set_state(requestToken, 0);
        pending = (PowerEvent){ 0, power.generation, 1 };
        deadline = monotonicSeconds() + 5.0;
    }
}
static BOOL proofMatches(void) {
    struct stat dir, lockStat, proofStat;
    if (lstat(kProofDir.fileSystemRepresentation, &dir) || !S_ISDIR(dir.st_mode) || dir.st_uid != SHOWCASE_DAEMON_EXPECTED_UID || (dir.st_mode & 0022)) return NO;
    int lock = open([[kProofDir stringByAppendingPathComponent:@"lock"] fileSystemRepresentation], O_RDONLY | O_NOFOLLOW);
    if (lock < 0) return NO;
    BOOL safe = !fstat(lock, &lockStat) && S_ISREG(lockStat.st_mode) && lockStat.st_uid == SHOWCASE_DAEMON_EXPECTED_UID && !(lockStat.st_mode & 0022);
    if (!safe || flock(lock, LOCK_EX | LOCK_NB)) { close(lock); return NO; }
    int proof = open([[kProofDir stringByAppendingPathComponent:@"stopped"] fileSystemRepresentation], O_RDONLY | O_NOFOLLOW);
    uint64_t observed = 0;
    safe = proof >= 0 && !fstat(proof, &proofStat) && S_ISREG(proofStat.st_mode) && proofStat.st_uid == SHOWCASE_DAEMON_EXPECTED_UID && !(proofStat.st_mode & 0022) && read(proof, &observed, sizeof(observed)) == sizeof(observed) && observed == nonce;
    if (proof >= 0) close(proof);
    BOOL completed = NO;
    int currentPower = safe ? readPower() : -1;
    if (safe && currentPower == 1) completed = saveRecovery(4, 0);
    if (safe && currentPower == 0) {
        CFStringRef (*front)(void) = sbSymbol("SBSCopyFrontmostApplicationDisplayIdentifier");
        CFStringRef current = front ? front() : NULL;
        BOOL foreground = current && CFEqual(current, (__bridge CFStringRef)kBundle);
        BOOL otherForeground = current && !foreground;
        if (current) CFRelease(current);
        if (otherForeground) completed = saveRecovery(4, 0);
        if (foreground) {
            int (*lockDevice)(mach_port_t) = sbSymbol("SBSLockDevice");
            mach_port_t port = sbPort();
            if (lockDevice && port) {
                uint64_t oldNonce = nonce;
                if (saveRecovery(4, 0)) {
                    if (lockDevice(port) == 0) { nonce = 0; completed = YES; }
                    else saveRecovery(4, oldNonce);
                }
            }
        }
    }
    flock(lock, LOCK_UN);
    close(lock);
    return completed;
}
static BOOL completeStopIfProven(void) {
    if (!proofMatches()) return NO;
    nonce = 0;
    if (requestToken >= 0) notify_set_state(requestToken, 0);
    return YES;
}
static void onStopped(unsigned int tries) {
    if (!serviceEnabled() || !nonce || readPower() != 0 || completeStopIfProven()) return;
    if (tries < 60 && !stopAckRetryScheduled) {
        stopAckRetryScheduled = YES;
        uint64_t request = nonce;
        int64_t delay = tries < 20 ? NSEC_PER_SEC / 4 : 15 * NSEC_PER_SEC;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), dispatch_get_main_queue(), ^{
            stopAckRetryScheduled = NO;
            if (nonce == request) onStopped(tries + 1);
        });
    }
}
static void pollPower(void);
static void pollAfterDebounce(PowerEvent event, double seconds) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (event.generation == power.generation && deadline > 0) pollPower();
    });
}
static void pollPower(void) {
    if (!serviceEnabled()) { publishPower(-1); deadline = 0; nonce = 0; waitingForUnlock = NO; launchPending = NO; updatePollTimer(); return; }
    int now = readPower();
    if (now != lastLoggedPower) { NSLog(@"[ShowcasePower] power state=%d", now); lastLoggedPower = now; }
    int previous = power.last;
    PowerEvent event = power_state_update(&power, now);
    /* Installing or starting while powered must not activate the car. */
    if (previous < 0 && now >= 0) {
        event.schedule = 0;
        if (now == 0 && recoveredStopRequest) {
            nonce = recoveredStopRequest;
            if (requestToken < 0 || notify_set_state(requestToken, nonce) != NOTIFY_STATUS_OK ||
                notify_post(kStop) != NOTIFY_STATUS_OK) {
                nonce = 0;
                event.schedule = 1;
            }
        } else if ((recoveredPhase == 1 && now == 0) || (recoveredPhase == 2 && now == 1) ||
                   (recoveredPhase == 4 && now == 1) || (recoveredPhase == 5 && now == 0)) {
            /* Resume an unfinished debounce or a transition while stopped. */
            event.schedule = 1;
        } else if (now == 1 && requestToken >= 0) {
            notify_set_state(requestToken, 0);
        }
        if (!event.schedule) {
            if (phaseToken >= 0) notify_set_state(phaseToken, now ? 5 : 4);
            saveRecovery(now ? 5 : 4, now ? 0 : nonce);
        }
        recoveredPowerState = recoveredStopRequest = recoveredPhase = 0;
    }
    if (event.schedule) {
        pending = event;
        double debounce = now ? 0.2 : 0.35;
        deadline = monotonicSeconds() + debounce;
        nonce = 0;
        saveRecovery(now ? 2 : 1, 0);
        if (phaseToken >= 0) notify_set_state(phaseToken, now ? 2 : 1);
        if (requestToken >= 0) notify_set_state(requestToken, 0);
        if (!now) { waitingForUnlock = NO; launchPending = NO; }
        pollAfterDebounce(event, debounce + 0.01);
    }
    publishPower(now);
    if (deadline && monotonicSeconds() >= deadline && power_event_current(&power, pending, now)) {
        deadline = 0;
        if (now) onConnected(); else onDisconnected();
        if (!now) saveRecovery(nonce ? 4 : 1, nonce);
        if (phaseToken >= 0) notify_set_state(phaseToken, now ? (launchPending ? 2 : 5) : (nonce ? 4 : 1));
    }
    // The app can write valid proof and exit before sending the notification.
    if (nonce && now == 0) completeStopIfProven();
    updatePollTimer();
}
static void powerChanged(void *context) { (void)context; pollPower(); }
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--disable") == 0) {
            notify_post("tr.net.kcs.showcase.power.disable");
            return 0;
        }
        if (argc == 2 && strcmp(argv[1], "--reset") == 0) {
            int state = -1, request = -1, phase = -1;
            if (notify_register_check(kState, &state) != NOTIFY_STATUS_OK ||
                notify_register_check(kStopRequest, &request) != NOTIFY_STATUS_OK ||
                notify_register_check(kPhase, &phase) != NOTIFY_STATUS_OK) return 1;
            NSString *path = [kProofDir stringByAppendingPathComponent:@"state.plist"];
            if (unlink(path.fileSystemRepresentation) != 0 && errno != ENOENT) return 1;
            return notify_set_state(state, 0) == NOTIFY_STATUS_OK &&
                   notify_set_state(request, 0) == NOTIFY_STATUS_OK &&
                   notify_set_state(phase, 0) == NOTIFY_STATUS_OK ? 0 : 1;
        }
        if (notify_register_check(kState, &stateToken) != NOTIFY_STATUS_OK ||
            notify_register_check(kStopRequest, &requestToken) != NOTIFY_STATUS_OK ||
            notify_register_check(kPhase, &phaseToken) != NOTIFY_STATUS_OK) return 1;
        notify_get_state(stateToken, &recoveredPowerState);
        notify_get_state(requestToken, &recoveredStopRequest);
        notify_get_state(phaseToken, &recoveredPhase);
        loadRecovery(&recoveredPhase, &recoveredStopRequest);
        int stoppedToken = 0, refreshToken = 0, unlockedToken = 0;
        if (notify_register_dispatch(kStopped, &stoppedToken, dispatch_get_main_queue(), ^(int token) { (void)token; onStopped(0); }) != NOTIFY_STATUS_OK ||
            notify_register_dispatch(kRefresh, &refreshToken, dispatch_get_main_queue(), ^(int token) { (void)token; pollPower(); }) != NOTIFY_STATUS_OK ||
            notify_register_dispatch("com.apple.springboard.lockstate", &unlockedToken, dispatch_get_main_queue(), ^(int token) {
            (void)token;
            if (waitingForUnlock) launchIfUnlocked(power.generation, 0);
        }) != NOTIFY_STATUS_OK) return 1;
        CFRunLoopSourceRef source = IOPSNotificationCreateRunLoopSource(powerChanged, NULL);
        if (source) CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
        pollPower();
        pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        updatePollTimer();
        dispatch_source_set_event_handler(pollTimer, ^{ pollPower(); });
        dispatch_resume(pollTimer);
        NSLog(@"[ShowcasePower] isolated power service started");
        CFRunLoopRun();
        if (source) CFRelease(source);
    }
    return 0;
}
