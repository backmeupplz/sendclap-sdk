<?php

declare(strict_types=1);

namespace Sendclap;

/** The key is already activated on its maximum number of instances. */
final class ActivationLimitException extends SendclapException
{
    public function __construct(int $status, string $message, public readonly LicenseInfo $license, public readonly ProductRef $product)
    {
        parent::__construct($status, $message);
    }
}
