--=============================================================================
-- KromaddonGuildeux - Modules/Options/Options.lua
--
-- L'onglet Options (§ 7) : « Ouvrir aux loots », la liste des loots annonces
-- de la soiree avec des cases a cocher (par itemID, dans les SavedVariables,
-- purge a 6 h), « Ouvrir pour les loots cochés » (a l'ouverture de l'enchere
-- sur un objet coche : onglet Encheres + clignotement), position / echelle /
-- verrou de la fenetre.
--
-- Sans « Ouvrir aux loots », « Ouvrir pour les loots cochés » ni « Ouvrir pour
-- toutes les enchères » (12/09), la fenetre ne s'ouvre JAMAIS seule.
--
-- Les rangs officier (§ 6.2) sont en dur dans le code (KG.IsOfficerRankName),
-- « Vider le cache ?ka » est devenu la commande `/kg cache`, et le bouton
-- « /kg debug » a disparu (la commande /kg debug existe toujours) — les
-- quatre retires du panneau le 14/09 sur demande de Kroma.
--
-- La logique des loots est pure (OP.New) et testee dans tests/options_loots.lua.
--=============================================================================

local KG = KromaddonGuildeux
local OP = {}
KG.RegisterModule("Options", OP)

OP.LOOT_TTL = 6 * 3600

--=============================================================================
-- Logique pure des loots
--=============================================================================

-- opts : db (la base), now(), onEffect(kind, data).
function OP.New(opts)
    opts = opts or {}
    local L = {
        db = opts.db or { loots = {} },
        now = opts.now or function() return time() end,
        onEffect = opts.onEffect or function() end,
    }
    L.db.loots = L.db.loots or {}
    return setmetatable(L, { __index = OP })
end

function OP:Purge()
    local now = self.now()
    for id, e in pairs(self.db.loots) do
        if type(e) ~= "table" or not e.t or now - e.t > OP.LOOT_TTL then self.db.loots[id] = nil end
    end
end

-- « Butin de X : <liens> » d'un officier : chaque lien identifie par son
-- itemID ; une case deja cochee le reste ; les tranches repetent l'en-tete
-- (PackLootMessages), donc on CUMULE. Rend le nombre d'objets nouveaux.
function OP:OnLoot(ev)
    if not ev or not ev.links then return 0 end
    self:Purge()
    local added = 0
    local now = self.now()
    for _, link in ipairs(ev.links) do
        local id = KG.ItemID(link)
        if id then
            local e = self.db.loots[id]
            if not e then
                e = { link = link, checked = false, t = now, boss = ev.who }
                self.db.loots[id] = e
                added = added + 1
            else
                e.link = link   -- la date reste celle de la premiere annonce
            end
        end
    end
    if added > 0 and self.db.ouvrirAuxLoots then self.onEffect("open_options", { added = added }) end
    return added
end

function OP:Toggle(id, checked)
    local e = self.db.loots[id]
    if not e then return false end
    e.checked = checked and true or false
    return true
end

function OP:IsChecked(id)
    local e = id and self.db.loots[id]
    return e ~= nil and e.checked == true
end

-- A l'ouverture d'une enchere : si « toutes les enchères » est coche, ou si
-- l'objet est coche dans la liste, on ouvre l'onglet Encheres et on le fait
-- clignoter.
function OP:AuctionOpened(e)
    if not e then return false end
    if self.db.ouvrirToutesEncheres then
        self.onEffect("open_encheres", e)
        return true
    end
    if not e.itemID then return false end
    if not self.db.ouvrirPourCoches then return false end
    if not self:IsChecked(e.itemID) then return false end
    self.onEffect("open_encheres", e)
    return true
end

-- La liste, du plus recent au plus ancien.
function OP:List()
    self:Purge()
    local list = {}
    for id, e in pairs(self.db.loots) do table.insert(list, { id = id, link = e.link, checked = e.checked, t = e.t, boss = e.boss }) end
    table.sort(list, function(a, b)
        if a.t == b.t then return a.id < b.id end
        return a.t > b.t
    end)
    return list
end

function OP:Clear()
    self.db.loots = {}
end

--=============================================================================
-- Branchement sur le client
--=============================================================================

function OP:Logic()
    if self.logic then return self.logic end
    self.logic = OP.New({
        db = KG.GetDB(),
        now = KG.Now,
        onEffect = function(kind, data)
            if kind == "open_options" then
                KG.ShowWindow("options")
                KG.FlashTab("options")
            elseif kind == "open_encheres" then
                KG.ShowWindow("encheres")
                KG.FlashTab("encheres")
            end
            OP:Refresh()
        end,
    })
    return self.logic
end

function OP:OnLogin() self:Logic() end
function OP:OnLootAnnounced(ev, sender) self:Logic():OnLoot(ev) end
function OP:OnAuctionOpened(e) self:Logic():AuctionOpened(e) end
function OP:OnTabShown(key) if key == "options" then self:Refresh() end end

--=============================================================================
-- L'onglet
--=============================================================================

