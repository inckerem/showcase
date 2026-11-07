"""Exercise the app's foreground handler in each connection state."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'source/Showcase.m').read_text()
method = source[source.index('- (void)handleForeground {'):source.index('- (void)applicationWillTerminate:', source.index('- (void)handleForeground {'))]
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
- (void)endBackgroundTask;
- (void)pollAP;
- (void)renderState;
- (void)presentPendingBluetoothCompatibilityError;
- (void)handleForeground;
@end
@implementation Subject
- (void)endBackgroundTask {}
- (void)pollAP { polls++; }
- (void)renderState { renders++; }
- (void)presentPendingBluetoothCompatibilityError {}
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
    puts("PASS: foreground resumes video during every connection phase");
} }
'''
with tempfile.TemporaryDirectory(prefix='showcase-lifecycle-foreground-') as directory:
    path = Path(directory)
    (path / 'test.m').write_text(code)
    subprocess.run(['clang', '-fobjc-arc', '-framework', 'Foundation', str(path / 'test.m'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
