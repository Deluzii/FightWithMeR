-- ServerScriptService/SkillSystem/Skills/FlickerStrike.lua
-- PoE-style Flicker Strike (2025)
-- ALWAYS-BEHIND with tight micro-probe first, strict ground validation, enemy-only no-collide.
-- Skips cooldown when no target (returns false / fires "NoTarget").

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")

local ItemModule = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("ItemModule"))
local SkillRemotes = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("SkillRemotes")

-- Remote
local FlickerEvent = SkillRemotes:FindFirstChild("FlickerStrike")
if not FlickerEvent then
	FlickerEvent = Instance.new("RemoteEvent")
	FlickerEvent.Name = "FlickerStrike"
	FlickerEvent.Parent = SkillRemotes
end

-- Collision Groups
local FLICKER_GROUP = "FlickerPlayer"
local ENEMY_GROUP   = "Enemy"

local function ensureCollisionGroup(name)
	for _, g in ipairs(PhysicsService:GetRegisteredCollisionGroups()) do
		if g.name == name then return end
	end
	PhysicsService:RegisterCollisionGroup(name)
end

local function setupCollisionGroups()
	pcall(function()
		ensureCollisionGroup(FLICKER_GROUP)
		ensureCollisionGroup(ENEMY_GROUP)
		PhysicsService:CollisionGroupSetCollidable(FLICKER_GROUP, "Default", true)    -- floors/walls
		PhysicsService:CollisionGroupSetCollidable(FLICKER_GROUP, FLICKER_GROUP, true)
		PhysicsService:CollisionGroupSetCollidable(FLICKER_GROUP, ENEMY_GROUP, false) -- ignore enemies
	end)
end

setupCollisionGroups()

-- Ensure all "Enemy" tagged models/parts are in ENEMY_GROUP
local function applyEnemyGroupToModel(model)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CollisionGroup = ENEMY_GROUP
		end
	end
end

CollectionService:GetInstanceAddedSignal("Enemy"):Connect(function(inst)
	if inst:IsA("Model") then
		applyEnemyGroupToModel(inst)
	elseif inst:IsA("BasePart") then
		inst.CollisionGroup = ENEMY_GROUP
	end
end)

for _, inst in ipairs(CollectionService:GetTagged("Enemy")) do
	if inst:IsA("Model") then
		applyEnemyGroupToModel(inst)
	elseif inst:IsA("BasePart") then
		inst.CollisionGroup = ENEMY_GROUP
	end
end

local FlickerStrike = {}

-- Tunables
local MIN_RANGE = 2
local ATTACK_DELAY = 0.05
local CHAIN_DELAY = 0.15
local VALID_RARITIES = {"Common","Uncommon","Rare","Epic","Legendary","Mythic"}

-- Behind-only dash config (tight)
local MAX_DASH_RANGE = 100          -- absolute cap for behind search (studs)
local STEP_DIST      = 1            -- coarse step distance along "behind" (studs) for phase 2
local MIN_CLEAR_RAD  = 1            -- enemy clearance at landing
local BEHIND_MARGIN  = 0.5         -- distance just beyond enemy back from half-depth
local SOFT_BEHIND_EXTRA = 0.5        -- micro window length behind enemy
local WALKABLE_SLOPE = 0.6          -- up-facing requirement

-- Micro-probe settings (phase 1)
local MICRO_STEP = 0.25
local MICRO_LATERAL = {0, 0.35, -0.35, 0.7, -0.7}

-----------------------------------------------------
-- Helpers
-----------------------------------------------------
local function sanitize(skillData)
	local rarity = "Common"
	for _, r in ipairs(VALID_RARITIES) do
		if r == skillData.Rarity then
			rarity = r
			break
		end
	end
	return {
		rarity = rarity,
		damage = tonumber(skillData.Damage) or 0,
		range = tonumber(skillData.Range) or 20,
		attacksPerTarget = tonumber(skillData.AttacksPerTarget) or 1
	}
end

local function getCharacterFromPart(part)
	if not part then return nil end
	local model = part:FindFirstAncestorOfClass("Model")
	if model and model:FindFirstChildOfClass("Humanoid") then
		return model
	end
	return nil
