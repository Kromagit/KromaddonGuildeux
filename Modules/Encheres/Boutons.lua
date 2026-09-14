--=============================================================================
-- KromaddonGuildeux - Modules/Encheres/Boutons.lua
--
-- Le champ « Montant » et son bouton « Miser », « Bid Min » (le min requis en
-- un clic), le choix MS / OS, le champ « Max auto » (pre-rempli du solde,
-- borne par lui, arme par « Valider » ou Entree seulement) et la mise
-- AUTOMATIQUE jusqu'a ce max, « All In », « Rand », « Passe », et le PASSE
-- AUTOMATIQUE quand le min requis depasse mon solde (§ 5.2-5.5, refaits le
-- 12/09 sur les demandes de Kroma).
--
-- La LOGIQUE est pure (KG.Boutons.New) et testee dans tests/mise_min.lua et
-- tests/passe.lua : elle decide quoi envoyer et ce que les widgets affichent ;
-- l'envoi lui-meme (SendChatMessage, RandomRoll) est injecte. Les frames
-- sont construites plus bas, seulement en jeu (if KG.Frame).
--
-- Regle (§ 5.5) : aucun envoi en /raid sans geste du joueur — le clic sur
-- « Miser », « Bid Min », « All In », ou un MAX qu'il a VALIDE (Entree ou
-- « Valider » ; le champ pre-rempli du solde n'arme rien) : la mise
-- automatique est SA consigne, bornee par son chiffre — lui-meme borne par
-- son solde —, et elle s'arrete en le disant des que le min requis depasse ce
-- chiffre (« prends le relais »). Le passe automatique est l'exception
-- assumee : quand le min requis depasse le solde d'un joueur DEJA engage, il
-- ne peut plus suivre, il passe (decision de Kroma du 12/09).
--=============================================================================

local KG = KromaddonGuildeux
local E = KG.Etat
local B = {}
KG.Boutons = B

B.REPLY_TTL = 5         -- « pas de réponse de l'officier » apres 5 s
B.AUTO_DELAY = 1.5      -- une mise auto part 1,5 s apres le depassement, pas dans la meme image
B.AUTO_MAX_BIDS = 20    -- jamais plus par enchere (un garde-fou, pas une regle)
B.AUTO_MAX_REFUSALS = 3 -- trois refus de l'officier sur des mises auto : on arrete
B.ROWS_HEIGHT = 82      -- la place que les deux rangees + le retour prennent en bas du panneau

--=============================================================================
-- Logique pure
--=============================================================================

