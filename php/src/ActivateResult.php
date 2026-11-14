<?php

declare(strict_types=1);

namespace Sendclap;

final class ActivateResult
{
    public function __construct(public readonly string $instanceId, public readonly LicenseInfo $license, public readonly ProductRef $product)
    {
    }
}
