<?php
declare(strict_types=1);
require __DIR__ . '/common.php';
require_post('application/json');

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
    !preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i', $id)) {
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
$values['country'] = ($body['country'] ?? false) === true && is_string($country) &&
    preg_match('/^[A-Z]{2}$/', $country) ? $country : null;

try {
    $db = new PDO('sqlite:' . data_dir() . '/usage.sqlite', null, null,
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $db->exec('PRAGMA busy_timeout=3000');
    $db->exec('CREATE TABLE IF NOT EXISTS installs (
        id TEXT PRIMARY KEY, first_seen TEXT NOT NULL, last_seen TEXT NOT NULL,
        version TEXT, package TEXT, model TEXT, ios TEXT, jailbreak TEXT,
        language TEXT, country TEXT)');
    $now = gmdate('c');
    $stmt = $db->prepare('INSERT INTO installs
        (id, first_seen, last_seen, version, package, model, ios, jailbreak, language, country)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET last_seen=excluded.last_seen,
        version=excluded.version, package=excluded.package, model=excluded.model,
        ios=excluded.ios, jailbreak=excluded.jailbreak, language=excluded.language,
        country=excluded.country');
    $stmt->execute([strtolower($id), $now, $now, ...array_values($values)]);
} catch (Throwable $error) {
    error_log('Showcase usage storage failed: ' . $error->getMessage());
    http_response_code(503);
    exit;
}
http_response_code(204);
