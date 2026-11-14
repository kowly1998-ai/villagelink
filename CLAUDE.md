# VillageLink — contexte du projet pour Claude

## En bref

VillageLink est une application web installable (PWA) pour les associations de ressortissants
qui financent le développement de leur village d'origine : membres, cotisations, finances
transparentes, projets, annonces, réunions et discussion.

- Le propriétaire, Alpha, n'est pas développeur et travaille uniquement depuis son téléphone.
  Claude écrit, vérifie et met en ligne le code.
- Répondre en français simple, sans jargon. À la fin de chaque changement, dire précisément
  quoi tester sur le téléphone.
- Version actuelle : **2.2.9** (design v2, suspension d'association, photo de couverture, nouvelle icône, export CSV, rapport annuel, feuille de présence, verrou par code).

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
| `app.js` | Toute l'application (environ 2 750 lignes) |
| `styles.css` | Styles du design v2 : jetons (`--color-primary`…), composants, version ordinateur. **Une seule couleur de marque (#1B3A8C), aucun dégradé, aucun flou.** Les anciens noms de variables (`--accent`, `--muted`…) restent comme alias |
| `manifest.webmanifest`, `icon*` | Installation sur l'écran d'accueil |
| `sw.js` | Service worker du mode hors ligne (réseau d'abord, copie de secours) |
| `confidentialite.html`, `conditions.html`, `legal.css` | Politique de confidentialité et conditions d'utilisation (exigées par Google et le Play Store) |
| `supabase/schema.sql` | Structure complète de la base, à jour (vérifiée le 12/11/2026, version 2.2.4 : 27 tables, 5 vues, 90 fonctions identiques à la base) : référence et secours |

## Organisation de `app.js`

Une seule fonction auto-exécutée (`'use strict'`), découpée en sections dans cet ordre :
Démarrage → Outils → Rôles et droits → Contexte d'une association → Routeur → Connexion →
Accueil sans association → Cadre d'une association → Écrans → Formulaires → Événements → Session.

- **Routage par hash** : `#/`, `#/bienvenue`, `#/mot-de-passe`, `#/a/<id>/<écran>`.
- **Liens courts** (partage WhatsApp, `shortLink`) : `#/r/<8 car.>` réunion, `#/v/<8 car.>` vote, `#/rapport/<8 car. de l'asso>?m=AAAA-MM`. `openShort` retrouve la ligne (la RLS filtre) puis ouvre l'adresse complète. Lien gardé pendant la connexion Google (`sessionStorage vl:next`).
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

- **27 tables** (au 12/11/2026), par thème :
  - association et membres : `associations`, `members`, `sections`, `member_categories`,
    `member_category_history`, `member_exemptions`, `join_attempts` (essais de code d'invitation) ;
  - argent : `transactions`, `fee_history` (montant de cotisation par mois de départ), `pay_numbers`
    (numéros Wave / Orange / Free), `payment_claims` (paiements déclarés par les membres),
    `expense_requests` (dépenses à valider), `collections` (solidarité, collectes) ;
  - projets : `projects`, `project_updates` ;
  - vie de l'association : `announcements`, `meetings`, `meeting_attendance`, `polls`, `poll_options`,
    `poll_votes`, `documents`, `messages` ;
  - système : `activity_log`, `push_subscriptions`, `subscription_requests`, `app_admins`.
- **Vues** (toutes en `security_invoker = true`) : `v_balances`, `v_member_paid`,
  `v_project_totals`, `v_category_totals`, `v_collection_totals`.
- **Fonctions** : 90 au 12/11/2026, liste complète dans `supabase/schema.sql`. Les plus utilisées par l'app :
  `create_association`, `join_association`, `review_join`, `regenerate_invite_code`, `my_memberships`,
  `member_contacts`, `reverse_transaction`, `declare_payment`, `confirm_payment_claim`, `hide_message`,
  `create_poll`, `cast_vote`, `close_poll`, `poll_results`, `server_now` (heure du serveur pour les retards)
  (votes : aucune écriture directe dans les tables).
- **Stockage** : buckets privés `proofs` (justificatifs de paiement, 5 Mo maximum), `docs`
  (documents de l'association, 10 Mo maximum), `voice` (messages vocaux, 3 Mo) et `covers` (photo de couverture, 2 Mo, réduite sur le téléphone avant l'envoi). Chemin : `<id association>/<fichier>`.
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
   Ajouter aussi le même SQL à la fin de `supabase/schema.sql`, qui doit rester la photo complète de la base.
2. **Cache** : augmenter le numéro `?v=` dans `index.html` pour chaque fichier modifié
   (aujourd'hui `styles.css?v=44`, `config.js?v=2`, `i18n-ff.js?v=1`, `receipt.js?v=3`, `app.js?v=64`, `projet.js?v=2` dans `projet.html`). Sinon les téléphones gardent
   l'ancienne version.
3. **Vérification** : `node tests/verification.cjs` (avec Playwright, préparé au démarrage de chaque session cloud par `.claude/hooks/session-start.sh`, qui met aussi la branche à jour depuis `main` ou prévient si elle a du travail non fusionné) contrôle l'écriture du code, les fichiers appelés et leur `?v=` (rouge si un fichier a changé depuis `main` sans nouveau numéro), l'absence de clé secrète dans le dépôt, les empreintes SRI, le lecteur de reçus et l'ouverture des pages à 360 px. GitHub Actions (`.github/workflows/verification.yml`) la lance sur chaque demande de fusion et chaque envoi vers `main` : ne pas fusionner si elle est rouge. Ajouter un contrôle quand une nouvelle fonction le mérite.
4. **Commit** sur `main`, en français : `Version X.Y : <ce qui change>`.
5. **Push** : GitHub Pages met en ligne en quelques minutes.
6. Dire à Alpha quoi tester sur son téléphone.
7. **Site de test** : `test.villagelinkafrica.com` (dépôt `kowly1998-ai/villagelink-test`, base Supabase de test `phkiovzhlmozpdoiigpf`). Toute nouveauté y passe d'abord ; `tests/affichage.cjs` (GitHub Actions) l'ouvre à 360 px avec une fausse base, et `tests/ecrans.cjs` ouvre les 39 écrans (président en clair et en sombre, membre) avec de longs noms et des montants au milliard : rouge si une erreur apparaît ou si un texte dépasse de l'écran ou de sa carte (`CAPTURES=1` garde une capture de chaque écran). Ajouter à sa liste `PRES` tout nouvel écran.

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
- v2.2 lot 2 : export CSV des membres et des opérations (Paramètres, `exportData`), rapport annuel (`V.rapportannuel`), feuille de présence à imprimer (`r/<id>/feuille`), verrou par code PIN sur le téléphone (`vl:pin`, PBKDF2, effacé à la déconnexion). Politique de sécurité : plus de `'unsafe-inline'` pour `style-src` (seulement `style-src-attr`). Aucune migration de base.
- v2.2.3 (audit) : montants avec point/virgule refusés ; monnaie bloquée dès qu'il y a des montants (`associations_guard`) ; historique des cotisations (`fee_history`, `member_category_history`, `feeOf(m, période)`) ; paiement réparti sur plusieurs mois (`spread`) ; téléphone et e-mail des membres réservés au bureau (colonnes `phone`/`email` non lisibles, fonction `member_contacts`) : **toute nouvelle colonne de `members` doit être ajoutée au `grant select (...)`** ; on ne confirme pas son propre paiement déclaré ; `loadCtx` en parallèle ; verrou par code avec compteur d'essais gardé (`vl:pin:try`).
- v2.2.4 (suite de l'audit) : B6, les retards de cotisation utilisent la date du serveur (`server_now`, écart gardé dans `clockSkew` si plus de 2 minutes) ; B9, documentation remise à jour ; B8, test d'affichage étendu.
- v2.2.5 (audit B7) : numéro de saisie `client_ref` sur `transactions` et `expense_requests` (index unique par association). Les formulaires `pay` et `op` le reçoivent (`refField()`) ; un doublon refusé (`isDup`) s'affiche « déjà enregistré ». Un paiement réparti sur plusieurs mois envoie `<numéro>:1`, `:2`… **Tout nouveau formulaire qui crée de l'argent doit porter `refField()`.**
- v2.2.6 (audit S9) : relecture des 44 fonctions à droits élevés, aucune faille. Alerte « Numéros de paiement changés » sur l'accueil du président et du vice-président quand quelqu'un d'autre modifie `pay_numbers` (60 jours, jusqu'à confirmation : `vl:paynum:<asso>`, action `paynum-ok`). Entrées / sorties du mois au milliard lisibles dans la carte de la caisse.
- v2.2.7 (audit A7) : onglets du bas en 16 px sur téléphone, chaque onglet prend la largeur de son nom (`grid-template-columns:repeat(5,auto)`), même graisse pour l'onglet actif ; sur moins de 360 px, pastille d'icône à 46 px et marges réduites. Vérifié à 320 et 360 px.
- v2.2.8 : la page publique d'un projet (`public_project`, `projet.js`) n'affiche plus le texte libre des dépenses, seulement catégorie (liste fixe), date et montant ; retiré côté base, pas seulement à l'écran. Les « nouvelles du chantier » restent publiques (le bureau est prévenu de ne pas y mettre de nom). **Tout nouveau champ ajouté à `public_project` devient visible par tout le monde.**
- v2.2.9 (test de résistance du 14/11/2026) : un mois déjà payé ne peut plus être encaissé une 2e fois, quelle que soit la voie (trigger `tx_month_paid_check`, cotisation calculée par `fee_of(membre, mois)` = même calcul que `feeOf`) ; `declare_payment` refuse un mois déjà payé ; la carte d'une déclaration prévient si le mois est déjà payé. Limite de 50 membres de la formule Village aussi à la réintégration et à l'acceptation d'une demande (`members_plan_cap`). **Si `feeOf` change dans app.js, changer `fee_of` dans la base.** Association de démo sur la base de test : « Association de démo — Village de Sintiou » (comptes `<rôle>@demo.villagelink.test`).
- **Mis de côté** : paiement mobile directement dans l'app (agrégateurs type SasPay).
- **Plus tard** : publication sur le Play Store.
- La colonne `associations.plan` existe déjà pour de futures offres.

## Agents « ux-researcher » et « legal-advisor »

- `.claude/agents/ux-researcher.md` et `.claude/agents/legal-advisor.md` (davila7/claude-code-templates, licence MIT, copiés tels quels le 14/11/2026). Ils lisent, cherchent sur le web et rédigent ; ils ne touchent ni au code ni à la base.
- **ux-researcher** : pilote avec Kansaghel (guides d'entretien, questionnaires courts à envoyer par WhatsApp, analyse des retours). Utilisateurs francophones, souvent peu à l'aise avec le numérique, sur téléphone d'entrée de gamme. Noms et numéros anonymisés dans les rapports.
- **legal-advisor** : `confidentialite.html`, `conditions.html`, exigences du Play Store. Partir d'abord de la **loi sénégalaise n° 2008-12 sur les données personnelles (CDP)**, puis des pays où vivent les membres (Guinée, France/UE pour le RGPD…). Toujours un brouillon à faire relire, jamais un avis d'avocat.

## Agent « database-architect »

- `.claude/agents/database-architect.md` (davila7/claude-code-templates, licence MIT, copié tel quel le 14/11/2026) : à utiliser pour tout changement ou relecture de la base.
- **Les règles de ce fichier passent avant les siennes** (identifiants uuid, triggers `*_check` pour l'appartenance à l'association, nommage des migrations, ajout à `schema.sql`).
- Ses tests (« Prove it ») se font sur la **base de test** `phkiovzhlmozpdoiigpf`, jamais sur la vraie base `ncghmfwfnzgdddnqgnnl`. Il ne fait que proposer et tester ; la mise en ligne suit « Mettre en ligne un changement ».

## Points d'attention connus

- **Espaces parasites dans la base** : le code des fonctions stocké dans Supabase commence par des
  centaines d'espaces sur chaque ligne. Sans effet sur le fonctionnement, mais illisible : lire
  plutôt `supabase/schema.sql`, où il est ré-aligné.
- **Empreintes d'intégrité (SRI)** sur `supabase-js` (`index.html`) et `tesseract.js` (`TESS_SRI` dans `receipt.js`). Si une version change, recalculer : `curl -sL <url> | openssl dgst -sha384 -binary | openssl base64 -A`, et changer `SHELL` dans `sw.js`. Le moteur interne de Tesseract (worker, wasm, langue) reste chargé sans empreinte.
- `app.js` est long : faire des modifications ciblées, ne jamais le réécrire en entier.
