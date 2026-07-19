// lib/services/bff_cookie_web.dart
// Lecture du cookie bff_csrf — implémentation Web moderne
//
// Utilise package:web (dart:js_interop) au lieu de l'API dart:html
// dépréciée depuis Flutter 3.22+.
//
// Le cookie bff_csrf est posé par le BFF avec SameSite=Strict
// mais SANS HttpOnly, précisément pour que l'application puisse
// le lire ici et l'envoyer dans l'en-tête X-CSRF-Token.

import 'package:web/web.dart' as web;

/// Lit le token CSRF depuis le cookie bff_csrf (non-HttpOnly).
/// Retourne null si le cookie est absent (pas de session BFF active).
String? readCsrfCookie() {
  try {
    final cookies = web.document.cookie;
    for (final part in cookies.split(';')) {
      final trimmed = part.trim();
      if (trimmed.startsWith('bff_csrf=')) {
        return trimmed.substring('bff_csrf='.length).trim();
      }
    }
    return null;
  } catch (_) {
    return null;
  }
}
