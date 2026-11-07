<?php
declare(strict_types=1);
require __DIR__ . '/common.php';
require_post('application/x-tar');

const MAX_LOG_BYTES = 8 * 1024 * 1024;
const MAX_STORED_LOGS = 100;
if ((int)($_SERVER['CONTENT_LENGTH'] ?? 0) > MAX_LOG_BYTES) {
    http_response_code(413);
    exit;
}
$dir = data_dir() . '/logs';
if (!is_dir($dir) || !is_writable($dir)) {
    http_response_code(503);
    exit;
}
if (count(glob($dir . '/*.tar') ?: []) >= MAX_STORED_LOGS) {
    http_response_code(507);
    exit;
}
$name = gmdate('Ymd-His') . '-' . bin2hex(random_bytes(8)) . '.tar';
$path = $dir . '/' . $name;
$input = fopen('php://input', 'rb');
$output = fopen($path, 'xb');
if (!$input || !$output) {
    http_response_code(503);
    exit;
}
$bytes = stream_copy_to_stream($input, $output, MAX_LOG_BYTES + 1);
fclose($input);
fclose($output);
if ($bytes === false || $bytes === 0 || $bytes > MAX_LOG_BYTES) {
    unlink($path);
    http_response_code($bytes > MAX_LOG_BYTES ? 413 : 400);
    exit;
}
chmod($path, 0600);
header('Content-Type: application/json');
http_response_code(201);
echo json_encode(['id' => pathinfo($name, PATHINFO_FILENAME)]);
