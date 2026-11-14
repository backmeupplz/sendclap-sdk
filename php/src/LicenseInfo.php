<?php

declare(strict_types=1);

namespace Sendclap;

final class LicenseInfo
{
    public function __construct(public readonly string $key, public readonly int $activations, public readonly int $maxActivations)
    {
    }

    /** @param array<string, mixed> $d a license response body */
    public static function from(array $d): self
    {
        $l = is_array($d['license'] ?? null) ? $d['license'] : [];
        return new self((string) ($l['key'] ?? ''), (int) ($l['activations'] ?? 0), (int) ($l['max_activations'] ?? 0));
    }
}
