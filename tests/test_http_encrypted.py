"""Test the production encrypted-record functions with the real crypto code."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'source/carplay_services.m').read_text()
functions = source[source.index('static int enc_recv_frame('):source.index('/* ═══════════════════════════════════════════════════════════════\n * HTTP Request Parser')]
harness = r'''
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include "source/vendor/monocypher/monocypher.h"
#define ENCRYPTED_MAX_WRITE_SIZE 1024
typedef struct { uint8_t readKey[32], writeKey[32]; uint64_t readNonce, writeNonce; bool active; } encrypted_ctx_t;
''' + functions + r'''
int main(void) {
    int s[2]; assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, s));
    struct timeval tv = { .tv_sec = 0, .tv_usec = 100000 };
    assert(!setsockopt(s[1], SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)));
    encrypted_ctx_t writer = {0}, reader = {0};
    for (int i = 0; i < 32; i++) writer.writeKey[i] = reader.readKey[i] = (uint8_t)i;
    uint8_t input[2500], output[16384];
    for (int i = 0; i < 2500; i++) input[i] = (uint8_t)i;
    assert(enc_send_stream(s[0], &writer, input, sizeof(input)) == 0);
    size_t received = 0;
    for (int i = 0; i < 3; i++) {
        int n = enc_recv_frame(s[1], &reader, output + received, sizeof(output) - received);
        assert(n > 0); received += (size_t)n;
    }
    assert(received == sizeof(input) && !memcmp(input, output, received));
    assert(reader.readNonce == 3 && writer.writeNonce == 3);
    assert(enc_recv_frame(s[1], &reader, output, sizeof(output)) == -2);
    const uint8_t hdr[2] = {8, 0}; assert(write(s[0], hdr, 2) == 2);
    assert(enc_recv_frame(s[1], &reader, output, sizeof(output)) == -1);
    close(s[0]); close(s[1]);
    puts("real encrypted record roundtrip and partial timeout: PASS");
}
'''
with tempfile.TemporaryDirectory(prefix='showcase-http-crypto-') as tmp:
    cfile, binary = Path(tmp) / 'test.c', Path(tmp) / 'test'
    cfile.write_text(harness)
    subprocess.run(['clang', '-g', '-fsanitize=address,undefined', '-I', str(root),
                    str(cfile), str(root / 'source/vendor/monocypher/monocypher.c'),
                    '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
