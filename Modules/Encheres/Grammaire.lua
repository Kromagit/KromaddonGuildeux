--=============================================================================
-- KromaddonGuildeux - Modules/Encheres/Grammaire.lua
--
-- PUR : texte -> evenement. Aucune frame, aucune API WoW (RANDOM_ROLL_RESULT
-- est lu s'il existe, avec un repli anglais). Se charge tel quel sous lua5.1.
--
-- Le contrat est le § 3 de docs/creation-kromaddonguildeux-12-09.md : les
-- chaines que Kromaddon 3.9.9 (Modules/KromaCoin/KromaCoin.lua et
-- LootRules.lua) emet. tests/grammaire.lua fabrique ces chaines en APPELANT
-- le vrai source de Kromaddon quand il est a cote, et joue chaque motif tel
-- qu'il est ici.
--
-- Lua 5.1 n'a ni alternation « | » ni groupe optionnel « (...)? » : chaque
-- variante est un motif a part, ou une capture large puis une comparaison.
--
-- Deux moities :
--   G.Parse(text)        -> le VERDICT de l'officier (RAID / RW / GUILD)
--   G.ParseDemand(text)  -> ce qu'un joueur TAPE (« 150 », « ms », « passe »)
--   G.ParseWhisper(text) -> ce que l'officier chuchote au joueur (?ka, rappels)
--   G.ParseSystem(text)  -> le /roll (RANDOM_ROLL_RESULT)
-- Toutes rendent une table { kind = "...", ... } ou nil.
--=============================================================================

local KG = KromaddonGuildeux
local G = {}
KG.Grammaire = G

G.TIERS = { MS = "ms", OS = "os" }
G.PLACEMENTS = { ["A ma droite"] = true, ["A ma gauche"] = true, ["Au fond"] = true }
G.PROMPTS = { ["qui dit mieux?"] = true, ["pouvez-vous dire mieux?"] = true }
G.LINK_PATTERN = "|c%x%x%x%x%x%x%x%x|H[^|]+|h%[[^%]]*%]|h|r"

local function Tier(t)
    if t == "MS" then return "ms" elseif t == "OS" then return "os" end
    return nil
end

--=============================================================================
-- La reprise apres un retrait (queue de « passe » et de « Bid de X retiré »).
-- Quatre formes (KC:FormatResumeAfterRemoval) : bid MS, bid OS, rand MS, rand
-- OS, et « Plus aucune enchère en cours. ».
--=============================================================================

function G.ParseResume(s)
    if type(s) ~= "string" then return nil end
    local n, name = string.match(s, "^On reprend à (%d+) par (%S+)%.$")
    if n then return { kind = "bid", amount = tonumber(n), tier = "ms", name = name } end
    n, name = string.match(s, "^On reprend à (%d+) OS par (%S+)%.$")
    if n then return { kind = "bid", amount = tonumber(n), tier = "os", name = name } end
    n, name = string.match(s, "^On reprend au rand (%d+) par (%S+)%.$")
    if n then return { kind = "roll", amount = tonumber(n), tier = "ms", name = name } end
    n, name = string.match(s, "^On reprend au rand (%d+) OS par (%S+)%.$")
    if n then return { kind = "roll", amount = tonumber(n), tier = "os", name = name } end
    if s == "Plus aucune enchère en cours." then return { kind = "none" } end
    return nil
end

-- « Bob (Main) » ou « Bob » : le gagnant et, entre parentheses, son main.
local function SplitWinner(display)
    local name, main = string.match(display, "^(%S+) %((%S+)%)$")
    if name then return name, main end
    name = string.match(display, "^(%S+)$")
    if name then return name, nil end
    return nil
end

function G.ParseVictory(rest)
    -- VICTOIRE (rand 87) : Bob gagne <lien> - aucun KA deduit
    -- VICTOIRE (rand 87 OS) : Bob (Main) gagne <lien> - aucun KA deduit
    local value, tierTxt, tail = string.match(rest, "^%(rand (%d+)(.-)%) : (.+)$")
    if value then
        local tier = "ms"
        if tierTxt == " OS" then tier = "os" elseif tierTxt ~= "" then return nil end
        local display, lien = string.match(tail, "^(%S+) gagne (.+) %- aucun KA deduit$")
        if not display then display, lien = string.match(tail, "^(%S+ %b()) gagne (.+) %- aucun KA deduit$") end
        if not display then return nil end
        local name, main = SplitWinner(display)
        if not name then return nil end
        return { kind = "victory_roll", value = tonumber(value), tier = tier, name = name, main = main, lien = lien }
    end
    -- VICTOIRE : Bob gagne <lien> pour 300 KA
    -- VICTOIRE (OS) : Bob (Main) gagne <lien> pour 300 KA
    -- VICTOIRE (attribution) : Bob gagne <lien> pour 300 KA
    -- VICTOIRE (attribution) : Bob gagne <lien> - aucun KA deduit
    local prefix, tail2
    if string.sub(rest, 1, 2) == ": " then
        prefix, tail2 = "", string.sub(rest, 3)
    else
        prefix, tail2 = string.match(rest, "^(%b()) : (.+)$")
    end
    if not prefix or not tail2 or tail2 == "" then return nil end
    local tier, attribution = "ms", false
    if prefix == "" then
    elseif prefix == "(OS)" then tier = "os"
    elseif prefix == "(attribution)" then attribution = true
    else return nil end
    local display, lien, price = string.match(tail2, "^(%S+) gagne (.+) pour (%d+) KA$")
    if not display then display, lien, price = string.match(tail2, "^(%S+ %b()) gagne (.+) pour (%d+) KA$") end
    if display then
        local name, main = SplitWinner(display)
        if not name then return nil end
        return { kind = "victory", name = name, main = main, lien = lien, price = tonumber(price), tier = tier, attribution = attribution }
    end
    if attribution then
        display, lien = string.match(tail2, "^(%S+) gagne (.+) %- aucun KA deduit$")
        if not display then display, lien = string.match(tail2, "^(%S+ %b()) gagne (.+) %- aucun KA deduit$") end
        if display then
            local name, main = SplitWinner(display)
            if not name then return nil end
            return { kind = "victory", name = name, main = main, lien = lien, price = 0, tier = tier, attribution = true }
        end
    end
    return nil
end

--=============================================================================
-- Les verdicts (RAID, RAID_WARNING, GUILD). L'ordre compte : le plus
-- specifique d'abord (« ECHEC X : t'es déjà vainqueur » avant « ECHEC X : … »).
--=============================================================================

