# CHANGELOG — SONGRE / LifeSaver

---

## [Fix-POIDS-NULL + Fix-FCM-UPSERT] — 2026-07-22

### Résumé

Double correction suite à audit triple (code Flutter + logs Supabase) :
- **Bug 1 (bloquant)** : `poids_chiffre = null` dans chaque INSERT `profils_donneurs` → erreur Postgres 23502 systématique → boucle infinie `/completer-profil`
- **Bug 2 (secondaire)** : `ON CONFLICT` ciblait la PK (`id`) au lieu de `fcm_token` → 409 à chaque réinsertion de token FCM

---

### Bug 1 — Cause racine exacte

**Code fautif** (`lib/models/models.dart`, `toJsonPourBase()`) :
```dart
// AVANT — ligne 308 :
final poidsChiffre = CryptoService.chiffrer(poids.toString());
// ...
'poids_chiffre': poidsChiffre,  // ← null si SONGRE_ENCRYPT_KEY absente !
```

**Chaîne causale complète** :
1. `SONGRE_ENCRYPT_KEY` absente au build → `CryptoService._key = null` (L48-58 `crypto_service.dart`)
2. `CryptoService.chiffrer(poids.toString())` → `_key == null` → retourne `null` (L68)
3. `toJsonPourBase()` → `'poids_chiffre': null` dans le body JSON
4. PostgREST → `INSERT INTO public.profils_donneurs ... poids_chiffre = NULL`
5. Postgres → erreur 23502 : `null value in column "poids_chiffre" violates not-null constraint`
6. `creerOuMettreAJourProfil()` → `false` → `sauvegarderProfil()` → `false`
7. Profil en cache local uniquement → GoRouter OK pour cette session
8. À la déconnexion/reconnexion : cache purgé, `lireProfil()` → liste vide → `null`
9. GoRouter → `isAuth=true, hasProfil=false` → redirect `/completer-profil` → **BOUCLE INFINIE**

**Pourquoi ce bug n'était pas apparu avant** :
La "dégradation gracieuse" de `CryptoService` (ajoutée pour résoudre un crash au démarrage, commit précédent) était conçue pour les champs **nullables** (`telephone_chiffre`). Elle a été appliquée indistinctement à `poids_chiffre` qui est `NOT NULL` en base. Dans les anciens builds où `SONGRE_ENCRYPT_KEY` était correctement injectée, le bug était latent et dormant. Il s'est manifesté lors d'un build sans la variable d'environnement définie (incident de sandbox/CI).

---

### Bug 2 — Cause racine exacte

**Code fautif** (`lib/services/supabase_service.dart`, `enregistrerFcmToken()`) :
```dart
// AVANT — URL sans on_conflict :
final url = Uri.parse('$_supabaseUrl/rest/v1/device_tokens');
final hdrs = {
  'Prefer': 'return=minimal,resolution=merge-duplicates',  // ON CONFLICT sur PK(id) !
};
```

`resolution=merge-duplicates` sans `on_conflict=<colonne>` → PostgREST génère `ON CONFLICT (id)` (PK par défaut). Mais la contrainte violée est `device_tokens_fcm_token_key` (UNIQUE sur `fcm_token`). Ces deux colonnes ne matchent jamais → Postgres lève 23505 → HTTP 409.

---

### Fichiers modifiés

| Fichier | Nature du changement |
|---------|---------------------|
| `lib/models/models.dart` | `toJsonPourBase()` : guard `StateError` si `poidsChiffre == null`, avec message explicatif |
| `lib/services/supabase_service.dart` | `creerOuMettreAJourProfil()` : try/catch séparé autour de `toJsonPourBase()` (hors du try réseau) ; `enregistrerFcmToken()` : URL avec `?on_conflict=fcm_token` |
| `lib/services/app_state.dart` | `init()` : avertissement au démarrage si `SONGRE_ENCRYPT_KEY` absente |
| `lib/screens/login_screen.dart` | SnackBar erreur différencie config incorrecte (rouge) vs réseau (orange) |
| `Makefile` | Guard `SONGRE_ENCRYPT_KEY` obligatoire avant `flutter build apk` |

---

### Procédure de build correcte

```bash
# 1. Récupérer la clé depuis SECRETS_PROJET_A_SAUVEGARDER.md (dépôt privé)
export SONGRE_ENCRYPT_KEY="<valeur_32+_chars>"
export WEBHOOK_SECRET="<webhook_secret>"

# 2. Build APK (le Makefile vérifie maintenant la présence de la clé)
cd /home/user/flutter_app
make apk
# → Erreur immédiate si SONGRE_ENCRYPT_KEY vide ou < 32 chars
```

---

### Action manuelle obligatoire (Supabase Dashboard)

Le script `supabase-fix-profils-donneurs-rls.sql` (session précédente) doit avoir été exécuté pour que l'INSERT réussisse côté base (politiques RLS SELECT + INSERT + UPDATE sur `public.profils_donneurs`).

Pour vérifier l'utilisateur affecté :
```sql
SELECT id, email FROM auth.users WHERE email = 'poodasamuelpro@gmail.com';
SELECT * FROM public.profils_donneurs WHERE user_id = '<uuid_trouvé>';
```

---

### Tests de non-régression exécutés

- 3× création profil sans `SONGRE_ENCRYPT_KEY` → `StateError` catchée proprement → `false` retourné → SnackBar rouge "Erreur de configuration"
- 3× création profil avec `SONGRE_ENCRYPT_KEY` → `poids_chiffre` chiffré → `true` retourné → navigation `/home`
- Validator poids : 49 rejeté, 50-150 acceptés, 151 rejeté
- `flutter analyze` → 0 issues
