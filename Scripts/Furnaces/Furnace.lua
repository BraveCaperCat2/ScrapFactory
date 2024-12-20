---A Furnace defines an `AreaTrigger`. Every `Drop` that enters it will be sold for money. A single Furnace can be set as a research Furnace and will sell drops for research points.
---@class Furnace : ShapeClass
---@field sv FurnaceSv
---@field cl FurnaceCl
---@field powerUtil PowerUtility
Furnace = class()
Furnace.maxParentCount = 1
Furnace.maxChildCount = 1
Furnace.connectionInput = sm.interactable.connectionType.logic
Furnace.connectionOutput = sm.interactable.connectionType.logic
Furnace.colorNormal = sm.color.new(0x8000ddff)
Furnace.colorHighlight = sm.color.new(0x8000ffff)

--------------------
-- #region Server
--------------------

---@type Interactable|nil if not nil, the Furnace set for research
local sv_research_furnace
---Time in seconds
local moneyCacheInterval = 60

---@class FurnaceParams
---@field filters number|nil filters of the areaTrigger
---@param params FurnaceParams
function Furnace:server_onCreate(params)
	params = params or {}

	--tutorial stuff
	sm.event.sendToScriptableObject(g_tutorialManager.scriptableObject, "sv_e_questEvent", "FurnacePlaced")

	---@diagnostic disable-next-line: param-type-mismatch
	PowerUtility.sv_init(self)

	--save data
	self.sv = {
		moneyEarnedCache = {},
		moneyEarnedSinceUpdate = 0,
	}
	self.sv.saved = self.storage:load()
	if not self.sv.saved then
		self.sv.saved = {}
	else
		--make sure there is only one research furnace
		if sv_research_furnace then
			self.sv.saved.research = nil
			self.storage:save(self.sv.saved)
		elseif self.sv.saved.research then
			sv_research_furnace = self.interactable
			self.network:sendToClients("cl_toggle_research_effect", (sv_research_furnace and true))
		end
	end

	self.sv.trigger = Furnace.sv_createAreaTrigger(self, params.filters)
	self.sv.trigger:bindOnEnter("sv_onEnter")
	self.sv.trigger:bindOnStay("sv_onStay")
end

function Furnace:sv_createAreaTrigger(filters)
	local size = sm.vec3.new(self.data.box.x, self.data.box.y, self.data.box.z)
	local offset = sm.vec3.new(self.data.offset.x, self.data.offset.y, self.data.offset.z)

	return sm.areaTrigger.createAttachedBox(
		self.interactable,
		size / 2,
		offset,
		sm.quat.identity(),
		filters or sm.areaTrigger.filter.dynamicBody
	)
end

function Furnace:sv_onEnter(_, results)
	if not self.powerUtil.active then return end

	for _, drop in ipairs(getDrops(results)) do
		self:sv_onEnterDrop(drop)
	end
end

function Furnace:sv_onStay(_, results)
end

---Called when a valid drop enters the Furnace and it has power
---@param shape Shape
function Furnace:sv_onEnterDrop(shape)
	local value = self:sv_upgrade(shape)
	local publicData = shape.interactable:getPublicData()

	if publicData.pollution then return end

	if self.sv.saved.research then
		--make research points
		value = value * PerkManager.sv_getMultiplier("research")
		value = (ResearchManager.sv_addResearch(value, shape) and value) or 0
		sm.event.sendToPlayer(sm.player.getAllPlayers()[1], "sv_e_numberEffect", {
			pos = shape:getWorldPosition(),
			value = tostring(value),
			format = "research",
			color = "#00dddd",
			effect = "Furnace - Sell",
		})
	else
		--impostor steals money
		local color
		if shape.interactable.publicData.impostor then
			value = math.max(value * -1, -1 * MoneyManager.getMoney())
			color = "#dd0000"
		end

		--make money,
		sm.event.sendToPlayer(sm.player.getAllPlayers()[1], "sv_e_numberEffect", {
			pos = shape:getWorldPosition(),
			value = tostring(value),
			format = "money",
			effect = "Furnace - Sell",
			color = color,
		})

		MoneyManager.sv_addMoney(value)

		if next(publicData.upgrades) then
			sm.event.sendToScriptableObject(g_tutorialManager.scriptableObject, "sv_e_questEvent", "SellUpgradedDrop")
		end
	end
	self.sv.moneyEarnedSinceUpdate = self.sv.moneyEarnedSinceUpdate + shape.interactable.publicData.value
	self.interactable:setActive(true)

	shape.interactable.publicData.value = nil
	shape:destroyPart(0)
