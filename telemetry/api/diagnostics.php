<?php
declare(strict_types=1);
require __DIR__ . '/common.php';
require_post('application/json');
$raw = file_get_contents('php://input', false, null, 0, 262145);
if ($raw === false || strlen($raw) > 262144) { http_response_code(413); exit; }
$p = json_decode($raw, true);
if (!is_array($p) || ($p['schema'] ?? null) !== 1 ||
    !is_string($p['installation'] ?? null) ||
    !preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/D', $p['installation']) ||
    !is_array($p['reports'] ?? null) || count($p['reports']) > 2 ||
    !is_int($p['freeMB'] ?? null) || $p['freeMB'] < 0) { http_response_code(400); exit; }
$clean = ['schema' => 1, 'installation' => $p['installation'], 'freeMB' => $p['freeMB'], 'received' => gmdate('c'), 'reports' => []];
foreach (['model', 'os', 'version'] as $key) {
    if (!is_string($p[$key] ?? null) || strlen($p[$key]) > 160) { http_response_code(400); exit; }
    $clean[$key] = $p[$key];
}
foreach ($p['reports'] as $r) {
    if (!is_array($r) || !in_array($r['process'] ?? null, ['Showcase', 'carplay_bt', 'carplay_services', 'showcase-powerd'], true) ||
        !is_int($r['time'] ?? null) || !is_string($r['excerpt'] ?? null) || strlen($r['excerpt']) > 130000) { http_response_code(400); exit; }
    $clean['reports'][] = ['process' => $r['process'], 'time' => $r['time'], 'excerpt' => $r['excerpt']];
}
$dir = data_dir() . '/remote';
if (!is_dir($dir) || !is_writable($dir)) { http_response_code(503); exit; }
$lock = fopen($dir . '/.lock', 'c');
if (!$lock || !flock($lock, LOCK_EX)) { http_response_code(503); exit; }
// Bounded disk use and 14-day retention, including inactive installations.
foreach (glob($dir . '/*.json') ?: [] as $old) if (filemtime($old) < time() - 14*86400) unlink($old);
foreach (glob($dir . '/.clients/*') ?: [] as $old) if (filemtime($old) < time() - 3600) unlink($old);
$base = $dir . '/' . $p['installation'];
$latest = $base . '-latest.json';
if (is_file($latest) && time() - filemtime($latest) < 120) { http_response_code(429); exit; }
// First-report time and reporting client per installation (latest-file mtime only
// says when it was last heard). Kept under the lock; ids missing from it predate the
// index and fall back to their last-heard time. Entries whose latest report expired
// are dropped. Untagged entries (plain first-seen int) predate client tagging.
const MAX_IDS_PER_CLIENT = 10;
const MAX_LIVE_IDS = 1000;
const STORE_PRESSURE_IDS = 500;
const YOUNG_ID_SECONDS = 86400;
$firstPath = $dir . '/.first-seen';
$firstSeen = json_decode((string)@file_get_contents($firstPath), true);
if (!is_array($firstSeen)) $firstSeen = [];
$latestFiles = glob($dir . '/*-latest.json') ?: [];
$indexed = [];
foreach ($latestFiles as $file) {
    $id = basename($file, '-latest.json');
    $entry = $firstSeen[$id] ?? null;
    if (is_array($entry) && is_int($entry['first'] ?? null) && is_string($entry['client'] ?? null)) {
        $indexed[$id] = $entry;
    } else {
        $indexed[$id] = is_int($entry) ? $entry : filemtime($file);
    }
}
$firstOf = fn($entry): int => is_array($entry) ? $entry['first'] : $entry;
if (!is_file($latest)) {
    try {
        $client = client_key();
    } catch (RuntimeException $error) {
        error_log('Showcase client key failed: ' . $error->getMessage());
        http_response_code(503);
        exit;
    }
    // Ids per tagged client, oldest first report first.
    $byClient = [];
    foreach ($indexed as $id => $entry) {
        if (is_array($entry)) $byClient[$entry['client']][(string)$id] = $entry['first'];
    }
    foreach ($byClient as &$ids) asort($ids);
    unset($ids);
    // Under store pressure (at least STORE_PRESSURE_IDS live ids) one client
    // network holds at most MAX_IDS_PER_CLIENT live ids, so the hourly new-id
    // quota alone (which only slows a fill down) cannot let a single client
    // fill the store with fake ids. Car iPads report through carrier CGNAT or a
    // shared IPv6 prefix, so many genuine installations share one client key:
    // below that pressure the cap is not applied, and at the cap only the
    // client's own young ids (first report under a day old, oldest first) are
    // replaced. Its established ids (and their crash reports) are never evicted
    // by the cap; a client with no young id left is refused instead.
    // Full store: evict a young installation (first report under a day old,
    // oldest first report first, so refreshing a fake id buys nothing), else
    // the oldest id of the client network holding the most ids (more than one:
    // a lone iPad is never displaced by a flood). Established single
    // installations are never evicted: the oldest entry is usually a genuine
    // iPad that is offline in a car, and its crash report must not be
    // displaced by fake ids. A store full of those refuses new ones instead.
    $victim = null;
    $clientIds = $byClient[$client] ?? [];
    if (count($clientIds) >= MAX_IDS_PER_CLIENT && count($latestFiles) >= STORE_PRESSURE_IDS) {
        $clientYoung = array_filter($clientIds, fn(int $first) => $first > time() - YOUNG_ID_SECONDS);
        if (!$clientYoung) { http_response_code(429); exit; }
        $victim = (string)array_key_first($clientYoung);
    } elseif (count($latestFiles) >= MAX_LIVE_IDS) {
        $young = array_filter($indexed, fn($entry) => $firstOf($entry) > time() - YOUNG_ID_SECONDS);
        if ($young) {
            uasort($young, fn($a, $b) => $firstOf($a) <=> $firstOf($b));
            $victim = (string)array_key_first($young);
        } else {
            $largest = [];
            foreach ($byClient as $ids) {
                if (count($ids) < 2 || count($ids) < count($largest)) continue;
                if (count($ids) > count($largest) || reset($ids) < reset($largest)) $largest = $ids;
            }
            if (!$largest) { http_response_code(507); exit; }
            $victim = (string)array_key_first($largest);
        }
    }
    // New installations also count against the client's hourly quota. Checked
    // after the 507 refusal (which must not spend the hourly quota) and before
    // the eviction (which a rate-limited client must not cause).
    if (!client_rate_ok($dir, 5)) { http_response_code(429); exit; }
    if ($victim !== null) {
        @unlink($dir . '/' . $victim . '-latest.json');
        @unlink($dir . '/' . $victim . '-crash.json');
        unset($indexed[$victim]);
    }
    $indexed[$p['installation']] = ['first' => time(), 'client' => $client];
}
if ($indexed != $firstSeen) save_report($firstPath, json_encode($indexed, JSON_THROW_ON_ERROR));
$body = json_encode($clean, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
function save_report(string $path, string $body): void {
    $tmp = tempnam(dirname($path), '.incoming-');
    if ($tmp === false || file_put_contents($tmp, $body) !== strlen($body)) { if ($tmp) unlink($tmp); http_response_code(503); exit; }
    chmod($tmp, 0600);
    if (!rename($tmp, $path)) { unlink($tmp); http_response_code(503); exit; }
}
if ($clean['reports']) {
    // Preserve the latest crash batch even after a heartbeat replaces latest.
    save_report($base . '-crash.json', $body);
}
save_report($latest, $body);
flock($lock, LOCK_UN); fclose($lock);
header('Content-Type: application/json');
http_response_code(201);
echo '{"accepted":true}';
