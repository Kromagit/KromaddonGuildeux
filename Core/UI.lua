--=============================================================================
-- KromaddonGuildeux - Core/UI.lua
--
-- La fenetre, ses trois onglets, et les helpers d'interface (theme, zone
-- bordee, bouton, champ). Le theme est celui de Kromaddon (Core/Init.lua,
-- KA.Theme) pour que les deux fenetres se ressemblent en raid.
--
-- Pieges herites, tous documentes dans le CLAUDE.md de Kromaddon :
--  * un ScrollFrame a template DOIT etre nomme (UIPanelTemplates.lua fait
--    getglobal(self:GetName() .. "ScrollBar")) ;
--  * un EditBox multiligne dans un ScrollFrame n'est cliquable que si le
--    ScrollFrame a EnableMouse(true) ET un OnMouseDown qui donne le focus ;
--  * une popup s'ouvre en strate TOOLTIP, sinon elle passe derriere la
--    fenetre (SetToplevel) et le bouton parait mort ;
--  * 3.3.5a ne rogne pas les enfants d'un cadre : ce qui deborde se dessine
--    sur le monde.
--=============================================================================

local KG = KromaddonGuildeux

KG.Theme = {
    window = { 0.025, 0.020, 0.014 },
    panel = { 0.055, 0.046, 0.031, 0.94 },
    rowOdd = { 0.075, 0.064, 0.045, 0.34 },
    rowEven = { 0.025, 0.022, 0.018, 0.18 },
    button = { 0.145, 0.112, 0.065, 1.00 },
    buttonPressed = { 0.280, 0.205, 0.075, 1.00 },
    gold = { 0.91, 0.70, 0.25 },
    goldDim = { 0.62, 0.47, 0.19 },
    hover = { 0.86, 0.68, 0.28 },
    text = { 0.94, 0.90, 0.80 },
    muted = { 0.55, 0.52, 0.46 },
    red = { 0.90, 0.30, 0.30 },
    green = { 0.30, 0.85, 0.35 },
    yellow = { 1.00, 0.80, 0.00 },
}

local WHITE = "Interface\\Buttons\\WHITE8X8"
KG.WHITE_TEXTURE = WHITE

function KG.SetThemeTexture(texture, colorKey, alpha)
    if not texture then return end
    local c = KG.Theme[colorKey] or KG.Theme.gold
    texture:SetTexture(WHITE)
    texture:SetVertexColor(c[1], c[2], c[3], alpha ~= nil and alpha or (c[4] or 1))
end

function KG.Hex(colorKey)
    local c = KG.Theme[colorKey] or KG.Theme.text
    return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255)
end

--=============================================================================
-- Helpers
--=============================================================================

function KG.CreateZone(parent, belowFrame)
    local zone = CreateFrame("Frame", nil, parent)
    zone:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, tile = false, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    local c = KG.Theme.panel
    zone:SetBackdropColor(c[1], c[2], c[3], c[4])
    c = KG.Theme.goldDim
    zone:SetBackdropBorderColor(c[1], c[2], c[3], 0.82)
    local ref = belowFrame or parent
    local lvl = (ref.GetFrameLevel and ref:GetFrameLevel()) or 1
    zone:SetFrameLevel(math.max(0, lvl - 1))
    return zone
end

function KG.SkinButton(btn)
    if not btn or btn.kgSkinned then return end
    btn.kgSkinned = true
    pcall(function()
        btn:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, tile = false, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        local c = KG.Theme.button
        btn:SetBackdropColor(c[1], c[2], c[3], c[4])
        c = KG.Theme.goldDim
        btn:SetBackdropBorderColor(c[1], c[2], c[3], 0.72)
        btn:SetNormalTexture(WHITE)
        KG.SetThemeTexture(btn:GetNormalTexture(), "button", 0.96)
        btn:SetPushedTexture(WHITE)
        KG.SetThemeTexture(btn:GetPushedTexture(), "buttonPressed", 1)
        btn:SetHighlightTexture(WHITE, "ADD")
        KG.SetThemeTexture(btn:GetHighlightTexture(), "hover", 0.18)
        btn:SetDisabledTexture(WHITE)
        KG.SetThemeTexture(btn:GetDisabledTexture(), "muted", 0.16)
    end)
    local fs = btn:GetFontString()
    if fs then
        local c = KG.Theme.text
        fs:SetTextColor(c[1], c[2], c[3])
    end
    if btn.SetDisabledFontObject and GameFontDisable then btn:SetDisabledFontObject(GameFontDisable) end
