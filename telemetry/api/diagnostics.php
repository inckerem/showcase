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
$base = $dir . '/' . $p['installation'];
$latest = $base . '-latest.json';
if (is_file($latest) && time() - filemtime($latest) < 120) { http_response_code(429); exit; }
if (!is_file($latest) && count(glob($dir . '/*-latest.json') ?: []) >= 1000) { http_response_code(507); exit; }
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
