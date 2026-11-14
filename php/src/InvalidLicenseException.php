<?php

declare(strict_types=1);

namespace Sendclap;

/** The key does not exist, or was disabled after a refund or dispute (the server can't tell them apart). */
final class InvalidLicenseException extends SendclapException
{
}
