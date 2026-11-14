<?php

declare(strict_types=1);

namespace Sendclap;

final class ValidateResult
{
    /** @param string $status "active", "not_activated" or "invalid" (license and product are null then) */
    public function __construct(
        public readonly bool $valid,
        public readonly string $status,
        public readonly ?LicenseInfo $license = null,
        public readonly ?ProductRef $product = null,
    ) {
    }
}
