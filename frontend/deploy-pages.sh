#!/usr/bin/env bash
# Publish the frontend to GitHub Pages (static export, client-side only app).
set -euo pipefail
cd "$(dirname "$0")"
NEXT_PUBLIC_BASE_PATH=/hindsight-hook \
NEXT_PUBLIC_RPC_URL=https://sepolia.unichain.org \
NEXT_PUBLIC_HOOK=0xC4E83D74A486C056c6164655F1d2D5ae5408d0C4 \
NEXT_PUBLIC_TOKEN0=0x7401fd17a05Bf34CABAaDb233638E90375bb7d41 \
NEXT_PUBLIC_TOKEN1=0xEbb36dd92C105c88C8Eb8d9e1c6d611F0191f157 \
NEXT_PUBLIC_SWAP_ROUTER=0x5117b13AeB096e24FDf2F90a2012Df7D77DFF4da \
NEXT_PUBLIC_POOL_ID=0xd745e877a4fdbd31ba9989e11750a9a720af064e773a7b65fe68b6c48213ab03 \
npx next build
touch out/.nojekyll
cd out && git init -q -b gh-pages && git add -A \
  && git commit -q -m "Hindsight frontend — static export" \
  && git push -q --force https://github.com/OoJae/hindsight-hook.git gh-pages
cd .. && rm -rf out/.git
echo "live: https://oojae.github.io/hindsight-hook/"
