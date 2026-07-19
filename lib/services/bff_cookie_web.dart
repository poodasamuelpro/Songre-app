// lib/services/bff_cookie_web.dart
// Lecture du cookie bff_csrf via dart:js_interop compatible Flutter 3.35.4

// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

/// Lit le token CSRF depuis le cookie bff_csrf (non-HttpOnly).
String? readCsrfCookie() {
  try {
    final cookies = html.document.cookie ?? '';
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
