// lib/services/bff_cookie_stub.dart
// Stub pour Android / iOS — readCsrfCookie() ne doit JAMAIS être appelé
// sur ces plateformes (BffClient n'est utilisé que si estBffActif == true,
// qui requiert kIsWeb). Ce fichier existe uniquement pour satisfaire le
// compilateur lors des builds natifs.

/// Stub Android/iOS — toujours null (jamais appelé en pratique).
String? readCsrfCookie() => null;
