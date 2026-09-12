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
KA.REFRESH_GAP = 60          -- « Actualiser » : un par minute
KA.ASK_TIMEOUT = 20          -- sans reponse a mon « ?ka » : on reessaie plus tard
KA.HISTORY_MAX = 200

--=============================================================================
-- Logique pure
--=============================================================================

-- opts : me, whisper(target, text), now(), isOfficer(name), onlineOfficers()
-- -> liste de noms connectes et officiers, raidMembers() -> set, raidLeader(),
-- masterLooter(), inCombat(), getAuction() -> l'enchere courante ou nil,
-- db (KromaddonGuildeuxDB), debug(text), onChange().
function KA.New(opts)
    opts = opts or {}
    local L = {
        me = opts.me or "?",
        whisper = opts.whisper or function() end,
        now = opts.now or function() return time() end,
        isOfficer = opts.isOfficer or function() return false end,
        onlineOfficers = opts.onlineOfficers or function() return {} end,
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
    return setmetatable(L, { __index = KA })
end

--=============================================================================
-- L'officier elu (§ 6.2)
--=============================================================================

-- En raid : les membres du raid qui sont officiers et connectes, chef de
-- raid d'abord, puis maitre du butin, puis alphabetique. Hors raid : les
-- officiers connectes de la guilde. Ceux qui ont dit « pas encore
-- synchronisé » passent apres les autres.
function KA:Elect()
    local online = {}
    for _, n in ipairs(self.onlineOfficers()) do if n ~= self.me then online[n] = true end end
    local raid = self.raidMembers()
    local rl, ml = self.raidLeader(), self.masterLooter()
    local function Rank(n)
        -- Les non epuises d'abord ; dans le raid avant la guilde ; chef de
        -- raid, maitre du butin, puis alphabetique.
        local r = 0
        if self.exhausted[n] then r = r + 100 end
        if not raid[n] then r = r + 10 end
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
    return candidates[1]
end

--=============================================================================
-- Mon propre ?ka (§ 6.1)
--=============================================================================

function KA:AskSelf(force)
    local now = self.now()
    if force then
        if self.lastRefreshAt and now - self.lastRefreshAt < KA.REFRESH_GAP then
            return false, "actualisation : une par minute"
        end
        self.lastRefreshAt = now
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
    self.whisper(elu, "?ka")
    self.debug("?ka -> " .. elu)
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
    self.whisper(elu, "?ka " .. name)
    self.debug("?ka " .. name .. " -> " .. elu)
    return name
end

function KA:Tick()
    self:ScanAuction()
    return self:Pump()
end

--=============================================================================
-- Les reponses (G.ParseWhisper)
--=============================================================================

function KA:AddHistory(main, entry)
    local h = self.db.historique[main]
    if not h then h = {}; self.db.historique[main] = h end
    for _, x in ipairs(h) do
        if x.date == entry.date and x.author == entry.author and x.delta == entry.delta and x.reason == entry.reason then
            return false
        end
    end
    table.insert(h, 1, entry)
    while #h > KA.HISTORY_MAX do table.remove(h) end
    return true
end

function KA:HandleReply(ev, sender)
    if not ev then return "ignoré" end
    local kind = ev.kind
    local fromElu = (sender == self.askedTo)

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
        self:AddHistory(main, { date = "", author = sender, delta = ev.delta, total = nil, reason = ev.reason, live = true, t = self.now() })
        if self.selfInfo then self.selfInfo.solde = (self.selfInfo.solde or 0) + ev.delta end
        self.onChange()
        return "mouvement " .. tostring(ev.delta)
    end
    if not fromElu then return "ignoré : pas l'officier interrogé" end

    if kind == "ka_self" then
        self.selfState = "known"
        self.selfInfo = { solde = ev.solde, main = ev.main, marker = ev.marker, t = self.now() }
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
        self:AddHistory(main, { date = ev.date, author = ev.author, delta = ev.delta, total = ev.total, reason = ev.reason, t = self.now() })
        self.onChange()
        return "ligne d'historique"
    end
    if kind == "ka_nologs" then
        return "historique vide"
    end
    if kind == "bad_main" then
        return "mauvais nom de main (?)"
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

-- « ?ka 20 logs », une fois par personnage (§ 6.3).
function KA:RequestLogs()
    if not self:MayLookup() then return false end
    if self.db.logsDemandes[self.me] then return false end
    local elu = self.askedTo or self:Elect()
    if not elu then return false end
    self.db.logsDemandes[self.me] = true
    self.whisper(elu, "?ka 20 logs")
    return true
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
        return string.format("%d KA (Main : %s)", self.selfInfo.solde or 0, self.selfInfo.main or "?")
    end
    if self.selfState == "asked" then return "demande envoyée à " .. tostring(self.askedTo) .. "…" end
    if self.selfState == "unlinked" then return "personnage non lié : envoie « ?ka #NomDeTonMain » à un officier" end
    if self.selfState == "noofficer" then return "aucun officier joignable" end
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
    local W = self.widgets
    if not W or not W.child then return end
    local L = self:Logic()
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
