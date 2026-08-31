#!/usr/bin/env bash
# Preview the site locally. The api worker serves these pages as its assets.
set -euo pipefail
cd "$(dirname "$0")/../../api"
exec npx wrangler dev
