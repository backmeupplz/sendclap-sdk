<?php

declare(strict_types=1);

namespace Sendclap;

/** Deactivate was called for an instance that isn't activated (instance_not_found). */
final class InstanceNotFoundException extends SendclapException
{
    public function __construct(int $status, string $message)
    {
        parent::__construct($status, $message, 'instance_not_found');
    }
}
