#!/bin/sh
# One-time registry setup, run by a human with their own logins. After this, every release publishes by itself through
# trusted publishing (.github/workflows/release.yml), with no tokens stored anywhere.
#
#   npm        `npm login` first (your account and 2FA); this trusts the GitHub workflow for the `sendclap` package,
#              which also reserves the name
#   crates.io  crates.io only trusts a workflow for a crate that already exists, so 0.2.0 is published once from here
#              with the crates.io key from Vaultwarden; then add the trusted publisher on the crate's settings page
set -eu
cd "$(dirname "$0")/.."

echo "== npm: trust backmeupplz/sendclap-sdk .github/workflows/release.yml for 'sendclap'"
npm whoami >/dev/null 2>&1 || { echo "run 'npm login' first" >&2; exit 1; }
npm trust github sendclap --repo backmeupplz/sendclap-sdk --file release.yml --allow-publish --yes
npm trust list sendclap

echo "== crates.io: first publish of sendclap $(scripts/version.sh)"
(cd rust && node ~/.openclaw/bin/openclaw-vaultwarden-exec.mjs --item 'Crates.io API key' --field password \
  --env CARGO_REGISTRY_TOKEN -- cargo publish --locked)
echo "Now open https://crates.io/crates/sendclap/settings and add a GitHub trusted publisher:"
echo "  owner backmeupplz, repository sendclap-sdk, workflow release.yml, environment empty"
