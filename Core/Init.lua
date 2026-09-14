--=============================================================================
-- KromaddonGuildeux - Core/Init.lua
--
-- L'addon d'un MEMBRE de la guilde : il lit ce que l'officier annonce en raid
-- (Kromaddon, module KromaCoin) et ecrit ce que le joueur aurait tape
-- lui-meme. Aucun protocole d'addon, aucune base partagee.
--
-- Ce fichier : la table globale, la base (SavedVariables), les helpers de
-- noms recopies de Kromaddon, le journal de diagnostic (/kg debug), la file
-- de chuchotements, les evenements et la commande /kg.
--
-- Regles heritees de Kromaddon (docs/creation-kromaddonguildeux-12-09.md) :
-- Lua 5.1 ; un module qui touche a une frame n'en cree pas en dehors du
-- client ; tout ce qui est pur se teste hors jeu.
--=============================================================================

KromaddonGuildeux = KromaddonGuildeux or {}
local KG = KromaddonGuildeux

KG.ADDON_NAME = "KromaddonGuildeux"
KG.Version = (GetAddOnMetadata and GetAddOnMetadata(KG.ADDON_NAME, "Version")) or "dev"

-- Les rangs de guilde qui font de quelqu'un un officier (§ 6.2). En dur
-- depuis le 14/09 (Kroma : « la liste des rangs peut être mise en dur dans
-- le code, il me semble ») — plus configurable depuis Options.
KG.OFFICER_RANK_NAMES = { "Officier", "GM", "Chef de guilde", "Guild Master" }

--=============================================================================
-- Base (par compte)
--=============================================================================

-- La table de defauts est recopiee champ par champ dans la base a chaque
-- GetDB : un champ ajoute plus tard existe donc aussi sur une base ancienne.
function KG.Defaults()
    return {
        -- Options
        ouvrirAuxLoots = true,
        ouvrirPourCoches = true,
        ouvrirToutesEncheres = false,
        verrouille = false,
        echelle = 1.0,
        -- Etat persistant
        loots = {},          -- [nightKey] = { [itemID] = { link=, checked=, t= } }
        historique = {},     -- [main] = { { t=, auteur=, delta=, total=, raison= }, ... }
        logsDemandes = {},   -- [perso] = true : "?ka 20 logs" deja envoye une fois
        position = nil,      -- { point, relativePoint, x, y }
        onglet = "encheres",
    }
end

function KG.GetDB()
    KromaddonGuildeuxDB = KromaddonGuildeuxDB or {}
    local db = KromaddonGuildeuxDB
    for k, v in pairs(KG.Defaults()) do
        if db[k] == nil then db[k] = v end
    end
    return db
end

--=============================================================================
-- Noms de joueurs (recopies de Kromaddon, Modules/KromaCoin/KromaCoin.lua ;
-- tests/grammaire.lua compare au vrai source quand il est a cote)
--=============================================================================

function KG.TrimStr(s)
    if not s then return "" end
    return (string.gsub(string.gsub(s, "^%s+", ""), "%s+$", ""))
end

function KG.NormalizeName(name)
    if not name then return nil end
    name = string.match(name, "^([^%-]+)") or name
    name = KG.TrimStr(name)
    if name == "" then return nil end
    return string.upper(string.sub(name, 1, 1)) .. string.lower(string.sub(name, 2))
end

-- Identifiant d'objet dans un lien, ou nil (texte libre : « Morsure BQL »).
function KG.ItemID(value)
    if not value then return nil end
    local id = string.match(tostring(value), "item:(%d+)")
    return id and tonumber(id) or nil
end

-- Tout texte venu d'un joueur est nettoye de ses barres AVANT d'etre
-- affiche ou stocke (classe de bug 6 de Kromaddon : un lien ouvert jamais
-- ferme plante le client). Un lien d'objet devient son seul libelle.
function KG.Flatten(text)
    if type(text) ~= "string" then return "" end
    text = string.gsub(text, "|c%x%x%x%x%x%x%x%x|H[^|]*|h%[([^%]]*)%]|h|r", "%1")
    text = string.gsub(text, "|T[^|]*|t", "")
    text = string.gsub(text, "|", "")
    return text
end

