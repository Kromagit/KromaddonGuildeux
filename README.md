# KromaddonGuildeux

KromaddonGuildeux affiche, de ton côté, le tableau des enchères que l'officier
tient dans Kromaddon : qui a misé quoi, en MS ou en OS, qui a rand, qui a passé,
et te donne trois boutons — **Mise Min**, **Rand**, **Passe** — qui tapent en
`/raid` exactement ce que tu aurais tapé toi-même. Il te montre aussi ton
solde de KA, ton main, ton marqueur Naxx/Uldu et ton historique, en demandant
à un officier par chuchotement (`?ka`), comme tu le ferais à la main.

Il ne fait **rien tout seul** : aucun envoi en `/raid` sans un clic de toi,
aucun chuchotement en combat, jamais plus d'un chuchotement toutes les 2 s.

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
  * **Mise Min** : premier clic, le bouton affiche « Miser N » (le montant
    minimum valide au-dessus de la meilleure mise de ton palier) ; second
    clic, il l'envoie. Le montant ne bouge pas entre les deux clics. Clic
    droit pour annuler. Le petit bouton **Auto / MS / OS** choisit le palier
    (Auto = celui de ta dernière mise, sinon celui par défaut de l'enchère).
  * **Rand** : un `/roll 1-100`. Grisé dès que ton rand est compté ; réactivé
    si un départage te nomme.
  * **Passe** : envoie « passe ». Si tu es vainqueur pour le moment, l'officier
    demande confirmation : le bouton devient « Confirmer le passe », reclique.
* **KA** — ton solde, ton main, ton marqueur et ton historique. « Actualiser »
  redemande (une fois par minute). Si tu lis « personnage non lié » : envoie
  `?ka #NomDeTonMain` à un officier, comme Kromaddon te le dit.
* **Options** — la liste des loots annoncés dans la soirée avec des cases à
  cocher ; « Ouvrir la fenêtre quand un butin est annoncé » et « Ouvrir sur
  l'enchère d'un loot coché » (la fenêtre s'ouvre alors sur Enchères et
  l'onglet clignote). Sans ces deux cases, la fenêtre ne s'ouvre jamais
  seule. Échelle, verrou de position, et les **noms des rangs officier** de la
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
