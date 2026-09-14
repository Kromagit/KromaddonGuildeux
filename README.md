# KromaddonGuildeux

## [⬇ Télécharger KromaddonGuildeux — prêt à installer](https://github.com/Kromagit/KromaddonGuildeux/releases/latest/download/KromaddonGuildeux.zip)

Ce lien télécharge directement **KromaddonGuildeux.zip**, avec le dossier **KromaddonGuildeux** déjà nommé correctement. Il restera le même pour les prochaines versions.

**Ferme WoW, décompresse le ZIP et place le dossier `KromaddonGuildeux` dans `Interface\AddOns\`. Aucun renommage à faire.**

Pour installer l'addon, utilise le lien ci-dessus. Le bouton vert **Code → Download ZIP** télécharge l'archive du code avec le suffixe `-main`.

KromaddonGuildeux affiche, de ton côté, le tableau des enchères que l'officier
tient dans Kromaddon : qui a misé quoi, en MS ou en OS, qui a rand, qui a passé,
et te donne de quoi miser — un champ **Montant** et son bouton **Miser**, un bouton **Bid Min**, les
cases **MS / OS**, un champ **Max auto** (validé) pour une mise automatique, **All In**, **Rand**,
**Passe** — qui tapent en `/raid` exactement ce que tu aurais tapé toi-même. Il te montre aussi ton
solde de KA, ton main, ton marqueur Naxx/Uldu et ton historique. Ces informations
sont demandées à l'addon de l'officier sans encombrer le chat. À utiliser avec
**Kromaddon 3.9.17 ou une version ultérieure côté officier** pour bénéficier de l'historique actualisé.

Le **Max auto** ne démarre les mises qu'après ta validation. Après une mise
de ta part, l'addon peut aussi envoyer **all in** ou **passe** si tu es dépassé
et ne peux plus payer le minimum requis : le détail est expliqué ci-dessous.
Les demandes KA attendent la fin du combat et sont espacées de deux secondes.

Sous le titre, un rappel : Kromaddon contient un **bonus caché**, 5k KA à
gagner, et l'indice du moment.

## Installer

1. Ferme complètement World of Warcraft.
2. [Télécharge KromaddonGuildeux.zip](https://github.com/Kromagit/KromaddonGuildeux/releases/latest/download/KromaddonGuildeux.zip), puis décompresse son dossier `KromaddonGuildeux` dans `Interface\AddOns\` de ton
   client 3.3.5a (à côté des dossiers `Blizzard_*`).
3. Lance le jeu, vérifie dans la liste des addons (écran de sélection du
   personnage) que **KromaddonGuildeux** est coché.
4. En jeu : `/kg` ouvre et ferme la fenêtre. Échap la ferme aussi.

**Il ne faut PAS avoir Kromaddon en même temps** sur le même client :
Kromaddon est l'addon des officiers, il lit et écrit la base de la guilde.
Un membre n'en a pas l'usage, et les deux ensemble parleraient tous les deux
au chat.

## Les trois onglets

* **Enchères** — le tableau, reconstruit à partir de ce que l'officier
  annonce. Sous un trait rouge : les participations retirées (passé, retiré
  par l'officier, hors règle) avec leur motif. Une croix verte = l'officier a
  forcé la participation. Un `~` gris après un nom = l'addon n'est pas sûr de
  qui a misé ce montant (deux messages dans la même seconde). Un bandeau jaune
  = le tableau ne suit plus l'officier : **c'est l'officier qui a raison**,
  l'addon ne corrige rien tout seul.
  * **Montant** + **Miser** : le champ propose le minimum requis (au-dessus
    de la meilleure mise de ton palier), ou ton solde si seul un all in est
    encore possible. Il reste vide quand aucune offre n'est possible. Tu
    peux saisir un autre montant. Un clic sur Miser envoie « <montant> ms » ou
    « <montant> os ». Sous le minimum, rien ne part et l'addon te dit
    pourquoi.
  * **Bid Min** : un clic envoie le minimum requis de ton palier, calculé au
    moment du clic. Le bouton affiche « Bid 125 », par exemple. Si le minimum
    dépasse ton solde mais qu'un all in reste possible, il affiche
    « All in 9966 » et envoie un all in. Sinon, il est grisé.
  * **MS / OS** : deux cases, une seule cochée. MS au début de chaque
    enchère ; quand l'officier annonce « OS <objet> », OS se coche toute
    seule. Tu peux changer quand tu veux : le palier envoyé est toujours
    celui de la case cochée.
  * **Max auto** : le champ est pré-rempli de ton solde (le maximum naturel)
    mais il n'arme RIEN tant que tu ne l'as pas validé — **Entrée** ou le
    bouton **Valider**. Tape moins si tu veux ; plus que ton solde est ramené
    à ton solde. Une fois validé, l'addon mise pour toi — le minimum requis,
    dans ton palier, 1,5 s après chaque dépassement, jamais tant que tu es le
    meilleur de ton palier. Dès que le minimum requis dépasse ton max, il
    s'arrête, le dit dans le chat et fait clignoter l'onglet : **à toi de
    prendre le relais**. Le max ne survit pas à l'enchère : à la clôture, le
    champ remontre ton solde, désarmé. C'est aussi le cas lorsqu'un nouvel
    objet interrompt l'enchère précédente : le Max auto ne passe pas à l'objet
    suivant. Vide le champ et valide pour arrêter.
  * **All In** : tout ton solde dans ton palier, en un clic. Si ton solde est
    entre la meilleure mise et le minimum requis, c'est le « all in » de
    Kromaddon qui part (la seule mise acceptée à ce niveau) ; s'il ne dépasse
    pas la meilleure mise, rien ne part et l'addon te le dit.
  * **All in ou passe automatique** : si tu as une mise active, qu'on t'a
    dépassé dans ton palier et que le minimum requis dépasse ton solde,
    l'addon envoie « all in » si ton solde dépasse encore la meilleure mise.
    Sinon, il envoie « passe ». Il annonce l'action dans le chat et fait
    clignoter l'onglet. Une fois par enchère, jamais sans mise de ta part.
  * **Rand** : un `/roll 1-100`. Grisé dès que ton rand est compté ; réactivé
    si un départage te nomme.
  * **Passe** : envoie « passe ». Si tu es vainqueur pour le moment, l'officier
    demande confirmation : le bouton devient « Confirmer le passe », reclique.
    Il redevient « Passe » si tu es dépassé ou si une nouvelle mise de ta part
    est acceptée.
* **KA** — ton solde, ton main, ton marqueur et ton historique. « Actualiser »
  redemande les informations et les 20 derniers mouvements, avec un délai de
  **10 secondes** entre deux actualisations. Les mouvements reçus sont remis
  dans l'ordre du plus récent au plus ancien. Le dernier solde connu est
  conservé après déconnexion et signalé comme tel jusqu'à sa confirmation.
  Les officiers connus sont prioritaires ; un chef, assistant ou maître du
  butin dont le rang est inconnu peut aussi répondre par l'addon. En dernier
  recours, l'addon essaie le dernier officier qui t'a répondu pour ces échanges
  automatiques. Si personne ne peut répondre, il affiche « aucun officier
  joignable » ou attend la réponse.
  **Personnage non lié** : un formulaire recouvre les onglets. Saisis le
  **nom de ton main**, puis clique sur **Valider** ou appuie sur Entrée.
  La liaison nécessite un officier connecté : sinon, le formulaire affiche
  « aucun officier joignable » sans envoyer de chuchotement.
  La demande `?ka NomDuMain` et la réponse restent visibles dans le chat.
  Les onglets redeviennent accessibles une fois la liaison confirmée.
* **Options** — la liste des loots annoncés dans la soirée avec des cases à
  cocher ; « Ouvrir la fenêtre quand un butin est annoncé », « Ouvrir sur
  l'enchère d'un loot coché » et « Ouvrir pour toutes les enchères » (la
  fenêtre s'ouvre alors sur Enchères et l'onglet clignote). Sans ces cases, la
  fenêtre ne s'ouvre jamais seule. Le panneau permet aussi de régler
  l'échelle et de verrouiller la position. Les anciens réglages de masquage
  du chat et des rangs officier ont été retirés. Les demandes KA automatiques
  utilisent directement les addons ; les chuchotements texte restent visibles.
  La commande `/kg cache` vide le cache KA et `/kg debug` affiche le diagnostic.

## Si quelque chose cloche

`/kg debug` imprime d'abord l'état qui décide de tout (ta guilde, le roster,
les rangs officier, et pour chaque galonné du raid si l'addon le tient pour
officier — et pourquoi), puis les 50 dernières lignes lues avec ce que l'addon
en a compris (« ignoré (rang Membre) », « ligne d'officier NON RECONNUE »…).
C'est ce qu'il faut envoyer à Kroma avec la capture. `/kg roster` redemande le
roster de guilde au client.

Ce que l'addon ne peut pas savoir : le solde d'un joueur qu'un officier ne
lui a pas donné, et l'état d'une enchère commencée avant que tu sois dans le
raid (bandeau « enchère rejointe en cours »).

## Commandes

`/kg` — ouvre/ferme · `/kg options` · `/kg ka` · `/kg debug` · `/kg cache` · `/kg roster` · `/kg version`

## Mettre à jour

Ferme complètement WoW, [télécharge KromaddonGuildeux.zip](https://github.com/Kromagit/KromaddonGuildeux/releases/latest/download/KromaddonGuildeux.zip) et remplace les fichiers dans le dossier `KromaddonGuildeux` existant. Le chemin final doit être `Interface\AddOns\KromaddonGuildeux\KromaddonGuildeux.toc`. Relance ensuite le jeu.

Le téléchargement contient directement le dossier `KromaddonGuildeux`, sans renommage à faire. Les [anciennes versions](https://github.com/Kromagit/KromaddonGuildeux/releases) restent disponibles.
