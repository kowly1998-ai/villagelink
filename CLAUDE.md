# VillageLink — contexte du projet pour Claude

## En bref

VillageLink est une application web installable (PWA) pour les associations de ressortissants
qui financent le développement de leur village d'origine : membres, cotisations, finances
transparentes, projets, annonces, réunions et discussion.

- Le propriétaire, Alpha, n'est pas développeur et travaille uniquement depuis son téléphone.
  Claude écrit, vérifie et met en ligne le code.
- Répondre en français simple, sans jargon. À la fin de chaque changement, dire précisément
  quoi tester sur le téléphone.
- Version actuelle : **2.0** (nouvelle interface « design v2 »).

## Stack

- HTML, CSS et JavaScript **sans compilation** : pas de npm, pas de framework, pas de build.
- **Supabase** (projet `ncghmfwfnzgdddnqgnnl`) : connexion email + mot de passe ou Google (client OAuth du projet Google Cloud `villagelink-512200`, `signInWithOAuth`), Postgres avec
  RLS, stockage de fichiers.
- `supabase-js` **2.45.4** chargé depuis jsDelivr (version figée).
- Hébergement : **GitHub Pages** depuis la branche `main`. Un push sur `main` = mise en ligne.
- Police **Inter** (Google Fonts). Thème **clair par défaut**, sombre ou automatique au choix dans « Mon profil » (`data-theme` sur `<html>`, réglage `vl:theme`).

## Fichiers