-- Libelle affichable d'un lien ou d'un texte libre.
function KG.ItemLabel(value)
    if not value then return "" end
    local label = string.match(tostring(value), "|h%[([^%]]*)%]|h")
    return label or KG.Flatten(tostring(value))
end

function KG.Now()
    return time()
end

function KG.PlayerName()
    return KG.NormalizeName(UnitName and UnitName("player")) or "?"
end

--=============================================================================
-- Journal de diagnostic : les 50 dernieres lignes lues, avec ce qu'on en a
-- compris (« ignoré » sinon). C'est l'outil de la premiere soiree : au
-- premier /kg debug on sait sur quel evenement arrivent les lignes « via
-- /ar » de l'officier, et quelle ligne n'a pas ete reconnue.
--=============================================================================

KG.DEBUG_MAX = 50
KG.debugLines = KG.debugLines or {}

function KG.Debug(channel, sender, text, verdict)
    local line = string.format("%s %s <%s> %s => %s",
        date("%H:%M:%S"), tostring(channel), tostring(sender or ""), KG.Flatten(tostring(text or "")), tostring(verdict or "ignoré"))
    table.insert(KG.debugLines, line)
    while #KG.debugLines > KG.DEBUG_MAX do table.remove(KG.debugLines, 1) end
end

function KG.Print(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffd9b34a[KG]|r " .. tostring(msg))
    end
end

--=============================================================================
-- Raid, groupe, combat
--=============================================================================

function KG.InRaid()
    return (GetNumRaidMembers and GetNumRaidMembers() or 0) > 0
end

function KG.InGroup()
    if KG.InRaid() then return true end
    return (GetNumPartyMembers and GetNumPartyMembers() or 0) > 0
end

-- Noms (normalises) des membres du raid ou du groupe, moi compris.
function KG.GroupMembers()
    local set = {}
    set[KG.PlayerName()] = true
    if KG.InRaid() then
        for i = 1, GetNumRaidMembers() do
            local n = GetRaidRosterInfo and GetRaidRosterInfo(i)
            n = KG.NormalizeName(n)
            if n then set[n] = true end
        end
    else
        for i = 1, (GetNumPartyMembers and GetNumPartyMembers() or 0) do
            local n = KG.NormalizeName(UnitName and UnitName("party" .. i))
            if n then set[n] = true end
        end
    end
    return set
end

function KG.IsInMyGroup(name)
    name = KG.NormalizeName(name)
    return name ~= nil and KG.GroupMembers()[name] == true
end

-- Chef de raid et maitre du butin (noms normalises), nil hors raid.
function KG.RaidLeader()
    if not KG.InRaid() then return nil end
    for i = 1, GetNumRaidMembers() do
        local n, rank = GetRaidRosterInfo(i)
        if rank == 2 then return KG.NormalizeName(n) end
    end
end

function KG.MasterLooter()
    if not (GetLootMethod and KG.InRaid()) then return nil end
    local method, _, raidIndex = GetLootMethod()
    if method == "master" and raidIndex then
        local n = GetRaidRosterInfo(raidIndex)
        return KG.NormalizeName(n)
    end
end

-- Corollaire C2 de Kromaddon : un mort est hors combat. Un membre du raid
-- (ou du groupe de 5 : GetNumRaidMembers() vaut 0 en groupe) en combat
-- suffit a retenir un chuchotement.
function KG.AnyRaidMemberInCombat()
    if UnitAffectingCombat and UnitAffectingCombat("player") then return true end
    if KG.InRaid() then
        for i = 1, GetNumRaidMembers() do
            if UnitAffectingCombat("raid" .. i) then return true end
        end
        return false
    end
    for i = 1, (GetNumPartyMembers and GetNumPartyMembers() or 0) do
        if UnitAffectingCombat("party" .. i) then return true end
    end
    return false
end

--=============================================================================
-- Roster de guilde : rangs par nom, pour « qui est officier ».
-- Le rang vient TOUJOURS du roster, jamais d'un message.
--=============================================================================

KG.guildRanks = KG.guildRanks or {}       -- [nom] = nom du rang
KG.guildOnline = KG.guildOnline or {}     -- [nom] = true si connecte au dernier scan
KG.rosterComplete = false                -- au moins un membre HORS LIGNE enumere : le roster dit tout

-- GetGuildRosterInfo n'enumere les hors-ligne que si le client est regle
-- pour les montrer (SetGuildRosterShowOffline) : sans ca le main d'un reroll
-- deconnecte passerait pour un PU. Classe de bug 5 de Kromaddon : une
-- conclusion « pas en guilde » ne se prend que sur un roster COMPLET.
--
-- 13/09 (Kroma : « dans l'onglet guilde du jeu de base les deco restent
-- affiches meme case decochee ») : SetGuildRosterShowOffline(true) est un
-- REGLAGE CLIENT GLOBAL, pas un parametre de CETTE demande -- le forcer sans
-- jamais le desarmer laisse l'onglet Guilde standard de Blizzard afficher
-- les hors-ligne en permanence, quoi que Kroma ait decoche. On ne le force
-- que le temps de lire NOTRE roster (KG.RequestGuildRoster), puis on le
-- restaure des que GUILD_ROSTER_UPDATE nous a livre la reponse.
function KG.RefreshGuildRoster()
    -- Toute reponse (meme vide) desarme le forcage : on ne veut jamais
    -- laisser le reglage client force au-dela d'un aller-retour GUILD_ROSTER_UPDATE.
    if KG.rosterShowOfflineArmed and SetGuildRosterShowOffline then
        pcall(SetGuildRosterShowOffline, false)
        KG.rosterShowOfflineArmed = false
    end
    if not (GetNumGuildMembers and GetGuildRosterInfo) then return end
    local n = GetNumGuildMembers()
    if not n or n == 0 then return end
    local online, sawOffline = {}, false
    for i = 1, n do
        local name, rank, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
        name = KG.NormalizeName(name)
        if name then
            if rank then KG.guildRanks[name] = rank end
            if isOnline then online[name] = true else sawOffline = true end
        end
    end
    KG.guildOnline = online
    if sawOffline then KG.rosterComplete = true end
end

-- Demander le roster au client. Au PLAYER_LOGIN la guilde n'est souvent pas
-- encore connue (constat de Kromaddon : GetGuildInfo("player") ne repond pas
-- tout de suite) et la demande part dans le vide : GetNumGuildMembers() reste
-- a 0, KG.guildRanks reste vide, et PERSONNE n'est officier - c'est le
-- symptome du premier essai en jeu (12/09 : « ça détecte pas les enchères »
-- et « aucun officier joignable »). On redemande donc a l'entree dans le
-- monde, a chaque PLAYER_GUILD_UPDATE, et toutes les ROSTER_RETRY secondes
-- tant que le roster n'est pas complet. `force` saute la cadence (evenements).
KG.ROSTER_RETRY = 30
KG.rosterRequestedAt = -1e9
KG.rosterShowOfflineArmed = false  -- vrai tant que RefreshGuildRoster n'a pas restaure le reglage client

function KG.RequestGuildRoster(force, now)
    if not GuildRoster then return false end
    if IsInGuild and not IsInGuild() then return false end
    now = now or (GetTime and GetTime()) or 0
    if not force and now - KG.rosterRequestedAt < KG.ROSTER_RETRY then return false end
    KG.rosterRequestedAt = now
    if SetGuildRosterShowOffline then
        pcall(SetGuildRosterShowOffline, true)
        KG.rosterShowOfflineArmed = true
    end
    pcall(GuildRoster)
    return true
end

-- Les noms des rangs officier (KG.OFFICER_RANK_NAMES, en dur - jamais un
-- numero de rang). Comparaison insensible a la casse.
function KG.IsOfficerRankName(rank)
    if type(rank) ~= "string" then return false end
    local lower = string.lower(rank)
    for _, r in ipairs(KG.OFFICER_RANK_NAMES) do
        if string.lower(r) == lower then return true end
    end
    return false
end

-- Galon de raid d'un nom : 2 chef, 1 assistant, 0 membre ; nil hors raid ou
-- absent du raid. `online` : le 8e retour de GetRaidRosterInfo (nil = on ne
-- sait pas, traite comme connecte).
function KG.RaidRank(name)
    name = KG.NormalizeName(name)
    if not name or not KG.InRaid() then return nil end
    for i = 1, GetNumRaidMembers() do
        local n, rank, _, _, _, _, _, online = GetRaidRosterInfo(i)
        if KG.NormalizeName(n) == name then return rank or 0, online ~= false end
    end
    return nil
end

-- Le chef de raid, ses assistants et le maitre du butin font foi quand le
-- roster de guilde ne dit rien d'un nom.
function KG.IsRaidTrusted(name)
    name = KG.NormalizeName(name)
    if not name then return false end
    local rank = KG.RaidRank(name)
    if rank and rank > 0 then return true end
    return KG.MasterLooter() == name
end

-- Officier ou pas, ET POURQUOI (pour /kg debug). Le rang de guilde decide
-- quand il est connu ; quand il ne l'est pas (roster pas encore lu, ou moi
-- hors guilde), les galons de raid font foi POUR LIRE : une ligne de verdict
-- a la forme Kromaddon ne peut venir que d'un officier, l'accepter ne coute
-- rien. Un rang connu non officier n'est jamais rattrape par un galon.
-- Pour lui ECRIRE, voir KG.OnlineOfficers : depuis 0.5.8, un galon de rang
-- de guilde inconnu suffit aussi, parce que la demande est un message
-- d'addon que personne ne voit.
function KG.OfficerStatus(name)
    name = KG.NormalizeName(name)
    if not name then return false, "nom vide" end
    local rank = KG.guildRanks[name]
    if rank ~= nil then
        if KG.IsOfficerRankName(rank) then return true, "rang " .. tostring(rank) end
        return false, "rang " .. tostring(rank)
    end
    local rr = KG.RaidRank(name)
    if rr == 2 then return true, "rang de guilde inconnu, chef de raid" end
    if rr == 1 then return true, "rang de guilde inconnu, assistant" end
    if KG.MasterLooter() == name then return true, "rang de guilde inconnu, maître du butin" end
    return false, "rang de guilde inconnu, sans galon de raid"
