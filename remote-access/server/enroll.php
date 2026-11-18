<?php
// Showcase Remote Access — cihaz kayıt uç noktası (kcs.net.tr/rssh/enroll.php).
// iPad, ilk kurulumda KENDİ ürettiği AÇIK anahtarını ve sshd host anahtarını
// buraya POST eder. Burada hiçbir şey yetkilendirilmez; kayıt "pending" olarak
// web kökü DIŞINA yazılır. Yetkilendirmeyi operatör `approve.sh` ile yapar.
//
// Güvenlik: yalnız POST, enrollment token şart, katı alan doğrulaması, kota.
// Özel anahtar buraya ASLA gelmez (iPad'de kalır).
declare(strict_types=1);

const STORE   = '/var/www/vhosts/keremincesu.com/private/showcase-remote';
const TOKFILE = '/var/www/vhosts/keremincesu.com/private/showcase-remote/.enroll-token';
const MAX_PENDING = 20;
const MAX_BODY    = 8192;

header('X-Robots-Tag: noindex, nofollow');
header('Cache-Control: no-store');
header('Content-Type: text/plain; charset=utf-8');

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') { http_response_code(405); exit("POST\n"); }

$raw = file_get_contents('php://input', false, null, 0, MAX_BODY + 1);
if ($raw === false || strlen($raw) > MAX_BODY) { http_response_code(413); exit("buyuk\n"); }
parse_str($raw, $in);

$want = is_file(TOKFILE) ? trim((string)file_get_contents(TOKFILE)) : '';
$got  = (string)($in['token'] ?? '');
if ($want === '' || !hash_equals($want, $got)) { http_response_code(403); exit("token\n"); }

// ssh-ed25519 / ecdsa / rsa açık anahtar satırı (base64 gövdeli, tek satır).
function clean_key(string $s): ?string {
    $s = trim(preg_replace('/\s+/', ' ', $s));
    if (!preg_match('~^(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/]+={0,2}( [^\s]{0,64})?$~', $s)) {
        return null;
    }
    return mb_substr($s, 0, 1200);
}

$pub  = clean_key((string)($in['pubkey']  ?? ''));
$host = clean_key((string)($in['hostkey'] ?? ''));
$dev  = preg_replace('/[^A-Za-z0-9._-]/', '', (string)($in['device'] ?? ''));
$dev  = $dev === '' ? 'ipad' : mb_substr($dev, 0, 40);
if ($pub === null || $host === null) { http_response_code(400); exit("anahtar\n"); }

if (!is_dir(STORE)) { mkdir(STORE, 0700, true); }
$pending = glob(STORE . '/*.json') ?: [];
if (count($pending) >= MAX_PENDING) { http_response_code(429); exit("kota\n"); }

// Aynı açık anahtar tekrar gelirse yeni kayıt açma (idempotent kurulum).
foreach ($pending as $f) {
    $old = json_decode((string)file_get_contents($f), true);
    if (is_array($old) && ($old['pubkey'] ?? '') === $pub) { echo "zaten-kayitli\n"; exit; }
}

$id  = bin2hex(random_bytes(8));
$rec = ['device' => $dev, 'pubkey' => $pub, 'hostkey' => $host,
        'ip' => $_SERVER['REMOTE_ADDR'] ?? '', 'time' => gmdate('c'), 'status' => 'pending'];
file_put_contents(STORE . "/$id.json",
    json_encode($rec, JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT), LOCK_EX);

echo "ok $id\n";