end

local function isTaggedEnemyModel(model)
	if not model or not model:IsA("Model") then return false end
	if Players:GetPlayerFromCharacter(model) then
		return false
	end
	if CollectionService:HasTag(model, "Enemy") then return true end
	if model:GetAttribute("IsEnemy") == true then return true end
	return false
end

local function isEnemy(part, selfChar)
	if not part then return false end
	if part.Name == "EnemyHitbox" then
		local ownerModel = part:FindFirstAncestorOfClass("Model")
		return isTaggedEnemyModel(ownerModel)
	end
	local otherChar = getCharacterFromPart(part)
	if not otherChar or otherChar == selfChar then return false end
	if not isTaggedEnemyModel(otherChar) then return false end
	local h = otherChar:FindFirstChildOfClass("Humanoid")
	return h and h.Health > 0
end

local function isSpawnPad(inst)
	if not inst then return false end
	if CollectionService:HasTag(inst, "MobSpawner") then return true end
	local a = inst
	for _ = 1, 4 do
		if not a then break end
		if CollectionService:HasTag(a, "MobSpawner") then return true end
		a = a.Parent
	end
	local name = string.lower(inst.Name or "")
	if string.find(name, "spawner") or string.find(name, "spawnpad") or string.find(name, "spawn_pad") then
		return true
	end
	return false
end

local function ensurePlayerMobility(char)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.PlatformStand = false
		hum.Sit = false
		local currentState = hum:GetState()
		if currentState == Enum.HumanoidStateType.Physics
			or currentState == Enum.HumanoidStateType.Seated
			or currentState == Enum.HumanoidStateType.PlatformStanding then
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
		task.spawn(function()
			task.wait(0.03)
			if hum and char.Parent then
				hum:ChangeState(Enum.HumanoidStateType.Freefall)
			end
		end)
	end
end

-- Swap player to Flicker group
local function enableFlickerCollision(char)
	local originalGroups = {}
	for _, part in ipairs(char:GetDescendants()) do
		if part:IsA("BasePart") then
			originalGroups[part] = part.CollisionGroup
			part.CollisionGroup = FLICKER_GROUP
		end
	end
	return originalGroups
end

local function restoreNormalCollision(_char, originalGroups)
	if type(originalGroups) ~= "table" then return end
	for part, groupName in pairs(originalGroups) do
		if part and part.Parent and part:IsA("BasePart") then
			part.CollisionGroup = groupName
		end
	end
end

-- Utility: check if a hit result is walkable ground (not Enemy, CanCollide, up-facing)
local function _isWalkable(hit)
	if not hit then return false end
	local inst = hit.Instance
	if not inst or not inst:IsA("BasePart") then return false end
	if CollectionService:HasTag(inst, "Enemy") or (inst.Parent and CollectionService:HasTag(inst.Parent, "Enemy")) then
		return false
	end
	if inst.CollisionGroup == ENEMY_GROUP then return false end
	if not inst.CanCollide then return false end
	if hit.Normal.Y < WALKABLE_SLOPE then return false end
	return true
end

-- Build list of things to exclude for ground rays
local function _buildExclude(playerRoot, enemyModel)
	local exclude = { playerRoot.Parent, enemyModel }
	for _, inst in ipairs(CollectionService:GetTagged("Enemy")) do
		table.insert(exclude, inst)
	end
	return exclude
end

-- Ray helpers
local function _groundHitAtXZ(x, z, excludeList)
	local originBase = Vector3.new(x, 3000, z)
	local dir = Vector3.new(0, -6000, 0)

	-- Pass 1: normal exclude
	local rp1 = RaycastParams.new()
	rp1.FilterType = Enum.RaycastFilterType.Exclude
	rp1.IgnoreWater = true
	rp1.FilterDescendantsInstances = excludeList
	local hit = workspace:Raycast(originBase, dir, rp1)
	if _isWalkable(hit) then return hit end

	-- Pass 2: Terrain only
	local rp2 = RaycastParams.new()
	rp2.FilterType = Enum.RaycastFilterType.Include
	rp2.IgnoreWater = true
	rp2.FilterDescendantsInstances = { workspace.Terrain }
	hit = workspace:Raycast(originBase, dir, rp2)
	if _isWalkable(hit) then return hit end

	return nil
