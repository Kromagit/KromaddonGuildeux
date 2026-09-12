--=============================================================================
-- KromaddonGuildeux - Modules/Encheres/Tableau.lua
--
-- Le module « Encheres » : branche la Grammaire et l'Etat sur les evenements
-- du client, tient le journal /kg debug, et dessine l'onglet Encheres (§ 5.1)
-- - le meme tableau que celui des officiers, reconstruit depuis /raid.
--
-- Colonnes : Nom, Main, Rang, Roll, Bid, KA, MS. Blocs MS puis OS, un trait
-- rouge sous la derniere ligne valide, puis les lignes retirees (barrees,
-- motif en gris a la place de la MS). PU entoure de rouge, croix verte sur
-- une participation forcee, « ~ » gris sur une association incertaine.
--=============================================================================

local KG = KromaddonGuildeux
local G, E = KG.Grammaire, KG.Etat

local EN = {}
KG.RegisterModule("Encheres", EN)

--=============================================================================
-- Etat et logique, branches sur le vrai client
--=============================================================================

function EN.ItemInfo(lien)
    if not GetItemInfo then return nil end
    local name, _, _, ilvl, _, _, _, _, equipSlot = GetItemInfo(lien)
    if not name then return nil end
    return ilvl, (equipSlot ~= nil and equipSlot ~= "")
end

function EN:EnsureState()
    if self.S then return self.S end
    self.S = E.New({
        me = KG.PlayerName(),
        isOfficer = KG.IsOfficer,
        inGroup = KG.IsInMyGroup,
        itemInfo = EN.ItemInfo,
        now = KG.Now,
        onEffect = function(kind, data) EN:OnEffect(kind, data) end,
    })
    self.L = KG.Boutons.New({
        me = KG.PlayerName(),
        etat = self.S,
        now = KG.Now,
        inGroup = KG.InGroup,
        kaSelf = function() return KG.KA and KG.KA.Logic and KG.KA:Logic():SelfInfo() or nil end,
        send = function(text)
            local channel = KG.InRaid() and "RAID" or "PARTY"
            pcall(SendChatMessage, text, channel)
            KG.Debug("MOI", KG.PlayerName(), text, "envoyé en " .. channel)
        end,
        roll = function() if RandomRoll then RandomRoll(1, 100) end end,
    })
    return self.S
end

function EN:OnEffect(kind, data)
    if self.L then self.L:OnEffect(kind, data) end
    KG.Dispatch("OnAuctionEffect", kind, data)
    self:Refresh()
end

function EN:OnLogin()
    self:EnsureState()
end

