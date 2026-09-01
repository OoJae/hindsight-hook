#!/usr/bin/env bash
# Publish the frontend to GitHub Pages (static export, client-side only app).
set -euo pipefail
cd "$(dirname "$0")"
NEXT_PUBLIC_BASE_PATH=/hindsight-hook \
NEXT_PUBLIC_RPC_URL=https://sepolia.unichain.org \
NEXT_PUBLIC_HOOK=0xDecF9FA10d1dE837D96Fca76fE31302D82641aC4 \
NEXT_PUBLIC_HOOK_BLOCK=61282455 \
NEXT_PUBLIC_TOKEN0=0x7A18330B94Cdc15cf2426A4C61d2948B5C78562d \
NEXT_PUBLIC_TOKEN1=0xDa18a4C19601E698Af9e74d0b84d945871f096ea \
NEXT_PUBLIC_SWAP_ROUTER=0x4C12f1300b5277FEb15Ba77F8d7e9D8781bD11d0 \
NEXT_PUBLIC_POOL_ID=0x00d329ee1d22b569f6912ff6d01795d6c7f221dcff386b89f12ba1be18f3ce5a \
npx next build
touch out/.nojekyll
cd out && git init -q -b gh-pages && git add -A \
  && git commit -q -m "Hindsight frontend — static export" \
  && git push -q --force https://github.com/OoJae/hindsight-hook.git gh-pages
cd .. && rm -rf out/.git
echo "live: https://oojae.github.io/hindsight-hook/"
