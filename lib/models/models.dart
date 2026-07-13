// =====================================================================
// MODÈLES DE DONNÉES — Application SONGRE
// Synchronisé avec le schéma réel public.* (audit 2026-07-08)
// =====================================================================

import '../utils/crypto_service.dart';

// ── Durée de validité des demandes de sang (§2.5.6 — correction R-05)
// ── Correction audit 2026-07-13 : passage de 72h à 7 jours (168h).
// ── Le DEFAULT PostgreSQL sur demandes_sang.expires_at DOIT aussi être
// ── mis à jour via : scripts/migration_expires_at_7jours.sql
// ── Les deux modifications (SQL + Dart) sont indépendantes.
// SQL : ALTER TABLE public.demandes_sang ALTER COLUMN expires_at SET DEFAULT now() + interval '7 days';
const Duration kDureeValiditeDemande = Duration(hours: 168);
String get kDureeValiditeDemandeLabel {
  if (kDureeValiditeDemande.inHours < 24) {
    return '${kDureeValiditeDemande.inHours}h';
  }
  return '${kDureeValiditeDemande.inDays} jours';
}

// =====================================================================
// Énumérations (miroir des ENUMs PostgreSQL)
// =====================================================================

enum GroupeSanguin {
  ominus('O-'),
  oplus('O+'),
  aminus('A-'),
  aplus('A+'),
  bminus('B-'),
  bplus('B+'),
  abminus('AB-'),
  abplus('AB+');

  final String label;
  const GroupeSanguin(this.label);

  static GroupeSanguin fromLabel(String label) {
    return GroupeSanguin.values.firstWhere(
      (g) => g.label == label,
      orElse: () => GroupeSanguin.oplus,
    );
  }
}

enum StatutDemande {
  active('active'),
  enCours('en_cours'),
  satisfaite('satisfaite'),
  expiree('expiree'),
  annulee('annulee');

  final String value;
  const StatutDemande(this.value);
}

enum SourceDon {
  qrValide('qr_valide'),
  declaratif('declaratif');

  final String value;
  const SourceDon(this.value);
}

enum Genre {
  homme('homme'),
  femme('femme');

  final String value;
  const Genre(this.value);
}

// Miroir de public.type_notification_enum
// Synchronisé avec mission-d.sql — 10 valeurs totales (audit R-03, 2026-07-09)
// Valeurs originales (3) : demande_compatible, don_confirme, retour_eligibilite
// Valeurs ajoutées (7) : reponse_recue, reponse_encouragement,
//   don_confirme_demandeur, don_enregistre_manuel, suppression_demandee,
//   bienvenue, mdp_modifie
enum TypeNotification {
  // ── Valeurs historiques ──────────────────────────────────────────────
  demandeCompatible('demande_compatible'),
  donConfirme('don_confirme'),
  retourEligibilite('retour_eligibilite'),
  // ── Valeurs ajoutées (mission-d.sql) ─────────────────────────────────
  reponseRecue('reponse_recue'),
  reponseEncouragement('reponse_encouragement'),
  donConfirmeDemandeur('don_confirme_demandeur'),
  donEnregistreManuel('don_enregistre_manuel'),
  suppressionDemandee('suppression_demandee'),
  bienvenue('bienvenue'),
  mdpModifie('mdp_modifie');

  final String value;
  const TypeNotification(this.value);

  static TypeNotification fromValue(String val) {
    return TypeNotification.values.firstWhere(
      (t) => t.value == val,
      orElse: () => TypeNotification.demandeCompatible,
    );
  }
}

// =====================================================================
// Ville — référentiel public.villes
// =====================================================================
class Ville {
  final int id;
  final String nom;
  final int? regionId;
  final bool active;

  const Ville({
    required this.id,
    required this.nom,
    this.regionId,
    this.active = true,
  });

  factory Ville.fromJson(Map<String, dynamic> json) => Ville(
        id: json['id'] as int,
        nom: json['nom'] as String,
        regionId: json['region_id'] as int?,
        active: json['active'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'nom': nom,
        'region_id': regionId,
        'active': active,
      };

  @override
  String toString() => nom;
}

// =====================================================================
// Structure sanitaire — référentiel public.structures_sanitaires
// =====================================================================
class StructureSanitaire {
  final int id;
  final String nom;
  final int villeId;
  final String? type;
  final bool active;

