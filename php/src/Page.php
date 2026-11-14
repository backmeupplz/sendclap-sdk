<?php

declare(strict_types=1);

namespace Sendclap;

/** One page of a list, newest first. When $hasMore is true, pass $next as `after` for the following page. */
final class Page
{
    /** @param list<array<string, mixed>> $data */
    public function __construct(public readonly array $data, public readonly bool $hasMore, public readonly ?int $next)
    {
    }

    /** @param array<string, mixed> $d a list response body */
    public static function from(array $d): self
    {
        return new self($d['data'], (bool) $d['has_more'], isset($d['next']) ? (int) $d['next'] : null);
    }
}
