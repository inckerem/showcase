# KCS diagnostics API

Deploy `api/*.php` to `https://kcs.net.tr/repo/api/`. The host must provide PHP
with PDO SQLite. Create `<vhost-parent>/private/showcase/logs/` writable by the
PHP pool user, outside the public document root. The application database keeps
one row per random installation ID and does not store the IP address. Normal
web server access logs may still contain IP addresses.

`ping.php` accepts optional usage fields only after the user enables anonymous
sharing in Settings. A fresh KCS installation ID is used rather than reusing
the upstream recipient's ID. `logs.php` accepts an at most 8 MiB tar archive
only after the user taps Send Logs to KCS and confirms the destination. The
archive can contain Wi-Fi names, device details, and Bluetooth captures. It is
stored outside the web root, without an index or download endpoint. At 100
archives the endpoint rejects uploads until an operator reviews and removes
old files. Do not publish the private directory or archive contents.

## Optional remote diagnostics (iOS 12 rootful)

Installing **Showcase Uzaktan Tanilama** explicitly enables automatic reports;
this is a separate opt-in package, not a default dependency of Showcase. Remove
the package in Cydia to stop reporting, or create
`/var/mobile/Library/ShowcaseRemoteDiagnostics/disabled`. No settings toggle is
currently exposed in the application. The mobile-user launchd worker runs once
every three minutes and exits; it sends new Showcase/helper crash excerpts or a
heartbeat every 30 minutes. HTTPS requests time out within 25 seconds. Offline
failures retain unsent reports for the next invocation, without an upload queue.

Only allowlisted technical lines from recent iOS 12 text crash reports are sent,
plus a random installation ID, hardware model, OS/app version and free disk space.
No raw crash archives, screen content, audio, Wi-Fi names or pairing secrets are
collected. Unknown crash formats are reported without their raw content. The
worker cannot diagnose a hang that creates no crash report; device access may
still be needed. iOS may delay scheduled jobs while asleep.

Deploy `diagnostics.php` with `common.php`; create private `showcase/remote` with
mode 0700 owned by the PHP pool user. The endpoint retains latest status and latest
crash batch separately, with 14-day expiry on incoming requests and a 1000-install
cap. Reports have no public retrieval endpoint. Read them over authenticated SSH.
Install IDs are not verified device identities: incoming diagnostic text is
untrusted. Normal web-server access logs may contain IP addresses.

Validation: `python3 telemetry/test_remote.py /path/to/php telemetry/api`,
compile `agent/test.m` against host Foundation, and run `agent/test_package.py`
against the built deb. Physical iOS 12 launchd delivery must be verified after
installing the package; a successful host test does not establish device delivery.
