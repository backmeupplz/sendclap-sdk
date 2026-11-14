<?php

// Router for `php -S`: a tiny fake of the Sendclap API. Each request is logged to MOCK_LOG for the assertions.

declare(strict_types=1);

$uri = $_SERVER['REQUEST_URI'];
$path = (string) parse_url($uri, PHP_URL_PATH);
$method = $_SERVER['REQUEST_METHOD'];
$headers = array_change_key_case(getallheaders(), CASE_LOWER);
$raw = file_get_contents('php://input');
$body = $raw === '' ? null : json_decode($raw, true);
file_put_contents(sys_get_temp_dir() . '/sendclap-mock-' . $_SERVER['SERVER_PORT'] . '.json',
    json_encode(['method' => $method, 'uri' => $uri, 'headers' => $headers, 'body' => $body]));

function reply(int $status, mixed $data, string $type = 'application/json'): void
{
    http_response_code($status);
    header("Content-Type: $type");
    echo $type === 'application/json' ? json_encode($data) : $data;
}

$license = ['key' => 'GOOD', 'activations' => 1, 'max_activations' => 3];
$product = ['id' => 1, 'name' => 'Pro'];
$checkout = ['id' => '0xabc', 'status' => 'pending', 'type' => 'product', 'amount' => 29, 'currency' => 'usd', 'method' => 'card', 'email' => 'buyer@example.com'];

if (str_starts_with($path, '/api/v1/licenses/')) {
    $action = substr($path, strlen('/api/v1/licenses/'));
    $key = $body['license_key'] ?? null;
    $inst = $body['instance_id'] ?? null;
    if ($key !== 'GOOD' && $key !== 'FULL') {
        reply(404, ['valid' => false, 'error' => 'license key not found']);
    } elseif ($action === 'validate') {
        reply(200, ['valid' => $inst === null || $inst === 'dev-1', 'license' => $license, 'product' => $product]);
    } elseif (!$inst) {
        reply(400, ['error' => 'instance_id is required']);
    } elseif ($action === 'activate' && $key === 'FULL') {
        reply(409, ['activated' => false, 'error' => 'activation limit reached', 'license' => ['key' => 'FULL', 'activations' => 3, 'max_activations' => 3], 'product' => $product]);
    } elseif ($action === 'activate') {
        reply(200, ['activated' => true, 'instance_id' => $inst, 'license' => $license, 'product' => $product]);
    } else {
        reply(200, ['deactivated' => true, 'license' => ['activations' => 0] + $license, 'product' => $product]);
    }
} elseif ($path === '/api/v1/creators/demo') {
    reply(200, ['handle' => 'demo', 'name' => 'Ada Builds']);
} elseif (str_starts_with($path, '/api/v1/') && ($headers['authorization'] ?? '') !== 'Bearer sc_test') {
    reply(401, ['error' => 'invalid API key']);
} elseif ($path === '/api/v1/checkouts' && $method === 'POST') {
    reply(201, $checkout + ['url' => 'http://x/checkout/0xabc']);
} elseif ($path === '/api/v1/checkouts/0xabc') {
    reply(200, $checkout);
} elseif ($path === '/api/v1/payments') {
    reply(200, [['id' => 42, 'status' => $_GET['status'] ?? null]]);
} elseif ($path === '/api/v1/payments/42') {
    reply(200, ['id' => 42, 'item' => 'Pro', 'activity' => []]);
} elseif ($path === '/api/v1/payments/7') {
    reply(404, ['error' => 'payment not found']);
} elseif ($path === '/api/v1/broken') {
    reply(200, 'not json', 'text/plain');
} else {
    reply(404, '<html>Not found</html>', 'text/html');
}