end

function KG.IsOfficer(name)
    local ok = KG.OfficerStatus(name)
    return ok
end

-- Officier de rang CONNU : la seule porte pour lui chuchoter. nil (rang
-- inconnu) n'est pas false — /kg debug fait la difference.
function KG.IsKnownOfficer(name)
    name = KG.NormalizeName(name)
    local rank = name and KG.guildRanks[name]
    if rank == nil then return nil end
    return KG.IsOfficerRankName(rank) and true or false
end

-- Les officiers a qui l'on peut ECRIRE (KA par le canal d'addon) : rang
-- d'officier CONNU et connectes -- ceux du roster, plus ceux du raid dont le
-- roster connait le rang (un roster de connectes seulement peut etre en
-- retard sur le raid) -- et, depuis 0.5.8, les galonnes du raid dont le rang
-- de guilde est INCONNU (chef, assistants, maitre du butin : une autre
-- guilde, ou un roster muet). Jamais un rang CONNU non officier.
-- Le 13/09 (0.5.3) un galon ne suffisait pas : le chef d'un raid sans officier
-- est un membre, et nos « ?ka » CHUCHOTES s'affichaient chez lui. Depuis
-- 0.5.6 la demande est un message d'addon : quelqu'un sans Kromaddon ne
-- voit rien, ne recoit rien, et Kromalchif chez Kromagasin avait Kromandant
-- (chef de raid, maitre du butin, autre guilde) sous les yeux sans pouvoir
-- lui ecrire (constat de Kroma, 14/09). KA:Elect prefere toujours un
-- officier de rang connu ; un galon de rang inconnu passe apres.
function KG.OnlineOfficers()
    local list, seen = {}, {}
    for n in pairs(KG.guildOnline) do
        if KG.IsKnownOfficer(n) then seen[n] = true; table.insert(list, n) end
    end
    if KG.InRaid() then
        for i = 1, GetNumRaidMembers() do
            local n, _, _, _, _, _, _, online = GetRaidRosterInfo(i)
            n = KG.NormalizeName(n)
            if n and not seen[n] and online ~= false then
                local known = KG.IsKnownOfficer(n)
                if known == true or (known == nil and KG.IsOfficer(n)) then seen[n] = true; table.insert(list, n) end
            end
        end
    end
    return list
