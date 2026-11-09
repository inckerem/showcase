"""Exercise the actual embedded recovery script without touching host Bluetooth."""
import json
import pathlib
import re
import subprocess
import tempfile
import time

source = (pathlib.Path(__file__).parents[1] / "source/Showcase.m").read_text()
block = source.split("NSString *script =", 1)[1].split("NSDictionary *job", 1)[0]
script = "".join(json.loads(s) for s in re.findall(r'"(?:\\.|[^"\\])*"', block))
with tempfile.TemporaryDirectory(prefix="bluetooth recovery ") as directory:
    root = pathlib.Path(directory)
    log, ready, socket, owned = (root / name for name in
                                 ("calls", "ready", "socket", "owned"))
    restore = root / "restore"
    command = root / "mock command"
    command.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "' + str(log) + '"\n')
    command.chmod(0o755)
    btstack, bluetool, bluetoothd = (root / name for name in
                                     ("BTstack plist", "BlueTool plist",
                                      "bluetoothd plist"))
    btstack.touch()
    bluetool.touch()
    bluetoothd.touch()
    socket.touch()
    owner = subprocess.Popen(["sleep", "30"])
    guard = subprocess.Popen(["/bin/sh", "-c", script, "guard", str(owner.pid),
                              str(command), str(btstack), str(bluetool),
                              str(bluetoothd), str(ready), str(command),
                              str(socket), str(owned), "CarDisplaySim",
                              str(restore), "com.apple.BlueTool",
                              "com.apple.bluetoothd"])
    try:
        for _ in range(100):
            if ready.exists():
                break
            time.sleep(.01)
        assert ready.exists(), "Guard did not arm"
        assert not log.exists(), "Guard touched Bluetooth while app was alive"
        owner.kill()
        owner.wait()
        assert guard.wait(timeout=5) == 0
        assert log.read_text().splitlines() == [
            "-TERM CarDisplaySim", "unload " + str(btstack),
            "load " + str(bluetool), "load " + str(bluetoothd)]
        assert not ready.exists() and not socket.exists() and not restore.exists()
        # The restore file must abort the wait loop before the owner dies.
        owner2 = subprocess.Popen(["sleep", "30"])
        guard2 = subprocess.Popen(["/bin/sh", "-c", script, "guard", str(owner2.pid),
                                   str(command), str(btstack), str(bluetool),
                                   str(bluetoothd), str(ready), str(command),
                                   str(socket), str(owned), "CarDisplaySim",
                                   str(restore), "com.apple.BlueTool",
                                   "com.apple.bluetoothd"])
        try:
            for _ in range(100):
                if ready.exists() and restore.exists():
                    break
                time.sleep(.01)
            restore.touch()
            assert guard2.wait(timeout=5) == 0
            logLines = log.read_text().splitlines()
            assert logLines[-1] == "load " + str(bluetoothd)
            assert "-TERM CarDisplaySim" in logLines
        finally:
            owner2.kill()
            owner2.wait()
            if guard2.poll() is None:
                guard2.kill()
                guard2.wait()
    finally:
        for process in (owner, guard):
            if process.poll() is None:
                process.kill()
                process.wait()
print("Bluetooth crash recovery passed")
