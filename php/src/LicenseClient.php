<?php

declare(strict_types=1);

namespace Sendclap;

/** Keyless license checks, safe to call from the app you ship. */
final class LicenseClient
{
    private Http $http;

    public function __construct(string $baseUrl = Http::DEFAULT_BASE_URL, float $timeout = 15.0)
    {
        $this->http = new Http($baseUrl, $timeout);
    }

    /**
     * This machine's hostname, a stable default instance name. It is sent to Sendclap and shown to the creator,
     * and two machines with the same hostname share one activation; pass your own saved id if that matters.
     */
    public static function instanceName(): string
    {
        return (string) gethostname();
    }

    public function activate(string $licenseKey, string $instanceName): ActivateResult
    {
        $d = $this->post('activate', $licenseKey, $instanceName);
        return new ActivateResult((string) $d['instance_id'], LicenseInfo::from($d), ProductRef::from($d));
    }

    /** Never throws for a bad key (status "invalid"); throws NetworkException when Sendclap can't be reached. */
    public function validate(string $licenseKey, ?string $instanceId = null): ValidateResult
    {
        try {
            $d = $this->post('validate', $licenseKey, $instanceId);
        } catch (InvalidLicenseException) {
            return new ValidateResult(false, 'invalid');
        }
        $valid = ($d['valid'] ?? null) === true;
        return new ValidateResult($valid, $valid ? 'active' : 'not_activated', LicenseInfo::from($d), ProductRef::from($d));
    }

    public function deactivate(string $licenseKey, string $instanceId): DeactivateResult
    {
        $d = $this->post('deactivate', $licenseKey, $instanceId);
        return new DeactivateResult(LicenseInfo::from($d), ProductRef::from($d));
    }

    /** @return array<string, mixed> */
    private function post(string $action, string $licenseKey, ?string $instanceId): array
    {
        return $this->http->request('POST', "/licenses/$action", ['license_key' => $licenseKey, 'instance_id' => $instanceId]);
    }
}
