<?php

// Dependency-free test runner: starts tests/mock.php under `php -S` and runs plain assertions.
// Run from anywhere: php php/tests/run.php

declare(strict_types=1);

use Sendclap\ActivationLimitException;
use Sendclap\ApiClient;
use Sendclap\DisabledLicenseException;
use Sendclap\ExpiredLicenseException;
use Sendclap\Http;
use Sendclap\InstanceNotFoundException;
use Sendclap\InvalidLicenseException;
use Sendclap\LicenseClient;
use Sendclap\NetworkException;
use Sendclap\SendclapException;

spl_autoload_register(function (string $class): void {
    if (str_starts_with($class, 'Sendclap\\')) {
        require __DIR__ . '/../src/' . substr($class, strlen('Sendclap\\')) . '.php';
    }
});

$sock = stream_socket_server('tcp://127.0.0.1:0');
$port = (int) substr((string) strrchr((string) stream_socket_get_name($sock, false), ':'), 1);
fclose($sock);
$devnull = PHP_OS_FAMILY === 'Windows' ? 'NUL' : '/dev/null';
$server = proc_open([PHP_BINARY, '-S', "127.0.0.1:$port", __DIR__ . '/mock.php'], [1 => ['file', $devnull, 'w'], 2 => ['file', $devnull, 'w']], $pipes);
register_shutdown_function(fn () => proc_terminate($server));
for ($i = 0; $i < 100; $i++) {
    $conn = @fsockopen('127.0.0.1', $port);
    if ($conn) {
        fclose($conn);
        break;
    }
    usleep(50_000);
}

$base = "http://127.0.0.1:$port";
define('MOCK_LOG', sys_get_temp_dir() . "/sendclap-mock-$port.json");
$passed = 0;
$failed = 0;

function test(string $name, callable $fn): void
{
    global $passed, $failed;
    try {
        $fn();
        $passed++;
        echo "ok   $name\n";
    } catch (\Throwable $e) {
        $failed++;
        echo "FAIL $name: " . $e->getMessage() . "\n";
    }
}

function eq(mixed $want, mixed $got): void
{
    if ($want !== $got) {
        throw new \Exception('expected ' . var_export($want, true) . ', got ' . var_export($got, true));
    }
}

function throws(string $class, callable $fn): \Throwable
{
    try {
        $fn();
    } catch (\Throwable $e) {
        if (!$e instanceof $class) {
            throw new \Exception("expected $class, got " . get_class($e) . ': ' . $e->getMessage());
        }
        return $e;
    }
    throw new \Exception("expected $class, nothing thrown");
}

/** @return array{method: string, uri: string, headers: array<string, string>, body: mixed} */
function last(): array
{
    return json_decode((string) file_get_contents(MOCK_LOG), true);
}

$lic = new LicenseClient($base . '/');
$api = new ApiClient('sc_test', $base);

test('activate', function () use ($lic) {
    $r = $lic->activate('GOOD', 'dev-1');
    eq('dev-1', $r->instanceId);
    eq(3, $r->license->maxActivations);
    eq('Pro', $r->product->name);
    $req = last();
    eq('POST', $req['method']);
    eq('/api/v1/licenses/activate', $req['uri']);
    eq(['license_key' => 'GOOD', 'instance_id' => 'dev-1'], $req['body']);
    eq('sendclap-php/0.5.0', $req['headers']['user-agent']);
    eq('application/json', $req['headers']['content-type']);
    eq(false, isset($req['headers']['authorization']));
});

test('activation limit', function () use ($lic) {
    $e = throws(ActivationLimitException::class, fn () => $lic->activate('FULL', 'dev-9'));
    eq([409, 'activation_limit'], [$e->status, $e->errorCode]);
    eq(3, $e->license->activations);
    eq(1, $e->product->id);
    eq('activation limit reached', $e->getMessage());
});

test('activate invalid key', function () use ($lic) {
    $e = throws(InvalidLicenseException::class, fn () => $lic->activate('BAD', 'dev-1'));
    eq([404, 'license_not_found'], [$e->status, $e->errorCode]);
    eq('license key not found', $e->getMessage());
});

test('activate disabled key', function () use ($lic) {
    $e = throws(DisabledLicenseException::class, fn () => $lic->activate('REFUNDED', 'dev-1'));
    eq(false, $e instanceof InvalidLicenseException);
    eq([403, 'license_disabled'], [$e->status, $e->errorCode]);
});

test('expired key', function () use ($lic) {
    $r = $lic->validate('LAPSED', 'dev-1');
    eq([false, 'expired', '2026-01-01T00:00:00.000Z', 1], [$r->valid, $r->status, $r->license->expiresAt, $r->product->id]);
    $e = throws(ExpiredLicenseException::class, fn () => $lic->activate('LAPSED', 'dev-1'));
    eq([403, 'license_expired', '2026-01-01T00:00:00.000Z'], [$e->status, $e->errorCode, $e->license->expiresAt]);
});

