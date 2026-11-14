<?php

declare(strict_types=1);

namespace Sendclap;

/** @internal Shared transport for LicenseClient and ApiClient. */
final class Http
{
    public const VERSION = '0.2.0';
    public const DEFAULT_BASE_URL = 'https://sendclap.com';

    private string $base;

    public function __construct(string $baseUrl, private float $timeout, private ?string $apiKey = null)
    {
        $this->base = rtrim($baseUrl, '/') . '/api/v1';
    }

    /** @param array<string, mixed>|null $body @param array<string, mixed> $query */
    public function request(string $method, string $path, ?array $body = null, array $query = []): mixed
    {
        $url = $this->base . $path;
        $qs = http_build_query(array_filter($query, fn ($v) => $v !== null), '', '&', PHP_QUERY_RFC3986);
        if ($qs !== '') {
            $url .= '?' . $qs;
        }
        $headers = ['Accept: application/json', 'User-Agent: sendclap-php/' . self::VERSION];
        if ($this->apiKey !== null && $this->apiKey !== '') {
            $headers[] = 'Authorization: Bearer ' . $this->apiKey;
        }
        $ch = curl_init($url);
        $ms = (int) ($this->timeout * 1000);
        $opts = [
            CURLOPT_CUSTOMREQUEST => $method,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT_MS => $ms,
            CURLOPT_CONNECTTIMEOUT_MS => $ms,
        ];
        if ($body !== null) {
            $headers[] = 'Content-Type: application/json';
            $opts[CURLOPT_POSTFIELDS] = json_encode(array_filter($body, fn ($v) => $v !== null), JSON_THROW_ON_ERROR);
        }
        $opts[CURLOPT_HTTPHEADER] = $headers;
        curl_setopt_array($ch, $opts);
        $text = curl_exec($ch);
        if (!is_string($text)) {
            throw new NetworkException(curl_error($ch) ?: 'request failed');
        }
        $status = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);

        try {
            $data = json_decode($text, true, 512, JSON_THROW_ON_ERROR);
        } catch (\JsonException) {
            if ($status >= 200 && $status < 300) {
                throw new SendclapException($status, 'invalid JSON response');
            }
            $data = null;
        }
        if ($status >= 200 && $status < 300) {
            return $data;
        }
        $d = is_array($data) ? $data : [];
        $message = isset($d['error']) && is_string($d['error']) ? $d['error'] : "HTTP $status";
        $code = isset($d['code']) && is_string($d['code']) ? $d['code'] : '';
        throw match ($code) {
            'license_not_found' => new InvalidLicenseException($status, $message),
            'license_disabled' => new DisabledLicenseException($status, $message),
            'instance_not_found' => new InstanceNotFoundException($status, $message),
            'activation_limit' => new ActivationLimitException($status, $message, LicenseInfo::from($d), ProductRef::from($d)),
            default => new SendclapException($status, $message, $code),
        };
    }
}
