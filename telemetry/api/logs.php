<?php
declare(strict_types=1);
require __DIR__ . '/common.php';
require_post('application/x-tar');

const MAX_LOG_BYTES = 8 * 1024 * 1024;
const MAX_STORED_LOGS = 100;
// One client network must not take every slot: a few uploads per hour and a
// small share of the store (operator review still clears the rest).
const MAX_LOGS_PER_CLIENT_HOUR = 3;
const MAX_STORED_LOGS_PER_CLIENT = 10;
if ((int)($_SERVER['CONTENT_LENGTH'] ?? 0) > MAX_LOG_BYTES) {
    http_response_code(413);
    exit;
}
$dir = data_dir() . '/logs';
if (!is_dir($dir) || !is_writable($dir)) {
    http_response_code(503);
    exit;
}
$input = fopen('php://input', 'rb');
$temp = tempnam($dir, '.incoming-');
$output = $temp !== false ? fopen($temp, 'r+b') : false;
if (!$input || !$output) {
    if ($temp !== false) unlink($temp);
    http_response_code(503);
    exit;
}
$bytes = stream_copy_to_stream($input, $output, MAX_LOG_BYTES + 1);
fclose($input);
// The app sends a plain POSIX tar. Reject arbitrary bytes before using a slot.
$tarHeader = $bytes !== false && $bytes >= 1536 && $bytes % 512 === 0 &&
    fseek($output, 257) === 0 && fread($output, 5) === 'ustar';
fclose($output);
if (!$tarHeader || $bytes > MAX_LOG_BYTES) {
    unlink($temp);
    http_response_code($bytes > MAX_LOG_BYTES ? 413 : 400);
    exit;
}
$lock = fopen($dir . '/.lock', 'c');
if (!$lock || !flock($lock, LOCK_EX)) {
    unlink($temp);
    http_response_code(503);
    exit;
}
try {
    $client = substr(client_key(), 0, 12);
} catch (RuntimeException $error) {
    error_log('Showcase client key failed: ' . $error->getMessage());
    unlink($temp);
    http_response_code(503);
    exit;
}
foreach (glob($dir . '/.clients/*') ?: [] as $old) if (filemtime($old) < time() - 3600) unlink($old);
if (count(glob($dir . '/*-' . $client . '-*.tar') ?: []) >= MAX_STORED_LOGS_PER_CLIENT) {
    unlink($temp);
    http_response_code(429);
    exit;
}
if (count(glob($dir . '/*.tar') ?: []) >= MAX_STORED_LOGS) {
    unlink($temp);
    http_response_code(507);
    exit;
}
// Last check: only an upload that will take a slot consumes the hourly budget.
if (!client_rate_ok($dir, MAX_LOGS_PER_CLIENT_HOUR)) {
    unlink($temp);
    http_response_code(429);
    exit;
}
// The client tag (keyed hash prefix, not the address) enables the per-client quota.
$name = gmdate('Ymd-His') . '-' . $client . '-' . bin2hex(random_bytes(8)) . '.tar';
$path = $dir . '/' . $name;
if (!rename($temp, $path)) {
    unlink($temp);
    http_response_code(503);
    exit;
}
flock($lock, LOCK_UN);
fclose($lock);
header('Content-Type: application/json');
http_response_code(201);
echo json_encode(['id' => pathinfo($name, PATHINFO_FILENAME)]);
