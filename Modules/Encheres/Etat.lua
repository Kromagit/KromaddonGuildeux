--=============================================================================
-- KromaddonGuildeux - Modules/Encheres/Etat.lua
--
-- PUR : la machine a etats d'une enchere (§ 4 du cahier). Aucune frame,
-- aucune API WoW : tout ce qui vient du client (mon nom, qui est officier, qui
-- est dans le raid, GetItemInfo, l'heure) est INJECTE a la construction. Se
-- charge tel quel sous lua5.1.
--
-- Le principe : l'officier JUGE, le guildeux CONSTATE. Seules les lignes de
-- l'ANNONCEUR (l'officier qui a ouvert) changent l'etat ; les lignes brutes
-- des membres (« 150 », « all in ») ne font qu'entrer dans une file
-- d'attente, parce que l'acceptation de l'officier ne nomme pas le miseur
-- (§ 4.2). Un desaccord entre ce que l'officier dit et ce qu'on a calcule
-- s'AFFICHE, il ne se corrige jamais en silence.
--=============================================================================

local KG = KromaddonGuildeux
local E = {}
KG.Etat = E

E.ATTENTE_TTL = 5          -- une mise brute sans verdict apres 5 s est jetee
E.HISTORY_MAX = 20         -- encheres gardees en memoire, pour la soiree
E.SHOW_AFTER_CLOSE = 60    -- une enchere finie reste affichee 60 s
E.HM_ITEM_LEVELS = { [258] = true, [277] = true, [284] = true }   -- KC.HM_ITEM_LEVELS

E.OFF_PASSED = "Passé"
E.OFF_REMOVED = "Retiré par l'officier"
E.OFF_MARKER = "Rand annulé : enchère à marqueur"
E.RULE_MEMBER_ROLL = "Rand : c'est aux bids"    -- KC.BID_RULE_MEMBER_ROLL

--=============================================================================
-- Construction
--=============================================================================

-- opts : me (mon nom normalise), isOfficer(name), inGroup(name),
-- itemInfo(lien) -> ilvl, equippable (nil = pas en cache), now() -> secondes,
-- onEffect(kind, data) (optionnel : ce que les boutons ecoutent).
function E.New(opts)
    opts = opts or {}
    local S = {
        me = opts.me or "?",
        isOfficer = opts.isOfficer or function() return false end,
        inGroup = opts.inGroup or function() return true end,
        itemInfo = opts.itemInfo or function() return nil end,
        now = opts.now or function() return time() end,
        onEffect = opts.onEffect or function() end,
        current = nil,
        history = {},
        serial = 0,
        lastRoll = {},        -- [nom] = dernier /roll brut vu (pour habiller un rand refuse par regle)
        ms = {},              -- [nom] = texte de MS annonce dans la soiree
        lastAnnouncer = nil,
    }
    return setmetatable(S, { __index = E })
end

--=============================================================================
-- Circuit d'un objet (§ 4.3)
--=============================================================================

-- MARQUEUR se reconnait au TEXTE (KC:IsMarkerOnlyAuction), lien ou pas.
function E.IsMarkerText(value)
    if not value then return false end
    local text = string.lower(tostring(value))
    if string.find(text, "invincible", 1, true) then return true end
    if string.find(text, "morsure", 1, true) then return true end
    return false
end

E.SHADOWFROST_SHARD_ID = 50274      -- KC.SHADOWFROST_SHARD_ID : « sfs », se joue en NM (rands)
E.PRIMORDIAL_SARONITE_ID = 49908    -- KC.PRIMORDIAL_SARONITE_ID : va aux sacs, jamais aux encheres

-- Rend "MARQUEUR" | "SANG" | "HM" | "NM" | "AUTRE" | "?" ("?" = GetItemInfo
-- muet : on reessaie, on ne devine pas). Meme ordre que KC:ItemPolicy : SFS,
-- saronite, marqueur, puis « pas en cache », puis « non equipable » AVANT le
-- niveau (un 277 non equipable est « other », pas HM).
function E.Circuit(lien, sang, itemInfo)
    if sang then return "SANG" end
    local id = KG.ItemID(lien)
    if id == E.SHADOWFROST_SHARD_ID then return "NM" end
    if id == E.PRIMORDIAL_SARONITE_ID then return "AUTRE" end
    if E.IsMarkerText(lien) then return "MARQUEUR" end
    if not id then return "?" end
    local ilvl, equippable = itemInfo(lien)
    if ilvl == nil then return "?" end
    if not equippable then return "AUTRE" end
    if E.HM_ITEM_LEVELS[ilvl] then return "HM" end
    return "NM"
