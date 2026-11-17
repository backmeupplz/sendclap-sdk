<?php

declare(strict_types=1);

namespace Sendclap;

/** The subscription license key has expired (license_expired); ->license->expiresAt says when. */
final class ExpiredLicenseException extends SendclapException
{
    public function __construct(int $status, string $message, public readonly LicenseInfo $license, public readonly ProductRef $product)
    {
        parent::__construct($status, $message, 'license_expired');
    }
}
