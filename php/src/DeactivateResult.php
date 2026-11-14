<?php

declare(strict_types=1);

namespace Sendclap;

final class DeactivateResult
{
    public function __construct(public readonly LicenseInfo $license, public readonly ProductRef $product)
    {
    }
}
