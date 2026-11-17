<?php

declare(strict_types=1);

namespace Sendclap;

final class ValidateResult
{
    /** @param string $status "active", "not_activated", "expired" (subscription over), "disabled" (refunded or disputed) or "not_found" (unknown key); license and product are null for the last two */
    public function __construct(
        public readonly bool $valid,
        public readonly string $status,
        public readonly ?LicenseInfo $license = null,
        public readonly ?ProductRef $product = null,
    ) {
    }
}
