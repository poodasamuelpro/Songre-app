// =====================================================================
// MODÈLES DE DONNÉES — Application Sauve
// =====================================================================

// Énumérations (miroir des ENUMs PostgreSQL)
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

// =====================================================================
// Profil Donneur — données locales (sans données d'identité)
// =====================================================================
class ProfilDonneur {
  final String userId;
  final GroupeSanguin groupeSanguin;
  final int poids;
  final Genre genre;
  final String ville;
  final String? quartier;
  final List<String> contreIndications;
  final DateTime? dernierDonDate;
  final bool disponible;
  final DateTime createdAt;
  final DateTime updatedAt;

  ProfilDonneur({
    required this.userId,
    required this.groupeSanguin,
    required this.poids,
    required this.genre,
    required this.ville,
    this.quartier,
    this.contreIndications = const [],
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

  ProfilDonneur copyWith({
    GroupeSanguin? groupeSanguin,
    int? poids,
    Genre? genre,
    String? ville,
    String? quartier,
    List<String>? contreIndications,
    DateTime? dernierDonDate,
    bool? disponible,
  }) {
    return ProfilDonneur(
      userId: userId,
      groupeSanguin: groupeSanguin ?? this.groupeSanguin,
      poids: poids ?? this.poids,
      genre: genre ?? this.genre,
      ville: ville ?? this.ville,
      quartier: quartier ?? this.quartier,
      contreIndications: contreIndications ?? this.contreIndications,
      dernierDonDate: dernierDonDate ?? this.dernierDonDate,
      disponible: disponible ?? this.disponible,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'user_id': userId,
        'groupe_sanguin': groupeSanguin.label,
        'poids': poids,
        'genre': genre.value,
        'ville': ville,
        'quartier': quartier,
        'contre_indications': contreIndications,
        'dernier_don_date': dernierDonDate?.toIso8601String(),
        'disponible': disponible,
      };

  factory ProfilDonneur.fromJson(Map<String, dynamic> json) => ProfilDonneur(
        userId: json['user_id'] as String,
        groupeSanguin: GroupeSanguin.fromLabel(json['groupe_sanguin'] as String),
        poids: json['poids'] as int,
        genre: Genre.values.firstWhere(
          (g) => g.value == json['genre'],
          orElse: () => Genre.homme,
        ),
        ville: json['ville'] as String,
        quartier: json['quartier'] as String?,
        contreIndications: List<String>.from(json['contre_indications'] ?? []),
        dernierDonDate: json['dernier_don_date'] != null
            ? DateTime.parse(json['dernier_don_date'] as String)
            : null,
        disponible: json['disponible'] as bool? ?? true,
        createdAt: json['created_at'] != null
            ? DateTime.parse(json['created_at'] as String)
            : DateTime.now(),
        updatedAt: json['updated_at'] != null
            ? DateTime.parse(json['updated_at'] as String)
            : DateTime.now(),
      );
}

// =====================================================================
// Demande de sang — données visibles publiquement
// =====================================================================
class DemandeSang {
  final String id;
  final String auteurId;
  final GroupeSanguin groupeSanguinRecherche;
  final String ville;
  final String structureSanitaire;
  // Contact PRINCIPAL — obligatoire (§4.1 cahier des charges)
  // Stocké chiffré (AES-256) — jamais en clair dans le feed
  final String? contactChiffre;
  // Contact SECONDAIRE — optionnel (§4.1 cahier des charges)
  final String? contactSecondaireChiffre;
  final StatutDemande statut;
  final DateTime createdAt;
  final DateTime expiresAt;

  DemandeSang({
    required this.id,
    required this.auteurId,
    required this.groupeSanguinRecherche,
    required this.ville,
    required this.structureSanitaire,
    this.contactChiffre,
    this.contactSecondaireChiffre,
    this.statut = StatutDemande.active,
    required this.createdAt,
    required this.expiresAt,
  });

  bool get estActive => statut == StatutDemande.active && DateTime.now().isBefore(expiresAt);

  String get tempsEcoule {
    final diff = DateTime.now().difference(createdAt);
    if (diff.inMinutes < 60) return 'Il y a ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'Il y a ${diff.inHours}h';
    return 'Il y a ${diff.inDays}j';
  }

  // Vérifie si cette demande est compatible avec un profil donneur
  bool estCompatibleAvec(ProfilDonneur profil) {
    return _groupesCompatibles(groupeSanguinRecherche).contains(profil.groupeSanguin);
  }

  // Compatibilité universelle du don de sang
  static List<GroupeSanguin> _groupesCompatibles(GroupeSanguin recherche) {
    switch (recherche) {
      case GroupeSanguin.ominus:
        return [GroupeSanguin.ominus];
      case GroupeSanguin.oplus:
        return [GroupeSanguin.ominus, GroupeSanguin.oplus];
      case GroupeSanguin.aminus:
        return [GroupeSanguin.ominus, GroupeSanguin.aminus];
      case GroupeSanguin.aplus:
        return [GroupeSanguin.ominus, GroupeSanguin.oplus, GroupeSanguin.aminus, GroupeSanguin.aplus];
      case GroupeSanguin.bminus:
        return [GroupeSanguin.ominus, GroupeSanguin.bminus];
      case GroupeSanguin.bplus:
        return [GroupeSanguin.ominus, GroupeSanguin.oplus, GroupeSanguin.bminus, GroupeSanguin.bplus];
      case GroupeSanguin.abminus:
        return [GroupeSanguin.ominus, GroupeSanguin.aminus, GroupeSanguin.bminus, GroupeSanguin.abminus];
      case GroupeSanguin.abplus:
        return GroupeSanguin.values.toList();
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'auteur_id': auteurId,
        'groupe_sanguin_recherche': groupeSanguinRecherche.label,
        'ville': ville,
        'structure_sanitaire': structureSanitaire,
        'contact_chiffre': contactChiffre,
        'contact_secondaire_chiffre': contactSecondaireChiffre,
        'statut': statut.value,
        'created_at': createdAt.toIso8601String(),
        'expires_at': expiresAt.toIso8601String(),
      };

  factory DemandeSang.fromJson(Map<String, dynamic> json) => DemandeSang(
        id: json['id'] as String,
        auteurId: json['auteur_id'] as String,
        groupeSanguinRecherche: GroupeSanguin.fromLabel(
          json['groupe_sanguin_recherche'] as String,
        ),
        ville: json['ville'] as String,
        structureSanitaire: json['structure_sanitaire'] as String,
        contactChiffre: json['contact_chiffre'] as String?,
        contactSecondaireChiffre: json['contact_secondaire_chiffre'] as String?,
        statut: StatutDemande.values.firstWhere(
          (s) => s.value == json['statut'],
          orElse: () => StatutDemande.active,
        ),
        createdAt: DateTime.parse(json['created_at'] as String),
        expiresAt: DateTime.parse(json['expires_at'] as String),
      );
}

// =====================================================================
// Notification
// =====================================================================
enum TypeNotification {
  demandeCompatible,
  donConfirme,
  retourEligibilite,
}

class NotificationSauve {
  final String id;
  final TypeNotification type;
  final String message;
  final DateTime createdAt;
  final bool lue;

  NotificationSauve({
    required this.id,
    required this.type,
    required this.message,
    required this.createdAt,
    this.lue = false,
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
    const mois = ['jan.', 'fév.', 'mars', 'avr.', 'mai', 'juin', 'juil.', 'août', 'sep.', 'oct.', 'nov.', 'déc.'];
    return '${dt.day} ${mois[dt.month - 1]}';
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
// Données de référence — Villes et structures sanitaires (Burkina)
// =====================================================================
const Map<String, List<String>> villesEtStructures = {
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
  'Fada N\'Gourma': [
    'CHR Fada N\'Gourma',
  ],
};