end

function KG.NewButton(parent, text, width, height)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetWidth(width or 90)
    btn:SetHeight(height or 22)
    btn:SetText(text or "")
    KG.SkinButton(btn)
    return btn
end

function KG.StyleEditBox(box)
    if not box then return end
    if box.GetRegions then
        local n = select("#", box:GetRegions())
        for i = 1, n do
            local r = select(i, box:GetRegions())
            if r and r.GetObjectType and r:GetObjectType() == "Texture" then r:Hide() end
        end
    end
    box:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, tile = false, edgeSize = 1,
        insets = { left = 2, right = 2, top = 2, bottom = 2 } })
    local c = KG.Theme.panel
    box:SetBackdropColor(c[1], c[2], c[3], 0.98)
    c = KG.Theme.goldDim
    box:SetBackdropBorderColor(c[1], c[2], c[3], 0.88)
    if box.SetTextColor then
        c = KG.Theme.text
        box:SetTextColor(c[1], c[2], c[3], 1)
    end
    if not box.kgEnterWired and box.IsMultiLine and not box:IsMultiLine() then
        box.kgEnterWired = true
        box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    end
end

-- Un EditBox multiligne prend la hauteur de son texte : vide, il n'occupe
-- qu'une ligne en haut. Le clic dans le reste ne tombe sur rien si le
-- ScrollFrame ne recoit pas la souris.
function KG.MakeEditBoxClickable(scroll, box)
    if not (scroll and box) then return end
    scroll:EnableMouse(true)
    scroll:SetScript("OnMouseDown", function() box:SetFocus() end)
end

-- Un ScrollFrame NOMME (piege du template), avec sa molette branchee.
KG.scrollSerial = 0
function KG.NewScrollFrame(parent, name)
    KG.scrollSerial = KG.scrollSerial + 1
    name = name or ("KromaddonGuildeuxScroll" .. KG.scrollSerial)
    local scroll = CreateFrame("ScrollFrame", name, parent, "UIPanelScrollFrameTemplate")
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local max = self:GetVerticalScrollRange()
        local new = cur - delta * 20
        if new < 0 then new = 0 elseif new > max then new = max end
        self:SetVerticalScroll(new)
    end)
    return scroll
end

function KG.Label(parent, text, template)
    local fs = parent:CreateFontString(nil, "ARTWORK", template or "GameFontNormalSmall")
    fs:SetText(text or "")
    local c = KG.Theme.text
    fs:SetTextColor(c[1], c[2], c[3])
    return fs
end

function KG.ShowPopup(name, ...)
    StaticPopup_Show(name, ...)
    local shown = StaticPopup_Visible(name)
    if shown and _G[shown] then
        _G[shown]:SetFrameStrata("TOOLTIP")
        return _G[shown]
    end
end

--=============================================================================
-- La fenetre
--=============================================================================

KG.WIDTH, KG.HEIGHT = 560, 440

local main = CreateFrame("Frame", "KromaddonGuildeuxFrame", UIParent)
KG.Frame = main
main:SetWidth(KG.WIDTH)
main:SetHeight(KG.HEIGHT)
main:SetPoint("CENTER")
main:SetFrameStrata("FULLSCREEN_DIALOG")
main:SetToplevel(true)
main:SetMovable(true)
main:EnableMouse(true)
main:RegisterForDrag("LeftButton")
main:SetClampedToScreen(true)
main:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = WHITE, tile = true, tileSize = 32, edgeSize = 1,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
})
do
    local c = KG.Theme.window
    main:SetBackdropColor(c[1], c[2], c[3], 1)
    c = KG.Theme.gold
    main:SetBackdropBorderColor(c[1], c[2], c[3], 0.92)
end
main:Hide()
UISpecialFrames = UISpecialFrames or {}
tinsert(UISpecialFrames, "KromaddonGuildeuxFrame")

function KG.SavePosition()
    local db = KG.GetDB()
    local point, _, relativePoint, x, y = main:GetPoint(1)
    db.position = { point = point, relativePoint = relativePoint, x = x, y = y }
end

