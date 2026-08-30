#!/usr/bin/env bash
# Publish the frontend to GitHub Pages (static export, client-side only app).
set -euo pipefail
cd "$(dirname "$0")"
NEXT_PUBLIC_BASE_PATH=/hindsight-hook \
NEXT_PUBLIC_RPC_URL=https://sepolia.unichain.org \
NEXT_PUBLIC_HOOK=0xcEC97e16765395c6F1Af849625b21b4a532110c4 \
NEXT_PUBLIC_TOKEN0=0xbe082B9aC7b052B0fdbF4Ee0e0b097F292bfAB19 \
NEXT_PUBLIC_TOKEN1=0xfaEf98c9630cB42aEFb1C3a362AC217086C9da3B \
NEXT_PUBLIC_SWAP_ROUTER=0x112433567508c6640349D5C8Faf1151D71f88926 \
NEXT_PUBLIC_POOL_ID=0x6b7762dbf8e30d6a5cc94d7d38e14ef90469e0b0d2ae90d362e5fd6d1beba0bb \
npx next build
touch out/.nojekyll
cd out && git init -q -b gh-pages && git add -A \
  && git commit -q -m "Hindsight frontend — static export" \
  && git push -q --force https://github.com/OoJae/hindsight-hook.git gh-pages
cd .. && rm -rf out/.git
echo "live: https://oojae.github.io/hindsight-hook/"
