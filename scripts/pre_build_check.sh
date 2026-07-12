#!/usr/bin/env bash
# =============================================================================
# PRE-BUILD CHECK SONGRE — Vérification et correction automatique du nom d'app
# =============================================================================
#
# CONTEXTE :
# Le MCP tool flutter_signing_tool utilisé par l'agent de build réécrit
# android:label avec une valeur hardcodée ("Life Saver") extraite du session
# state de l'agent, ÉCRASANT la valeur correcte "@string/app_name" dans
# AndroidManifest.xml à CHAQUE appel.
#
# Ce script doit être exécuté AVANT chaque flutter build apk pour garantir
# que android:label pointe vers @string/app_name (→ strings.xml → "Songre").
#
# UTILISATION :
#   bash scripts/pre_build_check.sh
#   # ou intégré dans la commande de build :
#   bash scripts/pre_build_check.sh && flutter build apk --release [options]
#
# =============================================================================

set -e

MANIFEST="android/app/src/main/AndroidManifest.xml"
STRINGS="android/app/src/main/res/values/strings.xml"
EXPECTED_LABEL='@string/app_name'

echo "🔍 [pre-build] Vérification android:label dans $MANIFEST..."

# Vérifier que le manifest existe
if [ ! -f "$MANIFEST" ]; then
  echo "❌ [pre-build] AndroidManifest.xml introuvable : $MANIFEST"
  exit 1
fi

# Lire la valeur actuelle de android:label
CURRENT_LABEL=$(grep -o 'android:label="[^"]*"' "$MANIFEST" | head -1 | sed 's/android:label="//;s/"//')

if [ "$CURRENT_LABEL" = "$EXPECTED_LABEL" ]; then
  echo "✅ [pre-build] android:label correct : \"$CURRENT_LABEL\""
else
  echo "⚠️  [pre-build] RÉGRESSION DÉTECTÉE : android:label=\"$CURRENT_LABEL\" (attendu: \"$EXPECTED_LABEL\")"
  echo "🔧 [pre-build] Correction automatique en cours..."

  # Remplacer la valeur incorrecte par @string/app_name
  sed -i "s|android:label=\"[^\"]*\"|android:label=\"$EXPECTED_LABEL\"|g" "$MANIFEST"

  # Vérifier la correction
  NEW_LABEL=$(grep -o 'android:label="[^"]*"' "$MANIFEST" | head -1 | sed 's/android:label="//;s/"//')
  if [ "$NEW_LABEL" = "$EXPECTED_LABEL" ]; then
    echo "✅ [pre-build] android:label corrigé : \"$NEW_LABEL\""
  else
    echo "❌ [pre-build] Échec de la correction. Valeur actuelle : \"$NEW_LABEL\""
    exit 1
  fi
fi

# Vérifier que strings.xml contient bien "Songre"
if [ -f "$STRINGS" ]; then
  APP_NAME=$(grep -o '<string name="app_name">[^<]*</string>' "$STRINGS" | sed 's/<[^>]*>//g')
  echo "✅ [pre-build] app_name dans strings.xml : \"$APP_NAME\""
  if [ "$APP_NAME" != "Songre" ]; then
    echo "⚠️  [pre-build] app_name incorrect dans strings.xml : \"$APP_NAME\" (attendu: \"Songre\")"
    sed -i 's|<string name="app_name">[^<]*</string>|<string name="app_name">Songre</string>|g' "$STRINGS"
    echo "✅ [pre-build] strings.xml corrigé → Songre"
  fi
else
  echo "⚠️  [pre-build] strings.xml introuvable — création..."
  mkdir -p "$(dirname "$STRINGS")"
  cat > "$STRINGS" << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">Songre</string>
</resources>
EOF
  echo "✅ [pre-build] strings.xml créé avec app_name=Songre"
fi

echo "✅ [pre-build] Toutes les vérifications passées. Build autorisé."
