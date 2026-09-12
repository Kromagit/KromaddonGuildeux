--=============================================================================
-- KromaddonGuildeux - Modules/Encheres/Boutons.lua
--
-- « Mise Min » (deux clics, montant fige), « Rand », « Passe » (§ 5.2-5.5).
--
-- La LOGIQUE est pure (KG.Boutons.New) et testee dans tests/mise_min.lua et
-- tests/passe.lua : elle decide quoi envoyer et ce que le bouton affiche ;
-- l'envoi lui-meme (SendChatMessage, RandomRoll) est injecte. Les frames
-- sont construites plus bas, seulement en jeu (if KG.Frame).
--
-- Regle absolue (§ 5.5) : aucun envoi en /raid sans clic.
--=============================================================================

local KG = KromaddonGuildeux
local E = KG.Etat
local B = {}
KG.Boutons = B

B.ARM_TTL = 20          -- un « Miser N » non confirme retombe apres 20 s
B.REPLY_TTL = 5         -- « pas de réponse de l'officier » apres 5 s

--=============================================================================
-- Logique pure
--=============================================================================

-- opts : me, send(text) (envoi en RAID/PARTY), roll() (RandomRoll 1-100),
-- now(), etat (l'objet Etat), kaSelf() -> { marker = {kind=...} } ou nil,
-- inGroup() -> bool.
function B.New(opts)
    opts = opts or {}
    local L = {
        me = opts.me or "?",
        send = opts.send or function() end,
        roll = opts.roll or function() end,
        now = opts.now or function() return time() end,
        etat = opts.etat,
        kaSelf = opts.kaSelf or function() return nil end,
        inGroup = opts.inGroup or function() return true end,
        state = "idle",         -- "idle" | "armed" | "sent"
        montant = nil,
        armedAt = nil,
        sentAt = nil,
        tierChoice = "auto",    -- "auto" | "ms" | "os"
        feedback = nil,         -- { text=, color= }
        passState = "idle",     -- "idle" | "sent" | "confirm" | "done"
        passSentAt = nil,
        nudge = nil,            -- heure du dernier « BID OU PASSE PLZ !!! »
        rolledSerial = nil,     -- serial de l'enchere ou j'ai rand
        rolledRound = nil,      -- tour de departage ou j'ai rerand
    }
    return setmetatable(L, { __index = B })
end

function B:Current()
    return self.etat and self.etat.current or nil
end

function B:MyLine()
    local e = self:Current()
    return e and e.lignes[self.me] or nil
end

-- Le palier de ma prochaine mise : mon choix explicite, sinon mon palier
-- collant, sinon le palier par defaut de l'enchere.
function B:MyTier(e)
    if self.tierChoice ~= "auto" then return self.tierChoice end
    local l = self:MyLine()
    if l and l.tier then return l.tier end
    return e and e.palierDefaut or "ms"
end

-- Peut-on miser ? Rend true, ou false + la raison affichee.
function B:CanBid()
    local e = self:Current()
    if not self.inGroup() then return false, "hors raid" end
    if not e then return false, "aucune enchère" end
    if e.statut ~= "ouverte" and e.statut ~= "departage" then return false, "enchère " .. E.StatusText(e) end
    if e.circuit == "NM" or e.circuit == "SANG" then return false, "aux rands" end
    if e.circuit == "?" then return false, "objet pas encore identifié" end
    if e.circuit == "MARQUEUR" then
        local ka = self.kaSelf()
        if not (ka and ka.marker and ka.marker.kind == "valid") then return false, "marqueur Naxx/Uldu requis" end
    end
    return true
end

-- Premier clic : fige le montant. Second clic : envoie. Rend l'action.
function B:MiseMinClick()
    local ok, why = self:CanBid()
    if not ok then return "refused", why end
    local e = self:Current()
    local now = self.now()
    if self.state == "armed" and self.montant then
        local text = tostring(self.montant)
        if self.tierChoice == "os" then text = text .. " os" elseif self.tierChoice == "ms" then text = text .. " ms" end
        self.send(text)
        self.state, self.sentAt = "sent", now
        self.feedback = { text = "mise envoyée : " .. text, color = "muted" }
        return "send", text
    end
    local tier = self:MyTier(e)
    self.montant = E.NextValidBid(E.TopBid(e, tier))
    self.state, self.armedAt = "armed", now
    self.feedback = nil
    return "arm", self.montant
end

function B:CancelArm()
    if self.state == "armed" then self.state, self.montant = "idle", nil end
end

function B:MiseMinLabel()
    if self.state == "armed" and self.montant then return "Miser " .. self.montant end
    return "Mise Min"
end

function B:SetTierChoice(choice)
    if choice == "ms" or choice == "os" then self.tierChoice = choice else self.tierChoice = "auto" end
    self:CancelArm()
end

-- Rand : grise des que mon rand est lu, ou pendant un departage ou je ne
-- suis pas nomme ; reactive si un EGALITE me nomme (rerand).
function B:CanRoll()
    local e = self:Current()
    if not self.inGroup() then return false, "hors raid" end
    if not e then return false, "aucune enchère" end
    if e.statut == "departage" then
        if not (e.departage and e.departage.noms[self.me]) then return false, "départage sans moi" end
        if self.rolledRound == e.departage.tour and self.rolledSerial == e.serial then return false, "rerand déjà fait" end
        return true
    end
    if e.statut ~= "ouverte" then return false, "enchère " .. E.StatusText(e) end
    local l = self:MyLine()
    if l and l.roll ~= nil then return false, "déjà rand" end
    if self.rolledSerial == e.serial then return false, "rand envoyé" end
    return true
end

function B:RandClick()
    local ok, why = self:CanRoll()
    if not ok then return "refused", why end
    local e = self:Current()
    self.roll()
    self.rolledSerial = e.serial
    if e.statut == "departage" and e.departage then self.rolledRound = e.departage.tour end
    self.feedback = { text = "rand envoyé", color = "muted" }
    return "roll"
end

function B:CanPass()
    local e = self:Current()
    if not self.inGroup() then return false, "hors raid" end
    if not e then return false, "aucune enchère" end
    if e.statut ~= "ouverte" and e.statut ~= "departage" then return false, "enchère " .. E.StatusText(e) end
    return true
end

function B:PasseClick()
    local ok, why = self:CanPass()
    if not ok then return "refused", why end
    self.send("passe")
    self.passSentAt = self.now()
    if self.passState == "confirm" then self.passState = "sent" else self.passState = "sent" end
    self.nudge = nil
    return "send", "passe"
end

function B:PasseLabel()
    if self.passState == "confirm" then return "Confirmer le passe" end
    return "Passe"
end

-- Ce que l'Etat et les chuchotements me disent (effets).
function B:OnEffect(kind, data)
    if kind == "open" or kind == "cleared" then
        self.state, self.montant, self.sentAt = "idle", nil, nil
        self.passState, self.nudge, self.feedback = "idle", nil, nil
        self.rolledRound = nil
        return
    end
    if kind == "mine_accepted" then
        self.state, self.sentAt = "idle", nil
        self.feedback = { text = "mise passée : " .. tostring(data.amount) .. " " .. string.upper(data.tier or ""), color = "green" }
        self.nudge = nil
    elseif kind == "mine_refused" then
        self.state, self.montant, self.sentAt = "idle", nil, nil
        local why = data and data.why
        local text
        if why == "step" then text = string.format("refusée : c'est par %d, %d minimum", data.step or 0, data.min or 0)
        elseif why == "balance" then text = string.format("refusée : t'as %d, c'est pas assez", data.have or 0)
        elseif why == "self" then text = "refusée : t'es déjà vainqueur"
        elseif why == "allin" then text = "refusée : il en faut plus"
        elseif why == "marker" then text = "ignorée : pas de marqueur Naxx/Uldu"
        elseif data and data.motif then text = "hors jeu : " .. KG.Flatten(data.motif)
        else text = "refusée" end
        self.feedback = { text = text, color = "red" }
    elseif kind == "mine_rolled" then
        self.feedback = { text = "rand " .. tostring(data.value) .. " compté", color = "green" }
    elseif kind == "mine_passed" then
        self.passState, self.passSentAt = "done", nil
        self.feedback = { text = "passe fait", color = "green" }
        self.nudge = nil
    elseif kind == "mine_nothing" then
        self.passState, self.passSentAt = "idle", nil
        self.feedback = { text = "rien à retirer", color = "muted" }
    elseif kind == "nudge" then
        self.nudge = self.now()
        self.feedback = { text = "BID OU PASSE PLZ !!!", color = "yellow" }
    elseif kind == "pass_confirm" then
        self.passState, self.passSentAt = "confirm", nil
        self.feedback = { text = "tu es vainqueur pour le moment : confirme le passe", color = "yellow" }
    elseif kind == "mine_won" then
        self.feedback = { text = "gagné pour " .. tostring(data.prix or 0) .. " KA", color = "green" }
    end
end

-- Expirations : le montant fige retombe apres 20 s ; une mise ou un passe
-- sans verdict apres 5 s le dit.
function B:Tick(now)
    now = now or self.now()
    if self.state == "armed" and self.armedAt and now - self.armedAt >= B.ARM_TTL then
        self.state, self.montant = "idle", nil
    end
    if self.state == "sent" and self.sentAt and now - self.sentAt >= B.REPLY_TTL then
        self.state, self.sentAt = "idle", nil
        self.feedback = { text = "pas de réponse de l'officier", color = "yellow" }
    end
    if self.passState == "sent" and self.passSentAt and now - self.passSentAt >= B.REPLY_TTL then
        self.passState, self.passSentAt = "idle", nil
        self.feedback = { text = "pas de réponse de l'officier", color = "yellow" }
    end
end

-- Toujours sur l'horloge de la logique (time()) : le rendu, lui, tourne sur
-- GetTime() (uptime) — melanger les deux rendait la difference toujours
-- negative et le bouton clignotait sans fin.
function B:NudgeBlinking()
    local now = self.now()
    return self.nudge ~= nil and (now - self.nudge) < 30
end

--=============================================================================
-- Les frames (en jeu seulement)
--=============================================================================

if KG.Frame then
    function B.Build(panel, logic, host)
        local row = CreateFrame("Frame", nil, panel)
        row:SetHeight(26)
        row:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 4, 26)
        row:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 26)

        local mise = KG.NewButton(row, "Mise Min", 110, 22)
        mise:SetPoint("LEFT", row, "LEFT", 0, 0)
        mise:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        mise:SetScript("OnClick", function(self, button)
            if button == "RightButton" then logic:CancelArm() else logic:MiseMinClick() end
            host.Refresh()
        end)

        -- Le palier : Auto / MS / OS, un petit bouton qui tourne.
        local tier = KG.NewButton(row, "Auto", 50, 22)
        tier:SetPoint("LEFT", mise, "RIGHT", 4, 0)
        tier:SetScript("OnClick", function()
            local nextChoice = { auto = "ms", ms = "os", os = "auto" }
            logic:SetTierChoice(nextChoice[logic.tierChoice] or "auto")
            host.Refresh()
        end)

        local rand = KG.NewButton(row, "Rand", 80, 22)
        rand:SetPoint("LEFT", tier, "RIGHT", 8, 0)
        rand:SetScript("OnClick", function() logic:RandClick(); host.Refresh() end)

        local passe = KG.NewButton(row, "Passe", 130, 22)
        passe:SetPoint("LEFT", rand, "RIGHT", 8, 0)
        passe:SetScript("OnClick", function() logic:PasseClick(); host.Refresh() end)

        local fb = KG.Label(panel, "")
        fb:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 6, 8)
        fb:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -6, 8)
        fb:SetJustifyH("LEFT")

        local widgets = { mise = mise, tier = tier, rand = rand, passe = passe, fb = fb, row = row }
        function widgets.Refresh(now)
            mise:SetText(logic:MiseMinLabel())
            local ok, why = logic:CanBid()
            if ok then mise:Enable() else mise:Disable() end
            mise.tooltip = why
            tier:SetText(logic.tierChoice == "auto" and "Auto" or string.upper(logic.tierChoice))
            ok = logic:CanRoll()
            if ok then rand:Enable() else rand:Disable() end
            passe:SetText(logic:PasseLabel())
            ok = logic:CanPass()
            if ok then passe:Enable() else passe:Disable() end
            if logic:NudgeBlinking() and math.floor((now or GetTime()) * 2) % 2 == 0 then
                passe:LockHighlight()
            else
                passe:UnlockHighlight()
            end
            local f = logic.feedback
            if f then
                fb:SetText(KG.Hex(f.color or "text") .. f.text .. "|r")
            elseif not logic:CanBid() then
                local _, reason = logic:CanBid()
                fb:SetText(KG.Hex("muted") .. (reason or "") .. "|r")
            else
                fb:SetText("")
            end
        end
        return widgets
    end
end
