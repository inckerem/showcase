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
