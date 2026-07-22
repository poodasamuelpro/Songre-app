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
	@# [Fix-POIDS-NULL] Guard explicite : SONGRE_ENCRYPT_KEY DOIT être définie.
	@# Sans cette clé, poids_chiffre sera null en base → erreur Postgres 23502 systématique.
	@# Exporter la variable avant d'appeler make : export SONGRE_ENCRYPT_KEY="<clé>" && make apk
	@if [ -z "$$SONGRE_ENCRYPT_KEY" ]; then \
		echo ""; \
		echo "❌ ERREUR CRITIQUE : SONGRE_ENCRYPT_KEY n'est pas définie !"; \
		echo ""; \
		echo "   Sans cette clé, poids_chiffre sera null dans chaque INSERT profil_donneurs"; \
		echo "   → Postgres rejette avec 23502 (not-null constraint) → boucle /completer-profil."; \
		echo ""; \
		echo "   SOLUTION : Exporter la clé avant le build :"; \
		echo "     export SONGRE_ENCRYPT_KEY=\"<valeur_32+_chars_depuis_SECRETS_PROJET>\""; \
		echo "     make apk"; \
		echo ""; \
		exit 1; \
	fi
	@if [ $${#SONGRE_ENCRYPT_KEY} -lt 32 ]; then \
		echo "❌ ERREUR : SONGRE_ENCRYPT_KEY trop courte ($${#SONGRE_ENCRYPT_KEY} chars, minimum 32)."; \
		exit 1; \
	fi
	@echo "✅ SONGRE_ENCRYPT_KEY présente ($${#SONGRE_ENCRYPT_KEY} chars)"
	@cd $(shell pwd) && bash scripts/pre_build_check.sh
	flutter build apk --release \
		--dart-define=SONGRE_ENCRYPT_KEY=$$SONGRE_ENCRYPT_KEY \
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
