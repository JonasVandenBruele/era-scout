#!/bin/bash
# Installeert (of vernieuwt) de achtergrondtaak die de controles voor Aanbellen uitvoert (elke 15 minuten).
# Zonder importwachtwoord in de sleutelhanger doet de taak niets.
set -euo pipefail
cd "$(dirname "$0")/.."
DOEL="$HOME/Library/LaunchAgents/be.eraleustoye.era-scout-controle.plist"
cp mac/be.eraleustoye.era-scout-controle.plist "$DOEL"
launchctl bootout "gui/$(id -u)/be.eraleustoye.era-scout-controle" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DOEL"
echo "Achtergrondtaak actief. Logboek: ~/Library/Logs/era-scout-worker.log"