-- Une ligne de RAID / RW / PARTY / GUILD : un verdict de l'officier, sinon
-- une demande d'un membre. Tout est journalise.
function EN:OnChat(channel, text, sender)
    local S = self:EnsureState()
    local now = KG.Now()
    -- Un verdict ne peut venir que d'un officier : la ligne d'un membre est
    -- une demande, meme si elle ressemble a un verdict (« OS 150 » en
    -- majuscules a la forme du « OS <lien> » de l'officier).
    local officer, why = KG.OfficerStatus(sender)
    local ev = officer and G.Parse(text) or nil
    if ev then
        local verdict = S:Verdict(ev, sender, now)
        KG.Debug(channel, sender, text, verdict)
        if ev.kind == "loot" then KG.Dispatch("OnLootAnnounced", ev, sender) end
        if ev.kind == "open" and S.current and S.current.annonceur == sender then KG.Dispatch("OnAuctionOpened", S.current) end
        self:Refresh()
        return
    end
    if channel == "GUILD" then
        KG.Debug(channel, sender, text, "ignoré (guilde)")
        return
    end
    local dem = G.ParseDemand(text)
    if dem then
        KG.Debug(channel, sender, text, S:Demand(sender, dem, now))
        return
    end
    -- Le journal dit LAQUELLE des deux portes a refuse : la ligne d'un
    -- officier que la grammaire ne lit pas, ou un expediteur qui n'est pas
    -- officier (et pourquoi). Le premier /kg debug ne le disait pas.
    if officer then
        KG.Debug(channel, sender, text, "ignoré : ligne d'officier NON RECONNUE")
    else
        KG.Debug(channel, sender, text, "ignoré (" .. why .. ")")
    end
end

function EN:OnSystem(text)
    local S = self:EnsureState()
    local ev = G.ParseSystem(text)
    if ev then
        S:RawRoll(KG.NormalizeName(ev.name) or ev.name, ev.value, ev.lo, ev.hi)
        KG.Debug("SYSTEM", "", text, "roll brut")
    end
end

function EN:OnWhisper(text, sender)
    local ev = G.ParseWhisper(text)
    if not ev then KG.Debug("WHISPER", sender, text, "ignoré"); return end
    if ev.kind == "nudge" or ev.kind == "pass_confirm" then
        local S = self:EnsureState()
        if S.current and sender == S.current.annonceur then
            self:OnEffect(ev.kind, ev)
            KG.Debug("WHISPER", sender, text, ev.kind)
        else
            KG.Debug("WHISPER", sender, text, "ignoré : pas l'annonceur")
        end
        return
    end
    -- Les autres (?ka, mouvements) sont pour le module KA, qui journalise.
end

function EN:OnTick(now)
    if not self.S then return end
    self.S:Tick(KG.Now())
    if self.L then self.L:Tick(KG.Now()) end
    if self.widgets and self.widgets.Refresh and KG.Frame:IsShown() and KG.tabs.encheres.panel:IsShown() then
        self.widgets.Refresh(now)
    end
end

function EN:OnRaidChanged()
    self:Refresh()
end

--=============================================================================
-- L'onglet
--=============================================================================

-- Largeur utile de l'enfant du ScrollFrame : panneau 544 - zone 4 - barre 24
-- - marges = ~510 px. Les x sont relatifs a l'enfant ; les en-tetes, poses
-- sur le panneau, sont decales de EN.CHILD_X.
EN.COLS = {
    { key = "nom", label = "Nom", x = 4, w = 100, just = "LEFT" },
    { key = "main", label = "Main", x = 106, w = 80, just = "LEFT" },
    { key = "rang", label = "Rang", x = 188, w = 54, just = "LEFT" },
    { key = "roll", label = "Roll", x = 244, w = 34, just = "RIGHT" },
    { key = "bid", label = "Bid", x = 282, w = 46, just = "RIGHT" },
    { key = "ka", label = "KA", x = 332, w = 52, just = "RIGHT" },
    { key = "ms", label = "MS", x = 388, w = 118, just = "LEFT" },
}
EN.ROW_H = 16
EN.CHILD_X = 4
EN.FORCE_ICON = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12|t "

-- Ce que les colonnes Main / Rang / KA disent d'un nom (§ 5.1), d'apres le
-- module KA et le roster. Pure vis-a-vis des frames.
-- « PU » ne se conclut que sur un roster COMPLET (hors-ligne compris) : un
-- main deconnecte absent d'un roster partiel n'est pas un etranger, il est
-- inconnu pour l'instant (« ? »).
function EN.Identity(name, hasBid)
    local info = KG.KA and KG.KA.Logic and KG.KA:Logic():Lookup(name) or nil
    local main = info and info.main or nil
    local rang, pu = "", false
    if main then
        local mainRank = KG.guildRanks[main]
        if mainRank then
            rang = mainRank
            if not KG.guildRanks[name] then rang = "{" .. rang .. "}" end
        elseif KG.rosterComplete then
            rang, pu = "PU", true
        else
            rang = "?"
        end
    end
    local ka = (hasBid and info and info.solde ~= nil) and tostring(info.solde) or ""
    return main or "", rang, ka, pu
end

function EN:Build(panel)
    self:EnsureState()
    local W = { rows = {} }
    self.widgets = W

    -- Ligne d'objet et d'etat
    W.item = KG.Label(panel, "", "GameFontNormal")
    W.item:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, -4)
    W.item:SetWidth(360); W.item:SetHeight(16); W.item:SetWordWrap(false); W.item:SetJustifyH("LEFT")
    local itemBtn = CreateFrame("Button", nil, panel)
    itemBtn:SetAllPoints(W.item)
    itemBtn:SetScript("OnEnter", function(self)
        local e = EN.S and EN.S.current
        if e and e.lien and KG.ItemID(e.lien) then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(e.lien)
            GameTooltip:Show()
        end
    end)
    itemBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    W.status = KG.Label(panel, "")
    W.status:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -6)
    W.status:SetJustifyH("RIGHT")
    W.bandeau = KG.Label(panel, "")
    W.bandeau:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, -22)
    W.bandeau:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -22)
    W.bandeau:SetHeight(14); W.bandeau:SetWordWrap(false); W.bandeau:SetJustifyH("LEFT")
    do local c = KG.Theme.yellow; W.bandeau:SetTextColor(c[1], c[2], c[3]) end

    -- En-tetes
    local headerY = -40
    for _, col in ipairs(EN.COLS) do
        local h = KG.Label(panel, col.label)
        h:SetPoint("TOPLEFT", panel, "TOPLEFT", col.x + EN.CHILD_X, headerY)
        h:SetWidth(col.w); h:SetJustifyH(col.just)
        do local c = KG.Theme.gold; h:SetTextColor(c[1], c[2], c[3]) end
    end

    -- Le tableau defilant
    local zone = KG.CreateZone(panel)
    zone:SetPoint("TOPLEFT", panel, "TOPLEFT", 2, headerY - 14)
    zone:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -2, 56)
    local scroll = KG.NewScrollFrame(panel, "KromaddonGuildeuxEncheresScroll")
    scroll:SetPoint("TOPLEFT", zone, "TOPLEFT", 2, -2)
    scroll:SetPoint("BOTTOMRIGHT", zone, "BOTTOMRIGHT", -24, 2)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetWidth(520); child:SetHeight(10)
    scroll:SetScrollChild(child)
    W.scroll, W.child = scroll, child

    W.trait = child:CreateTexture(nil, "ARTWORK")
    W.trait:SetHeight(1)
    KG.SetThemeTexture(W.trait, "red", 0.9)
    W.trait:Hide()

    self.buttons = KG.Boutons.Build(panel, self.L, { Refresh = function() EN:Refresh() end })
    W.Refresh = function(now) EN.buttons.Refresh(now) end
    self:Refresh()