end

--=============================================================================
-- File de chuchotements : jamais en combat, un envoi toutes les
-- KG.WHISPER_GAP secondes. Point unique : tout ce que l'addon chuchote
-- passe ici (§ 5.5 / § 8 du cahier).
--=============================================================================

KG.WHISPER_GAP = 2
KG.whisperQueue = KG.whisperQueue or {}
KG.lastWhisperAt = KG.lastWhisperAt or -1e9

function KG.QueueWhisper(target, text)
    if not target or not text then return end
    table.insert(KG.whisperQueue, { to = target, text = text })
end

-- Rend le message envoye, ou nil. `now` et `send` sont injectables (tests).
function KG.PumpWhispers(now, send, inCombat)
    now = now or GetTime()
    if #KG.whisperQueue == 0 then return nil end
    if inCombat == nil then inCombat = KG.AnyRaidMemberInCombat() end
    if inCombat then return nil end
    if now - KG.lastWhisperAt < KG.WHISPER_GAP then return nil end
    local m = table.remove(KG.whisperQueue, 1)
    KG.lastWhisperAt = now
    send = send or function(t, to) pcall(SendChatMessage, t, "WHISPER", nil, to) end
    send(m.text, m.to)
    return m
end

--=============================================================================
-- File de messages d'addon (canal SendAddonMessage) : le protocole ?ka
-- transporte hors du chat (13/09, demande de Kroma « point 2 » ; brief
-- brief-kg-canal-addon-13-09.md pour le cote Kromaddon). Un message d'addon
-- n'entre JAMAIS dans le ChatFrame -- rien a masquer ici, contrairement a la
-- file de chuchotements ci-dessus. La meme discipline (jamais en combat,
-- KG.WHISPER_GAP entre deux envois) s'applique : seul le TRANSPORT change,
-- pas la cadence. AUCUN REPLI vers le chuchotement texte (choix explicite de
-- Kroma, 13/09) : tant que Kromaddon ne comprend pas ce canal, le solde/main/
-- historique KA ne repondent plus cote KromaddonGuildeux -- le temps que les
-- deux addons soient a jour.
--=============================================================================

