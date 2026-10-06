#!/bin/bash
# Eenmalig: maakt een willekeurig wachtwoord voor de importgebruiker van ERA Scout (rol scout_import) en bewaart
# het in je macOS-sleutelhanger ("ERA Scout import (Supabase)") en als GitHub-geheim SCOUT_IMPORT_PASSWORD.
# De publicatieworkflow zet daarmee de login van de rol aan. Het wachtwoord wordt nergens getoond.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
cd "$(dirname "$0")/.."
LABEL="ERA Scout import (Supabase)"
if security find-generic-password -s "$LABEL" >/dev/null 2>&1; then
  echo "Er staat al een wachtwoord in je sleutelhanger. Niets gewijzigd."; exit 0
fi
PW=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
printf 'add-generic-password -U -a scout_import -s "%s" -l "%s" -w "%s"\n' "$LABEL" "$LABEL" "$PW" | security -i >/dev/null
printf '%s' "$PW" | gh secret set SCOUT_IMPORT_PASSWORD -R JonasVandenBruele/era-scout >/dev/null
unset PW
gh workflow run publiceer.yml -R JonasVandenBruele/era-scout >/dev/null && echo "Workflow gestart: de importgebruiker wordt nu geactiveerd."
echo "Klaar: wachtwoord in je sleutelhanger en in GitHub. Je mag dit venster sluiten."
