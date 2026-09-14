--=============================================================================
-- KromaddonGuildeux - Modules/KA/KA.lua
--
-- La discipline « ?ka » (§ 6) : mon propre « ?ka » d'abord, jamais un
-- « ?ka Nom » avant sa reponse ; un officier elu ; une reponse par nom et par
-- soiree ; un chuchotement toutes les 2 s, jamais en combat, dix par enchere
-- au plus ; mon historique une fois puis au fil de l'eau. Et l'onglet KA.
--
-- LE PIEGE (§ 6.1) : « ?ka <Nom> » envoye par un personnage que Kromaddon ne
-- connait pas n'est pas une consultation, c'est une DEMANDE DE LIAISON vers
-- <Nom> (HandleKCWhisper, branche « personnage inconnu ») : le guildeux se
-- retrouverait lie au premier rival de son tableau, et un BroadcastLink
-- partirait chez tous les officiers. D'ou la porte : aucun « ?ka Nom » ne
-- part tant que la reponse a mon « ?ka » seul n'a pas dit que je suis connu.
--
-- La logique est pure (KA.New) et testee dans tests/ka_cache.lua ; les
-- frames sont construites plus bas, en jeu seulement.
--=============================================================================

local KG = KromaddonGuildeux
local KA = {}
KG.RegisterModule("KA", KA)

KA.LOOKUP_GAP = 2            -- secondes entre deux « ?ka Nom »
KA.LOOKUPS_PER_AUCTION = 10  -- jamais plus par enchere
KA.CACHE_TTL = 6 * 3600      -- une reponse par nom et par soiree
KA.REFRESH_GAP = 10          -- « Actualiser » : un toutes les 10 s (14/09, etait 60)
KA.ASK_TIMEOUT = 20          -- sans reponse a mon « ?ka » : on reessaie plus tard
KA.HISTORY_MAX = 200

--=============================================================================
-- Logique pure
--=============================================================================

-- opts : me, sendAddon(target, text), now(), isOfficer(name), onlineOfficers()
-- -> liste de noms connectes et officiers, officerKnown(name) -> true si son
-- rang de guilde est connu (0.5.8 : un galon de rang inconnu est elu apres
-- les officiers connus), raidMembers() -> set, raidLeader(),
-- masterLooter(), inCombat(), getAuction() -> l'enchere courante ou nil,
-- db (KromaddonGuildeuxDB), debug(text), onChange().
--
-- sendAddon (13/09, brief-kg-canal-addon-13-09.md) : mon ?ka, mes ?ka Nom et
-- mon ?ka 20 logs partent par SendAddonMessage (canal KG.ADDON_PREFIX), plus
-- par chuchotement texte -- AUCUN REPLI (choix explicite de Kroma). Les
-- REPONSES, elles, arrivent par les deux points d'entree possibles (OnWhisper
-- pour un Kromaddon pas encore a jour ou un ?ka tape a la main, OnAddonMessage
-- pour un Kromaddon a jour) : meme grammaire, meme HandleReply, seul le
-- transport CHANGE cote envoi.
function KA.New(opts)
    opts = opts or {}
    local L = {
        me = opts.me or "?",
        sendAddon = opts.sendAddon or function() end,
        whisper = opts.whisper or function() end,   -- chuchotement TEXTE, visible : seulement « ?ka <Main> » (liaison)
        now = opts.now or function() return time() end,
        isOfficer = opts.isOfficer or function() return false end,
        onlineOfficers = opts.onlineOfficers or function() return {} end,
        officerKnown = opts.officerKnown or function() return true end,
        raidMembers = opts.raidMembers or function() return {} end,
        raidLeader = opts.raidLeader or function() return nil end,
        masterLooter = opts.masterLooter or function() return nil end,
        inCombat = opts.inCombat or function() return false end,
        getAuction = opts.getAuction or function() return nil end,
        db = opts.db or { historique = {}, logsDemandes = {} },
        debug = opts.debug or function() end,
        onChange = opts.onChange or function() end,
        selfState = "idle",     -- idle | asked | known | unlinked | notsynced | noofficer
        selfInfo = nil,         -- { solde=, main=, marker= }
        askedAt = nil,
        askedTo = nil,
        askedOnce = false,
        lastRefreshAt = nil,
        exhausted = {},         -- officiers qui ont dit « pas encore synchronisé »
        silent = {},            -- officiers qui n'ont pas repondu a mon KA (ASK_TIMEOUT) : les autres d'abord
        logsAskedAt = nil,      -- dernier KA:LOGS:20 (une fois par REFRESH_GAP, plus « une fois par personnage »)
        logsWanted = false,     -- « Actualiser » : redemander l'historique des que mon solde est revenu
        logBatch = nil,         -- les lignes du KA:LOGS en cours, dans l'ordre de Kromaddon (le plus recent d'abord)
        linkFeedback = nil,     -- la reponse de l'officier a « ?ka <Main> » (porte des non lies)
        cache = {},             -- [nom] = { solde=, main=, t= } ou { unknown=true, t= }
        pending = {},           -- noms a demander, dans l'ordre
        awaiting = {},          -- [nom] = heure de la demande
        lastLookupAt = 0,
        lookupsThisAuction = 0,
        auctionSerial = nil,
        linkedAlarm = nil,
    }
    L.db.historique = L.db.historique or {}
    L.db.logsDemandes = L.db.logsDemandes or {}
    local self = setmetatable(L, { __index = KA })
    self:RestoreSelfInfo()
    return self