end

local function AcquireRow(W, i)
    local r = W.rows[i]
    if r then return r end
    local child = W.child
    r = CreateFrame("Frame", nil, child)
    r:SetHeight(EN.ROW_H)
    r:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -(i - 1) * EN.ROW_H)
    r:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -(i - 1) * EN.ROW_H)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints(r)
    KG.SetThemeTexture(r.bg, (i % 2 == 1) and "rowOdd" or "rowEven")
    r.cells = {}
    for _, col in ipairs(EN.COLS) do
        local fs = KG.Label(r, "")
        fs:SetPoint("LEFT", r, "LEFT", col.x, 0)
        fs:SetWidth(col.w); fs:SetHeight(EN.ROW_H); fs:SetWordWrap(false); fs:SetJustifyH(col.just)
        r.cells[col.key] = fs
    end
    r.strike = r:CreateTexture(nil, "OVERLAY")
    r.strike:SetHeight(1)
    r.strike:SetPoint("LEFT", r.cells.nom, "LEFT", 0, 0)
    r.strike:SetPoint("RIGHT", r.cells.bid, "RIGHT", 0, 0)
    KG.SetThemeTexture(r.strike, "muted", 0.9)
    r.strike:Hide()
    r:SetBackdrop({ edgeFile = KG.WHITE_TEXTURE, edgeSize = 1 })
    r:SetBackdropBorderColor(0, 0, 0, 0)
    W.rows[i] = r
    return r
end

local function Fmt(l, field, off)
    local v = l[field]
    if v == nil then return "" end
    if off then return KG.Hex("muted") .. tostring(v) .. "|r" end
    return tostring(v)