KG.ADDON_PREFIX = "KROMAKG"
KG.addonQueue = KG.addonQueue or {}
KG.lastAddonSentAt = KG.lastAddonSentAt or -1e9

function KG.QueueAddonMessage(target, message)
    if not target or not message then return end
    table.insert(KG.addonQueue, { to = target, text = message })
end

-- Rend le message envoye, ou nil. `now` et `send` sont injectables (tests).
function KG.PumpAddonMessages(now, send, inCombat)
    now = now or GetTime()
    if #KG.addonQueue == 0 then return nil end
    if inCombat == nil then inCombat = KG.AnyRaidMemberInCombat() end
    if inCombat then return nil end
    if now - KG.lastAddonSentAt < KG.WHISPER_GAP then return nil end
    local m = table.remove(KG.addonQueue, 1)
    KG.lastAddonSentAt = now
    send = send or function(t, to) pcall(SendAddonMessage, KG.ADDON_PREFIX, t, "WHISPER", to) end
    send(m.text, m.to)
    return m
end

-- Plus aucun masquage du chat (14/09) : KA parle par le canal d'addon,
-- invisible par nature, et le seul chuchotement texte qui reste --
-- « ?ka <Main> » de la porte des non lies -- doit etre VU des deux cotes
-- (Kroma : « je veux les voir ces wisps »). Le mecanisme de 0.5.0
-- (KG.ShouldHideOutgoing/Incoming, filtre de ChatFrame, db.masquerWisps) est
-- retire.

--=============================================================================
-- Modules et evenements. Chaque module s'inscrit et recoit :
--   OnLogin(), OnChat(channel, text, sender), OnSystem(text), OnWhisper(text,
--   sender), OnRoster(), OnTick(now), OnCombatStart(), OnCombatEnd(),
--   OnRaidChanged().
-- Les canaux : "RW" (RAID_WARNING), "RAID" (RAID + RAID_LEADER), "PARTY",
-- "GUILD". Ce qu'un joueur tape et ce que l'officier annonce arrivent par
-- les memes evenements ; c'est la grammaire qui separe les deux moities.
--=============================================================================