| Fichier | Rôle |
|---|---|
| `index.html` | Coquille de la page, politique de sécurité (CSP), chargement des scripts avec `?v=N` |
| `config.js` | URL et clé publique (anon) Supabase. Jamais la clé `service_role` |
| `app.js` | Toute l'application (environ 1 200 lignes) |
| `styles.css` | Styles du design v2 : jetons (`--color-primary`…), composants, version ordinateur. **Une seule couleur de marque (#1B3A8C), aucun dégradé, aucun flou.** Les anciens noms de variables (`--accent`, `--muted`…) restent comme alias |
| `manifest.webmanifest`, `icon*` | Installation sur l'écran d'accueil |
| `sw.js` | Service worker du mode hors ligne (réseau d'abord, copie de secours) |
| `confidentialite.html`, `conditions.html`, `legal.css` | Politique de confidentialité et conditions d'utilisation (exigées par Google et le Play Store) |
| `supabase/schema.sql` | Structure complète de la base à la v1.4 : référence et secours |

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
- **Navigation v2** : barre du bas à 5 onglets (Accueil, Membres, Cotisations, Caisse, Vie) ; sur ordinateur (≥ 900 px) barre latérale de 272 px avec sous-pages. Le modèle est `NAV` / `SUBS` dans `app.js` : une page se rattache à un onglet par sa clé. Caisse = Mouvements, Dépenses à valider, Projets, Solidarité, Transparence, Rapport, Journal. Vie = Annonces, Discussion, Réunions, Votes, Documents (écran `vie`). Le profil (`plus`) contient Paramètres, Abonnement, Mes associations, rappels, langue, apparence.
- **Accueil selon le rôle** (`V.home`) : président / vice-président (caisse en grand, dépenses à valider, où va l'argent), trésorier ou trésorier de section (tâches, retardataires, raccourcis, bouton « Encaisser » fixe), autres membres (leur situation de cotisation d'abord).
- Pas de temps réel Supabase.
- **Service worker** `sw.js` : réseau d'abord pour tout ; sans connexion, renvoie la dernière copie. Données : seulement les lectures `/rest/v1/` (GET) et les fonctions de lecture `my_memberships`, `poll_results` ; jamais les écritures. Cache des données vidé à la déconnexion (`clearOfflineData`). Changer `SHELL`/`DATA` dans `sw.js` pour forcer un nouveau cache.

## Données (Supabase, schéma `public`)

- **Tables** : `associations`, `members`, `transactions`, `projects`, `project_updates`,
  `announcements`, `meetings`, `meeting_attendance`, `polls`, `poll_options`, `poll_votes`,
  `documents`, `messages`, `activity_log`.
- **Vues** (toutes en `security_invoker = true`) : `v_balances`, `v_member_paid`,
  `v_project_totals`, `v_category_totals`.
- **Fonctions appelées par l'app** : `create_association`, `join_association`, `review_join`,
  `regenerate_invite_code`, `my_memberships`, `reverse_transaction`, `hide_message`,
  `create_poll`, `cast_vote`, `close_poll`, `poll_results` (votes : aucune écriture directe dans les tables).
- **Stockage** : buckets privés `proofs` (justificatifs de paiement, 5 Mo maximum) et `docs`
  (documents de l'association, 10 Mo maximum). Chemin : `<id association>/<fichier>`.
- **Définition exacte** de chaque table, fonction et règle : `supabase/schema.sql`. Le lire avant
  de toucher à la base.

## Rôles et droits

Rôles : `president`, `vice_president`, `secretaire`, `tresorier`, `projets`, `membre`.

| Droit (`CAN` dans `app.js`) | Rôles autorisés |
|---|---|
| Gérer les membres | président, vice-président, secrétaire, trésorier |
| Changer les rôles, paramètres | président |
| Encaisser des cotisations | trésorier, président, vice-président |
| Dépenser, annuler une opération | trésorier |
| Projets | président, vice-président, responsable des projets |
| Annonces, réunions, votes | président, vice-président, secrétaire |
| Documents (déposer, retirer) | président, vice-président, secrétaire, trésorier |

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

1. **Base de données** : écrire la migration dans
   `supabase/migrations/<AAAAMMJJHHMMSS>_vX_Y_description.sql`, puis l'appliquer avec
   `apply_migration` (même nom, même contenu, ex. `v1_5_...`). La base d'abord, le code ensuite.
   `supabase/schema.sql` reste la photo de départ (v1.4) ; les migrations s'ajoutent après.
2. **Cache** : augmenter le numéro `?v=` dans `index.html` pour chaque fichier modifié
   (aujourd'hui `styles.css?v=17`, `config.js?v=2`, `app.js?v=18`). Sinon les téléphones gardent
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

## Design v2 (2.0)

- Source : canevas « VillageLink v2 — Design system et maquettes » et guide de développement (jetons, composants, règles de rédaction, checklist de recette).
- Règles : fond clair, textes ≥ 16 px, cibles tactiles ≥ 48 px, statuts toujours avec un mot (et une icône), entrées en vert avec +, sorties en rouge avec −, animations ≤ 200 ms, pas de `backdrop-filter`.
- Ne pas réintroduire de dégradé, de verre dépoli ni de couleur de marque supplémentaire.

## Feuille de route

- **Fait** : v1.4 réunions (convocation, appel, compte rendu, partage WhatsApp) ; v1.4.1 bouton « Retirer de l'association » / « Réintégrer » sur la fiche membre (`active = false` : plus d'accès, plus de cotisation due, historique conservé) ; v1.4.2 sécurité (search_path, droits EXECUTE retirés sur les fonctions de trigger) ; v1.5 votes (secret ou à main levée, changement d'avis possible tant que le vote est ouvert).
- v1.6 documents (statuts, règlement, PV, rapports, reçus ; lecture par tous les membres).
- v1.7 rapport mensuel (écran `rapport?m=AAAA-MM`, PDF par l'impression du navigateur, résumé WhatsApp ; styles `@media print`).
- v1.8 notifications dans l'appli : la cloche (en-tête) compte les lignes de `activity_log` faites par les autres depuis la dernière visite (`localStorage vl:notif:<asso>`), écran `notifications`, pastille d'icône (`navigator.setAppBadge`). Les vraies notifications push viendront avec la version Play Store.
- v1.9 mode hors ligne (`sw.js`).
- v1.10 bouton « Continuer avec Google » sur l'écran de connexion (masquable avec `google: false` dans `config.js`).
- **Ensuite** : pilote réel avec Kansaghel, politique de confidentialité, page de présentation, Play Store.
- **Mis de côté** : paiement mobile directement dans l'app (agrégateurs type SasPay).
- **Plus tard** : publication sur le Play Store.
- La colonne `associations.plan` existe déjà pour de futures offres.

## Points d'attention connus

- **Espaces parasites dans la base** : le code des fonctions stocké dans Supabase commence par des
  centaines d'espaces sur chaque ligne. Sans effet sur le fonctionnement, mais illisible : lire
  plutôt `supabase/schema.sql`, où il est ré-aligné.
- **Pas de hash d'intégrité (SRI)** sur le script `supabase-js` chargé depuis jsDelivr. À ajouter.
- `app.js` est long : faire des modifications ciblées, ne jamais le réécrire en entier.
