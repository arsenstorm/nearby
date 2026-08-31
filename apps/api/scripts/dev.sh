#!/usr/bin/env bash
# Run the worker locally, serving the apps/web static site.
set -euo pipefail
cd "$(dirname "$0")/.."
exec npx wrangler dev
