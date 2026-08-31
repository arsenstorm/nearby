#!/usr/bin/env bash
# Deploy the worker (and the apps/web static site it serves) to Cloudflare.
set -euo pipefail
cd "$(dirname "$0")/.."
exec npx wrangler deploy
