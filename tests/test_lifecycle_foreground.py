"""Exercise the app's foreground handler in each connection state."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'source/Showcase.m').read_text()
# The shared resync helper sits right before handleForeground; test both.
start = source.index('- (void)resyncCarPlayVideo {')
foreground = source.index('- (void)handleForeground {')
method = source[start:source.index('\n- (void)', foreground + 1)] + '\n'
code = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
typedef enum { StateIdle, StateAwaitingAP, StatePreparingBT, StatePreparingNet,
               StateAwaitingPhone, StateActive, StateStopping } ShowcaseState;
static int32_t g_video_needs_resync, g_video_suspended;
static int visibility, polls, renders;
#define ip_log(...) ((void)0)
#define dispatch_async(q, block) (block)()
static void send_app_visibility(int n) { visibility = n; }
static int wifiRestores;
static void showcase_restore_wifi_power_after_cycle(const char *reason) { (void)reason; wifiRestores++; }
@interface AVSampleBufferDisplayLayer : NSObject
- (void)flush;
@end
@implementation AVSampleBufferDisplayLayer
- (void)flush {}
@end
@interface FakeView : NSObject
@property (nonatomic, strong) AVSampleBufferDisplayLayer *layer;
@end
@implementation FakeView @end
@interface Subject : NSObject
@property (assign) ShowcaseState state;
@property (nonatomic, strong) FakeView *videoView;
@property (assign) void *videoQueue;
@property (assign) void *bgQueue;
- (void)endBackgroundTask;
- (void)pollAP;
- (void)renderState;
- (void)presentPendingBluetoothCompatibilityError;
- (void)presentPendingWifiSetupError;
- (void)presentPendingServicesSetupError;
- (void)resyncCarPlayVideo;
- (void)handleForeground;
@end
@implementation Subject
- (void)endBackgroundTask {}
- (void)pollAP { polls++; }
- (void)renderState { renders++; }
- (void)presentPendingBluetoothCompatibilityError {}
- (void)presentPendingWifiSetupError {}
- (void)presentPendingServicesSetupError {}
''' + method + r'''
@end
int main(void) { @autoreleasepool {
    Subject *s = [Subject new]; s.videoView = [FakeView new];
    s.videoView.layer = [AVSampleBufferDisplayLayer new];
    for (int state = StateAwaitingAP; state <= StateActive; state++) {
        s.state = state; g_video_suspended = 1; g_video_needs_resync = 0;
        visibility = 0; [s handleForeground];
        assert(!g_video_suspended && g_video_needs_resync && visibility == 1);
    }
    assert(polls == 1 && renders == 5);
    assert(wifiRestores == 5); /* every foreground checks for an interrupted Wi-Fi power cycle */
    puts("PASS: foreground resumes video during every connection phase");
} }
'''
with tempfile.TemporaryDirectory(prefix='showcase-lifecycle-foreground-') as directory:
    path = Path(directory)
    (path / 'test.m').write_text(code)
    subprocess.run(['clang', '-fobjc-arc', '-framework', 'Foundation', str(path / 'test.m'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