end

--=============================================================================
-- Lignes et lecture de l'etat
--=============================================================================

function E.BidActive(l) return l.bid ~= nil and (l.bidOff == nil or l.force) end
function E.RollActive(l) return l.roll ~= nil and (l.rollOff == nil or l.force) end
function E.LineActive(l) return E.BidActive(l) or E.RollActive(l) end

local function GetLine(enchere, name, create)
    local l = enchere.lignes[name]
    if not l and create then
        l = { nom = name, tier = nil, traces = {} }
        enchere.lignes[name] = l
        table.insert(enchere.ordre, name)
    end
    return l
end

-- Lignes actives d'un palier, triees comme chez l'officier (KC:GetSortedBids)
-- : montant decroissant, puis nom.
function E.SortedActive(enchere, field, tier)
    local list = {}
    for _, name in ipairs(enchere.ordre) do
        local l = enchere.lignes[name]
        if l and (l.tier or enchere.palierDefaut) == tier then
            if field == "bid" and E.BidActive(l) then table.insert(list, l) end
            if field == "roll" and E.RollActive(l) then table.insert(list, l) end
        end
    end
    table.sort(list, function(a, b)
        if a[field] == b[field] then return a.nom < b.nom end
        return a[field] > b[field]
    end)
    return list
end

-- Le vainqueur CALCULE (pour la surbrillance et « Mise Min ») : meilleure
-- mise active du bloc MS, sinon du bloc OS. Sur NM il n'y a pas de vainqueur
-- avant le departage / la cloture. Rend la ligne et son palier, ou nil.
function E.Winner(enchere)
    if not enchere then return nil end
    if enchere.circuit == "NM" or enchere.circuit == "SANG" then return nil end
    for _, tier in ipairs({ "ms", "os" }) do
        local top = E.SortedActive(enchere, "bid", tier)[1]
        if top then return top, tier end
    end
    return nil
end

-- Meilleure mise active du palier (pour « Mise Min »), 0 sinon.
function E.TopBid(enchere, tier)
    local top = enchere and E.SortedActive(enchere, "bid", tier)[1]
    return top and top.bid or 0
end

-- Palier applicable a un montant, et premier montant valide au-dessus
-- (recopies de Kromaddon : BidTierStep / NextValidBid).
function E.BidTierStep(amount)
    if amount <= 100 then return 25
    elseif amount <= 1000 then return 100
    elseif amount <= 10000 then return 1000
    else return 2000 end
end

function E.NextValidBid(current)
    if not current or current <= 0 then return 25 end
    return current + E.BidTierStep(current)
end

-- Les lignes dans l'ordre d'affichage : bloc MS actives (mise desc, rand
-- desc), bloc OS actives, puis un trait, puis les retirees. Chaque entree :
-- { line = l, block = "ms"|"os"|"off" }.
function E.Rows(enchere)
    local rows = {}
    if not enchere then return rows end
    local function cmp(a, b)
        local ab, bb = a.bid or -1, b.bid or -1
        if ab ~= bb then return ab > bb end
        local ar, br = a.roll or -1, b.roll or -1
        if ar ~= br then return ar > br end
        return a.nom < b.nom
    end
    for _, tier in ipairs({ "ms", "os" }) do
        local list = {}
        for _, name in ipairs(enchere.ordre) do
            local l = enchere.lignes[name]
            if l and E.LineActive(l) and (l.tier or enchere.palierDefaut) == tier then table.insert(list, l) end
        end
        table.sort(list, cmp)
        for _, l in ipairs(list) do table.insert(rows, { line = l, block = tier }) end
    end
    local off = {}
    for _, name in ipairs(enchere.ordre) do
        local l = enchere.lignes[name]
        if l and not E.LineActive(l) then table.insert(off, l) end
    end
    table.sort(off, cmp)
    for _, l in ipairs(off) do table.insert(rows, { line = l, block = "off" }) end
    return rows
end

