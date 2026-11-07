# iOS 12 test workflow

`python3 tests/test_deb_compatibility.py /path/to/package.deb` checks the
rootful package format, the absence of extended tar headers, iOS 12 minimum
version and dynamic-loader dependencies. Run the existing Python tests too.
These checks cannot prove the app launches on a device.

Connect the iPad by USB, unlock it and trust this Mac. `idevice_id -l` should
show the device. Run `sh tools/device-test/collect-crashes.sh` after reproducing
a crash. The command copies reports without deleting them from the iPad.
The script copies both Showcase and SpringBoard crash reports, including those
relevant to a respring into Safe Mode. For live app logs, run
`idevicesyslog -m Showcase` and open the app on the iPad.
Logs and reports can include private device or network information.

The host's iOS 27 simulator cannot emulate iOS 12.5.8, a jailbreak, BTstack,
or the CarPlay authentication path. Final launch and CarPlay tests require the
real iPad and iPhone.
