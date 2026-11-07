<?php
declare(strict_types=1);

header('Cache-Control: no-store');

function data_dir(): string {
    // The API is deployed at <vhost>/repo/api; private/ is outside the web root.
    $dir = dirname(__DIR__, 3) . '/private/showcase';
    if (!is_dir($dir) || !is_writable($dir)) {
        http_response_code(503);
        exit;
    }
    return $dir;
}

function require_post(string $contentType): void {
    if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
        header('Allow: POST');
        http_response_code(405);
        exit;
    }
    if (strtolower(trim(explode(';', $_SERVER['CONTENT_TYPE'] ?? '')[0])) !== $contentType) {
        http_response_code(415);
        exit;
    }
}