  const StructureSanitaire({
    required this.id,
    required this.nom,
    required this.villeId,
    this.type,
    this.active = true,
  });

  factory StructureSanitaire.fromJson(Map<String, dynamic> json) =>
      StructureSanitaire(
        id: json['id'] as int,
        nom: json['nom'] as String,
        villeId: json['ville_id'] as int,
        type: json['type'] as String?,
        active: json['active'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'nom': nom,
        'ville_id': villeId,
        'type': type,
        'active': active,
      };

  @override
  String toString() => nom;
}

// =====================================================================
// Profil Donneur — synchronisé avec public.profils_donneurs
// Champs modifiés vs ancienne version :
//   - ville (String) → villeId (int) + villeNom (String pour affichage)
//   - poids (int)    → poidsChiffre (String, AES-256)
//   - contreIndications (List<String>) → contreIndicationsChiffre (String/JSONB, AES-256)
// =====================================================================
class ProfilDonneur {
  final String userId;
  final GroupeSanguin groupeSanguin;
  /// Poids en clair — jamais envoyé en base ; chiffré avant envoi.
  final int poids;
  final Genre genre;
  /// ID entier de la ville (FK vers public.villes.id)
  final int villeId;
  /// Nom de la ville (lecture seule — pour affichage)
  final String villeNom;
  final String? quartier;
  /// Contre-indications en clair — chiffrées avant envoi en base.
  final List<String> contreIndications;
  /// Numéro de téléphone en clair — optionnel.
  /// Jamais envoyé en base tel quel ; chiffré AES-256 avant envoi (telephone_chiffre).
  /// Visible uniquement par le demandeur dont la demande a été confirmée.
  final String? telephone;
  final DateTime? dernierDonDate;
  final bool disponible;
  final DateTime createdAt;
  final DateTime updatedAt;

  ProfilDonneur({
    required this.userId,
    required this.groupeSanguin,
    required this.poids,
    required this.genre,
    required this.villeId,
    required this.villeNom,
    this.quartier,
    this.contreIndications = const [],
    this.telephone,
    this.dernierDonDate,
    this.disponible = true,
    required this.createdAt,
    required this.updatedAt,
  });

  // Calcul d'éligibilité (60j homme / 90j femme)
  bool get estEligible {
    if (dernierDonDate == null) return true;
    final joursDepuis = DateTime.now().difference(dernierDonDate!).inDays;
    return genre == Genre.homme ? joursDepuis >= 60 : joursDepuis >= 90;
  }

  // Date du prochain don possible
  DateTime? get prochainDonDate {
    if (dernierDonDate == null) return null;
    final delai = genre == Genre.homme ? 60 : 90;
    return dernierDonDate!.add(Duration(days: delai));
  }

  // Identifiant anonyme affiché (4 derniers chars de l'UUID)
  String get anonymeId {
    if (userId.length >= 4) {
      return userId.substring(userId.length - 4).toUpperCase();
    }
    return userId.toUpperCase();
  }

  /// Champ de compatibilité pour les écrans (alias de villeNom)
  String get ville => villeNom;

