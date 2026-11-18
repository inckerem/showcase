<?php
declare(strict_types=1);
require __DIR__ . '/common.php';
require_post('application/json');

// Bounded storage: unauthenticated clients must not grow usage.sqlite without limit.
// New ids are rate-limited per client network, not globally, so one client cannot
// lock out genuine installs; when full, young or long-silent ids are evicted.
const MAX_INSTALLS = 50000;          // distinct ids kept; see eviction below
const MAX_NEW_INSTALLS_PER_CLIENT_HOUR = 20;
const MIN_PING_INTERVAL = 10;        // seconds between accepted pings for one id
const INSTALL_RETENTION_DAYS = 180;  // the app re-pings at least every 30 days while used

if ((int)($_SERVER['CONTENT_LENGTH'] ?? 0) > 4096) {
    http_response_code(413);
    exit;
}
$input = file_get_contents('php://input', false, null, 0, 4097);
if ($input === false || strlen($input) > 4096) {
    http_response_code(413);
    exit;
}
$body = json_decode($input, true);
$id = $body['id'] ?? null;
if (!is_array($body) || !is_string($id) ||
    !preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iD', $id)) {
    http_response_code(400);
    exit;
}

$fields = ['version', 'package', 'model', 'ios', 'jailbreak', 'language'];
$values = [];
foreach ($fields as $field) {
    $value = $body[$field] ?? null;
    $values[$field] = is_string($value) && $value !== '' ? mb_substr($value, 0, 64) : null;
}
$country = $_SERVER['HTTP_CF_IPCOUNTRY'] ?? null;

// Keyed hash of the client's network (IPv4 address or IPv6 /48), used only for the
// one-hour new-id limit. The raw IP is never stored; the key stays in private/.
$values['country'] = ($body['country'] ?? false) === true && is_string($country) &&
    preg_match('/^[A-Z]{2}$/D', $country) ? $country : null;

try {
    $db = new PDO('sqlite:' . data_dir() . '/usage.sqlite', null, null,
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $db->exec('PRAGMA busy_timeout=3000');
    $db->exec('CREATE TABLE IF NOT EXISTS installs (
        id TEXT PRIMARY KEY, first_seen TEXT NOT NULL, last_seen TEXT NOT NULL,
        version TEXT, package TEXT, model TEXT, ios TEXT, jailbreak TEXT,
        language TEXT, country TEXT)');
    $db->exec('CREATE TABLE IF NOT EXISTS new_install_sources (
        client TEXT NOT NULL, created TEXT NOT NULL)');
    $db->exec('CREATE INDEX IF NOT EXISTS new_install_sources_client
        ON new_install_sources (client, created)');
    $db->exec('CREATE INDEX IF NOT EXISTS installs_last_seen ON installs (last_seen)');
    $time = time();
    $now = gmdate('c', $time);
    $lowerId = strtolower($id);
    // gmdate('c') strings share one format and offset, so they compare lexically.
    $db->exec('BEGIN IMMEDIATE');
    $db->prepare('DELETE FROM installs WHERE last_seen < ?')
        ->execute([gmdate('c', $time - INSTALL_RETENTION_DAYS * 86400)]);
    $hourAgo = gmdate('c', $time - 3600);
    $db->prepare('DELETE FROM new_install_sources WHERE created <= ?')->execute([$hourAgo]);
    $seen = $db->prepare('SELECT last_seen FROM installs WHERE id = ?');
    $seen->execute([$lowerId]);
    $lastSeen = $seen->fetchColumn();
    $reject = 0;
    if (is_string($lastSeen)) {
        if ($lastSeen > gmdate('c', $time - MIN_PING_INTERVAL)) $reject = 429;
    } else {
        $client = client_key();
        $recent = $db->prepare('SELECT COUNT(*) FROM new_install_sources WHERE client = ?');
        $recent->execute([$client]);
        if ((int)$recent->fetchColumn() >= MAX_NEW_INSTALLS_PER_CLIENT_HOUR) {
            $reject = 429;
        } else {
            $excess = (int)$db->query('SELECT COUNT(*) FROM installs')->fetchColumn()
                - MAX_INSTALLS + 1;
            if ($excess > 0) {
                // Established = seen across at least one day. Fake ids re-pinged
                // every MIN_PING_INTERVAL do not qualify, so a flood can only
                // displace young ids (oldest first_seen first, so re-pinging gives
                // no advantage) and established ids silent for more than 30 days
                // (oldest last_seen first; the app re-pings every 30 days).
                $db->prepare('DELETE FROM installs WHERE id IN
                    (SELECT id FROM installs
                     WHERE julianday(last_seen) - julianday(first_seen) < 1 OR last_seen < ?
                     ORDER BY julianday(last_seen) - julianday(first_seen) >= 1,
                        CASE WHEN julianday(last_seen) - julianday(first_seen) >= 1
                             THEN last_seen ELSE first_seen END ASC
                     LIMIT ?)')
                    ->execute([gmdate('c', $time - 30 * 86400), $excess]);
                if ((int)$db->query('SELECT COUNT(*) FROM installs')->fetchColumn() >= MAX_INSTALLS)
                    $reject = 507;
            }
            // Spend the client's new-id quota only for an id that is actually stored;
            // a 507 refusal (store still full) must not count against it.
            if ($reject === 0) {
                $db->prepare('INSERT INTO new_install_sources (client, created) VALUES (?, ?)')
                    ->execute([$client, $now]);
            }
        }
    }
    if ($reject !== 0) {
        $db->exec('COMMIT');
        http_response_code($reject);
        exit;
    }
    $stmt = $db->prepare('INSERT INTO installs
        (id, first_seen, last_seen, version, package, model, ios, jailbreak, language, country)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET last_seen=excluded.last_seen,
        version=excluded.version, package=excluded.package, model=excluded.model,
        ios=excluded.ios, jailbreak=excluded.jailbreak, language=excluded.language,
        country=excluded.country');
    $stmt->execute([$lowerId, $now, $now, ...array_values($values)]);
    $db->exec('COMMIT');
} catch (Throwable $error) {
    error_log('Showcase usage storage failed: ' . $error->getMessage());
    http_response_code(503);
    exit;
}
http_response_code(204);
