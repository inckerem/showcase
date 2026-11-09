"""Exercise peer credentials and partial reads on the real broker transport."""
from pathlib import Path
import subprocess
import tempfile

source = Path(__file__).resolve().parents[1] / "source"
harness = r"""
#include <assert.h>
#include <stdio.h>
#include "baa_broker.h"

int main(void) {
    int pair[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    assert(baa_peer_is_root(pair[0]) == (geteuid() == 0));
    assert(baa_prepare_socket(pair[0]));
    assert(baa_prepare_socket(pair[1]));

    const char sent[] = "hello";
    char received[sizeof(sent)];
    assert(baa_write_exact(pair[0], sent, sizeof(sent), baa_now_ms() + 1000));
    assert(baa_read_exact(pair[1], received, sizeof(received), baa_now_ms() + 1000));
    assert(memcmp(sent, received, sizeof(sent)) == 0);

    assert(baa_write_exact(pair[0], sent, 1, baa_now_ms() + 1000));
    uint64_t deadline = baa_now_ms() + 150;
    assert(!baa_read_exact(pair[1], received, sizeof(received), deadline));
    assert(baa_now_ms() >= deadline);

    close(pair[0]);
    assert(!baa_write_exact(pair[1], sent, sizeof(sent), baa_now_ms() + 1000));
    close(pair[1]);
    puts("PASS: peer UID, full read, partial response deadline, broken pipe");
}
"""

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / "broker.c").write_text(harness)
    subprocess.run([
        "clang", "-Wall", "-Wextra", "-Werror", "-I", str(source),
        str(path / "broker.c"), "-o", str(path / "broker"),
    ], check=True)
    subprocess.run([str(path / "broker")], check=True, timeout=5)
