#!/bin/bash
# VillageLink — démarrage d'une session Claude Code sur le cloud.
# 1. Met la copie de travail à jour depuis origin/main, sans jamais écraser du travail non fusionné.
# 2. Prépare Playwright pour lancer « node tests/verification.cjs ».
set -uo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" || exit 0

# --- 1. Copie de travail à jour ------------------------------------------------
if git fetch --quiet origin main 2>/dev/null; then
  branch=$(git rev-parse --abbrev-ref HEAD)
  ahead=$(git rev-list --count origin/main..HEAD)
  behind=$(git rev-list --count HEAD..origin/main)
  if [ "$behind" = "0" ]; then
    echo "VillageLink : la branche « $branch » est à jour avec main."
  elif [ "$ahead" = "0" ] && [ -z "$(git status --porcelain)" ]; then
    git merge --quiet --ff-only origin/main
    echo "VillageLink : la branche « $branch » a été mise à jour avec les $behind dernier(s) changement(s) de main."
  else
    echo "ATTENTION VillageLink : la branche « $branch » a $ahead changement(s) pas encore dans main, et main a $behind changement(s) absent(s) d'ici."
    echo "Ne rien construire avant d'avoir regardé : git log --oneline HEAD..origin/main (fusionner main si besoin)."
  fi
else
  echo "VillageLink : impossible de joindre GitHub, la copie de travail n'a pas été vérifiée."
fi

# --- 2. Outil du test automatique (Playwright) ----------------------------------
PW_DIR="$HOME/.cache/villagelink-pw"
if [ ! -d "$PW_DIR/node_modules/playwright" ]; then
  npm install --silent --no-save --no-package-lock --no-audit --no-fund --prefix "$PW_DIR" playwright@1.56.0 >/dev/null 2>&1 \
    || echo "VillageLink : installation de Playwright impossible, le test automatique ne pourra pas ouvrir les pages."
fi

chrome=$(ls -d /opt/pw-browsers/chromium-*/chrome-linux*/chrome 2>/dev/null | sort -V | tail -1)
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export NODE_PATH=\"$PW_DIR/node_modules\"" >> "$CLAUDE_ENV_FILE"
  [ -n "$chrome" ] && echo "export CHROME_PATH=\"$chrome\"" >> "$CLAUDE_ENV_FILE"
fi
echo "VillageLink : test automatique prêt (node tests/verification.cjs)."
exit 0