test('activate missing instance', function () use ($lic) {
    $e = throws(SendclapException::class, fn () => $lic->activate('GOOD', ''));
    eq([400, 'bad_request'], [$e->status, $e->errorCode]);
    eq('instance_id is required', $e->getMessage());
});

test('validate', function () use ($lic) {
    $r = $lic->validate('GOOD');
    eq([true, 'active'], [$r->valid, $r->status]);
    eq(['license_key' => 'GOOD'], last()['body']);
    eq('active', $lic->validate('GOOD', 'dev-1')->status);
    $r = $lic->validate('GOOD', 'other');
    eq([false, 'not_activated', 'GOOD'], [$r->valid, $r->status, $r->license->key]);
    $r = $lic->validate('BAD', 'dev-1');
    eq([false, 'not_found', null, null], [$r->valid, $r->status, $r->license, $r->product]);
    $r = $lic->validate('REFUNDED', 'dev-1');
    eq([false, 'disabled', null, null], [$r->valid, $r->status, $r->license, $r->product]);
});

test('deactivate', function () use ($lic) {
    eq(0, $lic->deactivate('GOOD', 'dev-1')->license->activations);
    throws(InvalidLicenseException::class, fn () => $lic->deactivate('BAD', 'dev-1'));
    $e = throws(InstanceNotFoundException::class, fn () => $lic->deactivate('GOOD', 'nope'));
    eq([404, 'instance_not_found'], [$e->status, $e->errorCode]);
});

test('html 404 is not an invalid license', function () use ($base) {
    $e = throws(SendclapException::class, fn () => (new LicenseClient($base . '/nope'))->validate('GOOD'));
    eq(SendclapException::class, get_class($e));
    eq([404, '', 'HTTP 404'], [$e->status, $e->errorCode, $e->getMessage()]);
});

test('network error', function () {
    $e = throws(NetworkException::class, fn () => (new LicenseClient('http://127.0.0.1:1', 2.0))->validate('GOOD'));
    eq([0, 'network_error'], [$e->status, $e->errorCode]);
});

test('invalid json', function () use ($base) {
    $e = throws(SendclapException::class, fn () => (new Http($base, 5.0))->request('GET', '/broken'));
    eq([200, 'invalid JSON response'], [$e->status, $e->getMessage()]);
});

test('checkouts', function () use ($api) {
    $c = $api->createCheckout(['type' => 'product', 'product_id' => 1, 'email' => 'buyer@example.com']);
    eq('http://x/checkout/0xabc', $c['url']);
    $req = last();
    eq(['type' => 'product', 'product_id' => 1, 'email' => 'buyer@example.com'], $req['body']);
    eq('Bearer sc_test', $req['headers']['authorization']);
    $g = $api->getCheckout('0xabc');
    eq(['pending', 'http://x/checkout/0xabc', null], [$g['status'], $g['url'], $g['paid_at']]);
    eq('2026-11-14T10:00:00.000Z', $api->getCheckout('0xpaid')['paid_at']);
});

test('payments page', function () use ($api) {
    $page = $api->listPayments(['status' => 'paid', 'limit' => 2]);
    eq('/api/v1/payments?status=paid&limit=2', last()['uri']);
    eq([[['id' => 3], ['id' => 2]], true, 2], [$page->data, $page->hasMore, $page->next]);
    $rest = $api->listPayments(['after' => $page->next]);
    eq([[['id' => 1]], false, null], [$rest->data, $rest->hasMore, $rest->next]);
    eq('Pro', $api->getPayment(42)['item']);
    $e = throws(SendclapException::class, fn () => $api->getPayment(7));
    eq([404, 'not_found', 'payment not found'], [$e->status, $e->errorCode, $e->getMessage()]);
});

test('all payments follows next', function () use ($api) {
    $ids = [];
    foreach ($api->allPayments(['status' => 'paid']) as $p) {
        $ids[] = $p['id'];
    }
    eq([3, 2, 1], $ids);
    eq('/api/v1/payments?after=2&status=paid', last()['uri']);
    eq(1, count(iterator_to_array($api->allMembers(), false)));
});

test('unauthorized', function () use ($base) {
    $e = throws(SendclapException::class, fn () => (new ApiClient('sc_wrong', $base))->me());
    eq([401, 'invalid_api_key', 'invalid API key'], [$e->status, $e->errorCode, $e->getMessage()]);
});

test('creator without key', function () use ($base) {
    $c = (new ApiClient(null, $base))->getCreator('demo');
    eq('Ada Builds', $c['name']);
    eq(['week', null], array_column($c['products'], 'interval'));
    eq(false, isset(last()['headers']['authorization']));
});

test('instance name', function () {
    eq(true, LicenseClient::instanceName() !== '');
});

@unlink(MOCK_LOG);
echo "\n$passed passed, $failed failed\n";
exit($failed > 0 ? 1 : 0);