end

-- Le solde que je connais SURVIT a la deconnexion (13/09). Avant, il ne
-- vivait qu'en memoire : a chaque connexion tout repartait de « inconnu »
-- jusqu'a la reponse d'un officier a mon « ?ka » - et quand elle ne venait
-- pas (test de Kroma, Kromalchib, 13/09 : « Max auto vide », « il passe pas
-- seul »), tout ce qui depend du solde etait mort : Max auto, All In, le
-- passe automatique. Le dernier solde connu est range dans la base sous MON
-- nom, repris a la connexion tant qu'il a moins de KA.SELF_TTL, et marque
-- `stale` jusqu'a ce qu'un officier le confirme (?ka) ou le corrige (un
-- chuchotement de credit/debit porte le solde, un refus « T'as N » aussi).
KA.SELF_TTL = 14 * 24 * 3600

function KA:PersistSelfInfo()
    if not self.selfInfo then return end
    self.db.selfInfo = {
        name = self.me, solde = self.selfInfo.solde, main = self.selfInfo.main,
        marker = self.selfInfo.marker, t = self.now(),
    }
end

function KA:RestoreSelfInfo()
    local d = self.db.selfInfo
    if type(d) ~= "table" or d.name ~= self.me or type(d.solde) ~= "number" then return false end
    if not d.t or self.now() - d.t > KA.SELF_TTL then return false end
    self.selfInfo = { solde = d.solde, main = d.main, marker = d.marker, t = d.t, stale = true }
    self.selfState = "known"
    return true
end

-- Un solde appris d'un officier autrement que par « ?ka » : le chuchotement
-- d'un mouvement (« ... (Solde : N KA) », Kromaddon 3.9.12) ou un refus
-- (« T'as N. C'est pas assez »). Il remplace ce qu'on croyait, et rend le
-- solde « connu » s'il ne l'etait pas encore - le main, lui, n'est connu
-- que par « ?ka » et reste ce qu'il etait.
function KA:LearnSelfBalance(solde)
    if type(solde) ~= "number" then return false end
    if self.selfInfo then
        self.selfInfo.solde = solde
        self.selfInfo.t = self.now()
        self.selfInfo.stale = nil
    else
        self.selfInfo = { solde = solde, main = nil, marker = nil, t = self.now() }
    end
    if self.selfState ~= "asked" then self.selfState = "known" end
    self:PersistSelfInfo()
    self.onChange()
    return true
end

--=============================================================================
-- L'officier elu (§ 6.2)
--=============================================================================

-- En raid : les membres du raid qui sont officiers et connectes, chef de
-- raid d'abord, puis maitre du butin, puis alphabetique. Hors raid : les
-- officiers connectes de la guilde. Un galon de rang de guilde inconnu
-- (0.5.8 : autre guilde, roster muet) passe apres TOUS les officiers de rang
-- connu, meme hors raid (un officier de ma guilde a surement Kromaddon et ma
-- base ; un chef de raid inconnu, peut-etre pas) ; ceux qui n'ont pas
-- repondu (silent) apres tous les autres, ceux qui ont dit « pas encore
-- synchronisé » en dernier.
-- requireOnline (14/09 soir, correctif du repli ci-dessous) : true pour un
-- appelant qui va CHUCHOTER pour de vrai (KA:LinkMain -- le seul chemin
-- visible). Dans ce cas pas de repli sur db.lastOfficer : un chuchotement
-- texte a quelqu'un de deconnecte, contrairement a un message d'addon, EST
-- visible (dans mon propre chat) et ne coute pas rien -- il part pour rien,
-- vers quelqu'un qui ne repondra jamais. AskSelf/Pump/RequestLogs, qui
-- n'envoient que par le canal d'addon, continuent d'appeler Elect() sans
-- argument et gardent le repli.
function KA:Elect(requireOnline)
    local online = {}
    for _, n in ipairs(self.onlineOfficers()) do if n ~= self.me then online[n] = true end end
    local raid = self.raidMembers()
    local rl, ml = self.raidLeader(), self.masterLooter()
    local function Rank(n)
        -- Les non epuises d'abord ; dans le raid avant la guilde ; chef de
        -- raid, maitre du butin, puis alphabetique.
        local r = 0
        if self.exhausted[n] then r = r + 100 end
        if self.silent[n] then r = r + 50 end
        if not raid[n] then r = r + 10 end
        if not self.officerKnown(n) then r = r + 15 end   -- apres tous les officiers de rang connu, meme hors raid
        if n == rl then r = r + 0 elseif n == ml then r = r + 1 else r = r + 2 end
        return r
    end
    local candidates = {}
    for n in pairs(online) do table.insert(candidates, n) end
    table.sort(candidates, function(a, b)
        local ra, rb = Rank(a), Rank(b)
        if ra ~= rb then return ra < rb end
        return a < b
    end)
    if candidates[1] then return candidates[1] end
    if requireOnline then return nil end
    -- Personne (hors raid, ou raid sans galon connu) : le dernier officier qui
    -- m'a repondu (14/09, Kroma : « quand j'actualise j'ai toujours "aucun
    -- officier joignable" » -- Kromalchif, hors raid, avec Kromandant en
    -- ligne dans une autre guilde). Un message d'addon a quelqu'un de
    -- deconnecte ne coute rien : il se perd.
    local last = self.db.lastOfficer
    if last and last ~= self.me then return last end
    return nil