KG.modules = KG.modules or {}

function KG.RegisterModule(name, module)
    KG.modules[name] = module
    KG[name] = module
end

function KG.Dispatch(method, ...)
    for _, m in pairs(KG.modules) do
        local fn = m[method]
        if fn then
            local ok, err = pcall(fn, m, ...)
            if not ok then KG.Print("erreur " .. tostring(method) .. " : " .. tostring(err)) end
        end
    end
end

KG.CHAT_CHANNELS = {
    CHAT_MSG_RAID_WARNING = "RW",
    CHAT_MSG_RAID = "RAID",
    CHAT_MSG_RAID_LEADER = "RAID",
    CHAT_MSG_PARTY = "PARTY",
    CHAT_MSG_PARTY_LEADER = "PARTY",
    CHAT_MSG_GUILD = "GUILD",
}

local frame = CreateFrame("Frame", "KromaddonGuildeuxEventFrame")
KG.eventFrame = frame
for ev in pairs(KG.CHAT_CHANNELS) do frame:RegisterEvent(ev) end
frame:RegisterEvent("CHAT_MSG_SYSTEM")
frame:RegisterEvent("CHAT_MSG_WHISPER")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("RAID_ROSTER_UPDATE")
frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_GUILD_UPDATE")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")

KG.inCombat = false

frame:SetScript("OnEvent", function(self, event, arg1, arg2, arg3, arg4)
    local channel = KG.CHAT_CHANNELS[event]
    if channel then
        KG.Dispatch("OnChat", channel, arg1, KG.NormalizeName(arg2))
    elseif event == "CHAT_MSG_SYSTEM" then
        KG.Dispatch("OnSystem", arg1)
    elseif event == "CHAT_MSG_WHISPER" then
        KG.Dispatch("OnWhisper", arg1, KG.NormalizeName(arg2))
    elseif event == "CHAT_MSG_ADDON" then
        -- (prefix, message, channelType, sender). Un prefixe different n'est
        -- pas a nous (un autre addon sur le meme canal) : on ne le transmet
        -- meme pas a KA:HandleReply, qui pourrait mal l'interpreter.
        if arg1 == KG.ADDON_PREFIX then
            KG.Dispatch("OnAddonMessage", arg2, KG.NormalizeName(arg4))
        end
    elseif event == "PLAYER_LOGIN" then
        KG.GetDB()
        KG.RequestGuildRoster(true)
        KG.Dispatch("OnLogin")
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- La guilde est connue maintenant : la demande du login est
        -- souvent partie dans le vide.
        KG.RequestGuildRoster(true)
        KG.Dispatch("OnEnterWorld")
    elseif event == "PLAYER_GUILD_UPDATE" then
        KG.RequestGuildRoster(true)
    elseif event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
        KG.Dispatch("OnRaidChanged")
    elseif event == "GUILD_ROSTER_UPDATE" then
        KG.RefreshGuildRoster()
        KG.Dispatch("OnRoster")
    elseif event == "PLAYER_REGEN_DISABLED" then
        KG.inCombat = true
        KG.Dispatch("OnCombatStart")
    elseif event == "PLAYER_REGEN_ENABLED" then
        KG.inCombat = false
        KG.Dispatch("OnCombatEnd")
    end
end)

-- Un seul OnUpdate pour tout l'addon, cadence de 2 par seconde.
KG.TICK = 0.5
local acc = 0
frame:SetScript("OnUpdate", function(self, elapsed)
    acc = acc + elapsed
    if acc < KG.TICK then return end
    acc = 0
    local now = GetTime()
    -- Tant que le roster n'a pas montre un seul hors-ligne, il n'est pas
    -- complet : on le redemande (cadence ROSTER_RETRY, la fonction la tient).
    if not KG.rosterComplete then KG.RequestGuildRoster(false, now) end
    KG.PumpWhispers(now)
    KG.PumpAddonMessages(now)
    KG.Dispatch("OnTick", now)
end)

--=============================================================================
-- /kg
--=============================================================================

