<?php

declare(strict_types=1);

namespace Sendclap;

/** Any failed request. $status is the HTTP status, 0 when no response arrived. */
class SendclapException extends \RuntimeException
{
    public function __construct(public readonly int $status, string $message)
    {
        parent::__construct($message, $status);
    }
}