end

--=============================================================================
-- Mon propre ?ka (§ 6.1)
--=============================================================================

function KA:AskSelf(force)
    local now = self.now()
    if force then
        if self.lastRefreshAt and now - self.lastRefreshAt < KA.REFRESH_GAP then
            return false, "actualisation : une toutes les " .. KA.REFRESH_GAP .. " s"
        end
        self.lastRefreshAt = now
        -- « Actualiser » rafraichit aussi l'historique (14/09 : « le montant
        -- est toujours bon, mais l'historique non ») : des que le solde est
        -- revenu, KA:LOGS:20 repart.
        self.logsWanted = true
    end
    if self.selfState == "asked" and self.askedAt and now - self.askedAt < KA.ASK_TIMEOUT then
        return false, "demande déjà en vol"
    end
    local elu = self:Elect()
    if not elu then
        self.selfState = "noofficer"
        self.onChange()
        return false, "aucun officier joignable"
    end
    if self.askedTo ~= elu then self.awaiting = {} end   -- les demandes en vol vers l'ancien elu ne reviendront pas de lui
    self.askedTo, self.askedAt, self.askedOnce = elu, now, true
    self.selfState = "asked"
    self.sendAddon(elu, "KA")
    self.debug("KA -> " .. elu)
    self.onChange()
    return true, elu
end

