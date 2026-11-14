<?php

declare(strict_types=1);

namespace Sendclap;

/** The product a license belongs to; both fields are null if the product was deleted. */
final class ProductRef
{
    public function __construct(public readonly ?int $id = null, public readonly ?string $name = null)
    {
    }

    /** @param array<string, mixed> $d a license response body */
    public static function from(array $d): self
    {
        $p = is_array($d['product'] ?? null) ? $d['product'] : [];
        return new self(isset($p['id']) ? (int) $p['id'] : null, isset($p['name']) ? (string) $p['name'] : null);
    }
}
