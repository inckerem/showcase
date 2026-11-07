"""Exercise the actual accept loop's shutdown and descriptor ownership on macOS."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'source/Showcase.m').read_text()
loop = source[source.index('- (void)ipcAcceptLoop {'):source.index('static bool read_exact(', source.index('- (void)ipcAcceptLoop {'))]
wake = source[source.index('static void wake_ipc_listener(void) {'):source.index('- (void)stopFlow {', source.index('static void wake_ipc_listener(void) {'))]
code = r'''
#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <pthread.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <assert.h>
#include <string.h>
static pthread_mutex_t g_ipc_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_touch_fd = -1;
static uint32_t g_touch_epoch, generation = 1;
static bool cancelled;
static const char *socket_path;
#define SOCK_PATH socket_path
static bool flow_cancelled(void) { return __atomic_load_n(&cancelled, __ATOMIC_ACQUIRE); }
static uint32_t flow_epoch(void) { return generation; }
#define ip_log(...) ((void)0)
#define dispatch_async(q, block) (block)()
#define UIApplicationStateActive 0
#define StateIdle 0
#define StateStopping 1
#define StateActive 2
static void send_app_visibility(int x) { (void)x; }
''' + wake + r'''
@interface UIApplication : NSObject
@property (assign) int applicationState;
+ (instancetype)sharedApplication;
@end
@implementation UIApplication
+ (instancetype)sharedApplication { return [self new]; }
@end
@interface Subject : NSObject
@property (assign) int listenFd, clientFd, state;
@property (assign) BOOL restartAfterStop;
@property (nonatomic, strong) dispatch_semaphore_t ipcDone;
- (void)ipcAcceptLoop;
- (void)ipcHandleConnection:(int)fd;
- (void)endAWDLSuppression;
- (void)stopFlow;
@end
@implementation Subject
- (void)ipcHandleConnection:(int)fd { char b; (void)read(fd, &b, 1); }
- (void)endAWDLSuppression {}
- (void)stopFlow { assert(0); }
''' + loop + r'''
@end
static void *worker(void *obj) { @autoreleasepool { [(__bridge Subject *)obj ipcAcceptLoop]; } return NULL; }
int main(int argc, char **argv) { @autoreleasepool {
    assert(argc == 2);
    socket_path = argv[1];
    for (int connected = 0; connected < 2; ++connected) {
        cancelled = false; ++generation;
        Subject *s = [Subject new]; s.clientFd = -1; s.state = StateStopping;
        s.ipcDone = dispatch_semaphore_create(0);
        int fd = socket(AF_UNIX, SOCK_STREAM, 0); assert(fd >= 0);
        struct sockaddr_un addr = {0}; addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, argv[1], sizeof(addr.sun_path)-1); unlink(argv[1]);
        assert(bind(fd, (void *)&addr, sizeof(addr)) == 0 && listen(fd, 1) == 0);
        s.listenFd = fd; pthread_t thread;
        assert(pthread_create(&thread, NULL, worker, (__bridge void *)s) == 0);
        int client = -1;
        if (connected) {
            client = socket(AF_UNIX, SOCK_STREAM, 0); assert(client >= 0);
            assert(connect(client, (void *)&addr, sizeof(addr)) == 0);
            for (int i = 0; i < 1000; ++i) {
                pthread_mutex_lock(&g_ipc_lock); int ready = s.clientFd >= 0;
                pthread_mutex_unlock(&g_ipc_lock); if (ready) break; usleep(1000);
            }
            pthread_mutex_lock(&g_ipc_lock); assert(s.clientFd >= 0);
            pthread_mutex_unlock(&g_ipc_lock);
        }
        __atomic_store_n(&cancelled, true, __ATOMIC_RELEASE);
        pthread_mutex_lock(&g_ipc_lock);
        if (s.clientFd >= 0) assert(shutdown(s.clientFd, SHUT_RDWR) == 0);
        pthread_mutex_unlock(&g_ipc_lock);
        wake_ipc_listener();
        assert(dispatch_semaphore_wait(s.ipcDone, dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC)) == 0);
        pthread_join(thread, NULL);
        assert(s.listenFd == -1 && s.clientFd == -1 && g_touch_fd == -1);
        if (client >= 0) close(client); unlink(argv[1]);
    }
    puts("PASS: listening and connected IPC loops stop and close their own descriptors");
} }
'''
with tempfile.TemporaryDirectory(prefix='showcase-lifecycle-socket-') as directory:
    path = Path(directory)
    (path / 'test.m').write_text(code)
    subprocess.run(['clang', '-fobjc-arc', '-framework', 'Foundation', str(path / 'test.m'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test'), str(path / 'socket')], check=True, timeout=8)