local function CheckBox(parent, label, x, y, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    cb:SetWidth(24); cb:SetHeight(24)
    local fs = KG.Label(parent, label)
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cb:SetChecked(get() and true or false)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    cb.Refresh = function() cb:SetChecked(get() and true or false) end
    return cb
end

function OP:Build(panel)
    local W = { rows = {} }
    self.widgets = W
    local db = KG.GetDB()

    W.cbLoots = CheckBox(panel, "Ouvrir la fenêtre quand un butin est annoncé", 4, -2,
        function() return KG.GetDB().ouvrirAuxLoots end, function(v) KG.GetDB().ouvrirAuxLoots = v end)
    W.cbCoches = CheckBox(panel, "Ouvrir sur l'enchère d'un loot coché", 4, -26,
        function() return KG.GetDB().ouvrirPourCoches end, function(v) KG.GetDB().ouvrirPourCoches = v end)
    W.cbToutes = CheckBox(panel, "Ouvrir pour toutes les enchères", 4, -50,
        function() return KG.GetDB().ouvrirToutesEncheres end, function(v) KG.GetDB().ouvrirToutesEncheres = v end)
    W.cbLock = CheckBox(panel, "Verrouiller la position", 4, -74,
        function() return KG.GetDB().verrouille end, function(v) KG.GetDB().verrouille = v end)

    -- Echelle
    local scaleLabel = KG.Label(panel, "Échelle")
    scaleLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 300, -8)
    local slider = CreateFrame("Slider", "KromaddonGuildeuxScaleSlider", panel, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", panel, "TOPLEFT", 300, -26)
    slider:SetWidth(200); slider:SetHeight(16)
    slider:SetMinMaxValues(0.6, 1.4); slider:SetValueStep(0.05)
    slider:SetValue(tonumber(db.echelle) or 1)
    if getglobal(slider:GetName() .. "Low") then getglobal(slider:GetName() .. "Low"):SetText("60 %") end
    if getglobal(slider:GetName() .. "High") then getglobal(slider:GetName() .. "High"):SetText("140 %") end
    if getglobal(slider:GetName() .. "Text") then getglobal(slider:GetName() .. "Text"):SetText("") end
    slider:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v * 20 + 0.5) / 20
        KG.GetDB().echelle = v
        KG.ApplyScale()
        scaleLabel:SetText(string.format("Échelle : %d %%", math.floor(v * 100 + 0.5)))
    end)
    scaleLabel:SetText(string.format("Échelle : %d %%", math.floor((tonumber(db.echelle) or 1) * 100 + 0.5)))

    -- Loots de la soiree
    local lootLabel = KG.Label(panel, "Loots annoncés cette soirée (coche ceux qui t'intéressent) :")
    lootLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -128)
    do local c = KG.Theme.gold; lootLabel:SetTextColor(c[1], c[2], c[3]) end
    local forget = KG.NewButton(panel, "Vider", 60, 20)
    forget:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -124)
    forget:SetScript("OnClick", function() OP:Logic():Clear(); OP:Refresh() end)

    local zone = KG.CreateZone(panel)
    zone:SetPoint("TOPLEFT", panel, "TOPLEFT", 2, -144)
    zone:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -2, 24)
    local scroll = KG.NewScrollFrame(panel, "KromaddonGuildeuxLootsScroll")
    scroll:SetPoint("TOPLEFT", zone, "TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", zone, "BOTTOMRIGHT", -26, 4)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetWidth(500); child:SetHeight(10)
    scroll:SetScrollChild(child)
    W.scroll, W.child = scroll, child

    local version = KG.Label(panel, "KromaddonGuildeux " .. tostring(KG.Version) .. "  —  /kg, /kg options, /kg ka, /kg debug, /kg cache")
    version:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 6, 6)
    do local c = KG.Theme.muted; version:SetTextColor(c[1], c[2], c[3]) end
    self:Refresh()
end

local function LootRow(W, i)
    local r = W.rows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, W.child)
    r:SetHeight(22)
    r:SetPoint("TOPLEFT", W.child, "TOPLEFT", 0, -(i - 1) * 22)
    r:SetPoint("TOPRIGHT", W.child, "TOPRIGHT", 0, -(i - 1) * 22)
    r.cb = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
    r.cb:SetPoint("LEFT", r, "LEFT", 0, 0); r.cb:SetWidth(22); r.cb:SetHeight(22)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetWidth(18); r.icon:SetHeight(18)
    r.icon:SetPoint("LEFT", r.cb, "RIGHT", 2, 0)
    r.name = CreateFrame("Button", nil, r)
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
    r.name:SetPoint("RIGHT", r, "RIGHT", -4, 0)
    r.name:SetHeight(22)
    r.text = KG.Label(r.name, "")
    r.text:SetAllPoints(r.name); r.text:SetJustifyH("LEFT")
    r.name:SetScript("OnEnter", function(self)
        if r.link and KG.ItemID(r.link) then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink(r.link); GameTooltip:Show()
        end
    end)
    r.name:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r.name:SetScript("OnClick", function() r.cb:Click() end)
    W.rows[i] = r
    return r
end

function OP:Refresh()
    local W = self.widgets
    if not W or not W.child then return end
    for _, cb in ipairs({ W.cbLoots, W.cbCoches, W.cbToutes, W.cbLock }) do if cb and cb.Refresh then cb.Refresh() end end
    local list = self:Logic():List()
    local i = 0
    for _, e in ipairs(list) do
        i = i + 1
        local r = LootRow(W, i)
        r.link = e.link
        local texture = GetItemIcon and GetItemIcon(e.id) or nil
        r.icon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
        local label = KG.ItemLabel(e.link)
        if e.boss then label = label .. KG.Hex("muted") .. "  (" .. KG.Flatten(e.boss) .. ")|r" end
        r.text:SetText(label)
        r.cb:SetChecked(e.checked)
        r.cb:SetScript("OnClick", function(self)
            OP:Logic():Toggle(e.id, self:GetChecked() and true or false)
        end)
        r:Show()
    end
    for j = i + 1, #W.rows do W.rows[j]:Hide() end
    W.child:SetHeight(math.max(10, i * 22 + 2))
    if W.scroll and W.scroll:GetWidth() > 0 then W.child:SetWidth(W.scroll:GetWidth()) end
end

if KG.RegisterTab then
    KG.RegisterTab("options", function(panel) OP:Build(panel) end)
end