function G.Parse(text)
    if type(text) ~= "string" or text == "" then return nil end
    local s = text
    local a, b, c, d

    -- Ouverture -----------------------------------------------------------
    a = string.match(s, "^(.-) MISE AUX ENCHERISSEMENTS%. Go bid/Rand%.$")
    if a then return { kind = "open", lien = a, sang = false } end
    a = string.match(s, "^(.-) Roll for both$")
    if a then return { kind = "open", lien = a, sang = true } end
    a = string.match(s, "^(.-) %- enchère annulée%.$")
    if a then return { kind = "cancel", lien = a } end

    -- Mise acceptee, sans nom --------------------------------------------
    a, b, c = string.match(s, "^(%d+) en (%u%u) (.+)$")
    if a then
        local tier = Tier(b)
        if tier then
            for placement in pairs(G.PLACEMENTS) do
                local plen = #placement
                if string.sub(c, 1, plen + 1) == placement .. " " then
                    local prompt = string.sub(c, plen + 2)
                    if G.PROMPTS[prompt] then
                        return { kind = "accept", amount = tonumber(a), tier = tier, placement = placement, prompt = prompt }
                    end
                end
            end
        end
    end

    -- Refus ----------------------------------------------------------------
    a, b, c = string.match(s, "^ECHEC (%S+) C'est par (%d+)%. (%d+) minimum requis$")
    if a then return { kind = "refuse", name = a, why = "step", step = tonumber(b), min = tonumber(c) } end
    a, b = string.match(s, "^ECHEC (%S+) T'as (%-?%d+)%. C'est pas assez$")
    if a then return { kind = "refuse", name = a, why = "balance", have = tonumber(b) } end
    a = string.match(s, "^ECHEC (%S+) il en faut plus$")
    if a then return { kind = "refuse", name = a, why = "allin" } end
    a = string.match(s, "^ECHEC (%S+) : t'es déjà vainqueur")
    if a then return { kind = "refuse", name = a, why = "self" } end
    a, b = string.match(s, "^ECHEC (%S+) : (.+) %(compté si un PU rand%)$")
    if a then return { kind = "refuse_rule", name = a, part = "roll", motif = b } end
    a, b = string.match(s, "^ECHEC (%S+) : (.+)$")
    if a then return { kind = "refuse_rule", name = a, part = "bid", motif = b } end

    -- Paliers, rands --------------------------------------------------------
    -- « X is bidding for OS » (RetagBid) et « X is rolling for OS » (TryRoll,
    -- un rand dans l'autre palier que la mise) : les deux changent le palier.
    a, b = string.match(s, "^(%S+) is bidding for (%u%u)$")
    if a and Tier(b) then return { kind = "retag", name = a, tier = Tier(b) } end
    a, b = string.match(s, "^(%S+) is rolling for (%u%u)$")
    if a and Tier(b) then return { kind = "retag", name = a, tier = Tier(b), roll = true } end
    a, b, c = string.match(s, "^Roll (%d+) en (%u%u) pour (%S+)$")
    if a and Tier(b) then return { kind = "roll", value = tonumber(a), tier = Tier(b), name = c } end
    a, b = string.match(s, "^Roll REFUSE pour (%S+)%. (.+)$")
    if a then return { kind = "roll_refused", name = a, motif = b } end
    if string.match(s, "^Clôture reportée : rangs de guilde pas encore chargés") then
        return { kind = "ranks_not_ready" }
    end

    -- Retraits ----------------------------------------------------------------
    a, b = string.match(s, "^(%S+) passe%. (.+)$")
    if a then
        local resume = G.ParseResume(b)
        if resume then return { kind = "pass", name = a, resume = resume } end
    end
    a = string.match(s, "^Osef de ton avis (%S+)$")
    if a then return { kind = "pass_nothing", name = a } end
    a, b = string.match(s, "^Bid de (%S+) retiré%. (.+)$")
    if a then
        local resume = G.ParseResume(b)
        if resume then return { kind = "removed", name = a, resume = resume } end
    end
    a = string.match(s, "^Bid retiré%. (.+)$")
    if a then
        local resume = G.ParseResume(a)
        if resume then return { kind = "removed_anonymous", resume = resume } end
    end
    a = string.match(s, "^Dérogation : la participation de (%S+) est réactivée%.$")
    if a then return { kind = "derogation", name = a } end
    if string.match(s, "^Départage annulé : dérogation") then return { kind = "tie_cancel" } end
    a = string.match(s, "^BID Ignoré (%S+) : Viens te mesurer à YoggSaron$")
    if a then return { kind = "marker_refused", name = a } end

    -- Departage ---------------------------------------------------------------
    a, b, c = string.match(s, "^EGALITE (.-) %(tour (%d+)%) : (.+) %- refaites /roll$")
    if a then
        local names = {}
        for n in string.gmatch(c, "[^,]+") do
            n = KG.TrimStr(n)
            if n ~= "" then table.insert(names, n) end
        end
        return { kind = "tie", lien = a, round = tonumber(b), names = names }
    end
    a, b = string.match(s, "^Départage (%d+) pour (%S+)$")
    if a then return { kind = "tie_roll", value = tonumber(a), name = b } end
    if string.match(s, "^Départage : personne n'a rand") then return { kind = "tie_none" } end

    -- Palier par defaut ------------------------------------------------------
    a = string.match(s, "^OS (.+)$")
    if a then return { kind = "default_os", lien = a } end

    -- Fin ------------------------------------------------------------------------
    a = string.match(s, "^VICTOIRE (.+)$")
    if a then return G.ParseVictory(a) end
    a = string.match(s, "^(.-) Personne n'en veut")
    if a then return { kind = "nobody", lien = a } end

    -- Loots, MS ------------------------------------------------------------------
    a, b = string.match(s, "^Butin de (.-) : (.+)$")
    if not a then
        b = string.match(s, "^Butin : (.+)$")
    end
    if b then
        local links = {}
        for link in string.gmatch(b, G.LINK_PATTERN) do table.insert(links, link) end
        return { kind = "loot", who = a, links = links, raw = b }
    end
    -- « [KoinApogee] MS : … » (le recap des MS de l'officier) commence par un
    -- crochet : ce n'est pas une declaration « Nom MS texte ».
    if string.match(s, "^[^%[%]%s]%S* MS ") then
        local entries = {}
        for part in string.gmatch(s .. " ; ", "(.-) ; ") do
            local n, txt = string.match(part, "^(%S+) MS (.+)$")
            if n then table.insert(entries, { name = n, text = txt }) end
        end
        if #entries > 0 then return { kind = "ms", entries = entries } end
    end
    return nil
end

--=============================================================================
-- Ce que le joueur tape (recopie de KC.ParseBidCommand / IsAllIn et du
-- traitement de HandleBidChat). « 123 » est ignore expres par l'officier.
--=============================================================================

function G.ParseDemand(text)
    local msg = string.lower(KG.TrimStr(text or ""))
    if msg == "" or msg == "123" then return nil end
    if msg == "p" or msg == "pass" or msg == "passe" then return { kind = "pass" } end
    if msg == "mieux" then return { kind = "mieux" } end
    if msg == "all in" or msg == "allin" then return { kind = "allin" } end
    if msg == "ms" then return { kind = "tag", tier = "ms" } end
    if msg == "os" then return { kind = "tag", tier = "os" } end
    local n = tonumber(msg)
    if n then
        -- Kromaddon (TryBid) ignore en silence un montant non entier ou < 1.
        if n ~= math.floor(n) or n < 1 then return nil end
        return { kind = "bid", amount = n, tier = nil }
    end
    local nn = string.match(msg, "^(%d+)%s*ms$")
    if nn then return { kind = "bid", amount = tonumber(nn), tier = "ms" } end
    nn = string.match(msg, "^(%d+)%s*os$")
    if nn then return { kind = "bid", amount = tonumber(nn), tier = "os" } end
    nn = string.match(msg, "^ms%s*(%d+)$")
    if nn then return { kind = "bid", amount = tonumber(nn), tier = "ms" } end
    nn = string.match(msg, "^os%s*(%d+)$")
    if nn then return { kind = "bid", amount = tonumber(nn), tier = "os" } end
    return nil
end

--=============================================================================
-- Ce que l'officier chuchote au joueur.
--=============================================================================

function G.ParseWhisper(text)
    if type(text) ~= "string" or text == "" then return nil end
    local s = text
    local a, b, c, d, e
    if s == "BID OU PASSE PLZ !!!" then return { kind = "nudge" } end
    if string.match(s, "^Tu es vainqueur pour le moment%.") then return { kind = "pass_confirm" } end
    -- Un solde peut etre NEGATIF (GetPoints n'est pas borne).
    a, b, c = string.match(s, "^(%S+) : (%-?%d+) KA %(Main : (%S+)%)$")
    if a then return { kind = "ka_lookup", name = a, solde = tonumber(b), main = c } end
    a = string.match(s, "^(%S+) : personnage inconnu%.$")
    if a then return { kind = "ka_unknown", name = a } end
    a, b, c = string.match(s, "^(%-?%d+) %(Main : (%S+)%)%. Marqueur Naxx/Uldu : (.+)$")
    if a then
        local marker = { kind = "none" }
        if c == "aucun." then
            marker = { kind = "none" }
        else
            d = string.match(c, "^valable jusqu'au (%d%d/%d%d/%d%d%d%d)%.$")
            if d then marker = { kind = "valid", until_ = d }
            else
                d = string.match(c, "^expiré depuis le (%d%d/%d%d/%d%d%d%d)%.$")
                if d then marker = { kind = "expired", since = d } else marker = { kind = "unknown", text = c } end
            end
        end
        return { kind = "ka_self", solde = tonumber(a), main = b, marker = marker }
    end
    if string.match(s, "^Personnage non lié%.") then return { kind = "ka_unlinked" } end
    if string.match(s, "^Kromaddon n'est pas encore synchronis") then return { kind = "ka_notsynced" } end
    if string.match(s, "^Roster de guilde pas encore synchronisé") then return { kind = "roster_not_ready" } end
    if s == "Aucun mouvement dans ton historique." then return { kind = "ka_nologs" } end
    if s == "T'es lié à personne." then return { kind = "unlinked_info" } end
    a = string.match(s, "^T'es lié à (%S+)$")
    if a then return { kind = "linked", main = a } end
    if s == "Mauvais Nom de main" then return { kind = "bad_main" } end
    -- 06/09 21:48 Kromandant +300 (total 6054) - Raid : 8/12HC
    a, b, c, d, e = string.match(s, "^(%d%d/%d%d %d%d:%d%d) (%S+) ([%+%-]%d+) %(total (%-?%d+)%) %- (.+)$")
    if not a then
        a, b, c, d = string.match(s, "^(%d%d/%d%d %d%d:%d%d) (%S+) ([%+%-]%d+) %(total (%-?%d+)%)$")
        e = nil
    end
    if a then return { kind = "ka_log", date = a, author = b, delta = tonumber(c), total = tonumber(d), reason = e } end
    -- [KoinApogee] Tu reçois 300 KA pour Raid : 8/12HC
    a, b, c = string.match(s, "^%[KoinApogee%] Tu (%S+) (%d+) KA pour (.+)$")
    if not a then
        a, b = string.match(s, "^%[KoinApogee%] Tu (%S+) (%d+) KA$")
        c = nil
    end
    if a then
        local delta
        if a == "reçois" then delta = tonumber(b) elseif a == "perds" then delta = -tonumber(b) end
        if delta then return { kind = "movement", delta = delta, reason = c } end
    end
    return nil
end

--=============================================================================
-- Le /roll : RANDOM_ROLL_RESULT converti en motif (recopie de
-- KC.BuildRollPattern). Localise, contrairement a tout le reste.
--=============================================================================

function G.BuildRollPattern(fmt)
    fmt = fmt or RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)"
    local out = fmt
    out = string.gsub(out, "%%s", "\1")
    out = string.gsub(out, "%%d", "\2")
    out = string.gsub(out, "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    out = string.gsub(out, "\1", "(%%S+)")
    out = string.gsub(out, "\2", "(%%d+)")
    return "^" .. out .. "$"
end

function G.ParseSystem(text, pattern)
    if type(text) ~= "string" then return nil end
    G.rollPattern = G.rollPattern or G.BuildRollPattern()
    local name, value, lo, hi = string.match(text, pattern or G.rollPattern)
    if name and value then
        return { kind = "roll", name = name, value = tonumber(value), lo = tonumber(lo), hi = tonumber(hi) }
    end
    return nil
end