function KG.RestorePosition()
    local p = KG.GetDB().position
    main:ClearAllPoints()
    if p and p.point then
        main:SetPoint(p.point, UIParent, p.relativePoint or p.point, p.x or 0, p.y or 0)
    else
        main:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

function KG.ApplyScale()
    local s = tonumber(KG.GetDB().echelle) or 1
    if s < 0.5 then s = 0.5 elseif s > 2 then s = 2 end
    main:SetScale(s)
end

main:SetScript("OnDragStart", function(self)
    if KG.GetDB().verrouille then return end
    self:StartMoving()
end)
main:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    KG.SavePosition()
end)

local title = KG.Label(main, "KromaddonGuildeux", "GameFontNormal")
title:SetPoint("TOPLEFT", main, "TOPLEFT", 12, -10)
do local c = KG.Theme.gold; title:SetTextColor(c[1], c[2], c[3]) end
KG.titleFS = title

local close = CreateFrame("Button", nil, main, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", main, "TOPRIGHT", -2, -2)
close:SetScript("OnClick", function() main:Hide() end)

-- Onglets ------------------------------------------------------------------

KG.tabs = {}
KG.TAB_ORDER = { "encheres", "ka", "options" }
KG.TAB_LABELS = { encheres = "Enchères", ka = "KA", options = "Options" }

local TAB_TOP = -34
local tabButtons = {}
for i, key in ipairs(KG.TAB_ORDER) do
    local btn = KG.NewButton(main, KG.TAB_LABELS[key], 100, 22)
    btn:SetPoint("TOPLEFT", main, "TOPLEFT", 12 + (i - 1) * 104, TAB_TOP)
    btn:SetScript("OnClick", function() KG.ShowTab(key) end)
    tabButtons[key] = btn
    local panel = CreateFrame("Frame", nil, main)
    panel:SetPoint("TOPLEFT", main, "TOPLEFT", 8, TAB_TOP - 28)
    panel:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -8, 8)
    panel:Hide()
    KG.tabs[key] = { button = btn, panel = panel, built = false }
end

-- Un module declare le constructeur de son onglet : appele une fois, au
-- premier affichage (les SavedVariables sont chargees a ce moment-la).
function KG.RegisterTab(key, buildFn)
    local t = KG.tabs[key]
    if not t then return end
    t.build = buildFn
end

function KG.ShowTab(key)
    if not KG.tabs[key] then key = "encheres" end
    for k, t in pairs(KG.tabs) do
        if k == key then
            if not t.built and t.build then
                t.built = true
                local ok, err = pcall(t.build, t.panel)
                if not ok then KG.Print("onglet " .. k .. " : " .. tostring(err)) end
            end
            t.panel:Show()
            KG.SetThemeTexture(t.button:GetNormalTexture(), "buttonPressed", 1)
            KG.StopFlash(k)
        else
            t.panel:Hide()
            KG.SetThemeTexture(t.button:GetNormalTexture(), "button", 0.96)
        end
    end
    KG.GetDB().onglet = key
    KG.Dispatch("OnTabShown", key)
end

function KG.ShowWindow(key)
    main:Show()
    KG.ShowTab(key or KG.GetDB().onglet or "encheres")
end

function KG.ToggleWindow()
    if main:IsShown() then main:Hide() else KG.ShowWindow() end
end

main:SetScript("OnShow", function()
    KG.ApplyScale()
    KG.RestorePosition()
    KG.ShowTab(KG.GetDB().onglet or "encheres")
end)

-- Clignotement d'un onglet (ouverture automatique sur un loot coche).
KG.flashing = KG.flashing or {}
function KG.FlashTab(key)
    if not KG.tabs[key] then return end
    KG.flashing[key] = GetTime()
end
function KG.StopFlash(key)
    KG.flashing[key] = nil
    local t = KG.tabs[key]
    if t then t.button:UnlockHighlight() end
end
function KG.TickFlash(now)
    for key, since in pairs(KG.flashing) do
        local t = KG.tabs[key]
        if t then
            if now - since > 20 then
                KG.StopFlash(key)
            elseif math.floor(now * 2) % 2 == 0 then
                t.button:LockHighlight()
            else
                t.button:UnlockHighlight()
            end
        end
    end
end

KG.RegisterModule("UI", {
    OnTick = function(self, now) KG.TickFlash(now) end,
    OnLogin = function() KG.ApplyScale(); KG.RestorePosition() end,
})
