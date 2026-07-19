# GUIDE DE MISE À JOUR — Version Web BFF Sécurisée SONGRE

> **Référence de style** : même niveau de détail que `GUIDE_CARTE_STRUCTURES.md`  
> **Version** : 1.0 — Session 8  
> **Audience** : développeur SONGRE, familier avec Flutter mais pas nécessairement avec Cloudflare Workers ou Vercel

---

## Table des matières

1. [Architecture de la version Web sécurisée](#1-architecture)
2. [Ce qui se passe à chaque build mobile](#2-build-mobile)
3. [Mettre à jour la version Web Flutter après un changement](#3-update-web-flutter)
4. [Mettre à jour le BFF Cloudflare](#4-update-bff-cloudflare)
5. [Mettre à jour le BFF Vercel](#5-update-bff-vercel)
6. [Tableau de décision — Que redéployer selon le type de modification](#6-tableau-decision)
7. [Explication de chaque service et fichier de configuration](#7-services-expliqués)
8. [Explication de chaque mesure de sécurité et comment la tester](#8-sécurité-expliquée)

---

## 1. Architecture {#1-architecture}

### Vue d'ensemble

```
┌─────────────────────────────────────────────────────────────────┐
│  UTILISATEUR                                                    │
│                                                                 │
│  📱 App Android/iOS         🌐 Navigateur (Web)                │
│  └─ Supabase directement    └─ Flutter Web (songre.bf)          │
│     (tokens Keystore/        └─ BFF (bff.songre.bf)             │
│      Keychain)                  └─ Supabase (tokens cachés)    │
└─────────────────────────────────────────────────────────────────┘
```

### Flux d'authentification Web avec BFF

```
Navigateur          BFF (Cloudflare/Vercel)      Supabase Auth
    │                        │                        │
    │── POST /bff/auth/login ──►                      │
    │   { email, password }   │                       │
    │                         │── POST /auth/v1/token ►│
    │                         │◄── { access_token,    │
    │                         │      refresh_token }  │
    │                         │                       │
    │                         │ Stocker tokens en KV/Redis
    │                         │ (JAMAIS transmis au navigateur)
    │                         │                       │
    │◄── Set-Cookie: bff_session=abc123.hmac (HttpOnly) ──
    │◄── Set-Cookie: bff_csrf=random.hmac (lisible JS)  ──
    │    { ok: true, userId }  │                       │
```

### Règle fondamentale

> **Le token Supabase (JWT) ne quitte JAMAIS le serveur BFF.**  
> Le navigateur reçoit uniquement un identifiant de session opaque dans un cookie HttpOnly.  
> Même le code Dart Flutter Web ne peut pas lire ce token.

---

## 2. Ce qui se passe à chaque build mobile {#2-build-mobile}

### Question : faut-il redéployer la Web à chaque `make apk` ?

**Non, pas systématiquement.** Le build APK et le déploiement Web sont indépendants.

### Tableau de décision rapide

| Type de modification | APK à rebuild | Web à rebuild | BFF à redéployer |
|---|---|---|---|
| Bug UI Android uniquement | ✅ Oui | ❌ Non | ❌ Non |
| Changement dans `lib/screens/` (logique partagée) | ✅ Oui | ✅ Oui | ❌ Non |
| Nouveau champ dans un modèle Dart | ✅ Oui | ✅ Oui | ❌ Non |
| Changement de schéma Supabase (nouvelle colonne) | ✅ Oui | ✅ Oui | ❌ Non |
| Modification `bff-cloudflare/src/*.ts` | ❌ Non | ❌ Non | ✅ Oui (CF uniquement) |
| Modification `bff-vercel/api/*.ts` | ❌ Non | ❌ Non | ✅ Oui (Vercel uniquement) |
| Nouveau endpoint Supabase utilisé | ✅ Oui | ✅ Oui | Parfois (si route proxy nouvelle) |
| Changement de clé `SUPABASE_ANON_KEY` | ✅ Oui | ✅ Oui | ✅ Oui (secret BFF) |

### Règle simple à retenir

> Si vous modifiez un fichier dans `lib/` → rebuild Web  
> Si vous modifiez un fichier dans `bff-cloudflare/src/` ou `bff-vercel/` → redéployez le BFF  
> Le BFF ne contient aucun code Flutter — les deux systèmes évoluent indépendamment.

---

## 3. Mettre à jour la version Web Flutter après un changement {#3-update-web-flutter}

### Cas A : CI/CD configuré (Git connecté à Cloudflare Pages)

Après avoir modifié et commité le code :

```bash
git add lib/
git commit -m "fix: correction affichage carte Web"
git push origin main
```

Cloudflare Pages détecte le push, déclenche automatiquement :
1. `flutter build web --release --dart-define=BFF_URL=https://bff.songre.bf`
2. Déploiement dans Cloudflare CDN
3. Disponible sur https://songre.bf en 2–3 minutes

**Vérification** : aller sur le dashboard Cloudflare Pages → voir le statut du build en cours.

### Cas B : déploiement manuel

```bash
# Étape 1 : builder la version Web
cd /home/user/flutter_app
flutter build web --release \
  --dart-define=BFF_URL=https://bff.songre.bf \
  --dart-define=SUPABASE_URL=https://ptomqwucvveuflfnyczo.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<votre_clé_anon>

# Étape 2 : vérifier que le build a réussi
ls -la build/web/

# Étape 3 : déployer sur Cloudflare Pages
npx wrangler pages deploy build/web --project-name=songre-web

# Ou sur Vercel :
vercel --prod build/web
```

### Vérification après déploiement Web

```bash
# 1. Vérifier que la page se charge
curl -I https://songre.bf

# 2. Vérifier que les headers de sécurité sont présents
curl -I https://songre.bf | grep -E "X-Frame|Content-Security|Strict-Transport"

# 3. Tester le rendu à différentes largeurs (dans le navigateur)
# → Ouvrir DevTools → Toggle Device Toolbar (Ctrl+Shift+M)
# → Tester à 375px (mobile), 768px (tablette), 1280px (desktop)
```

---

## 4. Mettre à jour le BFF Cloudflare {#4-update-bff-cloudflare}

### Structure du dossier BFF Cloudflare

```
bff-cloudflare/
├── wrangler.toml          ← configuration déploiement
├── package.json           ← scripts npm
├── tsconfig.json          ← config TypeScript
└── src/
    ├── index.ts           ← routeur principal (entrée)
    ├── types.ts           ← interfaces TypeScript
    ├── auth/              ← handlers d'authentification
    │   ├── login.ts       ← POST /bff/auth/login
    │   ├── signup.ts      ← POST /bff/auth/signup
    │   ├── logout.ts      ← POST /bff/auth/logout
    │   ├── recover.ts     ← POST /bff/auth/recover
    │   └── refresh.ts     ← POST /bff/auth/refresh
    ├── proxy/
    │   └── supabase.ts    ← proxy /bff/api/* et /bff/functions/*
    └── security/
        ├── headers.ts     ← CSP, CORS, HSTS, X-Frame-Options
        └── csrf.ts        ← HMAC double-submit CSRF
```

### Modifier et tester en local

```bash
cd bff-cloudflare

# Installer les dépendances (première fois)
npm install

# Copier le fichier d'environnement local
cp wrangler.toml wrangler.dev.toml  # optionnel, pour surcharger

# Créer un fichier .dev.vars pour les secrets en local
cat > .dev.vars << EOF
SESSION_SECRET=0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20
CSRF_SECRET=2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40
SUPABASE_ANON_KEY=<votre_clé_anon>
EOF
# ⚠️ NE JAMAIS committer .dev.vars

# Démarrer le serveur local
npm run dev
# → Disponible sur http://localhost:8787

# Tester une route en local
curl -X POST http://localhost:8787/bff/auth/login \
  -H "Content-Type: application/json" \
  -H "Origin: http://localhost:5060" \
  -d '{"email":"test@test.com","password":"test123"}'

# Vérifier les headers de sécurité
curl -I http://localhost:8787/bff/health \
  -H "Origin: http://localhost:5060"
```

### Déployer le BFF Cloudflare en production

```bash
cd bff-cloudflare

# Vérification TypeScript avant déploiement
npm run type-check

# Injecter les secrets (première fois ou si rotation)
npx wrangler secret put SESSION_SECRET
# → Entrer la valeur quand demandé (32 bytes hex, ex: openssl rand -hex 32)

npx wrangler secret put CSRF_SECRET
# → Entrer la valeur

npx wrangler secret put SUPABASE_ANON_KEY
# → Entrer la clé anon Supabase

# Déployer
npm run deploy
# → npx wrangler deploy

# Vérifier que le déploiement a réussi
curl https://bff.songre.bf/bff/health
# → {"ok":true,"service":"SONGRE BFF","version":"1.0.0"}
```

### Vérifier les headers de sécurité en production

```bash
# Headers complets sur une route réelle
curl -I https://bff.songre.bf/bff/health \
  -H "Origin: https://songre.bf"

# Réponse attendue (extrait) :
# HTTP/2 200
# content-security-policy: default-src 'self'; ...
# strict-transport-security: max-age=31536000; includeSubDomains; preload
# x-frame-options: DENY
# x-content-type-options: nosniff
# referrer-policy: strict-origin-when-cross-origin
# access-control-allow-origin: https://songre.bf
# access-control-allow-credentials: true
```

---

## 5. Mettre à jour le BFF Vercel {#5-update-bff-vercel}

### Structure du dossier BFF Vercel

```
bff-vercel/
├── vercel.json            ← configuration Vercel (rewrites, fonctions)
├── package.json           ← dépendances (@upstash/redis, @vercel/node)
├── tsconfig.json
├── lib/                   ← modules partagés
│   ├── types.ts           ← BffEnv, SessionData, getEnv()
│   ├── headers.ts         ← applySecurityHeaders(), handlePreflight()
│   ├── csrf.ts            ← generateCsrfToken(), verifyCsrfToken()
│   └── session.ts         ← Redis CRUD + rate limiting + cookie builders
└── api/bff/
    ├── auth/
    │   └── [action].ts    ← 5 routes auth (login/signup/logout/recover/refresh)
    ├── proxy.ts           ← proxy Supabase REST + Edge Functions
    └── health.ts          ← GET /bff/health
```

### Différence principale avec Cloudflare

| Aspect | Cloudflare Workers | Vercel Serverless |
|---|---|---|
| Stockage sessions | Cloudflare KV (intégré) | Upstash Redis (externe) |
| Rate limiting | API native Workers | INCR/EXPIRE Redis |
| Runtime | V8 isolates (Web API) | Node.js 20.x |
| Secrets | `wrangler secret put` | Variables d'env Vercel Dashboard |
| Déploiement | `wrangler deploy` | `vercel --prod` |

### Tester en local

```bash
cd bff-vercel

npm install

# Créer .env.local pour les secrets
cat > .env.local << EOF
SESSION_SECRET=<32 bytes hex>
CSRF_SECRET=<32 bytes hex>
SUPABASE_URL=https://ptomqwucvveuflfnyczo.supabase.co
SUPABASE_ANON_KEY=<votre_clé_anon>
ALLOWED_ORIGIN=http://localhost:5060
UPSTASH_REDIS_REST_URL=https://<votre-instance>.upstash.io
UPSTASH_REDIS_REST_TOKEN=<votre_token_upstash>
ENVIRONMENT=development
EOF
# ⚠️ NE JAMAIS committer .env.local

npm run dev
# → http://localhost:8788
```

### Configurer Upstash Redis (première fois)

1. Aller sur **https://console.upstash.com/**
2. Créer une base de données Redis : **Create Database** → **Global** (géo-distribué)
3. Copier les valeurs :
   - `UPSTASH_REDIS_REST_URL` → format `https://xxx.upstash.io`
   - `UPSTASH_REDIS_REST_TOKEN` → token d'accès
4. Dans Vercel Dashboard → **Settings** → **Environment Variables** → ajouter ces deux variables

### Déployer sur Vercel

```bash
cd bff-vercel

# Connexion à Vercel (première fois)
npx vercel login

# Lier au projet Vercel (première fois)
npx vercel link

# Vérification TypeScript
npm run build

# Déploiement production
npm run deploy
# → npx vercel --prod

# Vérification
curl https://bff-vercel.songre.bf/bff/health
```

---

## 6. Tableau de décision — Que redéployer selon le type de modification {#6-tableau-decision}

```
┌────────────────────────────────────────┬──────────┬──────────┬──────────┬──────────┐
│ Type de modification                   │ APK      │ Web      │ BFF CF   │ BFF VCL  │
│                                        │ rebuild  │ rebuild  │ redeploy │ redeploy │
├────────────────────────────────────────┼──────────┼──────────┼──────────┼──────────┤
│ Bug visuel Android uniquement          │ ✅       │ ❌       │ ❌       │ ❌       │
│ Modification lib/ (écrans partagés)    │ ✅       │ ✅       │ ❌       │ ❌       │
│ Nouveau modèle Dart                    │ ✅       │ ✅       │ ❌       │ ❌       │
│ Nouvelle table Supabase                │ ✅       │ ✅       │ ❌       │ ❌       │
│ Changement logique auth Flutter        │ ✅       │ ✅       │ ❌       │ ❌       │
│ Nouveau header de sécurité BFF         │ ❌       │ ❌       │ ✅       │ ✅       │
│ Modification durée session (TTL)       │ ❌       │ ❌       │ ✅ (*)   │ ✅ (*)   │
│ Rotation SECRET_SESSION / CSRF_SECRET  │ ❌       │ ❌       │ ✅       │ ✅       │
│ Changement SUPABASE_ANON_KEY           │ ✅       │ ✅       │ ✅       │ ✅       │
│ Nouveau endpoint proxy /bff/api/*      │ ❌       │ ✅       │ Rarement │ Rarement │
│ Mise à jour BFF_URL (nouveau domaine)  │ ❌       │ ✅ (**)  │ ❌       │ ❌       │
│ Ajout rate limiting nouveau IP range   │ ❌       │ ❌       │ ✅       │ ✅       │
│ Modification CSP (nouveau domaine src) │ ❌       │ ❌       │ ✅       │ ✅       │
└────────────────────────────────────────┴──────────┴──────────┴──────────┴──────────┘

(*) SESSION_TTL_SECONDS est une variable wrangler.toml / vercel.json — pas un secret.
    Modification dans le fichier de config + redéploiement BFF suffit.

(**) BFF_URL est un dart-define — rebuild Web avec la nouvelle valeur.
```

---

## 7. Explication de chaque service et fichier de configuration {#7-services-expliqués}

### 7.1 Cloudflare Workers

**Qu'est-ce que c'est ?**  
Cloudflare Workers est un environnement d'exécution de code JavaScript/TypeScript qui s'exécute directement dans les datacenters Cloudflare, au plus près des utilisateurs (200+ localisations mondiales). Il ne s'agit pas d'un serveur traditionnel — votre code tourne en "V8 isolates", des micro-processus très rapides démarrés à froid en moins de 1 ms.

**Pourquoi pour le BFF SONGRE ?**  
Le BFF doit intercepter les requêtes d'authentification avant qu'elles atteignent Supabase. Cloudflare Workers est idéal car il est déjà sur le chemin des requêtes (comme un proxy CDN) et peut stocker les sessions dans Cloudflare KV sans latence.

**Fichier principal** : `bff-cloudflare/wrangler.toml`  
```toml
name = "songre-bff"              # Nom du Worker dans le dashboard CF
main = "src/index.ts"            # Point d'entrée
compatibility_date = "2024-01-15"

[[kv_namespaces]]
binding = "SESSIONS"             # Variable accessible dans le code : env.SESSIONS
id = "xxx"                       # ID du namespace KV (créé dans le dashboard)

[vars]
ALLOWED_ORIGIN = "https://songre.bf"   # Variable publique (OK dans le fichier)
SESSION_TTL_SECONDS = "86400"          # 24 heures

# Ces variables sont des SECRETS → NE PAS les mettre dans ce fichier
# Injecter via : npx wrangler secret put SESSION_SECRET
# - SESSION_SECRET
# - CSRF_SECRET
# - SUPABASE_ANON_KEY
```

### 7.2 Cloudflare KV (Key-Value Store)

**Qu'est-ce que c'est ?**  
Cloudflare KV est un stockage clé-valeur distribué, disponible dans tous les datacenters CF. Il supporte un TTL (durée de vie) automatique : les clés expirent toutes seules sans code supplémentaire.

**Comment il est utilisé dans SONGRE ?**  
Chaque session utilisateur est stockée sous la clé `session:{sessionId}` avec une valeur JSON contenant le `userId`, `accessToken`, et `refreshToken`. Le navigateur ne reçoit que le `sessionId` (dans un cookie HttpOnly signé) — jamais les tokens réels.

```
KV Storage :
  "session:abc123def456" → {
    "userId": "uuid-utilisateur",
    "accessToken": "eyJhbGc...",   ← jamais envoyé au navigateur
    "refreshToken": "eyJhbGc...",  ← jamais envoyé au navigateur
    "expiresAt": 1703980800000
  }
  TTL: 86400 secondes (24h) → suppression automatique
```

**Créer le namespace KV** (première fois) :
```bash
npx wrangler kv namespace create "SESSIONS"
# → Copier l'ID retourné dans wrangler.toml [kv_namespaces]
```

### 7.3 Vercel Serverless Functions

**Qu'est-ce que c'est ?**  
Vercel est une plateforme d'hébergement qui transforme automatiquement les fichiers TypeScript dans le dossier `api/` en fonctions serverless. Chaque fichier = une route HTTP.

**Différence avec Cloudflare Workers** :
- Vercel utilise Node.js (accès aux API Node : `fs`, `crypto`, etc.)
- Cloudflare Workers utilise les Web API standards (`fetch`, `crypto.subtle`)
- Les deux sont "serverless" — pas de serveur permanent à gérer

**Fichier principal** : `bff-vercel/vercel.json`  
```json
{
  "rewrites": [
    { "source": "/bff/auth/:action", "destination": "/api/bff/auth/:action" }
  ]
}
```
Les "rewrites" permettent d'avoir des URLs propres (`/bff/auth/login`) qui pointent vers les fichiers de fonctions internes (`/api/bff/auth/[action]`).

### 7.4 Upstash Redis (équivalent Cloudflare KV pour Vercel)

**Pourquoi Redis et pas une simple base ?**  
Redis est un store en mémoire ultra-rapide avec support natif du TTL. La commande `SETEX key 86400 value` crée une clé qui s'autodétruit après 86400 secondes — exactement comme Cloudflare KV.

**Upstash** est la version serverless de Redis : pas de serveur à gérer, API REST disponible, facturation à l'usage. Il est l'option officielle recommandée par Vercel pour les sessions.

**Coût** : gratuit jusqu'à 10 000 requêtes/jour (largement suffisant pour SONGRE).

### 7.5 Cookie HttpOnly

**Qu'est-ce que c'est ?**  
Un cookie HTTP avec le flag `HttpOnly` ne peut pas être lu par JavaScript. Il est automatiquement envoyé par le navigateur dans chaque requête HTTP, mais `document.cookie` ne le montre pas.

**Pourquoi c'est important ?**  
Sans HttpOnly, un attaquant qui trouve une faille XSS (injection JavaScript) dans l'application peut voler tous les tokens stockés dans `localStorage` ou les cookies normaux. Avec HttpOnly, même si du JavaScript malveillant s'exécute, il ne peut pas accéder au token.

**Configuration dans SONGRE** :
```
Set-Cookie: bff_session=abc123.hmac; HttpOnly; Secure; SameSite=Strict; Max-Age=86400; Path=/
```
- `HttpOnly` → non lisible par JS
- `Secure` → HTTPS uniquement
- `SameSite=Strict` → jamais envoyé depuis un autre site (protection CSRF couche 1)
- `Max-Age=86400` → expire après 24h

### 7.6 Les fichiers BFF Flutter (`lib/services/`)

| Fichier | Rôle |
|---|---|
| `bff_client.dart` | Client Dart qui appelle le BFF (5 méthodes auth + proxy) |
| `bff_cookie_web.dart` | Lecture du cookie CSRF depuis `document.cookie` (Web seulement) |
| `bff_cookie_stub.dart` | Version vide pour Android/iOS (jamais appelée) |

**La règle `estBffActif`** dans `secure_storage_service.dart` :
```dart
bool get estBffActif => kIsWeb && kBffUrl.isNotEmpty;
```
Cette condition garantit que tout le code BFF est **strictement conditionné** à la plateforme Web ET à la présence d'une URL BFF. Sur Android, `kIsWeb = false` → jamais exécuté, même si `BFF_URL` est défini par erreur.

---

## 8. Explication de chaque mesure de sécurité et comment la tester {#8-sécurité-expliquée}

### 8.1 Cookies HttpOnly — Protection contre XSS

**Ce que ça protège** : vol de tokens par injection JavaScript (XSS). Si un attaquant injecte du JavaScript dans la page, `document.cookie` ne montre pas le token de session.

**Comment vérifier** :
1. Se connecter sur la version Web de SONGRE
2. Ouvrir les DevTools du navigateur → onglet **Application** → **Cookies**
3. Trouver le cookie `bff_session` → la colonne **HttpOnly** doit afficher ✓
4. Ouvrir la **Console** JavaScript et taper :
   ```javascript
   document.cookie
   // → ne doit PAS contenir "bff_session"
   // → peut contenir "bff_csrf" (intentionnellement non-HttpOnly)
   ```

### 8.2 CSRF Double-Submit HMAC — Protection contre les requêtes forgées

**Ce que ça protège** : une page malveillante (sur un autre domaine) qui tenterait de soumettre un formulaire vers votre BFF en exploitant le cookie de session automatiquement envoyé par le navigateur.

**Mécanisme** :
1. BFF pose `bff_csrf=random.hmacSig` (cookie non-HttpOnly)
2. L'app Dart lit ce cookie et l'envoie dans `X-CSRF-Token: random.hmacSig`
3. Le BFF vérifie que le header correspond au cookie → une page externe ne peut pas lire le cookie non-HttpOnly d'un autre domaine (politique Same-Origin)

**Test concret — requête sans CSRF doit être rejetée** :
```bash
# Tentative de requête mutante (POST) sans token CSRF → doit retourner 403
curl -X POST https://bff.songre.bf/bff/auth/logout \
  -H "Origin: https://songre.bf" \
  -H "Cookie: bff_session=validSession123" \
  -H "Content-Type: application/json"
# → {"ok":false,"error":"Token CSRF invalide"} + HTTP 403 ✅

# Avec un faux token CSRF → doit aussi retourner 403
curl -X POST https://bff.songre.bf/bff/auth/logout \
  -H "Origin: https://songre.bf" \
  -H "Cookie: bff_session=validSession123" \
  -H "X-CSRF-Token: faketoken.fakesig" \
  -H "Content-Type: application/json"
# → {"ok":false,"error":"Token CSRF invalide"} + HTTP 403 ✅
```

### 8.3 Content-Security-Policy (CSP) — Limitation des sources

**Ce que ça protège** : chargement de scripts malveillants depuis des CDN compromis, injection de contenu externe non autorisé.

**Politique SONGRE** :
```
default-src 'self'
script-src 'self'                                    ← scripts UNIQUEMENT depuis songre.bf
style-src 'self' 'unsafe-inline' fonts.googleapis.com
connect-src 'self' *.supabase.co *.supabase.io      ← appels réseau limités
img-src 'self' data: *.tile.openstreetmap.org        ← images OSM pour la carte
frame-ancestors 'none'                               ← impossible d'intégrer dans un iframe
```

**Comment vérifier** :
```bash
curl -I https://bff.songre.bf/bff/health | grep content-security-policy
# → doit afficher la politique complète
```

### 8.4 CORS Strict — Limitation des origines autorisées

**Ce que ça protège** : requêtes cross-origin depuis des sites non autorisés.

**Test** :
```bash
# Origine non autorisée → doit être rejetée
curl -I https://bff.songre.bf/bff/health \
  -H "Origin: https://evil-site.com"
# → Pas de header Access-Control-Allow-Origin ✅

# Origine autorisée → doit fonctionner
curl -I https://bff.songre.bf/bff/health \
  -H "Origin: https://songre.bf"
# → access-control-allow-origin: https://songre.bf ✅
```

### 8.5 Rate Limiting — Protection contre le brute force

**Ce que ça protège** : tentatives de connexion en masse (brute force sur le mot de passe).

**Limites SONGRE** : 5 requêtes par 60 secondes par adresse IP sur les routes `/bff/auth/login` et `/bff/auth/signup`.

**Test** :
```bash
# Envoyer 6 requêtes rapidement
for i in {1..6}; do
  curl -s -o /dev/null -w "%{http_code}\n" \
    -X POST https://bff.songre.bf/bff/auth/login \
    -H "Content-Type: application/json" \
    -H "Origin: https://songre.bf" \
    -d '{"email":"test@test.com","password":"wrong"}'; 
done
# → 401 401 401 401 401 429  ← la 6ème requête est bloquée ✅
```

### 8.6 HSTS — Forçage HTTPS

**Ce que ça protège** : attaques de downgrade vers HTTP (interception de communication non chiffrée).

**Vérifier** :
```bash
curl -I https://bff.songre.bf/bff/health | grep strict-transport
# → strict-transport-security: max-age=31536000; includeSubDomains; preload ✅
```

**Durée** : 1 an (31 536 000 secondes). Le navigateur mémorise que ce site ne doit être contacté qu'en HTTPS.

### 8.7 Signature HMAC du Session ID — Anti-falsification

**Ce que ça protège** : un attaquant qui devinerait ou modifierait le session ID dans le cookie.

**Mécanisme** : le session ID dans le cookie a le format `sessionId.hmacSignature`.  
Lors de chaque requête, le BFF recalcule `HMAC-SHA256(sessionId, SESSION_SECRET)` et compare avec la signature reçue (en timing-safe). Si quelqu'un modifie le sessionId, la signature ne correspond plus → rejet.

---

## Actions manuelles vs automatiques (résumé CI/CD)

| Action | Cloudflare | Vercel | Fréquence |
|---|---|---|---|
| **Automatique après git push** | Build + deploy Pages | Build + deploy Functions | À chaque push sur `main` |
| **Manuelle une seule fois** | Lier repo GitHub dans CF Dashboard | Lier repo GitHub dans Vercel Dashboard | Lors de la configuration initiale |
| **Manuelle à chaque rotation** | `wrangler secret put SESSION_SECRET` | Variables d'env Vercel Dashboard | Tous les 90 jours recommandé |
| **Manuelle (domaine custom)** | Ajouter CNAME dans DNS | Ajouter domaine dans Vercel | Une fois |
| **Manuelle (nouveau namespace KV)** | `wrangler kv namespace create` | Créer DB Upstash + configurer env vars | Une seule fois |

---

## PARTIE 6 — CI/CD GitHub natif : procédure de configuration

### Cloudflare Pages (pour l'app Flutter Web)

1. Aller sur **https://dash.cloudflare.com/** → Pages → **Create a project**
2. **Connect to Git** → sélectionner GitHub → autoriser Cloudflare
3. Sélectionner le repo `poodasamuelpro/Songre-app`
4. **Build settings** :
   - Framework preset : **None** (Flutter n'est pas dans la liste)
   - Build command : `flutter/bin/flutter build web --release --dart-define=BFF_URL=https://bff.songre.bf`
   - Build output directory : `build/web`
   - Root directory : `/` (racine du repo)
5. **Environment variables** (onglet Settings après création) :
   - `FLUTTER_VERSION` = `3.35.4`
   - `BFF_URL` = `https://bff.songre.bf`
6. **Branche de production** : `main`
7. Cliquer **Save and Deploy**

> À partir de maintenant : chaque `git push origin main` déclenche automatiquement un rebuild et redéploiement.

### Cloudflare Workers (pour le BFF)

1. Installer Wrangler CLI : `npm install -g wrangler`
2. Se connecter : `npx wrangler login`
3. Dans `bff-cloudflare/` : `npx wrangler deploy`
4. Pour l'automatisation via GitHub Actions, créer `.github/workflows/deploy-bff.yml` :

```yaml
name: Deploy BFF Cloudflare
on:
  push:
    branches: [main]
    paths: ['bff-cloudflare/**']  # uniquement si BFF modifié
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - run: cd bff-cloudflare && npm ci
      - run: cd bff-cloudflare && npx wrangler deploy
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

### Vercel (pour app Web + BFF Vercel)

1. Aller sur **https://vercel.com/new**
2. **Import Git Repository** → GitHub → sélectionner `Songre-app`
3. **Configure Project** :
   - Framework preset : **Other**
   - Root directory : `bff-vercel/`
   - Build command : `npm run build`
   - Output directory : `.vercel/output`
4. **Environment Variables** : ajouter `SESSION_SECRET`, `CSRF_SECRET`, `SUPABASE_ANON_KEY`, `UPSTASH_REDIS_REST_URL`, `UPSTASH_REDIS_REST_TOKEN`, `ALLOWED_ORIGIN`
5. Cliquer **Deploy**

> À partir de maintenant : chaque push sur `main` avec des modifications dans `bff-vercel/**` déclenche un redéploiement automatique.

---

*Guide produit en session 8 — SONGRE Web Platform v1.0*  
*Commit de référence : 3662398*