-- A l'entree en raid, et une fois par session. RAID_ROSTER_UPDATE tombe a
-- chaque mouvement du raid (25 fois en formation) : un non lie ne redemande
-- pas 25 fois. On redemande au plus une fois par ASK_TIMEOUT, et jamais quand
-- la reponse a deja ete « non lié » (elle ne changera pas sans geste du
-- joueur : « Actualiser » ou son propre « ?ka #Main »).
function KA:OnRaidEntered()
    if self.selfState == "known" or self.selfState == "asked" or self.selfState == "unlinked" then return end
    local now = self.now()
    if self.raidAskedAt and now - self.raidAskedAt < KA.ASK_TIMEOUT then return end
    self.raidAskedAt = now
    self:AskSelf(false)
end

function KA:OnSessionStart()
    if not self.askedOnce then self:AskSelf(false) end
end

-- Les « ?ka Nom » sont-ils autorises ? Seulement une fois que la reponse a
-- mon « ?ka » seul m'a dit connu.
function KA:MayLookup()
    return self.selfState == "known"
end

function KA:SelfInfo()
    return self.selfInfo
end

--=============================================================================
-- Cache et demandes (§ 6.3)
--=============================================================================

function KA:PruneCache()
    local now = self.now()
    for n, c in pairs(self.cache) do
        if c.t and now - c.t > KA.CACHE_TTL then self.cache[n] = nil end
    end
end

function KA:Lookup(name)
    if not name then return nil end
    if name == self.me and self.selfInfo then
        return { solde = self.selfInfo.solde, main = self.selfInfo.main, t = self.now() }
    end
    local c = self.cache[name]
    if c and c.t and self.now() - c.t > KA.CACHE_TTL then self.cache[name] = nil; return nil end
    if c and c.unknown then return nil end
    return c
end

-- Met un nom dans la file de demandes (les MISEURS d'une enchere, § 6.3),
-- une seule fois par soiree, si la porte est ouverte.
function KA:Request(name)
    if not self:MayLookup() then return false, "porte fermée : mon ?ka d'abord" end
    if name == self.me or name == "?" then return false end
    if self.cache[name] or self.awaiting[name] then return false end
    for _, p in ipairs(self.pending) do if p == name then return false end end
    if self.lookupsThisAuction + #self.pending >= KA.LOOKUPS_PER_AUCTION then return false, "10 par enchère" end
    table.insert(self.pending, name)
    return true
end

-- Balaye l'enchere courante : chaque miseur (pas les randeurs purs) sans
-- reponse est demande.
function KA:ScanAuction()
    local e = self.getAuction()
    if not e then return end
    if e.serial ~= self.auctionSerial then
        -- Nouvelle enchere : nouveau budget, et les demandes pas encore
        -- parties tombent (pas de relance, § 6.3).
        self.auctionSerial = e.serial
        self.lookupsThisAuction = 0
        self.pending = {}
    end
    if e.statut ~= "ouverte" and e.statut ~= "departage" then return end
    for _, n in ipairs(e.ordre) do
        local l = e.lignes[n]
        if l and l.bid ~= nil then self:Request(n) end
    end
end

-- Envoie au plus UNE demande par tic, toutes les 2 s, jamais en combat.
function KA:Pump()
    local now = self.now()
    -- Ma propre demande sans reponse : on la laisse retomber pour pouvoir
    -- reessayer (l'officier a peut-etre change).
    if self.selfState == "asked" and self.askedAt and now - self.askedAt >= KA.ASK_TIMEOUT then
        -- Muet (pas de Kromaddon, ou pas a jour) : la prochaine demande ira
        -- d'abord a un autre, s'il y en a un ; il redevient candidat des
        -- qu'il repond a quelque chose.
        if self.askedTo then self.silent[self.askedTo] = true end
        self.selfState = "idle"
        self.onChange()
    end
    if #self.pending == 0 then return nil end
    if not self:MayLookup() then self.pending = {}; return nil end
    if self.inCombat() then return nil end
    if now - self.lastLookupAt < KA.LOOKUP_GAP then return nil end
    local elu = self.askedTo or self:Elect()
    if not elu then return nil end
    local name = table.remove(self.pending, 1)
    self.awaiting[name] = now
    self.lastLookupAt = now
    self.lookupsThisAuction = self.lookupsThisAuction + 1
    self.sendAddon(elu, "KA:" .. name)
    self.debug("KA:" .. name .. " -> " .. elu)
    return name
end

function KA:Tick()
    self:ScanAuction()
    return self:Pump()
end

--=============================================================================
-- Les reponses (G.ParseWhisper)
--=============================================================================

-- Deux lignes sont le MEME mouvement si auteur, delta, total et raison
-- concordent -- et la date aussi quand les deux en ont une (une ligne
-- « live », venue d'un chuchotement de credit, n'a pas de date : c'est la
-- ligne de KA:LOGS qui la lui donne). Le total est dans la cle (14/09) :
-- deux « +1 test » de Kromandant dans la meme minute ont des totaux
-- differents, et l'ancienne cle (sans total) jetait le second comme un
-- doublon -- « il manque des mouvements ».
function KA.SameMovement(a, b)
    if a.author ~= b.author or a.delta ~= b.delta or a.reason ~= b.reason then return false end
    if a.total ~= nil and b.total ~= nil and a.total ~= b.total then return false end
    if a.date and a.date ~= "" and b.date and b.date ~= "" and a.date ~= b.date then return false end
    return true
end

function KA:AddHistory(main, entry)
    local h = self.db.historique[main]
    if not h then h = {}; self.db.historique[main] = h end
    for i, x in ipairs(h) do
        if KA.SameMovement(x, entry) then
            -- La version datee (KA:LOGS) remplace la version live sans date.
            if (not x.date or x.date == "") and entry.date and entry.date ~= "" then h[i] = entry end
            return false
        end
    end
    table.insert(h, 1, entry)
    while #h > KA.HISTORY_MAX do table.remove(h) end
    return true
end

-- Un lot KA:LOGS arrive ligne par ligne, du plus recent au plus ancien : il
-- fait autorite sur ce qu'il couvre. Le lot prend la tete de l'historique
-- dans l'ordre de Kromaddon ; ce qui etait deja la et que le lot ne
-- contient pas reste derriere (les lignes vivantes plus recentes que le lot
-- gardent leur place devant lui).
function KA:MergeLogBatch(main)
    local batch = self.logBatch
    if not batch or #batch == 0 then return end
    local old = self.db.historique[main] or {}
    local merged, seen = {}, {}
    -- Les lignes vivantes arrivees APRES le debut du lot (t > batch.t) : devant.
    for _, x in ipairs(old) do
        if x.live and x.t and batch.t and x.t > batch.t then
            local dup = false
            for _, b in ipairs(batch) do if KA.SameMovement(b, x) then dup = true; break end end
            if not dup then table.insert(merged, x); seen[x] = true end
        end
    end
    for _, b in ipairs(batch) do table.insert(merged, b) end
    for _, x in ipairs(old) do
        if not seen[x] then
            local dup = false
            for _, b in ipairs(batch) do if KA.SameMovement(b, x) then dup = true; break end end
            if not dup then table.insert(merged, x) end
        end
    end
    while #merged > KA.HISTORY_MAX do table.remove(merged) end
    self.db.historique[main] = merged
end

function KA:HandleReply(ev, sender)
    if not ev then return "ignoré" end
    local kind = ev.kind
    local fromElu = (sender == self.askedTo)
    if sender then self.silent[sender] = nil end

    if kind == "linked" then
        -- « T'es lié à X » est la reponse ATTENDUE quand le joueur, non lie,
        -- a lui-meme envoye « ?ka #SonMain » comme l'onglet le lui dit : on
        -- redemande notre ?ka. C'est une ALARME seulement si un « ?ka Nom »
        -- de l'addon etait en vol : la porte a fui, l'addon vient de lier le
        -- joueur au premier rival du tableau.
        if next(self.awaiting) == nil then
            self.selfState = "idle"
            self.onChange()
            self:AskSelf(false)
            return "lié à " .. tostring(ev.main) .. " (par le joueur) : ?ka redemandé"
        end
        self.linkedAlarm = "AUTO-LIAISON vers " .. tostring(ev.main) .. " : préviens un officier (?ka delie)"
        self.onChange()
        return "ALARME : auto-liaison"
    end
    if kind == "unlinked_info" then return "délié" end
    if kind == "movement" then
        if not self.isOfficer(sender) then return "ignoré : mouvement d'un non-officier" end
        local main = (self.selfInfo and self.selfInfo.main) or self.me
        self:AddHistory(main, { date = "", author = sender, delta = ev.delta, total = ev.solde, reason = ev.reason, live = true, t = self.now() })
        if ev.solde then
            -- Le chuchotement dit le solde APRES mouvement (3.9.12) : on le
            -- prend tel quel plutot que d'additionner un delta a une valeur
            -- qu'on n'avait peut-etre pas.
            self:LearnSelfBalance(ev.solde)
            return "mouvement " .. tostring(ev.delta) .. " (solde " .. tostring(ev.solde) .. ")"
        end
        if self.selfInfo then self.selfInfo.solde = (self.selfInfo.solde or 0) + ev.delta; self:PersistSelfInfo() end
        self.onChange()
        return "mouvement " .. tostring(ev.delta)
    end
    if not fromElu then return "ignoré : pas l'officier interrogé" end

    if kind == "ka_self" then
        self.selfState = "known"
        self.selfInfo = { solde = ev.solde, main = ev.main, marker = ev.marker, t = self.now() }
        self.linkFeedback = nil
        self:PersistSelfInfo()
        self.db.lastOfficer = sender   -- le dernier qui m'a repondu : repli d'election (KA:Elect)
        if self.logsWanted then self:RequestLogs(true) end
        self.onChange()
        return "connu : " .. tostring(ev.solde) .. " KA (Main : " .. tostring(ev.main) .. ")"
    end
    if kind == "ka_unlinked" then
        self.selfState = "unlinked"
        self.pending = {}
        self.onChange()
        return "non lié : aucun ?ka Nom ne partira"
    end
    if kind == "ka_notsynced" or kind == "roster_not_ready" then
        if kind == "roster_not_ready" and self.selfState == "unlinked" then
            self.linkFeedback = "roster de guilde pas encore synchronisé chez l'officier : réessaie dans une minute"
        end
        self.exhausted[sender] = true
        self.selfState = "idle"
        self.onChange()
        local ok, who = self:AskSelf(false)
        return "pas synchronisé chez " .. sender .. (ok and (" -> " .. tostring(who)) or " (aucun autre)")
    end
    if kind == "ka_lookup" then
        self.awaiting[ev.name] = nil
        self.cache[ev.name] = { solde = ev.solde, main = ev.main, t = self.now() }
        self.onChange()
        return "réponse : " .. ev.name
    end
    if kind == "ka_unknown" then
        self.awaiting[ev.name] = nil
        self.cache[ev.name] = { unknown = true, t = self.now() }
        return "inconnu : " .. ev.name
    end
    if kind == "ka_log" then
        local main = (self.selfInfo and self.selfInfo.main) or self.me
        local entry = { date = ev.date, author = ev.author, delta = ev.delta, total = ev.total, reason = ev.reason, t = self.now() }
        if self.logBatch then
            local dup = false
            for _, b in ipairs(self.logBatch) do if KA.SameMovement(b, entry) then dup = true; break end end
            if not dup then table.insert(self.logBatch, entry) end
            self:MergeLogBatch(main)
        else
            self:AddHistory(main, entry)
        end
        self.onChange()
        return "ligne d'historique"
    end
    if kind == "ka_nologs" then
        return "historique vide"
    end
    if kind == "bad_main" then
        self.linkFeedback = "Mauvais nom de main : vérifie l'orthographe"
        self.onChange()
        return "mauvais nom de main"
    end
    return "ignoré : " .. tostring(kind)
end

-- Une VICTOIRE debite le gagnant en local (§ 6.3).
-- MON solde n'est pas touche ici : AddPoints chez l'officier me chuchote
-- « [KoinApogee] Tu perds N KA pour … » AVANT la VICTOIRE, et ce mouvement
-- est deja applique (HandleReply). Le debiter ici aussi le compterait deux
-- fois. Les autres, eux, ne me chuchotent rien : leur cache est decremente.
function KA:OnAuctionClosed(e)
    if not e or not e.gagnant or not e.gagnant.prix or e.gagnant.prix == 0 then return end
    local g = e.gagnant
    local key = g.main or g.nom
    for _, n in ipairs({ g.nom, g.main }) do
        local c = n and self.cache[n]
        if c and c.solde then c.solde = c.solde - g.prix end
    end
    -- Toute ligne du cache dont le MAIN est le gagnant.
    for n, c in pairs(self.cache) do
        if c.main and c.main == key and n ~= g.nom and n ~= g.main and c.solde then c.solde = c.solde - g.prix end
    end
    self.onChange()
end

-- « ?ka 20 logs » (§ 6.3). Etait « une fois par personnage », pour
-- toujours (db.logsDemandes) : l'historique ne se remettait jamais a jour
-- d'une session a l'autre (14/09, « il manque des mouvements »). Maintenant :
-- une fois par REFRESH_GAP, a l'ouverture de l'onglet et a chaque
-- « Actualiser » (force), et les lignes recues font autorite (MergeLogBatch).
function KA:RequestLogs(force)
    if not self:MayLookup() then return false end
    local now = self.now()
    if self.logsAskedAt and now - self.logsAskedAt < KA.REFRESH_GAP then return false end
    local elu = self.askedTo or self:Elect()
    if not elu then return false end
    self.logsAskedAt, self.logsWanted = now, false
    self.logBatch = { t = now }
    self.sendAddon(elu, "KA:LOGS:20")
    return true
end

-- La porte des non lies (14/09, Kroma : « pour un joueur non lie je veux
-- KromaddonGuildeux completement inoperant avec juste un champ texte pour
-- qu'ils saisissent le nom de leur main et un bouton valider qui m'envoie
-- ?ka NomDuMain (je veux les voir ces wisps) ») : le seul chuchotement
-- TEXTE que l'addon envoie encore, visible des deux cotes, a l'officier elu.
-- Kromaddon repond « T'es lié à X » (le ?ka repart tout seul, HandleReply)
-- ou « Mauvais Nom de main ».
function KA:LinkMain(name)
    name = name and string.gsub(name, "^%s*#?(.-)%s*$", "%1") or ""
    if name == "" then self.linkFeedback = "tape le nom de ton main"; self.onChange(); return false, "nom vide" end
    -- requireOnline (14/09 soir) : jamais de repli sur le dernier officier
    -- qui a repondu ici -- ce chuchotement est REEL et VISIBLE, contrairement
    -- au canal d'addon ; l'envoyer a quelqu'un de deconnecte ne fait
    -- qu'afficher un chuchotement mort chez le guildeux, sans jamais de
    -- reponse (constat de Kroma, 14/09 soir : « KromaddonGuildeux envoie des
    -- wisp à des offis déco »).
    local elu = self:Elect(true)
    if not elu then self.linkFeedback = "aucun officier joignable"; self.onChange(); return false, "aucun officier joignable" end
    self.whisper(elu, "?ka " .. name)
    self.linkFeedback = "demande envoyée à " .. elu .. " : ?ka " .. name
    self.debug("?ka " .. name .. " -> " .. elu .. " (chuchotement)")
    self.onChange()
    return true, elu
end

function KA:History()
    local main = (self.selfInfo and self.selfInfo.main) or self.me
    return self.db.historique[main] or {}
end

function KA:ClearCache()
    self.cache, self.pending, self.awaiting = {}, {}, {}
end

function KA:StateText()
    if self.linkedAlarm then return self.linkedAlarm end
    if self.selfState == "known" and self.selfInfo then
        return string.format("%d KA (Main : %s)%s", self.selfInfo.solde or 0, self.selfInfo.main or "?",
            self.selfInfo.stale and " - dernier connu, Actualiser pour confirmer" or "")
    end
    if self.selfState == "asked" then return "demande envoyée à " .. tostring(self.askedTo) .. "…" end
    if self.selfState == "unlinked" then return "personnage non lié : envoie « ?ka #NomDeTonMain » à un officier" end
    if self.selfState == "noofficer" then return "aucun officier joignable (hors raid : un officier connecté de ta guilde, ou le dernier qui a répondu)" end
    return "solde inconnu (clique Actualiser)"
end

function KA:MarkerText()
    local m = self.selfInfo and self.selfInfo.marker
    if not m then return "" end
    if m.kind == "valid" then return "Marqueur Naxx/Uldu : valable jusqu'au " .. tostring(m.until_) end
    if m.kind == "expired" then return "Marqueur Naxx/Uldu : expiré depuis le " .. tostring(m.since) end
    if m.kind == "none" then return "Marqueur Naxx/Uldu : aucun" end
    return "Marqueur Naxx/Uldu : " .. KG.Flatten(tostring(m.text))
end

--=============================================================================
-- Branchement sur le client
--=============================================================================

function KA:Logic()
    if self.logic then return self.logic end
    self.logic = KA.New({
        me = KG.PlayerName(),
        whisper = KG.QueueWhisper,
        now = KG.Now,
        isOfficer = KG.IsOfficer,
        -- Roster connectes + galonnes du raid (KG.OnlineOfficers) : le roster
        -- seul laissait « aucun officier joignable » tant qu'il etait vide.
        onlineOfficers = KG.OnlineOfficers,
        raidMembers = function() if KG.InRaid() then return KG.GroupMembers() end return {} end,
        raidLeader = KG.RaidLeader,
        masterLooter = KG.MasterLooter,
        inCombat = KG.AnyRaidMemberInCombat,
        getAuction = function() return KG.Encheres and KG.Encheres.S and KG.Encheres.S.current or nil end,
        db = KG.GetDB(),
        sendAddon = KG.QueueAddonMessage,
        officerKnown = function(name) return KG.IsKnownOfficer(name) == true end,
        debug = function(text) KG.Debug("KA", KG.PlayerName(), text, "envoyé") end,
        onChange = function() KA:Refresh() end,
    })
    return self.logic
end

function KA:OnLogin()
    local L = self:Logic()
    if KG.InRaid() then L:OnRaidEntered() end
end

function KA:OnRoster()
    local L = self:Logic()
    if not L.askedOnce and next(KG.guildOnline) then L:OnSessionStart() end
end

function KA:OnRaidChanged()
    local L = self:Logic()
    if KG.InRaid() then L:OnRaidEntered() end
end

-- Le module Encheres journalise ses propres chuchotements (rappel,
-- confirmation) ; ici les notres. La logique pure recoit l'evenement
-- (HandleReply), le module recoit le texte.
function KA:OnWhisper(text, sender)
    if type(text) ~= "string" then return end
    local ev = KG.Grammaire.ParseWhisper(text)
    if not ev or ev.kind == "nudge" or ev.kind == "pass_confirm" then return end
    local verdict = self:Logic():HandleReply(ev, sender)
    KG.Debug("WHISPER", sender, text, verdict)
end

-- Le nouveau canal (13/09, brief-kg-canal-addon-13-09.md) : Kromaddon repond
-- avec le MEME texte qu'a un ?ka chuchote (KG.Grammaire.ParseWhisper) -- seul
-- le transport (SendAddonMessage, jamais affiche, jamais tapable a la main)
-- change. HandleReply, le cache, MayLookup, les delais : rien ne bouge, seul
-- ce point d'entree est nouveau. arg1 (le prefixe) est deja verifie par
-- Core/Init.lua avant l'appel : ici, `message` est deja LE texte de reponse.
function KA:OnAddonMessage(message, sender)
    if type(message) ~= "string" then return end
    local ev = KG.Grammaire.ParseWhisper(message)
    if not ev then return end
    local verdict = self:Logic():HandleReply(ev, sender)
    KG.Debug("ADDON", sender, message, verdict)
end

function KA:OnAuctionEffect(kind, data)
    if kind == "close" then self:Logic():OnAuctionClosed(data) end
end

function KA:OnTick(now)
    self:Logic():Tick()
end

function KA:OnTabShown(key)
    if key ~= "ka" then return end
    local L = self:Logic()
    L:RequestLogs()
    self:Refresh()
end

--=============================================================================
-- L'onglet KA (§ 6.4)
--=============================================================================

function KA:Build(panel)
    local W = {}
    self.widgets = W
    W.solde = KG.Label(panel, "", "GameFontNormalLarge")
    W.solde:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -6)
    W.solde:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -120, -6)
    W.solde:SetJustifyH("LEFT")
    do local c = KG.Theme.gold; W.solde:SetTextColor(c[1], c[2], c[3]) end
    W.marker = KG.Label(panel, "")
    W.marker:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -30)
    W.marker:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -120, -30)
    W.marker:SetJustifyH("LEFT")

    W.refresh = KG.NewButton(panel, "Actualiser", 100, 22)
    W.refresh:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -6)
    W.refresh:SetScript("OnClick", function()
        local ok, why = KA:Logic():AskSelf(true)
        if not ok and why then KG.Print(why) end
        KA:Refresh()
    end)

    local header = KG.Label(panel, "Historique (date, auteur, mouvement, total, raison)")
    header:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -52)
    do local c = KG.Theme.gold; header:SetTextColor(c[1], c[2], c[3]) end

    local zone = KG.CreateZone(panel)
    zone:SetPoint("TOPLEFT", panel, "TOPLEFT", 2, -66)
    zone:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -2, 2)
    local scroll = KG.NewScrollFrame(panel, "KromaddonGuildeuxKAScroll")
    scroll:SetPoint("TOPLEFT", zone, "TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", zone, "BOTTOMRIGHT", -26, 4)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetWidth(500); child:SetHeight(10)
    scroll:SetScrollChild(child)
    W.scroll, W.child, W.rows = scroll, child, {}
    self:Refresh()
