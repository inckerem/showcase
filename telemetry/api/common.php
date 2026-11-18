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

// Cloudflare's published edge ranges (https://www.cloudflare.com/ips/).
// CF-Connecting-IP is only meaningful when the connection itself comes from
// one of these; anyone reaching the origin directly can forge the header.
const CLOUDFLARE_RANGES = [
    '173.245.48.0/20', '103.21.244.0/22', '103.22.200.0/22', '103.31.4.0/22',
    '141.101.64.0/18', '108.162.192.0/18', '190.93.240.0/20', '188.114.96.0/20',
    '197.234.240.0/22', '198.41.128.0/17', '162.158.0.0/15', '104.16.0.0/13',
    '104.24.0.0/14', '172.64.0.0/13', '131.0.72.0/22',
    '2400:cb00::/32', '2606:4700::/32', '2803:f800::/32', '2405:b500::/32',
    '2405:8100::/32', '2a06:98c0::/29', '2c0f:f248::/32',
];

function packed_in_cidr(string $packed, string $cidr): bool {
    [$net, $bits] = explode('/', $cidr);
    $netPacked = @inet_pton($net);
    if ($netPacked === false || strlen($netPacked) !== strlen($packed)) return false;
    $bits = (int)$bits;
    $bytes = intdiv($bits, 8);
    if (strncmp($packed, $netPacked, $bytes) !== 0) return false;
    if ($bits % 8 === 0) return true;
    $mask = (0xff << (8 - $bits % 8)) & 0xff;
    return (ord($packed[$bytes]) & $mask) === (ord($netPacked[$bytes]) & $mask);
}

function client_address(): string {
    $packed = @inet_pton((string)($_SERVER['REMOTE_ADDR'] ?? ''));
    if ($packed === false) return '';
    foreach (CLOUDFLARE_RANGES as $range) {
        if (!packed_in_cidr($packed, $range)) continue;
        $ip = $_SERVER['HTTP_CF_CONNECTING_IP'] ?? '';
        $forwarded = is_string($ip) ? @inet_pton($ip) : false;
        return $forwarded === false ? $packed : $forwarded;
    }
    return $packed;
}

// The HMAC secret is published only once fully written (link/rename of a
// complete temp file), so readers never see a partial key. A truncated key
// left by an older writer is replaced instead of failing every request.
function client_secret(string $dir): string {
    $keyPath = $dir . '/client-key';
    for ($attempt = 0; $attempt < 4; $attempt++) {
        clearstatcache(true, $keyPath);
        $key = @file_get_contents($keyPath);
        if (is_string($key) && strlen($key) === 32) return $key;
        $exists = file_exists($keyPath);
        if ($attempt === 3 || ($key === false && $exists)) {
            if ($attempt < 3) usleep(20000);
            continue;  // unreadable but present: never overwrite a possibly valid key
        }
        $tmp = @tempnam($dir, '.client-key-');
        if ($tmp === false) break;
        if (@file_put_contents($tmp, random_bytes(32)) === 32 && @chmod($tmp, 0600)) {
            // link() fails if a key was published concurrently; the loop then reads it.
            $exists ? @rename($tmp, $keyPath) : @link($tmp, $keyPath);
        }
        @unlink($tmp);
    }
    throw new RuntimeException('client key unavailable');
}

// Keyed hash of the client network, never the raw address. IPv4 counts per
// address; IPv6 per /48, the usual end-site delegation: a /64 bucket would
// give one subscriber 65536 independent new-id quotas and let it fill the
// global install caps. IPv4-mapped IPv6 (dual-stack sockets) is unwrapped so
// every IPv4 client does not share one ::ffff:0:0/96 bucket.
const CLIENT_IPV6_PREFIX_BYTES = 6;

function client_key(): string {
    $packed = client_address();
    if (strlen($packed) === 16) {
        $packed = strncmp($packed, str_repeat("\0", 10) . "\xff\xff", 12) === 0
            ? substr($packed, 12)
            : substr($packed, 0, CLIENT_IPV6_PREFIX_BYTES);
    }
    return hash_hmac('sha256', $packed, client_secret(data_dir()));
}

// Allows at most $limit new items per client per hour; prunes older stamps.
function client_rate_ok(string $dir, int $limit): bool {
    $clients = $dir . '/.clients';
    if (!is_dir($clients) && !@mkdir($clients, 0700) && !is_dir($clients)) return false;
    try {
        $path = $clients . '/' . client_key();
    } catch (RuntimeException $error) {
        error_log('Showcase client key failed: ' . $error->getMessage());
        http_response_code(503);
        exit;
    }
    $now = time();
    $stamps = [];
    foreach (@file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
        if (ctype_digit($line) && (int)$line > $now - 3600) $stamps[] = $line;
    }
    if (count($stamps) >= $limit) return false;
    $stamps[] = (string)$now;
    return file_put_contents($path, implode("\n", $stamps) . "\n") !== false;
}
