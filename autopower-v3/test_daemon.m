#import <Foundation/Foundation.h>
#import <notify.h>
#import <assert.h>
static double fakeTime;
static int fakePower, connectedCount, disconnectedCount, stopPosts, fakeStopFail;
double testMonotonicSeconds(void) { return fakeTime; }
int testReadPower(void) { return fakePower; }
void testConnected(void) { connectedCount++; }
void testDisconnected(void) { disconnectedCount++; }
static uint32_t testNotifyPost(const char *name) { if (!strcmp(name,"tr.net.kcs.showcase.power.stop")) { stopPosts++; if (fakeStopFail) return 1; } return 0; }
#define SHOWCASE_POWER_TEST 1
#define notify_post testNotifyPost
#define main powerDaemonUnusedMain
#include "PowerDaemon.m"
#undef main
#undef notify_post
int main(void) {
    @autoreleasepool {
        power = (PowerState){ -1, 0 };
        fakeTime = 100; fakePower = 1; pollPower();
        fakeTime = 150; pollPower();
        assert(connectedCount == 0 && disconnectedCount == 0);
        fakeTime = 151; fakePower = 0; pollPower();
        fakeTime = 155; fakePower = 1; pollPower();
        fakeTime = 155.1; pollPower(); assert(connectedCount == 0 && disconnectedCount == 0);
        fakeTime = 155.21; pollPower(); assert(connectedCount == 1 && disconnectedCount == 0);
        fakeTime = 160; fakePower = 0; pollPower();
        fakeTime = 160.3; pollPower(); assert(disconnectedCount == 0);
        fakeTime = 160.36; fakePower = -1; pollPower(); assert(disconnectedCount == 0);
        fakeTime = 160.5; fakePower = 0; pollPower(); assert(disconnectedCount == 1);
        assert(desiredPollInterval() == 1);
        fakeTime = 181; fakePower = 1; pollPower();
        assert(desiredPollInterval() == 1);
        fakeTime = 181.1; fakePower = 0; pollPower();
        fakeTime = 181.16; pollPower(); assert(connectedCount == 1);
        /* A daemon restart during an unplug debounce resumes the stop. */
        power = (PowerState){ -1, 0 }; deadline = 0; recoveredPowerState = 2; recoveredPhase = 5; recoveredStopRequest = 0;
        fakePower = 0; fakeTime = 200; pollPower();
        fakeTime = 200.3; pollPower(); assert(disconnectedCount == 1);
        fakeTime = 200.36; pollPower(); assert(disconnectedCount == 2);
        /* Stable battery power must not synthesize a new unplug after restart. */
        power = (PowerState){ -1, 0 }; deadline = 0; recoveredPhase = 4; recoveredStopRequest = 0;
        fakeTime = 220; fakePower = 0; pollPower();
        fakeTime = 240; pollPower(); assert(disconnectedCount == 2);
        /* Power connected while the daemon was down is acted upon after debounce. */
        power = (PowerState){ -1, 0 }; deadline = 0; recoveredPhase = 4;
        fakeTime = 250; fakePower = 1; pollPower();
        fakeTime = 250.21; pollPower(); assert(connectedCount == 2);
        /* An interrupted off debounce restarts its full wait. */
        power = (PowerState){ -1, 0 }; deadline = 0; recoveredPhase = 1;
        fakeTime = 260; fakePower = 0; pollPower();
        fakeTime = 260.36; pollPower(); assert(disconnectedCount == 3);
        /* A previous sent request remains available after daemon restart. */
        power = (PowerState){ -1, 0 }; deadline = 0; recoveredPowerState = 1; recoveredPhase = 4; recoveredStopRequest = 444;
        assert(notify_register_check("tr.net.kcs.showcase.power.recovery-test", &requestToken) == NOTIFY_STATUS_OK);
        assert(notify_set_state(requestToken, 0) == NOTIFY_STATUS_OK);
        fakeTime = 300; fakePower = 0; pollPower();
        uint64_t restored = 0;
        assert(notify_get_state(requestToken, &restored) == NOTIFY_STATUS_OK);
        assert(nonce == 444 && restored == 444 && stopPosts == 1);
        /* A failed restored notification is not silently lost. */
        power = (PowerState){ -1, 0 }; deadline = 0; recoveredPhase = 4; recoveredStopRequest = 555;
        fakeTime = 320; fakePower = 0; fakeStopFail = 1; pollPower();
        assert(nonce == 0 && deadline > 320.34 && deadline < 320.36 && stopPosts == 2);
        fakeStopFail = 0; fakeTime = 320.36; pollPower();
        assert(disconnectedCount == 4);
        puts("daemon startup, debounce, unknown and cancellation scenarios passed");
    }
}