-- opts : me, send(text) (envoi en RAID/PARTY), roll() (RandomRoll 1-100),
-- now(), etat (l'objet Etat), kaSelf() -> { solde=, marker = {kind=...} } ou
-- nil, inGroup() -> bool, alert(text) (l'onglet clignote : « prends le relais »).
function B.New(opts)
    opts = opts or {}
    local L = {
        me = opts.me or "?",
        send = opts.send or function() end,
        roll = opts.roll or function() end,
        now = opts.now or function() return time() end,
        etat = opts.etat,
        kaSelf = opts.kaSelf or function() return nil end,
        -- Un solde appris au passage (refus « T'as N. C'est pas assez ») :
        -- rendu au module KA, qui le garde (13/09).
        kaLearn = opts.kaLearn or function() end,
        inGroup = opts.inGroup or function() return true end,
        alert = opts.alert or function() end,
        state = "idle",         -- "idle" | "sent"
        sentAt = nil,
        tierChoice = "ms",      -- "ms" | "os" : la case cochee
        feedback = nil,         -- { text=, color= }
        passState = "idle",     -- "idle" | "sent" | "confirm" | "done"
        passSentAt = nil,
        nudge = nil,            -- heure du dernier « BID OU PASSE PLZ !!! »
        rolledSerial = nil,     -- serial de l'enchere ou j'ai rand
        rolledRound = nil,      -- tour de departage ou j'ai rerand
        autoMax = nil,          -- le max tape par le joueur, pour CETTE enchere
        autoNextAt = nil,       -- heure de la prochaine mise auto (le delai)
        autoCount = 0,          -- mises auto parties sur cette enchere
        autoRefusals = 0,       -- refus de l'officier sur ces mises
        autoStopped = nil,      -- la raison de l'arret (« prends le relais »), ou nil
        autoSent = false,       -- la mise en vol est une mise auto
        autoPassedSerial = nil, -- l'enchere ou le passe automatique est parti (une fois)
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

-- Le palier de ma prochaine mise : la case cochee, toujours explicite. MS au
-- debut ; « OS <lien> » de l'officier coche OS ; le joueur peut changer.
function B:MyTier()
    return self.tierChoice == "os" and "os" or "ms"
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

-- Le min requis dans mon palier, calcule comme chez l'officier
-- (NextValidBid sur la meilleure mise active du palier). nil sans enchere.
function B:SuggestedBid()
    local e = self:Current()
    if not e then return nil end
    return E.NextValidBid(E.TopBid(e, self:MyTier()))
end

-- Suis-je la meilleure mise active de mon palier ? (l'officier refuse une
-- surenchere sur soi-meme : IsCurrentWinner)
function B:IsTopOfMyTier()
    local e = self:Current()
    if not e then return false end
    local top = E.SortedActive(e, "bid", self:MyTier())[1]
    return top ~= nil and top.nom == self.me
end

-- Le texte exact qui part en /raid : le montant et le palier, toujours.
function B:BidText(amount)
    return tostring(amount) .. " " .. self:MyTier()
end

-- Le clic sur « Miser » avec ce que le champ contient. Un montant sous le
-- min requis est refuse ICI (l'officier le refuserait, autant ne pas
-- encombrer le /raid) ; au-dessus, il part tel quel — le joueur mise ce
-- qu'il veut. Rend l'action : "send" + texte, ou "refused" + raison.
function B:BidClick(amount)
    local ok, why = self:CanBid()
    if not ok then return "refused", why end
    amount = tonumber(amount)
    if not amount or amount ~= math.floor(amount) or amount < 1 then
        self.feedback = { text = "montant illisible", color = "red" }
        return "refused", "montant illisible"
    end
    local min = self:SuggestedBid()
    if amount < min then
        self.feedback = { text = string.format("%d est sous le min requis (%d)", amount, min), color = "red" }
        return "refused", "sous le min"
    end
    if self:IsTopOfMyTier() then
        self.feedback = { text = "tu es déjà vainqueur de ton palier", color = "yellow" }
        return "refused", "déjà vainqueur"
    end
    return self:SendBid(amount, false)
end

-- Ce que « Bid Min » PEUT proposer, compte tenu de mon solde (14/09, Kroma :
-- « sur un perso avec 9966 KA le bouton propose "Bid 10966" »). Le min requis
-- ne regarde que la meilleure mise ; le bouton, lui, ne doit jamais tendre un
-- montant que je ne peux pas payer :
--   { kind = "min",   amount = min }   le min requis est payable (ou solde inconnu)
--   { kind = "allin", amount = solde } le min depasse mon solde, mais mon solde
--                                      depasse encore la meilleure mise : seul
--                                      « all in » passe chez l'officier
--   { kind = "none",  why = ... }      rien a proposer : deja vainqueur, ou
--                                      solde sous la meilleure mise
function B:BidMinOffer()
    local ok, why = self:CanBid()
    if not ok then return { kind = "none", why = why } end
    local min = self:SuggestedBid()
    if not min then return { kind = "none", why = "aucune enchère" } end
    if self:IsTopOfMyTier() then return { kind = "none", why = "déjà vainqueur" } end
    local solde = self:Solde()
    if not solde or min <= solde then return { kind = "min", amount = min } end
    local top = E.TopBid(self:Current(), self:MyTier())
    if solde > top then return { kind = "allin", amount = solde } end
    return { kind = "none", why = string.format("solde insuffisant : %d, meilleure mise %d", solde, top) }
end

-- Le clic sur « Bid Min » : l'offre du moment, calculee A L'INSTANT du clic
-- (pas le chiffre affiche dans le champ, qui peut avoir une image de
-- retard), avec les memes refus que « Miser ». Un seul clic : le champ montre
-- deja l'offre, le second clic de l'ancien « Mise Min » ne protegeait de rien.
function B:BidMinClick()
    local offer = self:BidMinOffer()
    if offer.kind == "min" then return self:BidClick(offer.amount) end
    if offer.kind == "allin" then return self:AllInClick() end
    if offer.why == "déjà vainqueur" then
        self.feedback = { text = "tu es déjà vainqueur de ton palier", color = "yellow" }
    elseif string.find(offer.why, "solde insuffisant", 1, true) then
        self.feedback = { text = offer.why, color = "red" }
    end
    return "refused", offer.why
end

-- Mon solde tel que ?ka l'a dit ; nil tant qu'on ne le connait pas.
function B:Solde()
    local ka = self.kaSelf()
    return ka and ka.solde or nil
end

-- « All In » : tout mon solde dans mon palier. Si le solde atteint le min
-- requis, c'est une mise ordinaire « <solde> <palier> » ; s'il est entre la
-- meilleure mise et le min requis, seul « all in » passe chez l'officier (la
-- regle de progression n'est pas appliquee) — le palier est alors pose par
-- un « ms »/« os » juste avant quand il differe de celui que l'officier me
-- donnerait ; sous la meilleure mise, l'officier refuserait (« il en faut
-- plus ») : refuse ici, rien ne part.
function B:AllInClick()
    local ok, why = self:CanBid()
    if not ok then return "refused", why end
    local solde = self:Solde()
    if not solde or solde < 1 then
        self.feedback = { text = "solde inconnu : demande ?ka d'abord", color = "red" }
        return "refused", "solde inconnu"
    end
    if self:IsTopOfMyTier() then
        self.feedback = { text = "tu es déjà vainqueur de ton palier", color = "yellow" }
        return "refused", "déjà vainqueur"
    end
    local e = self:Current()
    local tier = self:MyTier()
    local top = E.TopBid(e, tier)
    if solde <= top then
        self.feedback = { text = string.format("all in impossible : ton solde (%d) ne dépasse pas la meilleure mise (%d)", solde, top), color = "red" }
        return "refused", "il en faut plus"
    end
    if solde >= self:SuggestedBid() then
        return self:SendBid(solde, false)
    end
    local l = self:MyLine()
    local given = (l and E.BidActive(l) and l.tier) or (e.tierWanted and e.tierWanted[self.me]) or e.palierDefaut
    if given ~= tier then self.send(tier) end
    self.send("all in")
    self.state, self.sentAt, self.autoSent = "sent", self.now(), false
    self.feedback = { text = string.format("all in envoyé : %d %s", solde, tier), color = "muted" }
    return "send", "all in"
end

function B:SendBid(amount, auto)
    local text = self:BidText(amount)
    self.send(text)
    self.state, self.sentAt, self.autoSent = "sent", self.now(), auto and true or false
    self.feedback = { text = (auto and "mise auto envoyée : " or "mise envoyée : ") .. text, color = "muted" }
    return "send", text
end

function B:SetTierChoice(choice)
    self.tierChoice = (choice == "os") and "os" or "ms"
    self.autoNextAt = nil   -- le palier change : le delai repart
end

--=============================================================================
-- La mise automatique jusqu'au max (§ 5.2 bis, 12/09)
--=============================================================================

-- Le max VALIDE par le joueur (Entree ou « Valider » — jamais la perte du
-- focus : le champ pre-rempli n'arme rien tant qu'il ne l'a pas dit). nil ou
-- un nombre <= 0 : plus de mise auto. Plus que mon solde : ramene au solde,
-- en le disant — on ne peut pas promettre plus qu'on a.
function B:SetAutoMax(value)
    value = tonumber(value)
    if not value or value <= 0 then value = nil else value = math.floor(value) end
    local clamped = nil
    local solde = self:Solde()
    if value and solde and value > solde then value, clamped = solde, true end
    self.autoMax = value
    self.autoStopped, self.autoNextAt = nil, nil
    if value then
        if clamped then
            self.feedback = { text = string.format("max ramené à ton solde : %d", value), color = "yellow" }
        else
            self.feedback = { text = "mise auto jusqu'à " .. value, color = "muted" }
        end
    end
    return value
end

-- Ce que le champ Max montre quand rien n'est arme : mon solde (le max
-- naturel), ou rien si on ne le connait pas.
function B:DefaultMaxText()
    if self.autoMax then return tostring(self.autoMax) end
    local solde = self:Solde()
    return solde and tostring(solde) or ""
end

-- Pourquoi la mise auto ne part pas maintenant (nil = elle peut). Les arrets
-- DEFINITIFS pour cette enchere (le relais) sont a part : StopAuto.
function B:AutoBlocked()
    if not self.autoMax then return "pas de max" end
    if self.autoStopped then return self.autoStopped end
    local e = self:Current()
    local ok, why = self:CanBid()
    if not ok then return why end
    if e.statut ~= "ouverte" then return "départage" end
    if self.passState ~= "idle" then return "passe en cours" end
    if self.state == "sent" then return "mise en vol" end
    if self:IsTopOfMyTier() then return "vainqueur du palier" end
    return nil
end

function B:StopAuto(text)
    self.autoStopped = text
    self.autoNextAt = nil
    self.feedback = { text = text, color = "yellow" }
    self.alert(text)
end

-- Le passe automatique (12/09, Kroma : « quand une enchere depasse le total
-- de KA d'un joueur, il passe ») : j'ai une mise active dans mon palier, on
-- m'a depasse, et le min requis est au-dessus de mon solde — je ne peux plus
-- suivre normalement. MAIS (14/09, Kroma sur un cas vu en jeu : « le min
-- requis est inferieur au total de Kromalchib MAIS son all in est superieur
-- au bid actuel, donc il a le droit d'all in meme s'il atteint pas le min
-- requis ») un All In reste un coup legal tant que mon solde depasse la
-- meilleure mise de mon palier (la regle d'`AllInClick` : `solde > top`) —
-- dans ce cas-la, all in automatique plutot que passe. Seulement quand le
-- solde n'atteint meme pas la meilleure mise, l'officier refuserait
-- jusqu'a l'All In lui-meme (« il en faut plus ») : la, on passe. Une fois
-- par enchere (l'une ou l'autre). Sans mise de ma part : rien a retirer,
-- rien ne part.
function B:AutoPassTick()
    local e = self:Current()
    if not e or e.statut ~= "ouverte" then return nil end
    if self.autoPassedSerial == e.serial then return nil end
    if self.passState ~= "idle" or self.state == "sent" then return nil end
    if not self.inGroup() then return nil end
    local l = self:MyLine()
    local tier = self:MyTier()
    if not (l and E.BidActive(l) and (l.tier or e.palierDefaut) == tier) then return nil end
    if self:IsTopOfMyTier() then return nil end
    local solde = self:Solde()
    local min = self:SuggestedBid()
    if not solde or not min or min <= solde then return nil end
    local top = E.TopBid(e, tier)
    if self:CanBid() and solde > top then
        self.autoPassedSerial = e.serial
        self.autoNextAt = nil
        -- Deja actif dans CE palier (verifie ci-dessus) : pas besoin de
        -- reposer « ms »/« os », l'officier le sait deja.
        self.send("all in")
        self.state, self.sentAt, self.autoSent = "sent", self.now(), false
        local text = string.format("min requis %d > ton solde %d, mais all in encore valable (%d) : all in automatique", min, solde, solde)
        self.feedback = { text = text, color = "yellow" }
        self.alert(text)
        return "send"
    end
    self.autoPassedSerial = e.serial
    self.autoNextAt = nil
    local action = self:PasseClick()
    if action == "send" then
        self.feedback = { text = string.format("min requis %d > ton solde %d : passe automatique", min, solde), color = "yellow" }
        self.alert(string.format("min requis %d > ton solde %d : passe automatique", min, solde))
    end
    return action
end

-- Appelee a chaque tic : decide, temporise, envoie. Rend ce qui s'est passe
-- ("wait", "send", "stop", nil).
function B:AutoTick(now)
    if self:AutoBlocked() then self.autoNextAt = nil; return nil end
    local min = self:SuggestedBid()
    local tier = self:MyTier()
    local e = self:Current()
    -- En OS quand une mise MS existe : miser plus en OS ne gagne rien.
    if tier == "os" and E.TopBid(e, "ms") > 0 then
        self:StopAuto("une mise MS l'emporte sur l'OS : prends le relais")
        return "stop"
    end
    if min > self.autoMax then
        self:StopAuto(string.format("min requis %d > ton max %d : prends le relais", min, self.autoMax))
        return "stop"
    end
    local ka = self.kaSelf()
    if ka and ka.solde and min > ka.solde then
        self:StopAuto(string.format("min requis %d > ton solde %d : prends le relais", min, ka.solde))
        return "stop"
    end
    if self.autoCount >= B.AUTO_MAX_BIDS then
        self:StopAuto("mise auto : plafond de " .. B.AUTO_MAX_BIDS .. " mises atteint, prends le relais")
        return "stop"
    end
    if not self.autoNextAt then self.autoNextAt = now + B.AUTO_DELAY; return "wait" end
    if now < self.autoNextAt then return "wait" end
    self.autoNextAt = nil
    self.autoCount = self.autoCount + 1
    self:SendBid(min, true)
    return "send"
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
        self.state, self.sentAt, self.autoSent = "idle", nil, false
        self.passState, self.nudge, self.feedback = "idle", nil, nil
        self.rolledRound = nil
        -- MS cochee au debut de chaque enchere ; le max est propre a UNE
        -- enchere : il tombe a la cloture (ci-dessous), pas ici, pour qu'un
        -- max tape avant l'ouverture serve a l'enchere qui s'ouvre.
        self.tierChoice = "ms"
        self.autoNextAt, self.autoCount, self.autoRefusals, self.autoStopped = nil, 0, 0, nil
        self.autoPassedSerial = nil
        if kind == "cleared" then self.autoMax = nil end
        return
    end
    if kind == "close" then
        -- Le max ne survit pas a l'enchere : une mise auto sur l'objet SUIVANT
        -- serait un achat que le joueur n'a pas voulu.
        self.autoMax, self.autoNextAt, self.autoStopped = nil, nil, nil
        return
    end
    if kind == "default_os" then
        -- « OS <lien> » de l'officier : OS se coche. Le joueur peut rechanger.
        self.tierChoice = "os"
        self.autoNextAt = nil
        return
    end
    if kind == "mine_accepted" then
        self.state, self.sentAt, self.autoSent = "idle", nil, false
        self.feedback = { text = "mise passée : " .. tostring(data.amount) .. " " .. string.upper(data.tier or ""), color = "green" }
        self.nudge = nil
        -- (14/09) « Confirmer le passe » ne survit pas a une mise de ma part :
        -- j'ai remise, le passe repart de zero.
        if self.passState == "confirm" then self.passState = "idle" end
    elseif kind == "mine_refused" then
        self.state, self.sentAt = "idle", nil
        if self.autoSent then
            self.autoSent = false
            self.autoRefusals = self.autoRefusals + 1
            if self.autoRefusals >= B.AUTO_MAX_REFUSALS and self.autoMax and not self.autoStopped then
                self:StopAuto("mise auto : " .. B.AUTO_MAX_REFUSALS .. " refus de l'officier, prends le relais")
                return
            end
        end
        local why = data and data.why
        local text
        if why == "step" then text = string.format("refusée : c'est par %d, %d minimum", data.step or 0, data.min or 0)
        elseif why == "balance" then
            text = string.format("refusée : t'as %d, c'est pas assez", data.have or 0)
            -- L'officier vient de me dire mon solde : autant le garder.
            if type(data.have) == "number" then self.kaLearn(data.have) end
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

-- Expirations : une mise ou un passe sans verdict apres 5 s le dit ; puis la
-- mise automatique regarde si elle a quelque chose a faire.
function B:Tick(now)
    now = now or self.now()
    if self.state == "sent" and self.sentAt and now - self.sentAt >= B.REPLY_TTL then
        self.state, self.sentAt, self.autoSent = "idle", nil, false
        self.feedback = { text = "pas de réponse de l'officier", color = "yellow" }
    end
    self:AutoPassTick()
    self:AutoTick(now)
    -- (14/09, Kroma : « quand un joueur passe en etant vainqueur, le bouton
    -- Confirmer passe devrait se reinitialiser si un joueur (lui ou un autre)
    -- bid au-dessus ») : depasse, je ne suis plus vainqueur, un simple
    -- « passe » suffit de nouveau.
    if self.passState == "confirm" and not self:IsTopOfMyTier() then self.passState = "idle" end
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
    -- Un champ numerique court, au theme de l'addon.
    local function NumBox(parent, width)
        local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
        box:SetWidth(width); box:SetHeight(20)
        box:SetAutoFocus(false)
        box:SetNumeric(true)
        box:SetMaxLetters(7)
        KG.StyleEditBox(box)
        return box
    end

    -- Une case a cocher avec son libelle a droite.
    local function Check(parent, label)
        local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
        cb:SetWidth(22); cb:SetHeight(22)
        local fs = KG.Label(parent, label)
        fs:SetPoint("LEFT", cb, "RIGHT", 0, 0)
        cb.label = fs
        return cb
    end

    function B.Build(panel, logic, host)
        local W = { editedSerial = nil, settingText = false }
        -- Rangee du haut : Max auto, Valider, All In.
        local row2 = CreateFrame("Frame", nil, panel)
        row2:SetHeight(24)
        row2:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 4, 54)
        row2:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 54)
        local maxLabel = KG.Label(row2, "Max auto")
        maxLabel:SetPoint("LEFT", row2, "LEFT", 2, 0)
        local maxBox = NumBox(row2, 64)
        maxBox:SetPoint("LEFT", maxLabel, "RIGHT", 8, 0)
        -- « Valider » arme la mise auto sur ce que le champ contient ; Entree
        -- fait pareil. Perdre le focus n'arme RIEN : le champ est pre-rempli du
        -- solde, un clic ailleurs ne doit pas lancer des mises.
        local valider = KG.NewButton(row2, "Valider", 64, 22)
        valider:SetPoint("LEFT", maxBox, "RIGHT", 4, 0)
        local allIn = KG.NewButton(row2, "All In", 64, 22)
        allIn:SetPoint("LEFT", valider, "RIGHT", 8, 0)
        local maxHint = KG.Label(row2, "")
        maxHint:SetPoint("LEFT", allIn, "RIGHT", 8, 0)
        maxHint:SetPoint("RIGHT", row2, "RIGHT", 0, 0)
        maxHint:SetJustifyH("LEFT")
        do local c = KG.Theme.muted; maxHint:SetTextColor(c[1], c[2], c[3]) end
        local function CommitMax()
            local v = logic:SetAutoMax(maxBox:GetText())
            maxBox:SetText(v and tostring(v) or logic:DefaultMaxText())
            maxBox:ClearFocus()
            host.Refresh()
        end
        maxBox:SetScript("OnEnterPressed", CommitMax)
        maxBox:SetScript("OnEscapePressed", function(self) self:SetText(logic:DefaultMaxText()); self:ClearFocus() end)
        maxBox:SetScript("OnEditFocusLost", function(self) self:SetText(logic:DefaultMaxText()) end)
        valider:SetScript("OnClick", CommitMax)
        -- Le gestionnaire d'All In est pose plus bas, une fois `montant` cree :
        -- ecrit ici, il lirait une globale nulle (globaux_suspects l'a vu).

        -- Rangee du bas : Montant, Miser, MS / OS, Rand, Passe.
        local row = CreateFrame("Frame", nil, panel)
        row:SetHeight(26)
        row:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 4, 26)
        row:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 26)

        local montantLabel = KG.Label(row, "Montant")
        montantLabel:SetPoint("LEFT", row, "LEFT", 2, 0)
        local montant = NumBox(row, 64)
        montant:SetPoint("LEFT", montantLabel, "RIGHT", 8, 0)
        -- Le champ suit le min requis tant que le joueur n'y a pas tape (le
        -- drapeau, pas le 2e argument d'OnTextChanged : rien ne garantit
        -- qu'il arrive sur ce client). Une saisie vaut pour l'enchere en cours.
        montant:SetScript("OnTextChanged", function()
            if W.settingText then return end
            local e = logic:Current()
            W.editedSerial = e and e.serial or -1
        end)

        -- Largeurs comptees pour tenir dans les 536 px de la rangee (560 - 2*8
        -- de marge - 2*4) : ~50 + 8 + 64 + 4 + 56 + 4 + 64 + 8 + 40 + 6 + 40 + 8
        -- + 56 + 6 + 110 = 524. 3.3.5a ne rogne pas : ce qui deborde se voit.
        local miser = KG.NewButton(row, "Miser", 56, 22)
        miser:SetPoint("LEFT", montant, "RIGHT", 4, 0)
        miser:SetScript("OnClick", function()
            local action = logic:BidClick(montant:GetText())
            if action == "send" then W.editedSerial = nil; montant:ClearFocus() end
            host.Refresh()
        end)

        -- « Bid Min » (remis le 12/09 a la demande de Kroma) : un clic, le min
        -- requis part — sans passer par le champ.
        local bidMin = KG.NewButton(row, "Bid Min", 64, 22)
        bidMin:SetPoint("LEFT", miser, "RIGHT", 4, 0)
        bidMin:SetScript("OnClick", function()
            local action = logic:BidMinClick()
            if action == "send" then W.editedSerial = nil; montant:ClearFocus() end
            host.Refresh()
        end)

        allIn:SetScript("OnClick", function()
            local action = logic:AllInClick()
            if action == "send" then W.editedSerial = nil; montant:ClearFocus() end
            host.Refresh()
        end)

        local cbMS = Check(row, "MS")
        cbMS:SetPoint("LEFT", bidMin, "RIGHT", 8, 0)
        local cbOS = Check(row, "OS")
        cbOS:SetPoint("LEFT", cbMS.label, "RIGHT", 6, 0)
        cbMS:SetScript("OnClick", function() logic:SetTierChoice("ms"); host.Refresh() end)
        cbOS:SetScript("OnClick", function() logic:SetTierChoice("os"); host.Refresh() end)

        local rand = KG.NewButton(row, "Rand", 56, 22)
        rand:SetPoint("LEFT", cbOS.label, "RIGHT", 8, 0)
        rand:SetScript("OnClick", function() logic:RandClick(); host.Refresh() end)

        local passe = KG.NewButton(row, "Passe", 110, 22)
        passe:SetPoint("LEFT", rand, "RIGHT", 6, 0)
        passe:SetScript("OnClick", function() logic:PasseClick(); host.Refresh() end)

        local fb = KG.Label(panel, "")
        fb:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 6, 8)
        fb:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -6, 8)
        fb:SetJustifyH("LEFT")

        W.montant, W.miser, W.bidMin, W.cbMS, W.cbOS, W.rand, W.passe, W.fb = montant, miser, bidMin, cbMS, cbOS, rand, passe, fb
        W.maxBox, W.maxHint, W.valider, W.allIn, W.row, W.row2 = maxBox, maxHint, valider, allIn, row, row2
        function W.Refresh(now)
            local e = logic:Current()
            local serial = e and e.serial or -1
            -- Le champ Montant : le min requis, sauf si le joueur y tape.
            if W.editedSerial ~= serial then W.editedSerial = nil end
            -- (14/09) jamais un montant que je ne peux pas payer : l'offre de
            -- « Bid Min » (min payable, sinon all in, sinon rien).
            local offer = logic:BidMinOffer()
            if not W.editedSerial and not montant:HasFocus() then
                local txt = offer.amount and tostring(offer.amount) or ""
                if montant:GetText() ~= txt then W.settingText = true; montant:SetText(txt); W.settingText = false end
            end
            -- Un EditBox n'a ni Enable ni Disable en 3.3.5a (Button seulement) :
            -- c'est le bouton Miser qui se grise, le champ reste lisible.
            local ok, why = logic:CanBid()
            if ok then miser:Enable() else miser:Disable() end
            miser.tooltip = why
            -- Le bouton dit ce qu'il enverrait : « Bid 125 », « All in 9966 » —
            -- rien a proposer (deja vainqueur, solde insuffisant, sans enchere) :
            -- « Bid Min » grise, la raison en infobulle.
            if offer.kind == "min" then bidMin:Enable(); bidMin:SetText("Bid " .. offer.amount); bidMin.tooltip = nil
            elseif offer.kind == "allin" then bidMin:Enable(); bidMin:SetText("All in " .. offer.amount); bidMin.tooltip = "le min requis dépasse ton solde : all in"
            else bidMin:Disable(); bidMin:SetText("Bid Min"); bidMin.tooltip = offer.why end
            cbMS:SetChecked(logic.tierChoice ~= "os")
            cbOS:SetChecked(logic.tierChoice == "os")
            -- Le champ Max : le max arme, sinon mon solde (pre-rempli, pas arme).
            if not maxBox:HasFocus() then
                local txt = logic:DefaultMaxText()
                if maxBox:GetText() ~= txt then maxBox:SetText(txt) end
            end
            if logic.autoMax then
                local blocked = logic:AutoBlocked()
                if logic.autoStopped then maxHint:SetText(KG.Hex("yellow") .. "mise auto arrêtée : prends le relais|r")
                elseif blocked then maxHint:SetText("mise auto en veille (" .. blocked .. ")")
                else maxHint:SetText(KG.Hex("green") .. "mise auto active jusqu'à " .. logic.autoMax .. "|r") end
            else
                maxHint:SetText("pas armée : Valider (ou Entrée) et l'addon mise le min requis pour toi jusqu'à ce max.")
            end
            local sold = logic:Solde()
            if ok and sold and sold >= 1 then allIn:Enable() else allIn:Disable() end
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
        return W
    end
end
