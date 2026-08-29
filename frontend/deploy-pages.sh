#!/usr/bin/env bash
# Publish the frontend to GitHub Pages (static export, client-side only app).
set -euo pipefail
cd "$(dirname "$0")"
NEXT_PUBLIC_BASE_PATH=/hindsight-hook \
NEXT_PUBLIC_RPC_URL=https://sepolia.unichain.org \
NEXT_PUBLIC_HOOK=0x9b7835C368fc2E39f1225DaC36daA5c7560710c4 \
NEXT_PUBLIC_TOKEN0=0x43cfD0b48d741Bd6F947fBc86a42E0cDa625fE58 \
NEXT_PUBLIC_TOKEN1=0x8Fb42abC96DcF78C86585Cff4823937140f09bCB \
NEXT_PUBLIC_SWAP_ROUTER=0x13502fa74BB545E9d279215802Be88959f2D6e3d \
NEXT_PUBLIC_POOL_ID=0xb9ea48e9c48411175d620a0df86efba05623279b4f46850323f9f04b734bdfc8 \
npx next build
touch out/.nojekyll
cd out && git init -q -b gh-pages && git add -A \
  && git commit -q -m "Hindsight frontend — static export" \
  && git push -q --force https://github.com/OoJae/hindsight-hook.git gh-pages
cd .. && rm -rf out/.git
echo "live: https://oojae.github.io/hindsight-hook/"
