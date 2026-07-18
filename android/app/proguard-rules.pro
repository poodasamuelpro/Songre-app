# =============================================================================
# ProGuard / R8 — Règles pour SONGRE
# =============================================================================
#
# Activé via build.gradle.kts : isMinifyEnabled = true + isShrinkResources = true
#
# Ce fichier préserve les classes qui sont accédées par réflexion ou via
# des mécanismes non détectables statiquement par R8.
# =============================================================================

# ---------------------------------------------------------------------------
# Flutter Engine — classes critiques du runtime Flutter
# ---------------------------------------------------------------------------
-keep class io.flutter.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.app.** { *; }
-dontwarn io.flutter.**

# ---------------------------------------------------------------------------
# Firebase — firebase_core + firebase_messaging
# ---------------------------------------------------------------------------
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses
-dontwarn com.google.firebase.**
-dontwarn com.google.android.gms.**

# Firebase Messaging — service déclaré dans AndroidManifest
-keep class com.google.firebase.messaging.FirebaseMessagingService { *; }

# ---------------------------------------------------------------------------
# flutter_secure_storage — accès au Keystore Android via réflexion
# ---------------------------------------------------------------------------
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-keep class com.it_nomads.fluttersecurestorage.ciphers.** { *; }
-dontwarn com.it_nomads.fluttersecurestorage.**

# ---------------------------------------------------------------------------
# mobile_scanner — Google ML Kit Barcode Scanning
# ---------------------------------------------------------------------------
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.vision.** { *; }
-dontwarn com.google.mlkit.**

# Mobile Scanner plugin
-keep class dev.zxing.** { *; }
-keep class com.journeyapps.** { *; }
-dontwarn com.journeyapps.**

# ---------------------------------------------------------------------------
# Kotlin — stdlib et coroutines utilisées par plugins
# ---------------------------------------------------------------------------
-keep class kotlin.** { *; }
-keep class kotlin.Metadata { *; }
-dontwarn kotlin.**
-keepclassmembers class **$WhenMappings {
    <fields>;
}
-keepclassmembers class kotlin.Lazy {
    <methods>;
}

# ---------------------------------------------------------------------------
# url_launcher — intents Android
# ---------------------------------------------------------------------------
-keep class io.flutter.plugins.urllauncher.** { *; }
-dontwarn io.flutter.plugins.urllauncher.**

# ---------------------------------------------------------------------------
# qr_flutter — génération QR code (pur Dart, pas d'impact natif)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Règles générales R8/ProGuard
# ---------------------------------------------------------------------------
# Garder les constructeurs par défaut et les annotations pour la sérialisation JSON
-keepattributes Signature
-keepattributes Exceptions
-keepattributes SourceFile,LineNumberTable

# Garder les classes avec @Keep annotation
-keep class * {
    @androidx.annotation.Keep *;
}
-keep @androidx.annotation.Keep class *

# Empêcher le renommage des noms d'exceptions (pour les stack traces lisibles)
-keepnames class * extends java.lang.Exception

# Android standard
-keep class * extends android.app.Activity
-keep class * extends android.app.Service
-keep class * extends android.content.BroadcastReceiver
-keep class * extends android.content.ContentProvider

# androidx
-keep class androidx.** { *; }
-dontwarn androidx.**
