--[[
	DungeonMaster.server.lua
	Handles proximity-based spawners, infinite level scaling, party scaling, simple AI, and mob management
	Place in ServerScriptService
	
	SPAWNING: 
	- When player within 200 studs: Pre-generates 30 group locations at Level 1 (+1 per level)
	- Groups ONLY spawn when player within 250 studs of that group's location (progressive)
	- Each group contains 4-8 enemies in a cluster (RANDOM)
	- Enemies idle until player within 17 studs (then chase)
	- Enemies return to individual spawn at 3x speed when beyond leash (120 studs)
	- Total potential enemies = Groups � (4-8) random
	
	UPDATED:
	- Fixed party scaling bug - Party:0 now correctly uses 1x multiplier instead of 4.76x
	- Added Boss support: boss multipliers, boss attribute flags, and multi-drop behavior
	- NEW: Collision groups so Players and Mobs do not collide; Dead group collides with nothing
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ServerScriptService = game:GetService("ServerScriptService")
local PhysicsService = game:GetService("PhysicsService")
local DropManager = require(ServerScriptService:WaitForChild("DropManager"))
local DamageNumbers = require(ServerScriptService:WaitForChild("DamageNumbers"))

-- Verify DamageNumbers module loaded successfully
if DamageNumbers and DamageNumbers.Show then
	print("[DM] DamageNumbers module loaded successfully!")
else
	warn("[DM] WARNING: DamageNumbers module failed to load or missing Show function!")
end

-- === Boss Exit Remotes / Signals ===
local Remotes = ReplicatedStorage:FindFirstChild("Remotes") or Instance.new("Folder")
Remotes.Name = "Remotes"
Remotes.Parent = ReplicatedStorage

local BossExitEvent = Remotes:FindFirstChild("BossExitEvent") or Instance.new("RemoteEvent")
BossExitEvent.Name = "BossExitEvent"
BossExitEvent.Parent = Remotes

local BossExitDecision = Remotes:FindFirstChild("BossExitDecision") or Instance.new("RemoteEvent")
BossExitDecision.Name = "BossExitDecision"
BossExitDecision.Parent = Remotes

local RequestMapRegen = ReplicatedStorage:FindFirstChild("RequestMapRegen") or Instance.new("BindableEvent")
RequestMapRegen.Name = "RequestMapRegen"
RequestMapRegen.Parent = ReplicatedStorage

-- === Boss Vote Remotes (singleton) ===
local function getVoteRemotes()
	local RS = ReplicatedStorage
	local start = RS:FindFirstChild("BossVote_Start") or Instance.new("RemoteEvent", RS)
	start.Name = "BossVote_Start"
	local update = RS:FindFirstChild("BossVote_Update") or Instance.new("RemoteEvent", RS)
	update.Name = "BossVote_Update"
	local submit = RS:FindFirstChild("BossVote_Submit") or Instance.new("RemoteEvent", RS)
	submit.Name = "BossVote_Submit"
	local result = RS:FindFirstChild("BossVote_Result") or Instance.new("RemoteEvent", RS)
	result.Name = "BossVote_Result"
	return start, update, submit, result
end

-- === Boss Vote Session (server authoritative) ===
local ActiveBossVote = {
	isActive = false,
	votes = {},           -- [userId] = "Restart"|"Next"
	required = 0,
	countdownRunning = false,
	countdownThread = nil,
}

local function destroyBossVoteSession()
	if ActiveBossVote.countdownThread then
		ActiveBossVote.countdownRunning = false
		ActiveBossVote.countdownThread = nil
	end
	ActiveBossVote.isActive = false
	ActiveBossVote.votes = {}
	ActiveBossVote.required = 0
end

local function recountVotes()
	local r, n = 0, 0
	for _, choice in pairs(ActiveBossVote.votes) do
		if choice == "Restart" then r += 1
		elseif choice == "Next" then n += 1 end
	end
	return r, n
end

local function haveAllVotes()
	local r, n = recountVotes()
	return (r + n) >= ActiveBossVote.required and ActiveBossVote.required > 0
end

local function finalizeBossVote(choice)
	-- Send result to everyone
	local _, _, _, result = getVoteRemotes()
	for _, plr in ipairs(Players:GetPlayers()) do
		result:FireClient(plr, choice)
	end
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	-- Ensure a BindableEvent exists to request a new map
	local regen = ReplicatedStorage:FindFirstChild("RequestNewMap")
	if not regen then
		regen = Instance.new("BindableEvent")
		regen.Name = "RequestNewMap"
		regen.Parent = ReplicatedStorage
	end

	-- Apply decision (keep your current regeneration flow)
	if choice == "Next" then
		local lv = ReplicatedStorage:FindFirstChild("CurrentLevel")
		if lv then lv.Value = lv.Value + 1 end
		regen:Fire(choice)
	else
		regen:Fire(choice)
	end

	destroyBossVoteSession()
end

local function maybeStartCountdown()
	if ActiveBossVote.countdownRunning or not haveAllVotes() then return end
	ActiveBossVote.countdownRunning = true

	local _, update = getVoteRemotes() -- start is [1], update is [2]
	local endTime = tick() + 5

	ActiveBossVote.countdownThread = task.spawn(function()
		while ActiveBossVote.countdownRunning and tick() < endTime do
			local remain = math.max(0, math.ceil(endTime - tick()))
			local r, n = recountVotes()
			update:FireAllClients({
				type = "countdown",
				seconds = remain,
				restartVotes = r,
				nextVotes = n,
				required = ActiveBossVote.required
			})
			task.wait(0.2)
		end
		if ActiveBossVote.countdownRunning then
			local r, n = recountVotes()
			local choice = (n >= r) and "Next" or "Restart"
			finalizeBossVote(choice)
		end
	end)
end

-- Call this to spin up a vote UI for all players
local function EnsureBossVoteScreen()
	if ActiveBossVote.isActive then return end
	ActiveBossVote.isActive = true
	ActiveBossVote.votes = {}
	ActiveBossVote.required = #Players:GetPlayers()
	ActiveBossVote.countdownRunning = false
	ActiveBossVote.countdownThread = nil

	local start, update, submit = getVoteRemotes()

	-- Tell clients to open the UI
	start:FireAllClients({
		required = ActiveBossVote.required
	})

	-- Handle incoming votes (FIXED)
	submit.OnServerEvent:Connect(function(player, choice)
		if not ActiveBossVote.isActive then return end
		if choice ~= "Restart" and choice ~= "Next" then return end

		ActiveBossVote.votes[tostring(player.UserId)] = choice

		local r, n = recountVotes()
		update:FireAllClients({
			type = "votes",
			restartVotes = r,
			nextVotes = n,
			required = ActiveBossVote.required
		})

		-- Start countdown only when EVERYONE has voted
		if haveAllVotes() then
			maybeStartCountdown()
		end
	end)

	-- Player joins/leaves during session
	Players.PlayerAdded:Connect(function()
		if not ActiveBossVote.isActive then return end
		-- New player must vote -> reset requirement, cancel countdown
		ActiveBossVote.required = #Players:GetPlayers()
		if ActiveBossVote.countdownRunning then
			ActiveBossVote.countdownRunning = false
			ActiveBossVote.countdownThread = nil
		end
		local r, n = recountVotes()
		local _, update = getVoteRemotes()
		update:FireAllClients({
			type = "votes",
			restartVotes = r,
			nextVotes = n,
			required = ActiveBossVote.required
		})
	end)

	Players.PlayerRemoving:Connect(function(player)
		if not ActiveBossVote.isActive then return end
		ActiveBossVote.votes[tostring(player.UserId)] = nil
		ActiveBossVote.required = math.max(0, #Players:GetPlayers() - 1)

		local r, n = recountVotes()
		local _, update = getVoteRemotes()
		update:FireAllClients({
			type = "votes",
			restartVotes = r,
			nextVotes = n,
			required = ActiveBossVote.required
		})

		-- If remaining players have all voted, start countdown; else cancel it.
		if haveAllVotes() then
			maybeStartCountdown()
		else
			if ActiveBossVote.countdownRunning then
				ActiveBossVote.countdownRunning = false
				ActiveBossVote.countdownThread = nil
				update:FireAllClients({ type = "countdown", seconds = -1 })
			end
		end
	end)
end

-- ========================================
-- COLLISION GROUPS: Players vs Mobs (no-collide) + Dead (ghost)
-- ========================================

local function ensureCollisionGroup(name)
	pcall(function() PhysicsService:CreateCollisionGroup(name) end)
	return name
end

local function setPair(a, b, doesCollide)
	pcall(function() PhysicsService:SetCollisionGroupPair(a, b, doesCollide) end)
end

local COLLISION = {
	Players = ensureCollisionGroup("Players"),
	Mobs    = ensureCollisionGroup("Mobs"),
	Dead    = ensureCollisionGroup("Dead"),
}

-- Baseline pairs
setPair(COLLISION.Players, COLLISION.Mobs,   false) -- Players do not collide with Mobs
setPair(COLLISION.Players, COLLISION.Players, true)
setPair(COLLISION.Mobs,    COLLISION.Mobs,    true)  -- set to false if you want mobs to ghost each other
-- Dead collides with nothing
setPair(COLLISION.Dead, COLLISION.Players, false)
setPair(COLLISION.Dead, COLLISION.Mobs,    false)
setPair(COLLISION.Dead, COLLISION.Dead,    false)

local function putModelInCollisionGroup(model, groupName)
	for _, inst in ipairs(model:GetDescendants()) do
		if inst:IsA("BasePart") then
			pcall(function() inst.CollisionGroup = groupName end)
		end
	end
end

-- Put current and future player characters into "Players" collision group
local function hookPlayerCharacters()
	local function onCharacter(char)
		if char then
			putModelInCollisionGroup(char, "Players")
		end
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.Character then onCharacter(plr.Character) end
		plr.CharacterAdded:Connect(onCharacter)
	end
	Players.PlayerAdded:Connect(function(plr)
		plr.CharacterAdded:Connect(onCharacter)
	end)
end

-- ========================================
-- CONFIGURATION
-- ========================================

local CONFIG = {
	-- Pack rarity distribution & stat scaling
	PACK_DISTRIBUTION = { Normal = 95, Magic = 4.9, Rare = 0.1 }, -- Base % mix for Normal/Magic/Rare packs
	PACK_MULTIPLIERS = {
		Normal = { HP = 1.00, DMG = 1.00 },
		Magic  = { HP = 1.5, DMG = 1.25 },  -- Magic: +50% HP, +25% DMG
		Rare   = { HP = 2.00, DMG = 1.5 },  -- Rare: +100% HP, +50% DMG
	},

	-- ? BOSS MULTIPLIERS (PoE-style map boss scaling)
	BOSS_MULTIPLIERS = {
		HP = 20.0,   -- 20x white mob HP (significant tank, epic fight)
		DMG = 4.0,   -- 4x white mob damage (dangerous but not instant death)
	},

	POLL_RATE = 0.25,            -- Check spawners every 0.25s (4 Hz)
	RETARGET_INTERVAL = 0.01,    -- AI retargets frequently
	ATTACK_COOLDOWN = 1.2,       -- Melee attack every 1.2s
	ATTACK_RANGE = 5,            -- Attack when within 5 studs
	ATTACK_DAMAGE_RANGE = 6,     -- Must be within this range to deal damage (slightly larger for forgiveness)
	ATTACK_JUMP_HEIGHT = 2,      -- Jump up 2 studs during attack
	ATTACK_LUNGE_DISTANCE = 3,   -- Lunge forward 3 studs toward target
	ATTACK_DURATION = 0.3,       -- Duration of forward lunge (seconds)
	ATTACK_RETURN_DURATION = 0.2,-- Duration of return to position (seconds)
	TARGET_RANGE = 50,           -- Max distance to target players (was 200, now 1/4)
	INITIAL_AGGRO_RANGE = 17,    -- Distance to activate AI on spawn (was 50, now 1/3)
	SPAWNER_ACTIVATION_RANGE = 200, -- Distance to activate spawner and generate groups
	GROUP_SPAWN_RANGE = 250,     -- Only spawn groups when player within this distance
	DESPAWN_RANGE = 250,         -- Despawn if no players within this range
	DESPAWN_TIME = 20,           -- Despawn after 20s of no players

	-- Spawn count (FIXED - does not scale with level)
	GROUPS_PER_SPAWNER = 1,      -- Fixed groups per spawner (does NOT increase with level)
	MIN_ENEMIES_PER_GROUP = 4,   -- Minimum enemies per group (RANDOM)
	MAX_ENEMIES_PER_GROUP = 8,   -- Maximum enemies per group (RANDOM)
	GROUP_SPREAD = 8,            -- Studs between enemies in a group
	MIN_GROUP_DISTANCE = 30,     -- Minimum distance between group centers
	MAX_SPAWN_ATTEMPTS = 20,     -- Max attempts to find valid spawn for a group

	-- Base stats at level 1
	BASE_HP = 100,
	BASE_DAMAGE = 10,

	-- Level scaling tiers (percentage growth per level)
	HP_GROWTH_TIERS = {
		{maxLevel = 10, rate = 0.14},
		{maxLevel = 20, rate = 0.10},
		{maxLevel = 35, rate = 0.08},
		{maxLevel = 60, rate = 0.06},
		{maxLevel = math.huge, rate = 0.04}
	},
	DAMAGE_GROWTH_TIERS = {
		{maxLevel = 10, rate = 0.06},
		{maxLevel = 20, rate = 0.05},
		{maxLevel = 35, rate = 0.045},
		{maxLevel = 60, rate = 0.03},
		{maxLevel = math.huge, rate = 0.02}
	},

	-- Party scaling multipliers (HP only, Diablo-style)
	-- 0 or 1 player = 1.0x, 2 players = 1.68x, 3 players = 2.83x, 4+ players = 4.76x
	PARTY_SCALING = {
		[0] = 1.00, -- FIXED: Added 0-player case to prevent fallback to max multiplier
		[1] = 1.00,
		[2] = 1.68,
		[3] = 2.83,
		[4] = 4.76
	},

	-- Debug settings
	DEBUG_MODE = true -- Set to true for troubleshooting (temporarily enabled)
}

-- ========================================
-- UTILITY FUNCTIONS
-- ========================================

local function log(message)
	print("[DM]", message)
end

local function debugLog(message)
	if CONFIG.DEBUG_MODE then
		print("[DM DEBUG]", message)
	end
end

local function getOrCreateCurrentLevel()
	local currentLevel = ReplicatedStorage:FindFirstChild("CurrentLevel")
	if not currentLevel then
		currentLevel = Instance.new("IntValue")
		currentLevel.Name = "CurrentLevel"
		currentLevel.Value = 1
		currentLevel.Parent = ReplicatedStorage
		log("Created ReplicatedStorage.CurrentLevel (default: 1)")
	end
	return currentLevel
end

local function calculateScaledStat(baseStat, level, growthTiers)
	if level <= 1 then
		return baseStat
	end

	local scaledValue = baseStat
	local currentLevel = 2

	for _, tier in ipairs(growthTiers) do
		local tierEnd = math.min(level, tier.maxLevel)
		local levelsInTier = tierEnd - currentLevel + 1

		if levelsInTier > 0 then
			for _ = 1, levelsInTier do
				scaledValue = scaledValue * (1 + tier.rate)
			end
			currentLevel = tierEnd + 1
		end

		if currentLevel > level then
			break
		end
	end

	return scaledValue
end

local function calculateMonotonicStat(baseStat, level, growthTiers, previousValue)
	local rawValue = calculateScaledStat(baseStat, level, growthTiers)
	local rounded = math.floor(rawValue + 0.5)

	-- Enforce monotonicity: ensure value increases by at least 1
	if previousValue and rounded <= previousValue then
		rounded = previousValue + 1
	end

	return rounded
end

local function getPartyMultiplier(playerCount)
	-- Clamp to valid range and ensure we always have a value
	playerCount = math.max(0, math.min(playerCount, 4))
	return CONFIG.PARTY_SCALING[playerCount] or CONFIG.PARTY_SCALING[1]
end

local function countNearbyPlayers(position, radius)
	local count = 0
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character then
			local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
			if humanoidRootPart then
				local distance = (humanoidRootPart.Position - position).Magnitude
				if distance <= radius then
					count = count + 1
				end
			end
		end
	end
	return count
end

local function getNearestPlayer(position, maxRange)
	local nearestPlayer = nil
	local nearestDistance = maxRange or math.huge

	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")

			if humanoid and humanoid.Health > 0 and humanoidRootPart then
				local distance = (humanoidRootPart.Position - position).Magnitude
				if distance < nearestDistance then
					nearestDistance = distance
					nearestPlayer = character
				end
			end
		end
	end

	return nearestPlayer, nearestDistance
end

local function getRandomPositionOnSurface(part, attempts)
	attempts = attempts or 10
	local size = part.Size
	local cframe = part.CFrame

	for _ = 1, attempts do
		-- Get random point within the part's bounding box
		local randomX = (math.random() - 0.5) * size.X
		local randomZ = (math.random() - 0.5) * size.Z
		local randomY = size.Y / 2 + 10 -- Start from above

		local randomOffset = Vector3.new(randomX, randomY, randomZ)
		local worldPosition = cframe:PointToWorldSpace(randomOffset)

		-- Raycast down to find the surface
		local rayOrigin = worldPosition
		local rayDirection = Vector3.new(0, -(size.Y + 20), 0)

		local raycastParams = RaycastParams.new()
		raycastParams.FilterType = Enum.RaycastFilterType.Whitelist
		raycastParams.FilterDescendantsInstances = {part}

		local raycastResult = workspace:Raycast(rayOrigin, rayDirection, raycastParams)

		if raycastResult then
			-- Found a surface point!
			return raycastResult.Position + Vector3.new(0, 0.5, 0) -- Slight offset above surface
		end
	end

	-- Fallback: use center of part
	return part.Position + Vector3.new(0, 2, 0)
end

local function isPositionNearPlayer(position, range)
	-- Check if position is within range of any player
	range = range or 200 -- Default activation range
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character then
			local hrp = character:FindFirstChild("HumanoidRootPart")
			if hrp then
				local distance = (hrp.Position - position).Magnitude
				if distance <= range then
					return true
				end
			end
		end
	end
	return false
end

local function createHealthBar(mob, humanoid)
	-- Find the head or use HumanoidRootPart
	local attachPart = mob:FindFirstChild("Head") or mob:FindFirstChild("HumanoidRootPart")
	if not attachPart then
		return
	end

	-- Create BillboardGui
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "HealthBar"
	billboard.Adornee = attachPart
	billboard.Size = UDim2.new(4, 0, 0.5, 0)
	billboard.StudsOffset = Vector3.new(0, 3, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = attachPart

	-- Background frame
	local background = Instance.new("Frame")
	background.Name = "Background"
	background.Size = UDim2.new(1, 0, 1, 0)
	background.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	background.BorderSizePixel = 2
	background.BorderColor3 = Color3.fromRGB(0, 0, 0)
	background.Parent = billboard

	-- Health bar (color by pack rarity; bosses look Rare color)
	local healthBar = Instance.new("Frame")
	healthBar.Name = "HealthBar"
	healthBar.Size = UDim2.new(1, 0, 1, 0)
	healthBar.BackgroundColor3 = Color3.fromRGB(255, 0, 0) -- default
	healthBar.BorderSizePixel = 0
	healthBar.Parent = background

	local function applyRarityColor()
		if mob:GetAttribute("IsBoss") then
			healthBar.BackgroundColor3 = Color3.fromRGB(255, 230, 50) -- boss: gold
			return
		end
		local rarity = mob:GetAttribute("PackRarity")
		if rarity == "Magic" then
			healthBar.BackgroundColor3 = Color3.fromRGB(70, 170, 255)
		elseif rarity == "Rare" then
			healthBar.BackgroundColor3 = Color3.fromRGB(255, 230, 50)
		else
			healthBar.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
		end
	end
	applyRarityColor()
	pcall(function()
		mob:GetAttributeChangedSignal("PackRarity"):Connect(applyRarityColor)
		mob:GetAttributeChangedSignal("IsBoss"):Connect(applyRarityColor)
	end)

	-- Tween info for smooth HP bar animation
	local tweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local lastUpdate = 0

	-- Update health bar on health change (throttled)
	local function updateHealthBar()
		local now = tick()
		-- Throttle updates to max 10 per second
		if now - lastUpdate < 0.1 then
			return
		end
		lastUpdate = now

		local healthPercent = 0
		if humanoid.MaxHealth > 0 then
			healthPercent = math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
		end

		-- Tween the size (only)
		local sizeTween = TweenService:Create(healthBar, tweenInfo, {
			Size = UDim2.new(healthPercent, 0, 1, 0)
		})
		sizeTween:Play()
	end

	-- Connect to health changes
	humanoid.HealthChanged:Connect(updateHealthBar)

	-- Initial update
	updateHealthBar()
end


-- =========================
-- Enemy tagging & collision helpers
-- =========================
local function markAsEnemy(model)
	if not model or not model:IsA("Model") then return end
	if not CollectionService:HasTag(model, "Enemy") then
		CollectionService:AddTag(model, "Enemy")
	end
	model:SetAttribute("IsEnemy", true)
end

local function markAsDead(model)
	if not model or not model:IsA("Model") then return end
	if CollectionService:HasTag(model, "Enemy") then
		CollectionService:RemoveTag(model, "Enemy")
	end
	if not CollectionService:HasTag(model, "Dead") then
		CollectionService:AddTag(model, "Dead")
	end
end

local function setDeadCollision(model)
	for _, inst in ipairs(model:GetDescendants()) do
		if inst:IsA("BasePart") then
			inst.CanCollide = false
			inst.CanTouch = false
			inst.CanQuery = false
			pcall(function() inst.CollisionGroup = "Dead" end)
		end
	end
end

local function playDeathAnimation(mob)
	local humanoidRootPart = mob:FindFirstChild("HumanoidRootPart")
	if not humanoidRootPart then
		return
	end

	-- Anchor all parts to prevent falling through floor
	for _, part in ipairs(mob:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.Anchored = true -- Keep them in place!
		end
	end

	-- Flip the model to the side (death animation)
	local currentCFrame = humanoidRootPart.CFrame
	local flipTween = TweenService:Create(humanoidRootPart, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = currentCFrame * CFrame.Angles(0, 0, math.rad(90)) -- Flip to the side
	})
	flipTween:Play()

	-- Wait a moment, then fade out
	task.wait(0.5)

	-- Fade out all parts
	local fadeInfo = TweenInfo.new(1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local fadeTweens = {}

	for _, part in ipairs(mob:GetDescendants()) do
		if part:IsA("BasePart") then
			local tween = TweenService:Create(part, fadeInfo, {
				Transparency = 1
			})
			table.insert(fadeTweens, tween)
			tween:Play()
		elseif part:IsA("Decal") or part:IsA("Texture") then
			local tween = TweenService:Create(part, fadeInfo, {
				Transparency = 1
			})
			table.insert(fadeTweens, tween)
			tween:Play()
		end
	end

	-- Fade out HP bar
	local healthBar = mob:FindFirstChild("Head") or mob:FindFirstChild("HumanoidRootPart")
	if healthBar then
		local billboard = healthBar:FindFirstChild("HealthBar")
		if billboard then
			local bgFrame = billboard:FindFirstChild("Background")
			if bgFrame then
				local bgTween = TweenService:Create(bgFrame, fadeInfo, {
					BackgroundTransparency = 1
				})
				bgTween:Play()

				-- Fade out the level text and borders
				for _, child in ipairs(bgFrame:GetDescendants()) do
					if child:IsA("GuiObject") then
						if child:IsA("TextLabel") then
							local textTween = TweenService:Create(child, fadeInfo, {
								TextTransparency = 1,
								TextStrokeTransparency = 1
							})
							textTween:Play()
						else
							local guiTween = TweenService:Create(child, fadeInfo, {
								BackgroundTransparency = 1
							})
							guiTween:Play()
						end
					end
				end
			end
		end
	end

	-- Wait for fade to complete, then destroy
	task.wait(2)
	mob:Destroy()
end

-- ========================================
-- SPAWNER MANAGER
-- ========================================

local SpawnerManager = {}
SpawnerManager.__index = SpawnerManager

function SpawnerManager.new()
	local self = setmetatable({}, SpawnerManager)
	self.spawners = {}
	self.currentLevel = getOrCreateCurrentLevel()
	self.mobsFolder = workspace:FindFirstChild("Mobs") or Instance.new("Folder", workspace)
	self.mobsFolder.Name = "Mobs"

	-- Cache for monotonic stat tracking per level
	self.cachedHP = {}
	self.cachedDamage = {}

	-- Track available prefabs
	self.availablePrefabs = {}
	self:scanPrefabs()

	return self
end

function SpawnerManager:scanPrefabs()
	log("Scanning ReplicatedStorage for enemy prefabs...")
	local enemiesFolder = ReplicatedStorage:FindFirstChild("Enemies")
	if not enemiesFolder then
		warn("[DM] WARNING: ReplicatedStorage.Enemies folder not found!")
		return
	end

	for _, child in ipairs(enemiesFolder:GetChildren()) do
		if child:IsA("Model") then
			local humanoid = child:FindFirstChildOfClass("Humanoid")
			if humanoid then
				self.availablePrefabs[child.Name] = child
				log(string.format("  Found prefab: %s (has Humanoid)", child.Name))
			else
				debugLog(string.format("  Skipping %s (no Humanoid)", child.Name))
			end
		end
	end

	if next(self.availablePrefabs) == nil then
		warn("[DM] WARNING: No valid enemy prefabs found in ReplicatedStorage.Enemies!")
		warn("[DM] Expected: Models with Humanoid (e.g., 'Shiba', etc.)")
	end
end

function SpawnerManager:getSpawnerData(spawnerPart)
	local data = {
		part = spawnerPart,
		enemyType = spawnerPart:GetAttribute("EnemyType") or "Shiba",
		leashRadius = spawnerPart:GetAttribute("LeashRadius") or 120,

		-- Runtime state
		aliveMobs = {},
		isActive = false,
		hasSpawned = false, -- Track if spawner has been triggered
		hasLogged = false, -- For one-time debug logs
		groupLocations = nil, -- Pre-generated group spawn locations
		spawnedGroups = {}, -- Track which groups have been spawned
	}
	return data
end

function SpawnerManager:getSpawnCount(_level)
	-- Fixed group count - does NOT scale with level
	local groupCount = CONFIG.GROUPS_PER_SPAWNER
	-- Total enemies is variable since each group has random size (4-8)
	local minTotalEnemies = groupCount * CONFIG.MIN_ENEMIES_PER_GROUP
	local maxTotalEnemies = groupCount * CONFIG.MAX_ENEMIES_PER_GROUP
	return groupCount, minTotalEnemies, maxTotalEnemies
end

function SpawnerManager:generateGroupLocations(spawnerData, groupCount)
	-- Pre-generate all group spawn locations with minimum distance
	local groupCenters = {}
	local minDistance = CONFIG.MIN_GROUP_DISTANCE

	for _ = 1, groupCount do
		local groupCenter = nil
		local attempts = 0

		while not groupCenter and attempts < CONFIG.MAX_SPAWN_ATTEMPTS do
			attempts = attempts + 1
			local candidatePosition = getRandomPositionOnSurface(spawnerData.part)

			-- Check distance from all existing group centers
			local validPosition = true
			for _, existingCenter in ipairs(groupCenters) do
				local distance = (candidatePosition - existingCenter).Magnitude
				if distance < minDistance then
					validPosition = false
					break
				end
			end

			if validPosition then
				groupCenter = candidatePosition
			end
		end

		-- Fallback if we couldn't find a valid position
		if not groupCenter then
			groupCenter = getRandomPositionOnSurface(spawnerData.part)
		end

		table.insert(groupCenters, groupCenter)
	end

	return groupCenters
end

function SpawnerManager:registerSpawner(spawnerPart)
	if self.spawners[spawnerPart] then
		return
	end

	local data = self:getSpawnerData(spawnerPart)
	self.spawners[spawnerPart] = data

	local currentLevel = self.currentLevel.Value
	local groupCount, minEnemies, maxEnemies = self:getSpawnCount(currentLevel)
	log(string.format("Registered spawner: %s (Type: %s, %d groups = %d-%d enemies per spawner - ALL LEVELS)", 
		spawnerPart.Name, data.enemyType, groupCount, minEnemies, maxEnemies))

	-- Check if the enemy type exists
	if not self.availablePrefabs[data.enemyType] then
		-- Try common variations
		local alternatives = {"Shiba", "Enemy", "Mob"}
		local found = false
		for _, alt in ipairs(alternatives) do
			if self.availablePrefabs[alt] then
				warn(string.format("[DM] EnemyType '%s' not found for spawner '%s', will try '%s' as fallback", 
					data.enemyType, spawnerPart.Name, alt))
				found = true
				data.enemyType = alt
				break
			end
		end
		if not found then
			warn(string.format("[DM] WARNING: EnemyType '%s' not found! Available: %s", 
				data.enemyType, table.concat(self:getAvailablePrefabNames(), ", ")))
		end
	end
end

function SpawnerManager:getAvailablePrefabNames()
	local names = {}
	for name, _ in pairs(self.availablePrefabs) do
		table.insert(names, name)
	end
	return names
end

function SpawnerManager:unregisterSpawner(spawnerPart)
	local data = self.spawners[spawnerPart]
	if data then
		-- Clean up all alive mobs
		for mob, _ in pairs(data.aliveMobs) do
			if mob.Parent then
				mob:Destroy()
			end
		end
		self.spawners[spawnerPart] = nil
		log(string.format("Unregistered spawner: %s", spawnerPart.Name))
	end
end

function SpawnerManager:getScaledStats(level, partyCount)
	local cacheKey = level

	-- Calculate HP with monotonicity
	if not self.cachedHP[cacheKey] then
		local previousHP = self.cachedHP[cacheKey - 1]
		self.cachedHP[cacheKey] = calculateMonotonicStat(CONFIG.BASE_HP, level, CONFIG.HP_GROWTH_TIERS, previousHP)
	end

	-- Calculate Damage with monotonicity
	if not self.cachedDamage[cacheKey] then
		local previousDamage = self.cachedDamage[cacheKey - 1]
		self.cachedDamage[cacheKey] = calculateMonotonicStat(CONFIG.BASE_DAMAGE, level, CONFIG.DAMAGE_GROWTH_TIERS, previousDamage)
	end

	local baseHP = self.cachedHP[cacheKey]
	local baseDamage = self.cachedDamage[cacheKey]

	-- Apply party scaling to HP only
	local partyMultiplier = getPartyMultiplier(partyCount)
	local finalHP = math.floor(baseHP * partyMultiplier + 0.5)

	return finalHP, baseDamage
end

function SpawnerManager:spawnMob(spawnerData, level, partyCount, customPosition)
	-- Get enemy prefab
	local prefabName = spawnerData.enemyType
	local prefab = self.availablePrefabs[prefabName]

	-- ? Check if this is a boss spawner
	local isBoss = spawnerData.part:GetAttribute("IsBoss") == true

	-- Try fallback options
	if not prefab then
		debugLog(string.format("Prefab '%s' not found, trying fallbacks...", prefabName))
		local fallbacks = {"Shiba", "Enemy", "Mob"}
		for _, fallbackName in ipairs(fallbacks) do
			prefab = self.availablePrefabs[fallbackName]
			if prefab then
				if not spawnerData.hasLoggedFallback then
					log(string.format("Using '%s' as fallback for '%s'", fallbackName, prefabName))
					spawnerData.hasLoggedFallback = true
				end
				prefabName = fallbackName
				break
			end
		end
	end

	if not prefab then
		if not spawnerData.hasLoggedError then
			warn(string.format("[DM] ERROR: Cannot spawn - no valid prefab found for '%s'", spawnerData.enemyType))
			warn(string.format("[DM] Available prefabs: %s", table.concat(self:getAvailablePrefabNames(), ", ")))
			spawnerData.hasLoggedError = true
		end
		return nil
	end

	-- Clone and setup
	local mob = prefab:Clone()
	local humanoid = mob:FindFirstChildOfClass("Humanoid")
	local humanoidRootPart = mob:FindFirstChild("HumanoidRootPart")

	if not humanoid then
		warn(string.format("[DM] ERROR: '%s' has no Humanoid", prefabName))
		mob:Destroy()
		return nil
	end

	-- Put the mob model into the "Mobs" collision group
	putModelInCollisionGroup(mob, "Mobs")

	-- Get scaled stats
	local hp, damage = self:getScaledStats(level, partyCount)

	-- ? Apply boss multipliers if this is a boss
	if isBoss then
		hp = math.floor(hp * CONFIG.BOSS_MULTIPLIERS.HP + 0.5)
		damage = math.floor(damage * CONFIG.BOSS_MULTIPLIERS.DMG + 0.5)

		-- Mark as boss for special handling
		mob:SetAttribute("IsBoss", true)
		mob:SetAttribute("BossName", prefabName)

		-- Scale boss to 2x size (do this before positioning)
		pcall(function()
			if mob and mob:IsA("Model") then
				mob:ScaleTo(2)
			end
		end)

		-- Red outline for boss (replace any existing highlight)
		pcall(function()
			local existingHL = mob:FindFirstChildOfClass("Highlight")
			if existingHL then existingHL:Destroy() end
			local bossHL = Instance.new("Highlight")
			bossHL.Name = "BossHighlight"
			bossHL.FillTransparency = 1
			bossHL.OutlineTransparency = 0
			bossHL.OutlineColor = Color3.fromRGB(255, 0, 0)
			bossHL.Parent = mob
		end)

		log(string.format("?? BOSS SPAWN: %s L%d HP=%d (x%.1f) DMG=%d (x%.1f)",
			prefabName, level, hp, CONFIG.BOSS_MULTIPLIERS.HP, damage, CONFIG.BOSS_MULTIPLIERS.DMG))
	end

	humanoid.MaxHealth = hp
	humanoid.Health = hp
	humanoid.AutoRotate = true

	-- Ensure proper collision
	if humanoidRootPart then
		humanoidRootPart.CanCollide = true
	end

	-- Store damage/metadata
	mob:SetAttribute("Damage", damage)
	mob:SetAttribute("Level", level)
	mob:SetAttribute("SpawnerOrigin", spawnerData.part.Position)
	mob:SetAttribute("LeashRadius", spawnerData.leashRadius)

	-- Spawn at custom position or random position on union surface
	local spawnPosition = customPosition or getRandomPositionOnSurface(spawnerData.part)
	if humanoidRootPart then
		humanoidRootPart.CFrame = CFrame.new(spawnPosition)
	else
		mob:PivotTo(CFrame.new(spawnPosition))
	end
	mob:SetAttribute("SpawnPosition", spawnPosition)

	mob.Parent = self.mobsFolder
	task.defer(markAsEnemy, mob)

	-- Health bar
	createHealthBar(mob, humanoid)

	-- Track in spawner's alive set
	spawnerData.aliveMobs[mob] = true

	-- Setup damage numbers on health change
	local lastHealth = humanoid.Health
	humanoid.HealthChanged:Connect(function(newHealth)
		if newHealth < lastHealth and newHealth > 0 then
			local damageDealt = math.floor(lastHealth - newHealth)
			print(string.format("[DM] Enemy took %.1f damage! (HP: %.1f -> %.1f)", damageDealt, lastHealth, newHealth))

			-- Show damage number above enemy
			if DamageNumbers and DamageNumbers.Show then
				print("[DM] Calling DamageNumbers.Show for enemy...")
				local success, err = pcall(function()
					DamageNumbers.Show(mob, damageDealt, false)
				end)
				if not success then
					warn("[DM] Failed to show damage numbers:", err)
				else
					print("[DM] Damage number created successfully!")
				end
			else
				warn("[DM] DamageNumbers.Show not available!")
			end
		end
		lastHealth = newHealth
	end)

	-- Local helper for guaranteed boss drops (no RNG miss)
	local function BossGuaranteedDrops(mobModel, centerPos)
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local dungeonLevel = 1
		local lvl = ReplicatedStorage:FindFirstChild("CurrentLevel")
		if lvl and lvl:IsA("IntValue") then dungeonLevel = lvl.Value end

		local count = math.random(3, 5)
		for i = 1, count do
			local itemId = DropManager:GetRandomItemForMob(mobModel)
			if itemId then
				local offset = Vector3.new(math.random(-3, 3), 0, math.random(-3, 3))
				DropManager:SpawnWorldDrop(itemId, centerPos + offset, dungeonLevel)
			end
		end
	end

	-- Setup death cleanup with animation
	local deathHandled = false
	humanoid.Died:Connect(function()
		if deathHandled then return end
		deathHandled = true

		-- Immediately disable interactions and tag as dead
		setDeadCollision(mob)
		markAsDead(mob)
		self:onMobDied(spawnerData, mob)

		-- Drop logic
		pcall(function()
			local hrp = mob:FindFirstChild("HumanoidRootPart")
			local pos = hrp and hrp.Position or (mob.PrimaryPart and mob.PrimaryPart.Position)
			if not pos then return end

			if isBoss then
				-- ? Guaranteed boss drops
				BossGuaranteedDrops(mob, pos)

				-- Show vote terminal (once)
				EnsureBossVoteScreen()

			else
				-- Regular mob: keep your existing single-roll behavior
				DropManager:RollForDropAtPosition(mob, pos)
			end
		end)

		playDeathAnimation(mob)
	end)

	-- Cleanup if mob is manually destroyed
	mob.AncestryChanged:Connect(function(_, parent)
		if not parent and not deathHandled then
			self:onMobDied(spawnerData, mob)
		end
	end)

	-- Initialize AI
	self:initializeMobAI(mob)

	debugLog(string.format("Spawned %s L%d HP=%d DMG=%d @%s (Party:%d)", prefabName, level, hp, damage, spawnerData.part.Name, partyCount))

	return mob
end


function SpawnerManager:spawnGroup(spawnerData, level, partyCount, groupCenter)
	-- Randomly determine group size for this specific group (4-8 enemies)
	local enemiesInGroup = math.random(CONFIG.MIN_ENEMIES_PER_GROUP, CONFIG.MAX_ENEMIES_PER_GROUP)
	local spread = CONFIG.GROUP_SPREAD

	debugLog(string.format("Spawning group of %d enemies at %s", enemiesInGroup, tostring(groupCenter)))
	-- If this spawner is a Boss, force exactly 1 enemy and no spread
	local isBossSpawner = spawnerData.part:GetAttribute("IsBoss") == true
	if isBossSpawner then
		enemiesInGroup = 1
		spread = 0
	end

	-- Roll this group's rarity and collect spawned mob refs
	local packRarity = (self.rollPackRarity and self:rollPackRarity()) or "Normal"
	local spawnedMobs = {}

	for i = 1, enemiesInGroup do
		-- Calculate offset for this enemy in the group (circular pattern)
		local angle = (i - 1) * (2 * math.pi / enemiesInGroup)
		local offset = Vector3.new(
			math.cos(angle) * spread,
			0,
			math.sin(angle) * spread
		)

		-- Spawn at group center + offset
		local spawnPosition = groupCenter + offset
		local mob = self:spawnMob(spawnerData, level, partyCount, spawnPosition)
		if mob then table.insert(spawnedMobs, mob) end
		-- Small delay between enemies in the same group
		if i < enemiesInGroup then
			task.wait(0.02)
		end
	end

	-- Apply rarity effects to the whole group (skip if boss)
	if #spawnedMobs > 0 and not (spawnerData.part:GetAttribute("IsBoss") == true) then
		self:_applyPackRarityToGroup(spawnedMobs, packRarity)
	end
end

function SpawnerManager:onMobDied(spawnerData, mob)
	spawnerData.aliveMobs[mob] = nil
end

function SpawnerManager:updateSpawner(spawnerData)
	if not spawnerData.part.Parent then
		return
	end

	local position = spawnerData.part.Position

	-- Check if spawner is near any player
	local isNearPlayer = isPositionNearPlayer(position, CONFIG.SPAWNER_ACTIVATION_RANGE)

	if isNearPlayer and not spawnerData.isActive then
		spawnerData.isActive = true

		-- Get current level and calculate spawn count (groups)
		local level = self.currentLevel.Value
		local groupCount, minEnemies, maxEnemies = self:getSpawnCount(level)

		-- Pre-generate all group spawn locations
		spawnerData.groupLocations = self:generateGroupLocations(spawnerData, groupCount)

		log(string.format("Activating spawner: %s (player nearby) - %d groups ready (%d-%d potential enemies)", 
			spawnerData.part.Name, groupCount, minEnemies, maxEnemies))

		debugLog(string.format("Generated %d group locations for %s", #spawnerData.groupLocations, spawnerData.part.Name))
	end

	-- Progressive group spawning based on player proximity
	if spawnerData.isActive and spawnerData.groupLocations then
		local level = self.currentLevel.Value
		local partyCount = countNearbyPlayers(position, 120)

		-- Check each group location
		for groupIndex, groupCenter in ipairs(spawnerData.groupLocations) do
			-- Skip if already spawned
			if not spawnerData.spawnedGroups[groupIndex] then
				-- Check if any player is within range of this group's spawn location
				local _, distToPlayer = getNearestPlayer(groupCenter, CONFIG.GROUP_SPAWN_RANGE)

				if distToPlayer and distToPlayer <= CONFIG.GROUP_SPAWN_RANGE then
					-- Mark as spawned
					spawnerData.spawnedGroups[groupIndex] = true

					debugLog(string.format("Spawning group %d/%d at distance %.1f from player", 
						groupIndex, #spawnerData.groupLocations, distToPlayer))

					-- Spawn this group
					task.spawn(function()
						self:spawnGroup(spawnerData, level, partyCount, groupCenter)
					end)
				end
			end
		end
	end
end

function SpawnerManager:performAttack(mob, aiData, targetHRP, targetHumanoid)
	-- Prevent overlapping attacks
	if aiData.isAttacking then return end

	aiData.isAttacking = true

	local humanoidRootPart = aiData.hrp
	local startPosition = humanoidRootPart.CFrame

	-- Calculate direction to target
	local direction = (targetHRP.Position - humanoidRootPart.Position).Unit
	local lungePosition = startPosition.Position + (direction * CONFIG.ATTACK_LUNGE_DISTANCE)

	-- Create CFrame that faces the target
	local lookAtCFrame = CFrame.lookAt(startPosition.Position, targetHRP.Position)

	-- Jump forward animation
	local jumpUpCFrame = lookAtCFrame + Vector3.new(0, CONFIG.ATTACK_JUMP_HEIGHT, 0)
	local lungeCFrame = CFrame.new(lungePosition) * jumpUpCFrame.Rotation + Vector3.new(0, CONFIG.ATTACK_JUMP_HEIGHT, 0)

	local tweenInfo = TweenInfo.new(CONFIG.ATTACK_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local forwardTween = TweenService:Create(humanoidRootPart, tweenInfo, {CFrame = lungeCFrame})

	forwardTween:Play()

	-- Deal damage at the peak of the attack
	task.wait(CONFIG.ATTACK_DURATION * 0.7)

	-- CRITICAL: Check if target is still in range before dealing damage
	if targetHRP and targetHumanoid and targetHumanoid.Health > 0 then
		local currentDistance = (targetHRP.Position - humanoidRootPart.Position).Magnitude

		if currentDistance <= CONFIG.ATTACK_DAMAGE_RANGE then
			-- Target is in range, deal damage
			local damage = mob:GetAttribute("Damage") or CONFIG.BASE_DAMAGE
			targetHumanoid:TakeDamage(damage)

			-- Show damage number above player
			if DamageNumbers and DamageNumbers.Show then
				local success, err = pcall(function()
					DamageNumbers.Show(aiData.target, damage, false)
				end)
				if not success then
					warn("[DM] Failed to show damage number on player:", err)
				end
			end
		end
	end

	task.wait(CONFIG.ATTACK_DURATION * 0.3)

	-- Return to original position
	local returnTweenInfo = TweenInfo.new(CONFIG.ATTACK_RETURN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local returnTween = TweenService:Create(humanoidRootPart, returnTweenInfo, {CFrame = startPosition})

	returnTween:Play()
	returnTween.Completed:Wait()

	aiData.isAttacking = false
end

function SpawnerManager:initializeMobAI(mob)
	local humanoid = mob:FindFirstChildOfClass("Humanoid")
	local humanoidRootPart = mob:FindFirstChild("HumanoidRootPart")

	if not humanoid or not humanoidRootPart then
		return
	end

	local aiData = {
		mob = mob,
		humanoid = humanoid,
		hrp = humanoidRootPart,
		target = nil,
		lastRetarget = 0,
		lastAttack = 0,
		path = nil, -- Create path lazily when needed
		isMoving = false,
		lastPlayerCheck = 0,
		isAttacking = false, -- Flag to prevent overlapping attacks
		normalWalkSpeed = humanoid.WalkSpeed, -- Store original walk speed
		isReturning = false -- Flag to track if returning to spawn
	}

	-- AI loop with random startup delay to spread out CPU load
	task.spawn(function()
		task.wait(math.random() * 0.3) -- Random 0-300ms delay

		-- Wait until a player is within initial aggro range
		local aggroActivated = false
		while mob.Parent and humanoid.Health > 0 and not aggroActivated do
			local _, distToNearestPlayer = getNearestPlayer(humanoidRootPart.Position, CONFIG.INITIAL_AGGRO_RANGE)
			if distToNearestPlayer and distToNearestPlayer <= CONFIG.INITIAL_AGGRO_RANGE then
				aggroActivated = true
				debugLog(string.format("%s activated - player within %d studs", mob.Name, CONFIG.INITIAL_AGGRO_RANGE))
			else
				task.wait(0.5) -- Check every 0.5s while idle
			end
		end

		-- Main AI loop (only runs after aggro activation)
		while mob.Parent and humanoid.Health > 0 do
			local currentTime = tick()

			-- Don't update AI during attack animation
			if not aiData.isAttacking then
				-- First priority: Check if we need to return to spawn (even if we have a target)
				local spawnPosition = mob:GetAttribute("SpawnPosition")
				local leashRadius = mob:GetAttribute("LeashRadius") or 120

				if spawnPosition then
					local distFromSpawn = (aiData.hrp.Position - spawnPosition).Magnitude

					-- If beyond leash OR already returning, force return to spawn
					if distFromSpawn > leashRadius or aiData.isReturning then
						if distFromSpawn > 3 then
							-- Still need to return
							aiData.target = nil -- Clear target to prevent retargeting
							self:returnToSpawn(aiData)
						else
							-- Reached spawn - stop returning and allow detection again
							if aiData.isReturning then
								humanoid.WalkSpeed = aiData.normalWalkSpeed
								aiData.isReturning = false
								humanoid:MoveTo(aiData.hrp.Position) -- Stop moving
							end
						end
					else
						-- Within leash range - normal AI behavior

						-- Retarget (only when not returning)
						if not aiData.isReturning and currentTime - aiData.lastRetarget >= CONFIG.RETARGET_INTERVAL then
							aiData.target, _ = getNearestPlayer(aiData.hrp.Position, CONFIG.TARGET_RANGE)
							aiData.lastRetarget = currentTime
						end

						-- Check for despawn
						if currentTime - aiData.lastPlayerCheck >= 2 then
							local _, distToPlayer = getNearestPlayer(aiData.hrp.Position, CONFIG.DESPAWN_RANGE)
							if not distToPlayer or distToPlayer > CONFIG.DESPAWN_RANGE then
								if not aiData.noPlayerTime then
									aiData.noPlayerTime = currentTime
								elseif currentTime - aiData.noPlayerTime >= CONFIG.DESPAWN_TIME then
									debugLog(string.format("Despawning %s (no players nearby)", mob.Name))
									mob:Destroy()
									break
								end
							else
								aiData.noPlayerTime = nil
							end
							aiData.lastPlayerCheck = currentTime
						end

						-- AI behavior with target
						if aiData.target then
							local targetHRP = aiData.target:FindFirstChild("HumanoidRootPart")
							local targetHumanoid = aiData.target:FindFirstChildOfClass("Humanoid")

							-- Validate target is still valid
							local targetValid = targetHRP 
								and targetHumanoid 
								and targetHumanoid.Health > 0 
								and targetHRP.Parent == aiData.target
								and aiData.target.Parent ~= nil

							if targetValid then
								local distance = (targetHRP.Position - aiData.hrp.Position).Magnitude

								-- Attack or move toward target
								if distance <= CONFIG.ATTACK_RANGE then
									-- Stop moving and prepare attack
									humanoid:MoveTo(aiData.hrp.Position)

									if currentTime - aiData.lastAttack >= CONFIG.ATTACK_COOLDOWN then
										-- Perform attack animation with range check
										aiData.lastAttack = currentTime
										self:performAttack(mob, aiData, targetHRP, targetHumanoid)
									end
								else
									-- Move toward target
									self:moveToTarget(aiData, targetHRP.Position)
								end
							else
								-- Target is invalid, clear it
								aiData.target = nil
							end
						end
					end
				end
			end

			task.wait(0.15) -- Slightly slower AI tick
		end
	end)
end

function SpawnerManager:returnToSpawn(aiData)
	local mob = aiData.mob
	local humanoid = aiData.humanoid
	local hrp = aiData.hrp

	-- Get individual spawn position
	local spawnPosition = mob:GetAttribute("SpawnPosition")
	if not spawnPosition then
		return -- Can't return if we don't know where spawn is
	end

	-- Check if we're already at spawn position
	local distanceToSpawn = (hrp.Position - spawnPosition).Magnitude

	if distanceToSpawn < 3 then
		-- We've reached spawn, reset to normal speed and stop returning
		if aiData.isReturning then
			humanoid.WalkSpeed = aiData.normalWalkSpeed
			aiData.isReturning = false
			aiData.target = nil -- Clear target
			humanoid:MoveTo(hrp.Position) -- Stop moving
		end
		return
	end

	-- If not returning yet, start returning with triple speed
	if not aiData.isReturning then
		aiData.isReturning = true
		humanoid.WalkSpeed = aiData.normalWalkSpeed * 3
	end

	-- Move toward spawn position
	humanoid:MoveTo(spawnPosition)
end

function SpawnerManager:moveToTarget(aiData, targetPosition)
	-- Create path lazily on first use
	if not aiData.path then
		aiData.path = PathfindingService:CreatePath({
			AgentRadius = 2,
			AgentHeight = 5,
			AgentCanJump = true,
			AgentCanClimb = false,
			WaypointSpacing = 4
		})
	end

	local success, _ = pcall(function()
		aiData.path:ComputeAsync(aiData.hrp.Position, targetPosition)
	end)

	if success and aiData.path.Status == Enum.PathStatus.Success then
		local waypoints = aiData.path:GetWaypoints()

		if #waypoints > 0 then
			-- Move to the next waypoint (skip first one as it's usually current position)
			local targetWaypoint = waypoints[2] or waypoints[1]
			if targetWaypoint then
				aiData.humanoid:MoveTo(targetWaypoint.Position)

				-- Handle jumping if needed
				if targetWaypoint.Action == Enum.PathWaypointAction.Jump then
					aiData.humanoid.Jump = true
				end
			end
		end
	else
		-- Fallback: move directly
		aiData.humanoid:MoveTo(targetPosition)
	end
end

function SpawnerManager:moveToPosition(aiData, position)
	aiData.humanoid:MoveTo(position)
end

function SpawnerManager:update()
	for spawnerPart, spawnerData in pairs(self.spawners) do
		if spawnerPart.Parent then
			self:updateSpawner(spawnerData)
		else
			self:unregisterSpawner(spawnerPart)
		end
	end
end



--====================================================
-- Pack Rarity Utilities
--====================================================
function SpawnerManager:setBasePackDistribution(normal, magic, rare)
	normal = tonumber(normal) or 80
	magic  = tonumber(magic)  or 15
	rare   = tonumber(rare)   or 5
	local total = normal + magic + rare
	if total <= 0 then normal, magic, rare = 80, 15, 5; total = 100 end
	self._packCdf = { n = normal / total, m = (normal + magic) / total }
	self._packBase = { Normal = normal, Magic = magic, Rare = rare }
end

function SpawnerManager:rollPackRarity()
	if not self._packCdf then
		local base = (CONFIG and CONFIG.PACK_DISTRIBUTION) or { Normal = 80, Magic = 15, Rare = 5 }
		self:setBasePackDistribution(base.Normal, base.Magic, base.Rare)
	end
	local r = math.random()
	if r < self._packCdf.n then return "Normal"
	elseif r < self._packCdf.m then return "Magic"
	else return "Rare" end
end

-- Apply rarity tags, highlights, and stat multipliers to a single mob model
function SpawnerManager:_applyPackRarityToMob(mobModel, packRarity)
	if not mobModel or not mobModel:IsA("Model") then return end

	pcall(function() mobModel:SetAttribute("PackRarity", packRarity) end)

	-- Outline for Magic/Rare
	local existing = mobModel:FindFirstChildOfClass("Highlight")
	if existing then existing:Destroy() end
	if packRarity == "Magic" or packRarity == "Rare" then
		local h = Instance.new("Highlight")
		h.Name = "RarityHighlight"
		h.FillTransparency = 1
		h.OutlineTransparency = 0
		if packRarity == "Magic" then
			h.OutlineColor = Color3.fromRGB(70, 170, 255)
		else
			h.OutlineColor = Color3.fromRGB(255, 230, 50)
		end
		h.Parent = mobModel
	end

	local mults = (CONFIG and CONFIG.PACK_MULTIPLIERS and CONFIG.PACK_MULTIPLIERS[packRarity]) or {HP=1,DMG=1}

	local humanoid = mobModel:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local baseMax = humanoid.MaxHealth
		if baseMax and baseMax > 0 then
			local newMax = math.max(1, math.floor(baseMax * mults.HP + 0.5))
			humanoid.MaxHealth = newMax
			humanoid.Health = newMax
		end
	end

	-- Damage scaling
	local dmgAttr = mobModel:GetAttribute("Damage")
	if type(dmgAttr) == "number" then
		mobModel:SetAttribute("Damage", math.max(1, math.floor(dmgAttr * mults.DMG + 0.5)))
	end
	local dmgNV = mobModel:FindFirstChild("Damage")
	if dmgNV and dmgNV:IsA("NumberValue") then
		dmgNV.Value = math.max(1, math.floor(dmgNV.Value * mults.DMG + 0.5))
	end
end

function SpawnerManager:_applyPackRarityToGroup(mobs, packRarity)
	if type(mobs) ~= "table" then return end
	for _, mob in ipairs(mobs) do
		self:_applyPackRarityToMob(mob, packRarity)
	end
end

-- ========================================
-- MAIN INITIALIZATION
-- ========================================

local function main()
	log("========================================")
	log("DungeonMaster initializing...")
	log("========================================")

	-- Create manager
	local manager = SpawnerManager.new()

	-- Ensure player characters are in the Players collision group
	hookPlayerCharacters()

	-- Register existing spawners
	local existingSpawners = CollectionService:GetTagged("MobSpawner")
	log(string.format("Found %d spawners with 'MobSpawner' tag", #existingSpawners))

	if #existingSpawners == 0 then
		warn("[DM] WARNING: No spawners found!")
		warn("[DM] Make sure you've tagged Parts with 'MobSpawner' using CollectionService")
		warn("[DM] Example: CollectionService:AddTag(part, 'MobSpawner')")
	end

	for _, spawner in ipairs(existingSpawners) do
		manager:registerSpawner(spawner)
	end

	-- Listen for new spawners
	CollectionService:GetInstanceAddedSignal("MobSpawner"):Connect(function(spawner)
		log("New spawner detected!")
		manager:registerSpawner(spawner)
	end)

	-- Listen for removed spawners
	CollectionService:GetInstanceRemovedSignal("MobSpawner"):Connect(function(spawner)
		manager:unregisterSpawner(spawner)
	end)

	-- Listen for level changes
	manager.currentLevel.Changed:Connect(function(newLevel)
		log(string.format("========== Level changed to %d ==========", newLevel))
	end)

	-- Main update loop (4 Hz)
	task.spawn(function()
		while true do
			manager:update()
			task.wait(CONFIG.POLL_RATE)
		end
	end)

	log("========================================")
	log("DungeonMaster READY!")
	log(string.format("Current level: %d", manager.currentLevel.Value))
	log(string.format("Registered spawners: %d", #existingSpawners))
	log(string.format("Available prefabs: %s", table.concat(manager:getAvailablePrefabNames(), ", ")))
	log(string.format("Spawners will trigger when players get within %d studs...", CONFIG.SPAWNER_ACTIVATION_RANGE))
	log("========================================")

	-- Debug: List players
	task.wait(2)
	local playerCount = #Players:GetPlayers()
	log(string.format("Active players in game: %d", playerCount))
	if playerCount == 0 then
		warn("[DM] No players in game - spawners won't activate until a player joins!")
	end
end

-- Player chose Restart / Next
BossExitDecision.OnServerEvent:Connect(function(player, choice)
	local currentLevel = ReplicatedStorage:FindFirstChild("CurrentLevel")
	if not currentLevel or not currentLevel:IsA("IntValue") then return end

	if choice == "Next" then
		currentLevel.Value = currentLevel.Value + 1
	elseif choice == "Restart" then
		-- keep the same level
	else
		return
	end

	-- Ask the map generator to rebuild
	RequestMapRegen:Fire()
end)

-- Start the system
main()
