<?php

declare(strict_types=1);

namespace Sendclap;

/** No HTTP response: DNS, refused connection, TLS or timeout. */
final class NetworkException extends SendclapException
{
    public function __construct(string $message)
    {
        parent::__construct(0, $message, 'network_error');
    }
}
