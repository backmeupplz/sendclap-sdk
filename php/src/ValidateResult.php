<?php

declare(strict_types=1);

namespace Sendclap;

final class ValidateResult
{
    /** @param string $status "active", "not_activated", "invalid" (unknown key) or "disabled" (refunded or disputed); license and product are null for the last two */
    public function __construct(
        public readonly bool $valid,
        public readonly string $status,
        public readonly ?LicenseInfo $license = null,
        public readonly ?ProductRef $product = null,
    ) {
    }
}
