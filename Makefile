# =============================================================================
# MAKEFILE SONGRE — Commandes de build standardisées
# =============================================================================
#
# PROBLÈME RÉSOLU :
# Le MCP tool flutter_signing_tool réécrit android:label="Life Saver" dans
# AndroidManifest.xml à chaque appel, écrasant @string/app_name (→ "Songre").
#
# RÈGLE IMPÉRATIVE : Ne JAMAIS appeler flutter_signing_tool pour ce projet.
# Le signing release est déjà configuré dans android/app/build.gradle.kts
# via android/key.properties + android/release-key.jks.
#
# Ces commandes make incluent automatiquement pre_build_check.sh avant chaque
# build APK pour détecter et corriger toute régression de android:label.
# =============================================================================

.PHONY: apk web clean check

# Build APK release avec vérification pre-build obligatoire
apk:
	@echo "🚀 Build APK release SONGRE..."
	@cd $(shell pwd) && bash scripts/pre_build_check.sh
	flutter build apk --release \
		--dart-define=SONGRE_ENCRYPT_KEY=SongreProdBurkinaFaso2026_SecureKey! \
		--dart-define=WEBHOOK_SECRET=$$WEBHOOK_SECRET \
		--dart-define=flutter.inspector.structuredErrors=false \
		--dart-define=debugShowCheckedModeBanner=false
	@echo "✅ APK généré : build/app/outputs/flutter-apk/app-release.apk"
	@/home/user/android-sdk/build-tools/35.0.0/aapt dump badging \
		build/app/outputs/flutter-apk/app-release.apk | grep "^application-label:'"

# Build web release
web:
	flutter build web --release
	@echo "✅ Web généré : build/web/"

# Vérification pre-build seule (sans build)
check:
	@bash scripts/pre_build_check.sh

# Nettoyage Android uniquement (préserve build/web)
clean-android:
	rm -rf android/build android/app/build android/.gradle
	@echo "✅ Cache Android nettoyé"

# Nettoyage complet
clean:
	flutter clean
	@echo "✅ Nettoyage complet"