end

local function _hasEnemyOverlap(pos, radius)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = CollectionService:GetTagged("Enemy")
	local parts = workspace:GetPartBoundsInRadius(pos, radius, params)
	return #parts > 0
end

local function _placeOnSurfaceY(groundY, playerRoot)
	local hum = playerRoot.Parent:FindFirstChildOfClass("Humanoid")
	local hip = hum and hum.HipHeight or 2
	return groundY + hip - 0.01
end

-- ALWAYS-BEHIND with micro-probe first
local function getTeleportPosition(enemyRoot, playerRoot)
	local enemyModel = enemyRoot.Parent
	local enemyCF    = enemyRoot.CFrame
	local back       = -enemyCF.LookVector
	local right      = enemyCF.RightVector

	-- Tighter start distance: prefer HRP size (bbox can inflate with animation)
	local hrpSizeZ = (enemyRoot.Size and enemyRoot.Size.Z) or 0
	local _, bbox = enemyModel:GetBoundingBox()
	local halfDepth = (hrpSizeZ > 0 and hrpSizeZ or (bbox and bbox.Z or 4)) / 2
	local baseBehind = halfDepth + BEHIND_MARGIN

	local startDist = math.max(baseBehind, 0.5)
	local maxDist   = MAX_DASH_RANGE
	local softMax   = math.min(startDist + SOFT_BEHIND_EXTRA, maxDist)

	local exclude = _buildExclude(playerRoot, enemyModel)
	local epos = enemyRoot.Position

	-- Phase 1: micro-probe directly behind (tiny steps + small lateral nudges)
	for dist = startDist, softMax, MICRO_STEP do
		for _, lat in ipairs(MICRO_LATERAL) do
			local probe = epos + back * dist + right * lat
			local hit = _groundHitAtXZ(probe.X, probe.Z, exclude)
			if hit and _isWalkable(hit) then
				local groundPos = hit.Position
				if not _hasEnemyOverlap(Vector3.new(groundPos.X, groundPos.Y + 2, groundPos.Z), MIN_CLEAR_RAD) then
					local finalY = _placeOnSurfaceY(groundPos.Y, playerRoot)
					return Vector3.new(groundPos.X, finalY, groundPos.Z), true
				end
			end
		end
	end

	-- Phase 2: extend behind with coarse stepping if micro window failed
	for dist = softMax + STEP_DIST, maxDist, STEP_DIST do
		local probe = epos + back * dist
		local hit = _groundHitAtXZ(probe.X, probe.Z, exclude)
		if hit and _isWalkable(hit) then
			local groundPos = hit.Position
			if not _hasEnemyOverlap(Vector3.new(groundPos.X, groundPos.Y + 2, groundPos.Z), MIN_CLEAR_RAD) then
				local finalY = _placeOnSurfaceY(groundPos.Y, playerRoot)
				return Vector3.new(groundPos.X, finalY, groundPos.Z), true
			end
		end
	end

	-- No valid ground found: cancel hop
	return playerRoot.Position, false
end

-----------------------------------------------------
-- Targeting and attacks
-----------------------------------------------------
local function findClosestEnemy(root, range, selfChar, excludeList)
	local closestEnemy, closestDistance = nil, math.huge

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {selfChar}

	for _, part in ipairs(workspace:GetPartBoundsInRadius(root.Position, range, params)) do
		if isEnemy(part, selfChar) and not isSpawnPad(part) then
			local enemyChar = getCharacterFromPart(part)
			if enemyChar and not excludeList[enemyChar] then
				local enemyRoot = enemyChar:FindFirstChild("HumanoidRootPart")
				if enemyRoot then
					local distance = (enemyRoot.Position - root.Position).Magnitude
					if distance >= MIN_RANGE and distance <= range and distance < closestDistance then
						closestDistance = distance
						closestEnemy = enemyChar
					end
				end
			end
		end
	end

	if not closestEnemy then
		for _, model in ipairs(workspace:GetDescendants()) do
			if model:IsA("Model") and isTaggedEnemyModel(model) and not excludeList[model] then
				local enemyRoot = model:FindFirstChild("HumanoidRootPart")
				local enemyHum = model:FindFirstChildOfClass("Humanoid")
				if enemyRoot and enemyHum and enemyHum.Health > 0 then
					local distance = (enemyRoot.Position - root.Position).Magnitude
					if distance <= range and distance < closestDistance then
						closestDistance = distance
						closestEnemy = model
					end
				end
			end
		end
	end

	return closestEnemy, closestDistance
