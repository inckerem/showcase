"""Exercise IPv4 TCP fallback failures using the production function."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'source/carplay_services.m').read_text()
function = source[source.index('static int bind_tcp_port_ipv4('):source.index('/* Helper: bind a TCP listen socket')]
harness = r'''
#include <arpa/inet.h>
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
static int fail_step, closed, listen_calls, name_calls;
static int fake_socket(int family, int type, int proto) {
    (void)family; (void)type; (void)proto; return 42;
}
static int fake_setsockopt(int fd, int level, int name, const void *value, socklen_t len) {
    (void)fd; (void)level; (void)name; (void)value; (void)len; return 0;
}
static int fake_bind(int fd, const struct sockaddr *addr, socklen_t len) {
    (void)fd; (void)addr; (void)len;
    if (fail_step == 1) { errno = EADDRINUSE; return -1; } return 0;
}
static int fake_listen(int fd, int backlog) {
    (void)fd; (void)backlog; listen_calls++;
    if (fail_step == 2) { errno = EOPNOTSUPP; return -1; } return 0;
}
static int fake_getsockname(int fd, struct sockaddr *addr, socklen_t *len) {
    (void)fd; (void)len; name_calls++;
    if (fail_step == 3) { errno = ENOTSOCK; return -1; }
    ((struct sockaddr_in *)addr)->sin_port = htons(43210); return 0;
}
static int fake_close(int fd) { assert(fd == 42); closed++; errno = EBADF; return 0; }
#define socket fake_socket
#define setsockopt fake_setsockopt
#define bind fake_bind
#define listen fake_listen
#define getsockname fake_getsockname
#define close fake_close
''' + function + r'''
int main(void) {
    uint16_t port;
    for (fail_step = 1; fail_step <= 3; fail_step++) {
        port = 7; closed = listen_calls = name_calls = 0; errno = 0;
        assert(bind_tcp_port_ipv4(&port) == -1);
        assert(closed == 1 && port == 7);
        assert(listen_calls == (fail_step >= 2));
        assert(name_calls == (fail_step == 3));
        if (fail_step == 2) assert(errno == EOPNOTSUPP);
        if (fail_step == 3) assert(errno == ENOTSOCK);
    }
    fail_step = 0; port = 0; closed = listen_calls = name_calls = 0;
    assert(bind_tcp_port_ipv4(&port) == 42);
    assert(port == 43210 && closed == 0 && listen_calls == 1 && name_calls == 1);
    puts("IPv4 TCP bind, listen, getsockname failures and success: PASS");
}
'''
with tempfile.TemporaryDirectory(prefix='showcase-tcp-bind-') as tmp:
    cfile, binary = Path(tmp) / 'test.c', Path(tmp) / 'test'
    cfile.write_text(harness)
    subprocess.run(['clang', '-g', '-fsanitize=address,undefined', str(cfile),
                    '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
