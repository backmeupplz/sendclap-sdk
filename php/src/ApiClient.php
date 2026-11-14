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
    public function createCheckout(array $params): array // id, status, type, amount, currency, method, email, url, paid_at (ISO 8601 or null)
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

    // Lists are pages, newest first. `limit` defaults to 50, at most 500, and `after` is the previous page's `next`.
    // The all*() generators follow `next`: foreach ($api->allPayments(['status' => 'paid']) as $payment).

    /** @param array{status?: string, type?: string, email?: string, limit?: int, after?: int} $filter */
    public function listPayments(array $filter = []): Page
    {
        return Page::from($this->http->request('GET', '/payments', null, $filter));
    }

    /** @param array{status?: string, type?: string, email?: string, limit?: int} $filter */
    public function allPayments(array $filter = []): \Generator
    {
        return $this->paginate(fn (?int $after) => $this->listPayments(['after' => $after] + $filter));
    }

    public function getPayment(int $id): array
    {
        return $this->http->request('GET', "/payments/$id");
    }

    /** @param array{limit?: int, after?: int} $page */
    public function listMembers(array $page = []): Page
    {
        return Page::from($this->http->request('GET', '/members', null, $page));
    }

    /** @param array{limit?: int} $page */
    public function allMembers(array $page = []): \Generator
    {
        return $this->paginate(fn (?int $after) => $this->listMembers(['after' => $after] + $page));
    }

    /** @param array{email?: string, limit?: int, after?: int} $filter */
    public function listLicenses(array $filter = []): Page
    {
        return Page::from($this->http->request('GET', '/licenses', null, $filter));
    }

    /** @param array{email?: string, limit?: int} $filter */
    public function allLicenses(array $filter = []): \Generator
    {
        return $this->paginate(fn (?int $after) => $this->listLicenses(['after' => $after] + $filter));
    }

    /** @param array{limit?: int, after?: int} $page */
    public function listDisputes(array $page = []): Page
    {
        return Page::from($this->http->request('GET', '/disputes', null, $page));
    }

    /** @param array{limit?: int} $page */
    public function allDisputes(array $page = []): \Generator
    {
        return $this->paginate(fn (?int $after) => $this->listDisputes(['after' => $after] + $page));
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

    /** @param callable(?int): Page $fetch */
    private function paginate(callable $fetch): \Generator
    {
        $after = null;
        do {
            $page = $fetch($after);
            yield from $page->data;
            $after = $page->next;
        } while ($page->hasMore && $after !== null);
    }
}