-- L'etat qui decide de tout : ma guilde, le roster, les rangs officier, et
-- pour chaque galonne du raid ce que KG.IsOfficer en pense. C'est ce qui a
-- manque au premier /kg debug (12/09) : cinquante lignes « ignoré » sans dire
-- que le roster etait vide.
function KG.DiagnosticLines()
    local lines = {}
    local guild = GetGuildInfo and GetGuildInfo("player")
    local inGuild = not IsInGuild or IsInGuild()
    local guildText
    if guild then guildText = tostring(guild)
    elseif inGuild then guildText = "pas encore lue"
    else guildText = "AUCUNE (hors guilde : seuls les galons de raid font foi)" end
    table.insert(lines, string.format("version %s, moi %s, guilde : %s", tostring(KG.Version), KG.PlayerName(), guildText))
    local n = 0
    for _ in pairs(KG.guildRanks) do n = n + 1 end
    table.insert(lines, string.format("roster : %d nom(s) avec un rang, %s ; rangs officier : %s",
        n, KG.rosterComplete and "complet" or "INCOMPLET (aucun hors-ligne vu, redemandé toutes les " .. KG.ROSTER_RETRY .. " s)",
        table.concat(KG.OFFICER_RANK_NAMES, ", ")))
    if KG.InRaid() then
        local ml = KG.MasterLooter()
        for i = 1, GetNumRaidMembers() do
            local raw, rank = GetRaidRosterInfo(i)
            local name = KG.NormalizeName(raw)
            if name and ((rank or 0) > 0 or name == ml) then
                local galon = rank == 2 and "chef de raid" or (rank == 1 and "assistant" or "membre")
                if name == ml then galon = galon .. ", maître du butin" end
                local ok, why = KG.OfficerStatus(name)
                local verdict = ok and "OFFICIER" or "non officier"
                if ok and KG.guildRanks[name] == nil then verdict = "OFFICIER par son galon (rang de guilde inconnu : ?ka par le canal, sans risque)" end
                table.insert(lines, string.format("raid : %s (%s) => %s (%s)", name, galon, verdict, why))
            end
        end
        local elu = KG.KA and KG.KA.Logic and KG.KA:Logic():Elect()
        local eluLine = "officier élu pour ?ka : " .. tostring(elu or "aucun")
        if not elu then
            eluLine = eluLine .. " (aucun officier de rang connu en ligne, et aucun galonné de rang inconnu dans le raid"
                .. (KG.rosterComplete and ")" or " ; roster incomplet)")
        end
        table.insert(lines, eluLine)
    else
        table.insert(lines, "hors raid")
    end
    return lines
end

function KG.HandleSlash(msg)
    msg = string.lower(KG.TrimStr(msg or ""))
    if msg == "debug" then
        for _, l in ipairs(KG.DiagnosticLines()) do KG.Print(l) end
        KG.Print("dernieres lignes lues (" .. #KG.debugLines .. ") :")
        for _, l in ipairs(KG.debugLines) do KG.Print(l) end
        return
    end
    if msg == "roster" then
        KG.RequestGuildRoster(true)
        KG.Print("roster de guilde redemandé au client.")
        for _, l in ipairs(KG.DiagnosticLines()) do KG.Print(l) end
        return
    end
    if msg == "options" then
        if KG.ShowWindow then KG.ShowWindow("options") end
        return
    end
    if msg == "ka" then
        if KG.ShowWindow then KG.ShowWindow("ka") end
        return
    end
    if msg == "version" then
        KG.Print("version " .. tostring(KG.Version))
        return
    end
    if msg == "cache" then
        -- Reprend exactement ce que faisait le bouton « Vider le cache ?ka »
        -- des Options, retire le 14/09 (Kroma : « pour vider le cache créer
        -- une commande /kg cache »).
        if KG.KA and KG.KA.Logic then KG.KA:Logic():ClearCache() end
        KG.Print("cache ?ka vidé")
        return
    end
    if KG.ToggleWindow then KG.ToggleWindow() end
end

SLASH_KROMADDONGUILDEUX1 = "/kg"
SLASH_KROMADDONGUILDEUX2 = "/kromaddonguildeux"
SlashCmdList["KROMADDONGUILDEUX"] = KG.HandleSlash
