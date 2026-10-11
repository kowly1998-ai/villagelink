# VillageLink — contexte du projet pour Claude

## En bref

VillageLink est une application web installable (PWA) pour les associations de ressortissants
qui financent le développement de leur village d'origine : membres, cotisations, finances
transparentes, projets, annonces, réunions et discussion.

- Le propriétaire, Alpha, n'est pas développeur et travaille uniquement depuis son téléphone.
  Claude écrit, vérifie et met en ligne le code.
- Répondre en français simple, sans jargon. À la fin de chaque changement, dire précisément
  quoi tester sur le téléphone.
- Version actuelle : **1.4** (réunions).

## Stack

- HTML, CSS et JavaScript **sans compilation** : pas de npm, pas de framework, pas de build.
- **Supabase** (projet `ncghmfwfnzgdddnqgnnl`) : connexion email + mot de passe, Postgres avec
  RLS, stockage de fichiers.
- `supabase-js` **2.45.4** chargé depuis jsDelivr (version figée).
- Hébergement : **GitHub Pages** depuis la branche `main`. Un push sur `main` = mise en ligne.
- Police Outfit (Google Fonts). Thème clair par défaut, sombre ou automatique au choix.

## Fichiers

| Fichier | Rôle |
|---|---|
| `index.html` | Coquille de la page, politique de sécurité (CSP), chargement des scripts avec `?v=N` |
| `config.js` | URL et clé publique (anon) Supabase. Jamais la clé `service_role` |
| `app.js` | Toute l'application (environ 1 200 lignes) |
| `styles.css` | Styles, variables de thème |
| `manifest.webmanifest`, `icon*` | Installation sur l'écran d'accueil |

## Organisation de `app.js`

Une seule fonction auto-exécutée (`'use strict'`), découpée en sections dans cet ordre :
Démarrage → Outils → Rôles et droits → Contexte d'une association → Routeur → Connexion →
Accueil sans association → Cadre d'une association → Écrans → Formulaires → Événements → Session.

- **Routage par hash** : `#/`, `#/bienvenue`, `#/mot-de-passe`, `#/a/<id>/<écran>`.
- **Écrans** : objet `V` (`home`, `membres`/`m`, `cotisations`, `encaisser`, `finances`,
  `operation`/`op`, `transparence`, `projets`/`p`, `annonces`, `reunions`/`r`, `discussion`,
  `journal`, `plus`, `parametres`). Code à lancer après l'affichage : `AFTER[écran]`.
- **Formulaires** : attribut `data-form="…"`, traités par l'objet `FORMS`.
  **Boutons d'action** : attribut `data-act="…"`.
- **Contexte** : `loadCtx(id)` charge l'association, les membres, les paiements et les soldes
  dans `S.ctx`. Rechargé si les données ont plus de 15 secondes.
- Barre du bas : Accueil, Membres, Cotisations, Projets, Plus.
- Pas de temps réel Supabase et pas de service worker pour l'instant.

## Données (Supabase, schéma `public`)

- **Tables** : `associations`, `members`, `transactions`, `projects`, `project_updates`,
  `announcements`, `meetings`, `meeting_attendance`, `messages`, `activity_log`.
- **Vues** (toutes en `security_invoker = true`) : `v_balances`, `v_member_paid`,
  `v_project_totals`, `v_category_totals`.
- **Fonctions appelées par l'app** : `create_association`, `join_association`, `review_join`,
  `regenerate_invite_code`, `my_memberships`, `reverse_transaction`, `hide_message`.
- **Stockage** : bucket privé `proofs` (justificatifs de paiement, 5 Mo maximum).

## Rôles et droits

Rôles : `president`, `vice_president`, `secretaire`, `tresorier`, `projets`, `membre`.

| Droit (`CAN` dans `app.js`) | Rôles autorisés |
|---|---|
| Gérer les membres | président, vice-président, secrétaire, trésorier |
| Changer les rôles, paramètres | président |
| Encaisser des cotisations | trésorier, président, vice-président |
| Dépenser, annuler une opération | trésorier |
| Projets | président, vice-président, responsable des projets |
| Annonces, réunions | président, vice-président, secrétaire |

## Règles de sécurité — non négociables

1. **La base décide.** Chaque droit est vérifié par la RLS et les triggers `*_guard` / `*_check`.
   `can()` dans `app.js` ne fait que cacher des boutons. Un changement de droit se fait dans la
   base **d'abord**, puis dans `CAN`.
2. Toute nouvelle table : RLS activée et politiques limitées aux membres de l'association
   (`is_member`, `has_role`).
3. Fonctions `security definer` : toujours `set search_path = public`, et vérifier l'appartenance
   ou le rôle à l'intérieur de la fonction.
4. Toute nouvelle vue : `with (security_invoker = true)`.
5. **Les opérations financières sont définitives** (trigger `tx_no_update`) : jamais de UPDATE ni
   de DELETE sur `transactions`. Une erreur se corrige par contre-écriture avec
   `reverse_transaction`.
6. `activity_log` est en ajout seul (trigger `log_no_update`).
7. Tout texte venant d'un utilisateur ou de la base passe par `esc()` avant `innerHTML`.
8. Tout nouveau domaine externe doit être ajouté à la CSP de `index.html`, sinon il est bloqué.
9. Le dépôt est **public** : aucune clé `service_role`, mot de passe ou jeton dedans.

## Mettre en ligne un changement

1. **Base de données** : migration nommée avec `apply_migration`, au format `vX_Y_description`
   (ex. `v1_4_reunions`). La base d'abord, le code ensuite.
2. **Cache** : augmenter le numéro `?v=` dans `index.html` pour chaque fichier modifié
   (aujourd'hui `styles.css?v=9`, `config.js?v=2`, `app.js?v=9`). Sinon les téléphones gardent
   l'ancienne version.
3. **Commit** sur `main`, en français : `Version X.Y : <ce qui change>`.
4. **Push** : GitHub Pages met en ligne en quelques minutes.
5. Dire à Alpha quoi tester sur son téléphone.

## Conventions produit

- Interface 100 % en français, phrases courtes. Utilisateurs non techniciens, souvent sur
  téléphone d'entrée de gamme avec une connexion lente.
- Mobile d'abord. Partage par WhatsApp (`waShare`, `waTo`).
- Montants entiers, format `fr-FR`, devise de l'association (FCFA par défaut ; aussi GNF, EUR,
  USD, XAF, CAD, GBP).
- Paiements saisis à la main avec leur mode : Espèces, Wave, Orange Money, Free Money,
  MTN Mobile Money, Virement, Autre.
- Cotisation mensuelle : `fee_amount`, `fee_due_day`, `dues_start`. Le calcul des retards est
  dans `dues()`.

## Feuille de route

- **Fait** : v1.4 réunions (convocation, appel, compte rendu, partage WhatsApp).
- **Mis de côté** : paiement mobile directement dans l'app (agrégateurs type SasPay).
- **Plus tard** : publication sur le Play Store.
- La colonne `associations.plan` existe déjà pour de futures offres.

## Points d'attention connus

- **Schéma non versionné** : seules 2 migrations sont enregistrées (`v1_3_2_vice_president_rights`,
  `v1_4_reunions`). La base d'origine a été créée avant. L'en-tête de `app.js` cite
  `supabase/schema.sql`, qui n'existe pas dans le dépôt. À exporter.
- **Pas de hash d'intégrité (SRI)** sur le script `supabase-js` chargé depuis jsDelivr. À ajouter.
- `app.js` est long : faire des modifications ciblées, ne jamais le réécrire en entier.
