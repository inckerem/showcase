#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach.h>
#import <notify.h>
#import <assert.h>
#import <unistd.h>

static double fakeTime = 100;
static int fakePower = 1, launchCalls, lockCalls, startPosts;
static int powerSequence[4], powerSequenceCount, powerSequenceIndex;
static BOOL fakeFront, fakeLocked, inspectPhaseOnPost, fakeStopFail;
static unsigned long long phaseAtStartPost;
static NSMutableArray *tasks;
static NSString *testProofDir(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString]; });
    return path;
}
double testMonotonicSeconds(void) { return fakeTime; }
int testReadPower(void) {
    if (powerSequenceIndex < powerSequenceCount) return powerSequence[powerSequenceIndex++];
    return fakePower;
}
static mach_port_t fakePort(void) { return 1; }
static void fakeLockStatus(mach_port_t port, BOOL *locked, BOOL *passcode) { (void)port; *locked = fakeLocked; *passcode = NO; }
static CFStringRef fakeFrontmost(void) { return fakeFront ? CFRetain(CFSTR("com.rostane.showcase")) : NULL; }
static int fakeLaunch(CFStringRef bundle, Boolean suspended) { (void)bundle; (void)suspended; return ++launchCalls == 1 ? 9 : 0; }
static int fakeLock(mach_port_t port) { (void)port; lockCalls++; return 0; }
void *testSbSymbol(const char *name) {
    if (!strcmp(name, "SBSSpringBoardServerPort")) return (void *)fakePort;
    if (!strcmp(name, "SBGetScreenLockStatus")) return (void *)fakeLockStatus;
    if (!strcmp(name, "SBSCopyFrontmostApplicationDisplayIdentifier")) return (void *)fakeFrontmost;
    if (!strcmp(name, "SBSLaunchApplicationWithIdentifier")) return (void *)fakeLaunch;
    if (!strcmp(name, "SBSLockDevice")) return (void *)fakeLock;
    return NULL;
}
static uint32_t fakeNotifyPost(const char *name) {
    if (!strcmp(name,"tr.net.kcs.showcase.power.start")) {
        startPosts++;
        if (inspectPhaseOnPost) {
            NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:[testProofDir() stringByAppendingPathComponent:@"state.plist"]];
            phaseAtStartPost = [state[@"phase"] unsignedLongLongValue];
        }
    }
    if (!strcmp(name,"tr.net.kcs.showcase.power.stop") && fakeStopFail) return 1;
    return 0;
}
static void fakeAfter(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) {
    (void)when; (void)queue;
    if (!tasks) tasks = [NSMutableArray new];
    [tasks addObject:[block copy]];
}
static void runNext(void) {
    assert(tasks.count);
    dispatch_block_t block = tasks.firstObject;
    [tasks removeObjectAtIndex:0];
    block();
}
#define SHOWCASE_POWER_TEST 1
#define SHOWCASE_POWER_TEST_INTEGRATION 1
#define SHOWCASE_DAEMON_PROOF_DIR testProofDir()
#define SHOWCASE_DAEMON_EXPECTED_UID getuid()
#define notify_post fakeNotifyPost
#define dispatch_after fakeAfter
#define main powerDaemonUnusedMain
#include "PowerDaemon.m"
#undef main
#undef dispatch_after
#undef notify_post
int main(void) {
    @autoreleasepool {
        assert([[NSFileManager defaultManager] createDirectoryAtPath:testProofDir() withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0755} error:NULL]);
        assert([[NSFileManager defaultManager] createFileAtPath:[testProofDir() stringByAppendingPathComponent:@"lock"] contents:[NSData data] attributes:@{NSFilePosixPermissions:@0644}]);
        assert(saveRecovery(2, 0));
        inspectPhaseOnPost = YES;
        power = (PowerState){ 1, 42 };
        launchPending = YES;
        launchIfUnlocked(42, 0);
        assert(launchCalls == 1 && tasks.count == 1 && startPosts == 0);
        runNext();
        assert(launchCalls == 2 && startPosts == 1 && !launchPending && phaseAtStartPost == 2);
        inspectPhaseOnPost = NO;
        launchPending = YES; fakePower = -1;
        launchIfUnlocked(42, 0);
        assert(tasks.count == 1 && launchCalls == 2);
        fakePower = 1;
        runNext();
        assert(launchCalls == 3 && startPosts == 2 && !launchPending);
        launchPending = YES; fakePower = -1;
        continueWake(42, 0);
        assert(tasks.count == 1);
        fakePower = 1;
        runNext();
        runNext();
        assert(launchCalls == 4 && startPosts == 3 && !launchPending);

        uint64_t proof = 31337;
        assert(notify_register_check("tr.net.kcs.showcase.power.request-integration-test", &requestToken) == NOTIFY_STATUS_OK);
        assert(notify_set_state(requestToken, proof) == NOTIFY_STATUS_OK);
        NSData *bytes = [NSData dataWithBytes:&proof length:sizeof(proof)];
        assert([[NSFileManager defaultManager] createFileAtPath:[testProofDir() stringByAppendingPathComponent:@"stopped"] contents:bytes attributes:@{NSFilePosixPermissions:@0644}]);
        nonce = proof; fakePower = -1; power = (PowerState){ 0, 50 };
        onStopped(0);
        assert(nonce == proof && lockCalls == 0);
        fakePower = 0; fakeFront = YES;
        pollPower();
        assert(lockCalls == 1 && nonce == 0);
        uint64_t cleared = 1;
        assert(notify_get_state(requestToken, &cleared) == NOTIFY_STATUS_OK && cleared == 0);
        uint64_t savedPhase = 0, savedRequest = 1;
        assert(loadRecovery(&savedPhase, &savedRequest) && savedPhase == 4 && savedRequest == 0);
        nonce = proof;
        powerSequence[0] = 0; powerSequence[1] = -1; powerSequenceCount = 2; powerSequenceIndex = 0;
        onStopped(0);
        assert(nonce == proof && tasks.count == 1 && lockCalls == 1);
        powerSequenceCount = 0; powerSequenceIndex = 0;
        runNext();
        assert(nonce == 0 && lockCalls == 2);
        assert(saveRecovery(1, 0));
        recoveredPhase = recoveredStopRequest = 0;
        assert(loadRecovery(&recoveredPhase, &recoveredStopRequest) && recoveredPhase == 1);
        power = (PowerState){ -1, 0 }; deadline = 0; fakePower = 0; fakeTime = 300;
        pollPower();
        assert(deadline > 300.34 && deadline < 300.36 && lockCalls == 2 && tasks.count == 1);
        fakeTime = 300.36; runNext();
        assert(deadline == 0 && nonce != 0);
        power = (PowerState){ 0, 90 }; fakePower = 0; fakeTime = 400; fakeStopFail = YES;
        onDisconnected();
        assert(nonce == 0 && deadline == 405);
        fakeStopFail = NO; fakeTime = 405; pollPower();
        assert(nonce != 0 && deadline == 0 && lockCalls == 2);
        NSData *lateProof = [NSData dataWithBytes:&nonce length:sizeof(nonce)];
        assert([lateProof writeToFile:[testProofDir() stringByAppendingPathComponent:@"stopped"] atomically:YES]);
        // No stopped notification is delivered. The next fallback poll must lock.
        fakeTime++; pollPower();
        assert(nonce == 0 && lockCalls == 3);
        assert(notify_get_state(requestToken, &cleared) == NOTIFY_STATUS_OK && cleared == 0);
        assert([[NSFileManager defaultManager] removeItemAtPath:testProofDir() error:NULL]);
        puts("daemon launch retry and deferred stop acknowledgement passed");
    }
}
