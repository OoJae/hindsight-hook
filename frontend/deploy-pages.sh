#!/usr/bin/env bash
# Publish the frontend to GitHub Pages (static export, client-side only app).
set -euo pipefail
cd "$(dirname "$0")"
NEXT_PUBLIC_BASE_PATH=/hindsight-hook \
NEXT_PUBLIC_RPC_URL=https://sepolia.unichain.org \
NEXT_PUBLIC_HOOK=0xeb77d98A9dfB72Fb17d196a3ec08F985bF0510c4 \
NEXT_PUBLIC_TOKEN0=0x011ca1BBc0Eae03AA9Ef4Fbf4e64923dAD3FB588 \
NEXT_PUBLIC_TOKEN1=0xd2b9c04a30E83ECf55FB5F4485F9910e74a9f082 \
NEXT_PUBLIC_SWAP_ROUTER=0x2B1CcA9D8AAf82Ec4cF8E3A23cA5Ca323741E8eD \
NEXT_PUBLIC_POOL_ID=0xcb25338a48454517a0bab70a8f1929ab043294f3aa57f34ff1f6dd9950194015 \
npx next build
touch out/.nojekyll
cd out && git init -q -b gh-pages && git add -A \
  && git commit -q -m "Hindsight frontend — static export" \
  && git push -q --force https://github.com/OoJae/hindsight-hook.git gh-pages
cd .. && rm -rf out/.git
echo "live: https://oojae.github.io/hindsight-hook/"
