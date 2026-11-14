<?php

declare(strict_types=1);

namespace Sendclap;

/** The key exists but was disabled after a refund or dispute (license_disabled). */
final class DisabledLicenseException extends SendclapException
{
    public function __construct(int $status, string $message)
    {
        parent::__construct($status, $message, 'license_disabled');
    }
}