end

function EN:Refresh()
    local W = self.widgets
    if not W or not W.child then return end
    local S = self.S
    local e = S and S.current
    local me = KG.PlayerName()

    -- Objet, etat, bandeau
    if e then
        local label = e.lien and KG.ItemLabel(e.lien) or "objet inconnu"
        W.item:SetText(string.format("%s  %s[%s]|r", label, KG.Hex("muted"), e.circuit))
        W.status:SetText(E.StatusText(e))
        local bandeau = {}
        if e.partial then table.insert(bandeau, "enchère rejointe en cours : tableau partiel") end
        if e.desaccord then table.insert(bandeau, "le tableau ne suit plus l'officier : " .. e.desaccord) end
        if e.officierAncien then table.insert(bandeau, "officier en version antérieure (retrait sans nom)") end
        if e.note then table.insert(bandeau, e.note) end
        W.bandeau:SetText(table.concat(bandeau, " — "))
    else
        W.item:SetText(KG.Hex("muted") .. "aucune enchère en cours|r")
        W.status:SetText("")
        W.bandeau:SetText("")
    end

    -- Lignes
    local rows = E.Rows(e)
    local winner = E.Winner(e)
    local i, lastActive = 0, 0
    for _, entry in ipairs(rows) do
        i = i + 1
        local l, off = entry.line, (entry.block == "off")
        local r = AcquireRow(W, i)
        local main, rang, ka, pu = EN.Identity(l.nom, l.bid ~= nil)
        local nom = KG.Flatten(l.nom)
        if winner and winner.nom == l.nom and not off then nom = KG.Hex("gold") .. nom .. "|r" end
        if l.nom == me then nom = KG.Hex("green") .. KG.Flatten(l.nom) .. "|r" end
        if l.incertain then nom = nom .. KG.Hex("muted") .. " ~|r" end
        if l.force and not off then nom = EN.FORCE_ICON .. nom end   -- la croix verte, en tete de ligne
        r.cells.nom:SetText(nom)
        r.cells.main:SetText(main)
        r.cells.rang:SetText(pu and (KG.Hex("red") .. rang .. "|r") or rang)
        r.cells.roll:SetText(Fmt(l, "roll", off or (l.rollOff and not l.force)))
        r.cells.bid:SetText(Fmt(l, "bid", off or (l.bidOff and not l.force)))
        r.cells.ka:SetText(off and "" or ka)
        if off then
            local motif = l.bidOff or l.rollOff or ""
            r.cells.ms:SetText(KG.Hex("muted") .. KG.Flatten(motif) .. "|r")
            r.strike:Show()
        else
            r.cells.ms:SetText(KG.Flatten(S.ms[l.nom] or ""))
            r.strike:Hide()
            lastActive = i
        end
        if pu then r:SetBackdropBorderColor(0.9, 0.3, 0.3, 0.9) else r:SetBackdropBorderColor(0, 0, 0, 0) end
        r:Show()
    end
    for j = i + 1, #W.rows do W.rows[j]:Hide() end

    -- Le trait sous la derniere ligne valide
    if lastActive > 0 and lastActive < i then
        W.trait:ClearAllPoints()
        W.trait:SetPoint("TOPLEFT", W.child, "TOPLEFT", 2, -lastActive * EN.ROW_H)
        W.trait:SetPoint("TOPRIGHT", W.child, "TOPRIGHT", -2, -lastActive * EN.ROW_H)
        W.trait:Show()
    else
        W.trait:Hide()
    end
    W.child:SetHeight(math.max(10, i * EN.ROW_H + 2))
    if W.scroll and W.scroll:GetWidth() > 0 then W.child:SetWidth(W.scroll:GetWidth()) end

    if self.buttons and self.buttons.Refresh then self.buttons.Refresh(GetTime and GetTime() or 0) end
end

function EN:OnTabShown(key)
    if key == "encheres" then self:Refresh() end
end

if KG.RegisterTab then
    KG.RegisterTab("encheres", function(panel) EN:Build(panel) end)
end
