-- Companion-owned clickable NPC target. The current action comes from stock
-- Polestar; no stock frame, function, setting or guide progress is changed.
local _, ns = ...
local Action = {}
ns.NpcAction = Action
local button, scheduled, driver
local function combat() return InCombatLockdown and InCombatLockdown() end
local function paint()
 if not button then return end
 local T=ns.Theme
 if not T then return end
 button.Bg:SetVertexColor(T.Color('panel'))
 button.Icon:SetVertexColor(T.Color('accent'))
 button.Label:SetTextColor(T.Color('textDim'))
 T.Font(button.Label,'small')
 T.Border(button,T.Color('border'))
end
local function create()
 if button or combat() or type(RegisterStateDriver)~='function' then return button end
 button=CreateFrame('Button','PolestarPlannerNpcButton',UIParent,'SecureActionButtonTemplate')
 button:Hide()
 button:SetSize(36,36)
 button:SetFrameStrata('MEDIUM')
 button:RegisterForClicks('AnyUp','AnyDown')
 button:SetAttribute('useOnKeyDown',false)
 button.Bg=button:CreateTexture(nil,'BACKGROUND')
 button.Bg:SetTexture(ns.Theme.Media('white'));button.Bg:SetAllPoints(button)
 button.Icon=button:CreateTexture(nil,'ARTWORK')
 button.Icon:SetTexture(ns.Theme.Media('qol-target'))
 button.Icon:SetPoint('TOPLEFT',button,'TOPLEFT',2,-2)
 button.Icon:SetPoint('BOTTOMRIGHT',button,'BOTTOMRIGHT',-2,2)
 button.Label=button:CreateFontString(nil,'OVERLAY')
 button.Label:SetPoint('LEFT',button,'RIGHT',8,0)
 button:SetScript('OnEnter',function(self)
  if not GameTooltip or not self.npcName then return end
  GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
  GameTooltip:SetText('Target '..self.npcName)
  GameTooltip:AddLine('Click to find this NPC nearby.',0.7,0.7,0.7)
  GameTooltip:Show()
 end)
 button:SetScript('OnLeave',function(self)
  if GameTooltip and GameTooltip:GetOwner()==self then GameTooltip:Hide() end
 end)
 paint()
 if ns.Theme.OnChanged then ns.Theme.OnChanged(paint) end
 return button
end
function Action.Refresh()
 -- State-driven visibility hides the existing secure frame in combat. A
 -- reload in combat creates no button until the first out-of-combat refresh.
 if combat() then return end
 local b=create()
 if not b then return end
 local action=ns.Adapter.NpcAction()
 local name=action and action.name
 b.npcName=name
 b:SetAttribute('type',name and 'macro' or nil)
 -- The conditional also prevents targeting if a click races combat entry.
 b:SetAttribute('macrotext',name and ('/targetexact [nocombat] '..name) or nil)
 b.Label:SetText(name or '')
 if action then
  b:SetScale(action.scale)
  b:ClearAllPoints();b:SetPoint('CENTER',action.anchor,'CENTER',0,0)
 end
 local visibility=name and '[combat] hide; show' or 'hide'
 if visibility~=driver then
  RegisterStateDriver(b,'visibility',visibility)
  driver=visibility
 end
end
local function refreshSoon()
 if scheduled then return end
 scheduled=true
 local function run() scheduled=false;Action.Refresh() end
 if C_Timer and C_Timer.After then C_Timer.After(0,run) else run() end
end
function Action.GetFrame() return button end
ns.OnLogin(refreshSoon)
for _,event in ipairs({'GUIDE_CHANGED','STEP_CHANGED','STEP_UPDATED','TABS_CHANGED','GUIDE_COMPLETED','CORE_SETTING_CHANGED'})do
 ns.On(event,refreshSoon)
end
ns.RegisterEvent('QUEST_LOG_UPDATE',refreshSoon)
ns.RegisterEvent('BAG_UPDATE_DELAYED',refreshSoon)
ns.RegisterEvent('PLAYER_REGEN_ENABLED',Action.Refresh)
