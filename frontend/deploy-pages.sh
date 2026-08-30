#!/usr/bin/env bash
# Publish the frontend to GitHub Pages (static export, client-side only app).
set -euo pipefail
cd "$(dirname "$0")"
NEXT_PUBLIC_BASE_PATH=/hindsight-hook \
NEXT_PUBLIC_RPC_URL=https://sepolia.unichain.org \
NEXT_PUBLIC_HOOK=0x4475d1A77cb15f7867A37877B3f59E9a847990C4 \
NEXT_PUBLIC_TOKEN0=0x1FD46d8F28EA465b228Df9Ef0A8A00cB7f9A3906 \
NEXT_PUBLIC_TOKEN1=0x7EFC03C77728919a56e2843817B824A8556aC744 \
NEXT_PUBLIC_SWAP_ROUTER=0x39c026aC59e106B353b27b809E8bC7c698d57F9B \
NEXT_PUBLIC_POOL_ID=0x022afa83b95fc7423696bcc99597b6f1b321ecec06b610bfa8e9e50237deabba \
npx next build
touch out/.nojekyll
cd out && git init -q -b gh-pages && git add -A \
  && git commit -q -m "Hindsight frontend — static export" \
  && git push -q --force https://github.com/OoJae/hindsight-hook.git gh-pages
cd .. && rm -rf out/.git
echo "live: https://oojae.github.io/hindsight-hook/"
