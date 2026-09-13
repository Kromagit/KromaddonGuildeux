# KromaddonGuildeux

KromaddonGuildeux affiche, de ton côté, le tableau des enchères que l'officier
tient dans Kromaddon : qui a misé quoi, en MS ou en OS, qui a rand, qui a passé,
et te donne de quoi miser — un champ **Montant** et son bouton **Miser**, un bouton **Bid Min**, les
cases **MS / OS**, un champ **Max auto** (validé) pour une mise automatique, **All In**, **Rand**,
**Passe** — qui tapent en `/raid` exactement ce que tu aurais tapé toi-même. Il te montre aussi ton
solde de KA, ton main, ton marqueur Naxx/Uldu et ton historique, en demandant
à un officier par chuchotement (`?ka`), comme tu le ferais à la main.

Il ne fait **rien tout seul** : aucun envoi en `/raid` sans un geste de toi
(un clic, ou un **Max** que tu as validé — la mise automatique est ta consigne,
bornée par ton chiffre), aucun chuchotement en combat, jamais plus d'un
chuchotement toutes les 2 s.

Sous le titre, un rappel : Kromaddon contient un **bonus caché**, 5k KA à
gagner, et l'indice du moment.

## Installer

1. Ferme complètement World of Warcraft.
2. Télécharge le ZIP de la [dernière version](https://github.com/Kromagit/KromaddonGuildeux/releases/latest), puis décompresse son dossier `KromaddonGuildeux` dans `Interface\AddOns\` de ton
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
    de la meilleure mise de ton palier) tant que tu n'y as rien tapé ; tu
    peux mettre plus. Un clic sur Miser envoie « <montant> ms » ou
    « <montant> os ». Sous le minimum, rien ne part et l'addon te dit
    pourquoi.
  * **Bid Min** : un clic, le minimum requis de ton palier part tout de
    suite (le bouton affiche le montant : « Bid 125 »). Même chose que taper
    ce chiffre dans Montant puis Miser, en un geste.
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
    champ remontre ton solde, désarmé — pas d'achat automatique sur l'objet
    suivant. Vide le champ et valide pour arrêter.
  * **All In** : tout ton solde dans ton palier, en un clic. Si ton solde est
    entre la meilleure mise et le minimum requis, c'est le « all in » de
    Kromaddon qui part (la seule mise acceptée à ce niveau) ; s'il ne dépasse
    pas la meilleure mise, rien ne part et l'addon te le dit.
  * **Passe automatique** : si tu as misé, qu'on t'a dépassé et que le
    minimum requis dépasse ton solde, tu ne peux plus suivre — l'addon envoie
    « passe » pour toi, le dit et fait clignoter l'onglet. Une fois par
    enchère, et jamais si tu n'as pas misé.
  * **Rand** : un `/roll 1-100`. Grisé dès que ton rand est compté ; réactivé
    si un départage te nomme.
  * **Passe** : envoie « passe ». Si tu es vainqueur pour le moment, l'officier
    demande confirmation : le bouton devient « Confirmer le passe », reclique.
* **KA** — ton solde, ton main, ton marqueur et ton historique. « Actualiser »
  redemande (une fois par minute). Si tu lis « personnage non lié » : envoie
  `?ka #NomDeTonMain` à un officier, comme Kromaddon te le dit. « Aucun
  officier joignable » : aucun officier de guilde connecté — dans un raid mené
  par un membre, l'addon n'écrit à personne (le chef de raid n'a pas
  Kromaddon), il attend qu'un officier se connecte.
* **Options** — la liste des loots annoncés dans la soirée avec des cases à
  cocher ; « Ouvrir la fenêtre quand un butin est annoncé », « Ouvrir sur
  l'enchère d'un loot coché » et « Ouvrir pour toutes les enchères » (la
  fenêtre s'ouvre alors sur Enchères et l'onglet clignote). Sans ces cases, la
  fenêtre ne s'ouvre jamais seule. « Masquer mes ?ka et leurs réponses dans le
  chat » (cochée par défaut) : les chuchotements que l'addon envoie et les
  réponses qu'il attend n'encombrent pas ton chat — ce que tu tapes toi-même,
  les « Tu reçois N KA » et les rappels restent visibles. Échelle, verrou de position, et les **noms des rangs officier** de la
  guilde (c'est ce qui dit à l'addon qui est officier : les rangs viennent du
  roster, jamais d'un message). Tant que le roster n'est pas lu — ou si tu
  n'es pas dans la guilde — le chef de raid, ses assistants et le maître du
  butin font foi.

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

`/kg` — ouvre/ferme · `/kg options` · `/kg ka` · `/kg debug` · `/kg roster` · `/kg version`

## Mettre à jour

Ferme complètement WoW, télécharge le ZIP de la dernière version et remplace les fichiers dans le dossier KromaddonGuildeux existant. Le chemin final doit être Interface\AddOns\KromaddonGuildeux\KromaddonGuildeux.toc. Relance ensuite le jeu.

Avec le bouton Code → Download ZIP de GitHub, renomme le dossier KromaddonGuildeux-main en KromaddonGuildeux avant de le placer dans AddOns. Le ZIP proposé dans Releases contient déjà le bon nom de dossier.
