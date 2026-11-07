"""Exercise the app's Unix listener with real filesystem permissions."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'source/Showcase.m').read_text()
start = source.index('- (BOOL)startIPCListener {')
end = source.index('- (void)ipcAcceptLoop {', start)
method = source[start:end]
with tempfile.TemporaryDirectory(prefix='showcase-ipc-test-') as directory:
    path = Path(directory)
    socket_path = path / 'test.sock'
    code = r'''
#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <assert.h>
#define SOCK_PATH "SOCKET_PATH_REPLACE"
#define ip_log(...) ((void)0)
#define dispatch_async(queue, block) ((void)0)
@interface Listener : NSObject
@property (assign) int listenFd;
- (BOOL)startIPCListener;
@end
@implementation Listener
''' + method + r'''
@end
int main(void) { @autoreleasepool {
  Listener *listener=[Listener new];
  assert([listener startIPCListener]);
  struct stat st; assert(stat(SOCK_PATH, &st) == 0);
  assert((st.st_mode & 0777) == 0600);
  int client=socket(AF_UNIX,SOCK_STREAM,0); assert(client>=0);
  struct sockaddr_un addr={0}; addr.sun_family=AF_UNIX;
  strncpy(addr.sun_path, SOCK_PATH, sizeof(addr.sun_path)-1);
  assert(connect(client,(struct sockaddr *)&addr,sizeof(addr))==0);
  close(client); close(listener.listenFd); unlink(SOCK_PATH);
  puts("PASS: app IPC listens successfully with owner-only permissions");
} return 0; }
'''
    (path / 'test.m').write_text(code.replace('SOCKET_PATH_REPLACE', str(socket_path)))
    subprocess.run(['clang', '-fobjc-arc', '-framework', 'Foundation', str(path/'test.m'), '-o', str(path/'test')], check=True)
    subprocess.run([str(path/'test')], check=True)
