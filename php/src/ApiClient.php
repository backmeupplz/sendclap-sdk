<?php

declare(strict_types=1);

namespace Sendclap;

/**
 * Creator REST API. Server side only: never ship the sc_ key inside an app.
 * Every method returns the API's JSON decoded into associative arrays (snake_case keys).
 */
final class ApiClient
{
    private Http $http;

    /** $apiKey may be null for getCreator(), which is public. */
    public function __construct(?string $apiKey = null, string $baseUrl = Http::DEFAULT_BASE_URL, float $timeout = 15.0)
    {
        $this->http = new Http($baseUrl, $timeout, $apiKey);
    }

    /** @param array{type: string, amount?: float|int, product_id?: int, tier_id?: int, email?: string, method?: string, message?: string} $params */
    public function createCheckout(array $params): array
    {
        return $this->http->request('POST', '/checkouts', $params);
    }

    public function getCheckout(string $id): array
    {
        return $this->http->request('GET', '/checkouts/' . rawurlencode($id));
    }

    public function me(): array
    {
        return $this->http->request('GET', '/me');
    }

    /** @param array{status?: string, type?: string, email?: string, limit?: int} $filter */
    public function listPayments(array $filter = []): array
    {
        return $this->http->request('GET', '/payments', null, $filter);
    }

    public function getPayment(int $id): array
    {
        return $this->http->request('GET', "/payments/$id");
    }

    public function listMembers(): array
    {
        return $this->http->request('GET', '/members');
    }

    public function listLicenses(?string $email = null): array
    {
        return $this->http->request('GET', '/licenses', null, ['email' => $email]);
    }

    public function listDisputes(): array
    {
        return $this->http->request('GET', '/disputes');
    }

    public function listProducts(): array
    {
        return $this->http->request('GET', '/products');
    }

    public function listMemberships(): array
    {
        return $this->http->request('GET', '/memberships');
    }

    /** Public: works without an API key. */
    public function getCreator(string $handle): array
    {
        return $this->http->request('GET', '/creators/' . rawurlencode($handle));
    }
}