end

function KA:Refresh()
    local L = self:Logic()
    -- La porte des non lies (Core/UI.lua) suit l'etat, onglet construit ou pas.
    if KG.SetGate then KG.SetGate(L.selfState == "unlinked", L) end
    local W = self.widgets
    if not W or not W.child then return end
    W.solde:SetText(L:StateText())
    W.marker:SetText(L:MarkerText())
    local hist = L:History()
    local i = 0
    for _, e in ipairs(hist) do
        i = i + 1
        local fs = W.rows[i]
        if not fs then
            fs = KG.Label(W.child, "")
            fs:SetPoint("TOPLEFT", W.child, "TOPLEFT", 2, -(i - 1) * 14)
            fs:SetPoint("TOPRIGHT", W.child, "TOPRIGHT", -2, -(i - 1) * 14)
            fs:SetHeight(14); fs:SetWordWrap(false)
            fs:SetJustifyH("LEFT")
            W.rows[i] = fs
        end
        local delta = (e.delta or 0) >= 0 and ("+" .. tostring(e.delta or 0)) or tostring(e.delta)
        local total = e.total and (" (total " .. tostring(e.total) .. ")") or ""
        local when = (e.date and e.date ~= "") and e.date or (e.t and date and date("%d/%m %H:%M", e.t)) or ""
        fs:SetText(string.format("%s %s %s%s%s", when, KG.Flatten(e.author or ""), delta, total, e.reason and (" - " .. KG.Flatten(e.reason)) or ""))
        fs:Show()
    end
    for j = i + 1, #W.rows do W.rows[j]:Hide() end
    W.child:SetHeight(math.max(10, i * 14 + 4))
    if W.scroll and W.scroll:GetWidth() > 0 then W.child:SetWidth(W.scroll:GetWidth()) end
end

if KG.RegisterTab then
    KG.RegisterTab("ka", function(panel) KA:Build(panel) end)
end