  ProfilDonneur copyWith({
    GroupeSanguin? groupeSanguin,
    int? poids,
    Genre? genre,
    int? villeId,
    String? villeNom,
    String? quartier,
    List<String>? contreIndications,
    String? telephone,
    /// Passage explicite de null pour effacer le téléphone
    bool effacerTelephone = false,
    DateTime? dernierDonDate,
    bool? disponible,
  }) {
    return ProfilDonneur(
      userId: userId,
      groupeSanguin: groupeSanguin ?? this.groupeSanguin,
      poids: poids ?? this.poids,
      genre: genre ?? this.genre,
      villeId: villeId ?? this.villeId,
      villeNom: villeNom ?? this.villeNom,
      quartier: quartier ?? this.quartier,
      contreIndications: contreIndications ?? this.contreIndications,
      telephone: effacerTelephone ? null : (telephone ?? this.telephone),
      dernierDonDate: dernierDonDate ?? this.dernierDonDate,
      disponible: disponible ?? this.disponible,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  /// Sérialisation pour envoi en base — chiffre poids, CI et téléphone.
  /// NE PAS inclure ville_nom (pas de colonne en base).
  Map<String, dynamic> toJsonPourBase() {
    final poidsChiffre = CryptoService.chiffrer(poids.toString());
    final ciChiffre = CryptoService.chiffrerListe(
      contreIndications.isEmpty ? null : contreIndications,
    );
    final telChiffre = CryptoService.chiffrer(telephone);
    return {
      'user_id': userId,
      'groupe_sanguin': groupeSanguin.label,
      'poids_chiffre': poidsChiffre,
      'genre': genre.value,
      'ville_id': villeId,
      'quartier': quartier,
      'contre_indications_chiffre': ciChiffre,
      'telephone_chiffre': telChiffre,
      'dernier_don_date':
          dernierDonDate?.toIso8601String().substring(0, 10),
      'disponible': disponible,
    };
  }

  /// Sérialisation pour cache local (SharedPreferences) — valeurs en clair.
  Map<String, dynamic> toJson() => {
        'user_id': userId,
        'groupe_sanguin': groupeSanguin.label,
        'poids': poids,
        'genre': genre.value,
        'ville_id': villeId,
        'ville_nom': villeNom,
        'quartier': quartier,
        'contre_indications': contreIndications,
        'telephone': telephone,
        'dernier_don_date': dernierDonDate?.toIso8601String(),
        'disponible': disponible,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  /// Désérialisation depuis le cache local (valeurs en clair).
  factory ProfilDonneur.fromJson(Map<String, dynamic> json) => ProfilDonneur(
        userId: json['user_id'] as String,
        groupeSanguin: GroupeSanguin.fromLabel(json['groupe_sanguin'] as String),
        poids: json['poids'] as int? ?? 0,
        genre: Genre.values.firstWhere(
          (g) => g.value == json['genre'],
          orElse: () => Genre.homme,
        ),
        villeId: json['ville_id'] as int? ?? 0,
        villeNom: json['ville_nom'] as String? ?? '',
        quartier: json['quartier'] as String?,
        contreIndications:
            List<String>.from(json['contre_indications'] as List? ?? []),
        telephone: json['telephone'] as String?,
        dernierDonDate: json['dernier_don_date'] != null
            ? DateTime.tryParse(json['dernier_don_date'] as String)
            : null,
        disponible: json['disponible'] as bool? ?? true,
        createdAt: json['created_at'] != null
            ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
            : DateTime.now(),
        updatedAt: json['updated_at'] != null
            ? DateTime.tryParse(json['updated_at'] as String) ?? DateTime.now()
            : DateTime.now(),
      );

  /// Désérialisation depuis la base Supabase — déchiffre poids et CI.
  factory ProfilDonneur.fromBase(
    Map<String, dynamic> json, {
    required String villeNom,
  }) {
    // Déchiffrer le poids
    int poidsEnClair = 0;
    final poidsChiffre = json['poids_chiffre'] as String?;
    if (poidsChiffre != null && poidsChiffre.isNotEmpty) {
      final dechiffre = CryptoService.dechiffrer(poidsChiffre);
      poidsEnClair = int.tryParse(dechiffre ?? '0') ?? 0;
    }

    // Déchiffrer les contre-indications
    List<String> ciEnClair = [];
    final ciChiffre = json['contre_indications_chiffre'];
    if (ciChiffre != null) {
      // contre_indications_chiffre est JSONB en base → peut arriver comme String
      final ciStr =
          ciChiffre is String ? ciChiffre : ciChiffre.toString();
      if (ciStr.isNotEmpty) {
        final dechiffre = CryptoService.dechiffrerListe(ciStr);
        ciEnClair = dechiffre;
      }
    }

    // Déchiffrer le téléphone (optionnel — null si absent ou non renseigné)
    String? telEnClair;
    final telChiffre = json['telephone_chiffre'] as String?;
    if (telChiffre != null && telChiffre.isNotEmpty) {
      telEnClair = CryptoService.dechiffrer(telChiffre);
    }

    return ProfilDonneur(
      userId: json['user_id'] as String,
      groupeSanguin:
          GroupeSanguin.fromLabel(json['groupe_sanguin'] as String),
      poids: poidsEnClair,
      genre: Genre.values.firstWhere(
        (g) => g.value == json['genre'],
        orElse: () => Genre.homme,
      ),
      villeId: json['ville_id'] as int? ?? 0,
      villeNom: villeNom,
      quartier: json['quartier'] as String?,
      contreIndications: ciEnClair,
      telephone: telEnClair,
      dernierDonDate: json['dernier_don_date'] != null
          ? DateTime.tryParse(json['dernier_don_date'] as String)
          : null,
      disponible: json['disponible'] as bool? ?? true,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

// =====================================================================
// Demande de sang — synchronisée avec public.demandes_sang
// Champs modifiés vs ancienne version :
//   - ville (String)              → villeId (int?) + villeNom (String)
//   - structureSanitaire (String) → structureId (int?) + structureNom (String)
//   + villeLibre (String?) et structureLibre (String?) pour les cas libres
// =====================================================================
class DemandeSang {
  final String id;
  final String auteurId;
  final GroupeSanguin groupeSanguinRecherche;
  /// ID entier ville (FK public.villes.id) — null si ville_libre renseignée
  final int? villeId;
  /// Nom de la ville pour affichage (résolu depuis ville_id ou ville_libre)
  final String villeNom;
  /// ID entier structure (FK public.structures_sanitaires.id) — null si structure_libre
  final int? structureId;
  /// Nom de la structure pour affichage
  final String structureNom;
  /// Ville en texte libre (si ville_id est null)
  final String? villeLibre;
  /// Structure en texte libre (si structure_id est null)
  final String? structureLibre;
  // Contact PRINCIPAL — obligatoire — chiffré AES-256
  final String? contactChiffre;
  // Contact SECONDAIRE — optionnel — chiffré AES-256
  final String? contactSecondaireChiffre;
  final StatutDemande statut;
  final DateTime createdAt;
  final DateTime expiresAt;

  DemandeSang({
    required this.id,
    required this.auteurId,
    required this.groupeSanguinRecherche,
    this.villeId,
    required this.villeNom,
    this.structureId,
    required this.structureNom,
    this.villeLibre,
    this.structureLibre,
    this.contactChiffre,
    this.contactSecondaireChiffre,
    this.statut = StatutDemande.active,
    required this.createdAt,
    required this.expiresAt,
  });

  bool get estActive =>
      statut == StatutDemande.active && DateTime.now().isBefore(expiresAt);

  String get tempsEcoule {
    final diff = DateTime.now().difference(createdAt);
    if (diff.inMinutes < 60) return 'Il y a ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'Il y a ${diff.inHours}h';
    return 'Il y a ${diff.inDays}j';
  }

  /// Ville à afficher : nom résolu ou texte libre
  String get villeAffichage => villeNom.isNotEmpty ? villeNom : (villeLibre ?? '');

  /// Structure à afficher : nom résolu ou texte libre
  String get structureAffichage =>
      structureNom.isNotEmpty ? structureNom : (structureLibre ?? '');

  // Compatibilité universelle du don de sang
  bool estCompatibleAvec(ProfilDonneur profil) {
    return _groupesCompatibles(groupeSanguinRecherche)
        .contains(profil.groupeSanguin);
  }

  static List<GroupeSanguin> _groupesCompatibles(GroupeSanguin recherche) {
    switch (recherche) {
      case GroupeSanguin.ominus:
        return [GroupeSanguin.ominus];
      case GroupeSanguin.oplus:
        return [GroupeSanguin.ominus, GroupeSanguin.oplus];
      case GroupeSanguin.aminus:
        return [GroupeSanguin.ominus, GroupeSanguin.aminus];
      case GroupeSanguin.aplus:
        return [
          GroupeSanguin.ominus,
          GroupeSanguin.oplus,
          GroupeSanguin.aminus,
          GroupeSanguin.aplus
        ];
      case GroupeSanguin.bminus:
        return [GroupeSanguin.ominus, GroupeSanguin.bminus];
      case GroupeSanguin.bplus:
        return [
          GroupeSanguin.ominus,
          GroupeSanguin.oplus,
          GroupeSanguin.bminus,
          GroupeSanguin.bplus
        ];
      case GroupeSanguin.abminus:
        return [
          GroupeSanguin.ominus,
          GroupeSanguin.aminus,
          GroupeSanguin.bminus,
          GroupeSanguin.abminus
        ];
      case GroupeSanguin.abplus:
        return GroupeSanguin.values.toList();
    }
  }

  /// Sérialisation pour cache local.
  Map<String, dynamic> toJson() => {
        'id': id,
        'auteur_id': auteurId,
        'groupe_sanguin_recherche': groupeSanguinRecherche.label,
        'ville_id': villeId,
        'ville_nom': villeNom,
        'structure_id': structureId,
        'structure_nom': structureNom,
        'ville_libre': villeLibre,
        'structure_libre': structureLibre,
        'contact_chiffre': contactChiffre,
        'contact_secondaire_chiffre': contactSecondaireChiffre,
        'statut': statut.value,
        'created_at': createdAt.toIso8601String(),
        'expires_at': expiresAt.toIso8601String(),
      };

  /// Désérialisation depuis Supabase ou cache local.
  /// Résout ville_nom et structure_nom depuis les maps optionnels.
  factory DemandeSang.fromJson(
    Map<String, dynamic> json, {
    Map<int, String>? villesMap,
    Map<int, String>? structuresMap,
  }) {
    // Résoudre le nom de la ville
    final villeId = json['ville_id'] as int?;
    String villeNom = json['ville_nom'] as String? ?? '';
    if (villeNom.isEmpty && villeId != null && villesMap != null) {
      villeNom = villesMap[villeId] ?? '';
    }
    if (villeNom.isEmpty) {
      villeNom = json['ville_libre'] as String? ?? '';
    }

    // Résoudre le nom de la structure
    final structureId = json['structure_id'] as int?;
    String structureNom = json['structure_nom'] as String? ?? '';
    if (structureNom.isEmpty && structureId != null && structuresMap != null) {
      structureNom = structuresMap[structureId] ?? '';
    }
    if (structureNom.isEmpty) {
      structureNom = json['structure_libre'] as String? ?? '';
    }

    return DemandeSang(
      id: json['id'] as String,
      auteurId: json['auteur_id'] as String,
      groupeSanguinRecherche: GroupeSanguin.fromLabel(
        json['groupe_sanguin_recherche'] as String,
      ),
      villeId: villeId,
      villeNom: villeNom,
      structureId: structureId,
      structureNom: structureNom,
      villeLibre: json['ville_libre'] as String?,
      structureLibre: json['structure_libre'] as String?,
      contactChiffre: json['contact_chiffre'] as String?,
      contactSecondaireChiffre:
          json['contact_secondaire_chiffre'] as String?,
      statut: StatutDemande.values.firstWhere(
        (s) => s.value == json['statut'],
        orElse: () => StatutDemande.active,
      ),
      createdAt: DateTime.parse(json['created_at'] as String),
      expiresAt: DateTime.parse(json['expires_at'] as String),
    );
  }
}

// =====================================================================
// Notification — synchronisée avec public.notifications_envoyees
// =====================================================================
class NotificationSauve {
  final String id;
  final TypeNotification type;
  final String message;
  final DateTime createdAt;
  final bool lue;
  final String? demandeId;

  NotificationSauve({
    required this.id,
    required this.type,
    required this.message,
    required this.createdAt,
    this.lue = false,
    this.demandeId,
  });

  String get tempsEcoule {
    final diff = DateTime.now().difference(createdAt);
    if (diff.inMinutes < 60) return 'Il y a ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'Il y a ${diff.inHours}h';
    if (diff.inDays == 1) return 'Hier, ${_heure(createdAt)}';
    return _dateFormatee(createdAt);
  }

  static String _heure(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  static String _dateFormatee(DateTime dt) {
    const mois = [
      'jan.', 'fév.', 'mars', 'avr.', 'mai', 'juin',
      'juil.', 'août', 'sep.', 'oct.', 'nov.', 'déc.'
    ];
    return '${dt.day} ${mois[dt.month - 1]}';
  }

  /// Désérialisation depuis public.notifications_envoyees (schéma réel).
  factory NotificationSauve.fromBase(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? 'demande_compatible';
    final typeEnum = TypeNotification.fromValue(typeStr);

    // Générer un message lisible depuis le type (le backend ne stocke pas de message)
    final message = _messageDepuisType(typeEnum);

    return NotificationSauve(
      id: json['id'] as String,
      type: typeEnum,
      message: message,
      createdAt: DateTime.parse(json['created_at'] as String),
      lue: json['lu'] as bool? ?? false,
      demandeId: json['demande_id'] as String?,
    );
  }

  static String _messageDepuisType(TypeNotification type) {
    switch (type) {
      case TypeNotification.demandeCompatible:
        return 'Une demande de sang compatible avec votre profil a été publiée.';
      case TypeNotification.donConfirme:
        return 'Votre don a été confirmé. Merci pour votre générosité.';
      case TypeNotification.retourEligibilite:
        return 'Vous êtes à nouveau éligible pour donner du sang.';
      case TypeNotification.reponseRecue:
        return 'Un donneur a répondu à votre demande. Consultez ses coordonnées.';
      case TypeNotification.reponseEncouragement:
        return 'Merci d\'avoir répondu ! Contactez le demandeur rapidement.';
      case TypeNotification.donConfirmeDemandeur:
        return 'Votre demande a été honorée. Le don a été validé avec succès.';
      case TypeNotification.donEnregistreManuel:
        return 'Votre don a été enregistré manuellement. Merci !';
      case TypeNotification.suppressionDemandee:
        return 'Votre demande de suppression de compte a été prise en compte.';
      case TypeNotification.bienvenue:
        return 'Bienvenue sur SONGRE ! Votre compte est prêt.';
      case TypeNotification.mdpModifie:
        return 'Votre mot de passe a été modifié avec succès.';
    }
  }

  /// Sérialisation pour cache local (SharedPreferences).
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.value,
        'message': message,
        'created_at': createdAt.toIso8601String(),
        'lue': lue,
        'demande_id': demandeId,
      };

  /// Désérialisation depuis le cache local.
  factory NotificationSauve.fromJson(Map<String, dynamic> json) {
    final typeRaw = json['type'];
    TypeNotification typeEnum;
    if (typeRaw is String) {
      typeEnum = TypeNotification.fromValue(typeRaw);
    } else if (typeRaw is int) {
      // Rétrocompatibilité avec l'ancien format (index int)
      typeEnum = typeRaw < TypeNotification.values.length
          ? TypeNotification.values[typeRaw]
          : TypeNotification.demandeCompatible;
    } else {
      typeEnum = TypeNotification.demandeCompatible;
    }
    return NotificationSauve(
      id: json['id'] as String,
      type: typeEnum,
      message: json['message'] as String? ??
          NotificationSauve._messageDepuisType(typeEnum),
      createdAt: DateTime.parse(json['created_at'] as String),
      lue: json['lue'] as bool? ?? false,
      demandeId: json['demande_id'] as String?,
    );
  }
}

// =====================================================================
// Contre-indications médicales (liste fermée)
// =====================================================================
const List<String> contreIndicationsDisponibles = [
  'Grossesse ou accouchement récent (< 6 mois)',
  'Allaitement en cours',
  'Traitement anticoagulant',
  'Infection récente (< 2 semaines)',
  'Chirurgie récente (< 6 mois)',
  'Tatouage ou piercing récent (< 6 mois)',
  'Hypertension artérielle non contrôlée',
  'Diabète insulinodépendant',
  'Épilepsie',
  'Cancer traité (< 5 ans)',
  'Infection par le VIH',
  'Hépatite B ou C',
];

// =====================================================================
// Données de référence statiques — Villes et structures (Burkina)
// UTILISÉES EN FALLBACK UNIQUEMENT si le backend n'est pas disponible.
// La source de vérité est public.villes + public.structures_sanitaires.
// =====================================================================
const Map<String, List<String>> villesEtStructuresFallback = {
  'Ouagadougou': [
    'CHU Yalgado Ouédraogo',
    'CHU Bogodogo',
    'CMA Bogodogo',
    'CMA Paul VI',
    'Clinique Notre-Dame',
    'Clinique Laafi',
    'Hôpital de Schiphra',
    'Centre National de Transfusion Sanguine (CNTS)',
  ],
  'Bobo-Dioulasso': [
    'CHU Souro Sanou',
    'CMA Dô',
    'CMA Konsa',
    'Clinique de la Paix',
  ],
  'Koudougou': [
    'CHR Koudougou',
    'CMA Koudougou Centre',
  ],
  'Banfora': [
    'CHR Banfora',
    'CMA Banfora',
  ],
  'Ouahigouya': [
    'CHR Ouahigouya',
    'CMA Sékou Touré',
  ],
  'Kaya': [
    'CHR Kaya',
  ],
  'Dédougou': [
    'CHR Dédougou',
  ],
  "Fada N'Gourma": [
    "CHR Fada N'Gourma",
  ],
};