function E.HasActive(enchere)
    for _, name in ipairs(enchere.ordre) do
        local l = enchere.lignes[name]
        if l and E.LineActive(l) then return true end
    end
    return false
end

--=============================================================================
-- Ouverture, archivage
--=============================================================================

function E:NewAuction(lien, sang, annonceur, t, partial)
    self.serial = self.serial + 1
    local e = {
        serial = self.serial,
        lien = lien,
        itemID = KG.ItemID(lien),
        ouvertA = t,
        annonceur = annonceur,
        circuit = "?",
        palierDefaut = "ms",
        statut = "ouverte",
        departage = nil,
        lignes = {},
        ordre = {},
        attente = {},
        tierWanted = {},      -- [nom] = palier demande par « ms »/« os » tape seul, avant toute mise (pendingTier chez l'officier)
        gagnant = nil,
        desaccord = nil,
        partial = partial or false,
        officierAncien = false,
        note = nil,
        marqueurVerrou = false,
        closedAt = nil,
    }
    e.circuit = E.Circuit(lien, sang, self.itemInfo)
    e.sang = sang and true or false
    return e
end

function E:Archive(e)
    if not e then return end
    table.insert(self.history, 1, e)
    while #self.history > E.HISTORY_MAX do table.remove(self.history) end
end

-- Une enchere encore ouverte (ni close ni annulee) qu'un nouveau debut
-- interrompt (§ 4.2, deux encheres de suite sans cloture propre : un autre
-- officier ouvre, ou le meme enchaine) doit quand meme emettre « close » --
-- sinon un Max auto VALIDE sur elle (Boutons.lua) survit tel quel a la
-- nouvelle enchere qui s'ouvre : ce ne serait plus « sa » consigne, ce serait
-- un achat non voulu sur un autre objet (constat de Kroma, 13/09 : « quand un
-- loot debute, les mises auto enregistrees doivent etre effacees »).
function E:InterruptCurrent(t)
    local e = self.current
    if not e or e.statut == "close" or e.statut == "annulee" then return end
    e.statut = "interrompue"
    e.closedAt = t
    self.onEffect("close", e)
end

function E:Open(lien, sang, annonceur, t)
    self:InterruptCurrent(t)
    self:Archive(self.current)
    self.current = self:NewAuction(lien, sang, annonceur, t, false)
    self.lastAnnouncer = annonceur
    self.onEffect("open", self.current)
    return self.current
end

-- « Rejoint en cours » (§ 5.6) : la premiere ligne de l'annonceur n'est pas
-- une ouverture. Etat cree avec lien inconnu, bandeau, boutons actifs.
function E:JoinInProgress(annonceur, t)
    self:InterruptCurrent(t)
    self:Archive(self.current)
    self.current = self:NewAuction(nil, false, annonceur, t, true)
    self.lastAnnouncer = annonceur
    self.onEffect("open", self.current)
    return self.current
end

function E:Close(statut, t)
    local e = self.current
    if not e then return end
    e.statut = statut
    e.closedAt = t
    e.attente = {}
    self.onEffect("close", e)
end

--=============================================================================
-- La file d'attente et l'association (§ 4.2)
--=============================================================================

function E:PurgeAttente(t)
    local e = self.current
    if not e then return end
    local kept = {}
    for _, a in ipairs(e.attente) do
        if t - a.t <= E.ATTENTE_TTL then table.insert(kept, a) end
    end
    e.attente = kept
end

-- Une ligne brute d'un MEMBRE du raid (§ 3, « ce que le joueur tape »).
function E:Demand(name, dem, t)
    local e = self.current
    if not e or not dem then return "ignoré : pas d'enchère" end
    if e.statut ~= "ouverte" and e.statut ~= "departage" then return "ignoré : enchère finie" end
    if not self.inGroup(name) then return "ignoré : hors raid" end
    self:PurgeAttente(t)
    if dem.kind == "bid" or dem.kind == "allin" then
        local l = e.lignes[name]
        local tier = dem.tier or e.tierWanted[name] or (l and l.tier) or e.palierDefaut
        e.tierWanted[name] = nil
        table.insert(e.attente, { name = name, amount = dem.amount, allin = (dem.kind == "allin"), tier = tier, t = t })
        return "mise en attente"
    end
    if dem.kind == "tag" then
        -- Avec une participation : l'officier confirme par « X is bidding for
        -- T », on attend son mot. Sans : il retient le palier pour la prochaine
        -- mise (pendingTier), on fait pareil.
        if not e.lignes[name] then e.tierWanted[name] = dem.tier end
        return "retag demandé"
    end
    return dem.kind
end

local function RemoveAttente(e, name)
    for i, a in ipairs(e.attente) do
        if a.name == name then table.remove(e.attente, i); return a end
    end
    return nil
end

-- L'acceptation se rattache a la plus ancienne entree de meme montant et
-- palier ; a defaut a la plus ancienne all-in du palier (le montant revele
-- alors le solde) ; a defaut a la plus ancienne tout court, marquee
-- incertaine. Rend name (ou "?"), incertain.
function E:Associate(e, amount, tier)
    for i, a in ipairs(e.attente) do
        if a.amount == amount and a.tier == tier then
            table.remove(e.attente, i)
            return a.name, false
        end
    end
    for i, a in ipairs(e.attente) do
        if a.allin and a.tier == tier then
            table.remove(e.attente, i)
            return a.name, false
        end
    end
    if e.attente[1] then
        local a = table.remove(e.attente, 1)
        return a.name, true
    end
    return "?", true
end

--=============================================================================
-- Les verdicts de l'annonceur (§ 4.3)
--=============================================================================

-- Verifie la reprise annoncee contre le vainqueur calcule ; pose
-- e.desaccord sinon. Jamais de correction en silence.
function E:CheckResume(e, resume)
    if not resume then return end
    if resume.kind == "none" then
        if E.HasActive(e) then
            e.desaccord = "l'officier dit « plus aucune enchère », le tableau en a encore"
        end
        return
    end
    local top = E.SortedActive(e, resume.kind, resume.tier)[1]
    if not top then
        e.desaccord = string.format("l'officier reprend à %d par %s, le tableau n'a rien en %s", resume.amount, resume.name, string.upper(resume.tier))
        return
    end
    if top.nom ~= resume.name or top[resume.kind] ~= resume.amount then
        e.desaccord = string.format("l'officier reprend à %d par %s, le tableau dit %d par %s",
            resume.amount, resume.name, top[resume.kind] or 0, top.nom)
    end
end

-- Un retrait explicite (passe, officier) remplace un motif de REGLE (« Bid :
-- c'est aux rands ») : chez l'officier RemoveBid pose « Passé » sur toute
-- participation qui existe, active ou hors regle. Un retrait explicite deja
-- pose, lui, ne bouge pas.
local function Explicit(off) return off == E.OFF_PASSED or off == E.OFF_REMOVED or off == E.OFF_MARKER end
local function Retire(l, motif)
    if l.bid ~= nil and not Explicit(l.bidOff) then l.bidOff = motif end
    if l.roll ~= nil and not Explicit(l.rollOff) then l.rollOff = motif end
    l.force = false
end

-- Un verdict (G.Parse). sender = qui l'a dit (normalise). Rend un texte pour
-- le journal /kg debug.
function E:Verdict(ev, sender, t)
    if not ev then return "ignoré" end
    local kind = ev.kind

    -- Ouverture : n'importe quel officier devient l'annonceur.
    if kind == "open" then
        if not self.isOfficer(sender) then return "ignoré : ouverture par un non-officier" end
        self:Open(ev.lien, ev.sang, sender, t)
        return "ouverture (" .. self.current.circuit .. ")"
    end
    -- Butin et MS : un officier, pas forcement l'annonceur.
    if kind == "loot" then
        if not self.isOfficer(sender) then return "ignoré : butin par un non-officier" end
        return "butin"
    end
    if kind == "ms" then
        if not self.isOfficer(sender) then return "ignoré : MS par un non-officier" end
        for _, en in ipairs(ev.entries) do self.ms[en.name] = en.text end
        return "MS"
    end

    local e = self.current
    if not e or e.statut == "close" or e.statut == "annulee" or e.statut == "interrompue" then
        -- Rejoint en cours : une ligne d'enchere d'un officier sans ouverture.
        if kind == "cancel" or kind == "nobody" or kind == "ranks_not_ready" then return "ignoré : rien d'ouvert" end
        if not self.isOfficer(sender) then return "ignoré : pas un officier" end
        if e and e.annonceur == sender and (kind == "victory" or kind == "victory_roll") and e.statut == "close" then
            return "ignoré : déjà close"
        end
        e = self:JoinInProgress(sender, t)
    end
    if sender ~= e.annonceur then return "ignoré : pas l'annonceur" end
    self:PurgeAttente(t)
    if e.circuit == "?" and e.lien then e.circuit = E.Circuit(e.lien, e.sang, self.itemInfo) end

    if kind == "cancel" then
        self:Close("annulee", t)
        return "annulée"
    end

    if kind == "accept" then
        local name, incertain = self:Associate(e, ev.amount, ev.tier)
        local l = GetLine(e, name, true)
        if l.bid ~= nil then table.insert(l.traces, { bid = l.bid, tier = l.tier, off = l.bidOff }) end
        l.bid, l.tier, l.bidOff, l.t, l.incertain = ev.amount, ev.tier, nil, t, incertain
        if e.circuit == "MARQUEUR" and not e.marqueurVerrou then
            e.marqueurVerrou = true
            for _, n in ipairs(e.ordre) do
                local o = e.lignes[n]
                if o.roll ~= nil and o.rollOff == nil then o.rollOff = E.OFF_MARKER end
            end
        end
        if name == self.me then self.onEffect("mine_accepted", { amount = ev.amount, tier = ev.tier }) end
        return "mise acceptée -> " .. name .. (incertain and " (incertain)" or "")
    end

    if kind == "refuse" then
        RemoveAttente(e, ev.name)
        if ev.name == self.me then self.onEffect("mine_refused", ev) end
        return "refus " .. ev.why .. " pour " .. ev.name
    end

    if kind == "refuse_rule" then
        local a = RemoveAttente(e, ev.name)
        local l = GetLine(e, ev.name, true)
        if ev.part == "bid" then
            l.bid = a and a.amount or l.bid or 0
            l.tier = (a and a.tier) or l.tier or e.palierDefaut
            l.bidOff = ev.motif
        else
            l.roll = self.lastRoll[ev.name] or l.roll or 0
            l.rollOff = ev.motif
        end
        l.t = l.t or t
        if ev.name == self.me then self.onEffect("mine_refused", ev) end
        return "hors jeu par règle : " .. ev.name
    end

    if kind == "marker_refused" then
        RemoveAttente(e, ev.name)
        if ev.name == self.me then self.onEffect("mine_refused", { why = "marker" }) end
        return "mise ignorée (marqueur) : " .. ev.name
    end

    if kind == "retag" then
        local l = GetLine(e, ev.name, true)
        l.tier = ev.tier
        return "palier " .. ev.tier .. " pour " .. ev.name
    end

    if kind == "roll" then
        local l = GetLine(e, ev.name, true)
        l.roll, l.tier, l.rollOff, l.t = ev.value, ev.tier, nil, l.t or t
        if e.marqueurVerrou then l.rollOff = E.OFF_MARKER end
        -- HM : un rand de lie sans PU n'est JAMAIS annonce « Roll N en T »
        -- (TryRoll sort sur l'ECHEC). Un « Roll » accepte en HM dit donc qu'un
        -- PU a rand dans ce palier : les rands de lies barres « c'est aux
        -- bids » redeviennent actifs chez l'officier, sans message (RuleBids
        -- se recalcule). On fait pareil.
        if e.circuit == "HM" then
            for _, n in ipairs(e.ordre) do
                local o = e.lignes[n]
                if o.rollOff == E.RULE_MEMBER_ROLL and (o.tier or e.palierDefaut) == ev.tier then o.rollOff = nil end
            end
        end
        if ev.name == self.me then self.onEffect("mine_rolled", ev) end
        return "rand " .. ev.value .. " pour " .. ev.name
    end

    if kind == "roll_refused" then
        return "rand refusé : " .. ev.name .. " (" .. ev.motif .. ")"
    end

    if kind == "pass" then
        local l = GetLine(e, ev.name, false)
        if l then Retire(l, E.OFF_PASSED) end
        RemoveAttente(e, ev.name)
        self:CheckResume(e, ev.resume)
        if ev.name == self.me then self.onEffect("mine_passed", ev) end
        return "passe : " .. ev.name
    end

    if kind == "pass_nothing" then
        if ev.name == self.me then self.onEffect("mine_nothing", ev) end
        return "rien à retirer : " .. ev.name
    end

    if kind == "removed" then
        local l = GetLine(e, ev.name, false)
        if l then Retire(l, E.OFF_REMOVED) end
        self:CheckResume(e, ev.resume)
        return "retiré par l'officier : " .. ev.name
    end

    if kind == "removed_anonymous" then
        e.officierAncien = true
        self:CheckResume(e, ev.resume)
        return "retrait sans nom (officier en version antérieure)"
    end

    if kind == "derogation" then
        local l = GetLine(e, ev.name, true)
        l.force = true
        return "dérogation : " .. ev.name
    end

    if kind == "tie_cancel" then
        e.statut = "ouverte"
        e.departage = nil
        return "départage annulé"
    end

    if kind == "tie" then
        if e.partial and not e.lien and ev.lien and ev.lien ~= "" then
            e.lien = ev.lien
            e.itemID = KG.ItemID(ev.lien)
            e.circuit = E.Circuit(ev.lien, false, self.itemInfo)
        end
        e.statut = "departage"
        if not e.departage or e.departage.tour ~= ev.round then
            e.departage = { tour = ev.round, noms = {}, ordre = {}, rands = {} }
        end
        for _, n in ipairs(ev.names) do
            if not e.departage.noms[n] then
                e.departage.noms[n] = true
                table.insert(e.departage.ordre, n)
            end
        end
        if e.departage.noms[self.me] then self.onEffect("tie_me", e.departage) else self.onEffect("tie_not_me", e.departage) end
        return "départage tour " .. ev.round
    end

    if kind == "tie_roll" then
        if e.departage then e.departage.rands[ev.name] = ev.value end
        return "départage : " .. ev.value .. " pour " .. ev.name
    end

    if kind == "tie_none" then
        return "départage : personne n'a rand"
    end

    if kind == "default_os" then
        e.palierDefaut = "os"
        self.onEffect("default_os", e)
        return "palier par défaut : OS"
    end

    if kind == "victory" or kind == "victory_roll" then
        if e.partial and not e.lien and ev.lien then
            e.lien = ev.lien
            e.itemID = KG.ItemID(ev.lien)
        end
        e.gagnant = { nom = ev.name, main = ev.main, prix = ev.price or 0, tier = ev.tier, rand = ev.value, attribution = ev.attribution }
        self:Close("close", t)
        if ev.name == self.me then self.onEffect("mine_won", e.gagnant) end
        return "victoire : " .. ev.name
    end

    if kind == "nobody" then
        self:Close("close", t)
        return "personne n'en veut"
    end

    if kind == "ranks_not_ready" then
        e.note = "rangs pas chargés chez l'officier : clôture reportée"
        return "clôture reportée"
    end

    return "ignoré : " .. tostring(kind)
end

-- Un /roll brut (CHAT_MSG_SYSTEM). Retenu par nom pour habiller un rand
-- refuse par regle ; l'officier reste le seul a le compter.
function E:RawRoll(name, value, lo, hi)
    if lo == 1 and hi == 100 then self.lastRoll[name] = value end
end

--=============================================================================
-- Tic : purge de la file, rangement d'une enchere finie
--=============================================================================

function E:Tick(t)
    local e = self.current
    if not e then return end
    self:PurgeAttente(t)
    if e.circuit == "?" and e.lien then e.circuit = E.Circuit(e.lien, e.sang, self.itemInfo) end
    if e.closedAt and (t - e.closedAt) >= E.SHOW_AFTER_CLOSE then
        self:Archive(e)
        self.current = nil
        self.onEffect("cleared", e)
    end
end

-- Libelle d'etat pour la ligne de statut du tableau.
function E.StatusText(e)
    if not e then return "aucune enchère" end
    if e.statut == "departage" then
        return string.format("départage (tour %d)", e.departage and e.departage.tour or 0)
    end
    if e.statut == "ouverte" then
        if e.palierDefaut == "os" then return "ouverte, OS par défaut" end
        return "ouverte"
    end
    if e.statut == "close" then return "close" end
    if e.statut == "annulee" then return "annulée" end
    if e.statut == "interrompue" then return "interrompue par une autre enchère" end
    return e.statut
end