end

local function attackTarget(player, char, root, p, targetEnemy, chainNumber)
	local targetRoot = targetEnemy:FindFirstChild("HumanoidRootPart")
	local targetHum = targetEnemy:FindFirstChildOfClass("Humanoid")
	if not targetRoot or not targetHum or targetHum.Health <= 0 then
		return false
	end

	local teleportPos, ok = getTeleportPosition(targetRoot, root)
	if not ok then
		-- No valid ground behind: cancel this hop
		return false
	end

	local originalPos = root.Position

	-- Face target from the grounded point & clear momentum
	root.AssemblyLinearVelocity = Vector3.new()
	root.AssemblyAngularVelocity = Vector3.new()
	local lookAt = Vector3.new(targetRoot.Position.X, teleportPos.Y, targetRoot.Position.Z)
	root.CFrame = CFrame.lookAt(teleportPos, lookAt)

	FlickerEvent:FireAllClients("Teleport", player.UserId, originalPos, teleportPos, p.rarity, chainNumber)

	for attackNum = 1, p.attacksPerTarget do
		if not targetHum or targetHum.Health <= 0 then
			return true
		end

		targetHum:TakeDamage(p.damage)
		FlickerEvent:FireAllClients("Attack", player.UserId, targetRoot.Position, p.rarity, attackNum, chainNumber)

		if attackNum == p.attacksPerTarget then
			local knockbackDir = (targetRoot.Position - root.Position).Unit
			local bv = Instance.new("BodyVelocity")
			bv.MaxForce = Vector3.new(30000, 10000, 30000)
			bv.Velocity = knockbackDir * 20
			bv.Parent = targetRoot
			game:GetService("Debris"):AddItem(bv, 0.1)
		end

		if attackNum < p.attacksPerTarget then
			task.wait(ATTACK_DELAY)
		end
	end

	return targetHum.Health <= 0
end

local function performFlickerChain(player, char, root, hum, p, chainNumber, hitTargets)
	if not char.Parent or hum.Health <= 0 then
		ensurePlayerMobility(char)
		return
	end

	local targetEnemy = findClosestEnemy(root, p.range, char, hitTargets)
	if not targetEnemy then
		ensurePlayerMobility(char)
		if chainNumber == 0 then
			FlickerEvent:FireClient(player, "NoTarget")
		end
		return
	end

	hitTargets[targetEnemy] = true
	local killed = attackTarget(player, char, root, p, targetEnemy, chainNumber)

	if killed then
		task.wait(CHAIN_DELAY)
		if char.Parent and hum.Health > 0 then
			performFlickerChain(player, char, root, hum, p, chainNumber + 1, hitTargets)
		else
			ensurePlayerMobility(char)
		end
	else
		ensurePlayerMobility(char)
	end
end

-----------------------------------------------------
-- API
-----------------------------------------------------
function FlickerStrike.Activate(player, _skillId, skillData, _aimPos)
	local char = player.Character
	if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not (hum and root) or hum.Health <= 0 then return end

	local p = sanitize(skillData)

	-- Pre-check: avoid cooldown on whiff
	local preHitTargets = {}
	local firstEnemy = findClosestEnemy(root, p.range, char, preHitTargets)
	if not firstEnemy then
		FlickerEvent:FireClient(player, "NoTarget")
		return false
	end

	local originalGroups = enableFlickerCollision(char)

	local hitTargets = {}
	performFlickerChain(player, char, root, hum, p, 0, hitTargets)

	restoreNormalCollision(char, originalGroups)
	ensurePlayerMobility(char)

	return true
end

Players.PlayerRemoving:Connect(function(player)
	FlickerEvent:FireAllClients("Stop", player.UserId)
end)

return FlickerStrike
