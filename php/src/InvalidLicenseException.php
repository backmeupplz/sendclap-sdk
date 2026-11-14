<?php

declare(strict_types=1);

namespace Sendclap;

/** The license key does not exist (license_not_found). */
final class InvalidLicenseException extends SendclapException
{
    public function __construct(int $status, string $message)
    {
        parent::__construct($status, $message, 'license_not_found');
    }
}
