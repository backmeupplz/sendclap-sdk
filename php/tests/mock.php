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
$checkout = ['id' => '0xabc', 'status' => 'pending', 'type' => 'product', 'amount' => 29, 'currency' => 'usd', 'method' => 'card', 'email' => 'buyer@example.com', 'url' => 'http://x/checkout/0xabc'];
$fail = fn (int $status, string $code, string $error, array $extra = []) => reply($status, $extra + ['error' => $error, 'code' => $code]);

if (str_starts_with($path, '/api/v1/licenses/')) {
    $action = substr($path, strlen('/api/v1/licenses/'));
    $key = $body['license_key'] ?? null;
    $inst = $body['instance_id'] ?? null;
    if ($key === 'REFUNDED') {
        $fail(403, 'license_disabled', 'this license key is disabled', ['valid' => false]);
    } elseif ($key !== 'GOOD' && $key !== 'FULL') {
        $fail(404, 'license_not_found', 'license key not found', ['valid' => false]);
    } elseif ($action === 'validate') {
        reply(200, ['valid' => $inst === null || $inst === 'dev-1', 'license' => $license, 'product' => $product]);
    } elseif (!$inst) {
        $fail(400, 'bad_request', 'instance_id is required');
    } elseif ($action === 'deactivate' && $inst !== 'dev-1') {
        $fail(404, 'instance_not_found', 'that instance is not activated', ['deactivated' => false, 'license' => $license, 'product' => $product]);
    } elseif ($action === 'activate' && $key === 'FULL') {
        $fail(409, 'activation_limit', 'activation limit reached', ['activated' => false, 'license' => ['key' => 'FULL', 'activations' => 3, 'max_activations' => 3], 'product' => $product]);
    } elseif ($action === 'activate') {
        reply(200, ['activated' => true, 'instance_id' => $inst, 'license' => $license, 'product' => $product]);
    } else {
        reply(200, ['deactivated' => true, 'license' => ['activations' => 0] + $license, 'product' => $product]);
    }
} elseif ($path === '/api/v1/creators/demo') {
    reply(200, ['handle' => 'demo', 'name' => 'Ada Builds']);
} elseif ($path === '/api/v1/broken') { // before the key check: the test calls it without a key
    reply(200, 'not json', 'text/plain');
} elseif (str_starts_with($path, '/api/v1/') && ($headers['authorization'] ?? '') !== 'Bearer sc_test') {
    $fail(401, 'invalid_api_key', 'invalid API key');
} elseif ($path === '/api/v1/checkouts' && $method === 'POST') {
    reply(201, $checkout);
} elseif ($path === '/api/v1/checkouts/0xabc') {
    reply(200, $checkout);
} elseif ($path === '/api/v1/payments') {
    // two per page, newest first, cursor = the last id on the page
    $after = (int) ($_GET['after'] ?? PHP_INT_MAX);
    $rows = array_values(array_filter([['id' => 3], ['id' => 2], ['id' => 1]], fn ($r) => $r['id'] < $after));
    $data = array_slice($rows, 0, 2);
    $more = count($rows) > 2;
    reply(200, ['data' => $data, 'has_more' => $more, 'next' => $more ? end($data)['id'] : null]);
} elseif ($path === '/api/v1/members') {
    reply(200, ['data' => [['email' => 'a@b.co']], 'has_more' => false, 'next' => null]);
} elseif ($path === '/api/v1/payments/42') {
    reply(200, ['id' => 42, 'item' => 'Pro', 'activity' => []]);
} elseif ($path === '/api/v1/payments/7') {
    $fail(404, 'not_found', 'payment not found');
} else {
    reply(404, '<html>Not found</html>', 'text/html');
}