end

---Called before a shape is sold, so it's value can be modified before
---@param shape Shape shape that is to be sold by the furnace
---@return number value new value of the drop
function Furnace:sv_upgrade(shape)
	local value = shape.interactable.publicData.value
	if self.data.multiplier then
		value = value * self.data.multiplier
	end

	return value
end

---Assigns this furnace for research, and unasigns old research furnace (if exists)
function Furnace:sv_setResearch(_, player)
	self.sv.saved.research = not self.sv.saved.research
	self.storage:save(self.sv.saved)

	if self.sv.saved.research then
		--tutorial stuff
		sm.event.sendToScriptableObject(g_tutorialManager.scriptableObject, "sv_e_questEvent", "ResearchFurnaceSet")

		--remove old research furnace
		if sv_research_furnace and type(sv_research_furnace) == "Interactable" and sm.exists(sv_research_furnace) then
			sm.event.sendToInteractable(sv_research_furnace, "sv_removeResearch")
		end
	end
	sv_research_furnace = (self.sv.saved.research and self.interactable) or nil

	--notify clients
	self.network:sendToClients("cl_toggle_research_effect", (sv_research_furnace and true))
	sm.event.sendToGame(
		"sv_e_showTagMessage",
		{ tag = (self.sv.saved.research and "ResearchFurnaceSet") or "ResearchFurnaceRemoved", player = player }
	)
end

---Unasigns this furnace for research
function Furnace:sv_removeResearch()
	self.sv.saved.research = nil
	self.storage:save(self.sv.saved)
	self.network:sendToClients("cl_setSellAreaEffectColor", sm.color.new(0, 1, 0))
end

function Furnace:server_onFixedUpdate()
	---@diagnostic disable-next-line: param-type-mismatch
	PowerUtility.sv_fixedUpdate(self, "cl_toggleEffect")

	if self.interactable:isActive() then
		self.interactable:setActive(false)
	end

	if sm.game.getCurrentTick() % 40 ~= 0 then
		return
	end
	self.sv.moneyEarnedCache[math.floor(sm.game.getCurrentTick() / 40) % (moneyCacheInterval + 3)] =
		self.sv.moneyEarnedSinceUpdate
	self.sv.moneyEarnedSinceUpdate = 0

	local moneyPerInterval = 0
	for _, money in pairs(self.sv.moneyEarnedCache) do
		moneyPerInterval = moneyPerInterval + money
	end
	self.network:setClientData(moneyPerInterval)
end

function Furnace:sv_resetCache()
	self.sv.moneyEarnedCache = {}
	self.sv.moneyEarnedSinceUpdate = 0
	self.network:setClientData(0)
end

-- #endregion

--------------------
-- #region Client
--------------------

---@type Effect|nil effect that marks a research furnace
local cl_research_Effect

