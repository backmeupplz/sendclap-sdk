<?php

declare(strict_types=1);

namespace Sendclap;

/**
 * Any failed request. $status is the HTTP status (0 when no response arrived) and $errorCode the server's
 * machine-readable code such as "invalid_api_key" or "not_found" ('' when the reply wasn't a Sendclap
 * error, "network_error" with no reply). It isn't called $code because PHP's Exception already owns that name.
 */
class SendclapException extends \RuntimeException
{
    public function __construct(public readonly int $status, string $message, public readonly string $errorCode = '')
    {
        parent::__construct($message, $status);
    }
}
