--// MasterSkillRouter.lua (ServerScriptService/SkillSystem)
--// Central router - delegates to individual skill handlers
--// Updated: cooldown is applied ONLY if the handler actually activates (e.g., FlickerStrike skips when NoTarget)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local DataModule = require(game.ServerScriptService:WaitForChild("DataHandler"):WaitForChild("DataModule"))
local ItemModule = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("ItemModule"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local SkillActivation = Remotes:WaitForChild("SkillActivation")

local CooldownEvent = Remotes:FindFirstChild("CooldownEvent")
if not CooldownEvent then
	CooldownEvent = Instance.new("RemoteEvent")
	CooldownEvent.Name = "CooldownEvent"
	CooldownEvent.Parent = Remotes
end

local lastActivationTimes = {}
local MIN_ACTIVATION_DELAY = 0.01
local playerCooldowns = {}

local skillHandlers = {}
local handlersFolder = script.Parent:FindFirstChild("Skills")

if handlersFolder then
	for _, module in pairs(handlersFolder:GetChildren()) do
		if module:IsA("ModuleScript") then
			local success, handler = pcall(function()
				return require(module)
			end)

			if success and handler then
				skillHandlers[module.Name] = handler
				print("? Loaded skill handler:", module.Name)
			else
				warn("? Failed to load skill handler:", module.Name)
			end
		end
	end
else
	warn("?? Skills folder not found - create ServerScriptService/SkillSystem/Skills/")
end

-- ? Helper: extract ItemId from leveled items
local function getItemId(item)
	if type(item) == "table" then
		return item.ItemId
	elseif type(item) == "string" and item ~= "" then
		return item
	end
	return nil
end

-- ? Helper: extract Level from leveled items
local function getItemLevel(item)
	if type(item) == "table" then
		return item.Level or 1
	end
	return 1
end

local function verifySkillOwnership(player, skillId, data)
	if not data or not data.Skills then
		return false
	end
	for slotName, skillItem in pairs(data.Skills) do
		local equippedSkillId = getItemId(skillItem)
		if equippedSkillId == skillId then
			return true
		end
	end
	return false
end

local function canUseSkill(character)
	if not character then return false end
	local humanoid = character:FindFirstChild("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return false end
	return true
end

-- ? New helpers for conditional cooldowns
local function shouldStartCooldown(result)
	-- Handlers can return:
	--   false / "NoTarget"           => do NOT start cooldown
	--   { started=false }            => do NOT start cooldown
	--   { started=true, cooldown=x } => start cooldown using x
	--   true / nil                   => start cooldown using default
	if result == false or result == "NoTarget" then return false end
	if type(result) == "table" and result.started == false then return false end
	return true
end

local function resolveCooldownTime(skillData, result)
	if type(result) == "table" and typeof(result.cooldown) == "number" then
		return result.cooldown
	end
	return skillData.Cooldown or 1
end

-- NEW: accepts optional aimPos (Vector3) as 2nd arg from client
SkillActivation.OnServerEvent:Connect(function(player, slotIndex, aimPos)
	if lastActivationTimes[player] and tick() - lastActivationTimes[player] < MIN_ACTIVATION_DELAY then
		return
	end
	lastActivationTimes[player] = tick()

	if type(slotIndex) ~= "number" or slotIndex ~= math.floor(slotIndex) or slotIndex < 1 or slotIndex > 5 then
		return
	end

	local data = DataModule:Get(player)
	if not data or not data.Skills then
		return
	end

	local character = player.Character
	if not canUseSkill(character) then
		return
	end

	local slotName = "Slot" .. tostring(slotIndex)
	local skillItem = data.Skills[slotName]
	local skillId = getItemId(skillItem)
	local skillLevel = getItemLevel(skillItem)

	if not skillId or skillId == "" then
		return
	end

	local skillData = ItemModule.Items[skillId]
	if not skillData or skillData.Type ~= "Skill" then
		return
	end

	if not verifySkillOwnership(player, skillId, data) then
		warn("?? Skill ownership violation:", player.Name, "tried to use", skillId)
		return
	end

	-- Respect cooldown if active
	local cooldownKey = player.UserId .. "_" .. skillId
	if playerCooldowns[cooldownKey] then
		local timeLeft = playerCooldowns[cooldownKey] - tick()
		if timeLeft > 0 then
			return
		end
	end

	local handlerName = skillData.SkillModule
	if not (handlerName and skillHandlers[handlerName]) then
		warn("? No handler found for skill:", skillId, "expected:", handlerName or "nil")
		return
	end

	-- Always pass aimPos; handlers can ignore if unused
	local safeAim = typeof(aimPos) == "Vector3" and aimPos or nil

	-- ? IMPORTANT: Run the handler FIRST, then decide cooldown based on its result
	local ok, result = pcall(function()
		return skillHandlers[handlerName].Activate(player, skillId, skillData, safeAim)
	end)

	if not ok then
		warn("? Error executing", handlerName, ":", result)
		return
	end

	-- Apply cooldown only if handler actually activated (true/nil or table.started=true)
	if shouldStartCooldown(result) then
		local cooldownTime = resolveCooldownTime(skillData, result)
		playerCooldowns[cooldownKey] = tick() + cooldownTime
		CooldownEvent:FireClient(player, skillId, cooldownTime)
		task.delay(cooldownTime, function()
			playerCooldowns[cooldownKey] = nil
		end)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	local userId = player.UserId
	for key in pairs(playerCooldowns) do
		if string.match(key, "^" .. userId .. "_") then
			playerCooldowns[key] = nil
		end
	end
	lastActivationTimes[player] = nil
end)

print("?? MasterSkillRouter loaded successfully! (conditional cooldowns)")