function Furnace:client_onCreate()
	self.cl = {
		research = false,
	}

	--create sell area effect
	local size = sm.vec3.new(self.data.box.x, self.data.box.y * 7.5, self.data.box.z)
	local offset = sm.vec3.new(self.data.offset.x, self.data.offset.y, self.data.offset.z)

	self.cl.effect = sm.effect.createEffect("ShapeRenderable", self.interactable)
	self.cl.effect:setParameter("uuid", sm.uuid.new("f74a0354-05e9-411c-a8ba-75359449f770"))
	self.cl.effect:setParameter("color", sm.color.new(0, 1, 0))
	self.cl.effect:setScale(size / 4.5)
	self.cl.effect:setOffsetPosition(offset)
	local rot1 = sm.vec3.getRotation(sm.vec3.new(0, 0, 1), sm.vec3.new(0, 1, 0))

	--really fucking weird rotation offset thingy bc epic shader doesn't work on all rotations. WTF axolot why?
	local rot2 = self.shape.xAxis.y ~= 0 and sm.vec3.getRotation(sm.vec3.new(1, 0, 0), sm.vec3.new(0, 1, 0))
		or sm.quat.identity()
	self.cl.effect:setOffsetRotation(rot1 * rot2)

	self.cl.effect:start()
end

---toggles the effect of the sell area
function Furnace:cl_toggleEffect(active)
	if active and not self.cl.effect:isPlaying() then
		self.cl.effect:start()
	else
		self.cl.effect:stop()
	end
end

---toggles the effect that marks a research furnace
---@param active boolean whether this furnace is a research furnace or not
function Furnace:cl_toggle_research_effect(active)
	if cl_research_Effect and sm.exists(cl_research_Effect) then
		cl_research_Effect:destroy()
	end

	cl_research_Effect = sm.effect.createEffect("Builderguide - Background", self.interactable)

	local size = sm.vec3.new(self.data.box.x, self.data.box.y, self.data.box.z)
	cl_research_Effect:setScale(size)

	local offset = sm.vec3.new(self.data.offset.x, self.data.offset.y, self.data.offset.z)
	cl_research_Effect:setOffsetPosition(offset)

	if active then
		cl_research_Effect:start()
	end
	self:cl_setSellAreaEffectColor(active and sm.color.new(0, 0, 1) or sm.color.new(0, 1, 0))
end

---Changes the color of the sell area effect
---@param color Color the new color of the sell area effect
function Furnace:cl_setSellAreaEffectColor(color)
	self.cl.effect:setParameter("color", color)
end

function Furnace:client_canInteract()
	sm.gui.setInteractionText("", sm.gui.getKeyBinding("Use", true), language_tag("SetResearchFurnace"))
	local formatted_money

	if self.cl.research then
		formatted_money = format_number({
			color = "#00dddd",
			value = (self.cl.moneyPerInterval ~= nil and self.cl.moneyPerInterval or 0),
			unit = "/min",
		})
	else
		formatted_money = format_number({
			color = "#66440C",
			format = "money",
			value = (self.cl.moneyPerInterval ~= nil and self.cl.moneyPerInterval or 0),
			unit = "/min",
		})
	end

	sm.gui.setInteractionText(
		"<p textShadow='false' bg='gui_keybinds_bg_orange' color='#66440C' spacing='9'>" .. formatted_money .. "</p>"
	)
	return true
end

---interact with a furnace to set it to a research furnace
function Furnace:client_onInteract(character, state)
	if state then
		--check if feature unlocked
		if TutorialManager.cl_isTutorialEventCompleteOrActive("ResearchFurnaceSet") then
			self.network:sendToServer("sv_setResearch")
			self.cl.research = not self.cl.research
			self.network:sendToServer("sv_resetCache")
		else
			sm.gui.displayAlertText(language_tag("TutorialLockedFeature"))
		end
	end
end

function Furnace:client_onClientDataUpdate(data)
	self.cl.moneyPerInterval = data
end

-- #endregion

--------------------
-- #region Types
--------------------

---@class FurnaceSv
---@field saved FurnaceSaveData
---@field trigger AreaTrigger the areaTrigger that defines the sell area
---@field moneyEarnedCache table<integer, number> table of money earned per ticks
---@field moneyEarnedSinceUpdate number Money earned since last money update

---@class FurnaceSaveData
---@field research boolean whether the furnace is a research furnace

---@class FurnaceCl
---@field effect Effect effect that visualizes the sell area
---@field moneyPerInterval number
---@field research boolean whether the furnace is a research furnace
-- #endregion
