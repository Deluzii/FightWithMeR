-- ServerScriptService/SkillSystem/Skills/Fireball.lua
-- Ground-aligned projectile. Uses tags to detect enemies (ignores players).
-- Requires enemy models to be tagged "Enemy" (or have IsEnemy=true attribute).
-- Ignores spawn pads (MobSpawner tag/name). No tabs used.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local ItemModule = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("ItemModule"))
local SkillRemotes = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("SkillRemotes")
local FireballEvent = SkillRemotes:WaitForChild("Fireball")

local Fireball = {}

-- Tunables (timing/behavior only, all stats from ItemModule)
local VALID_RARITIES = {"Common","Uncommon","Rare","Epic","Legendary","Mythic"}

-- Projectile enemy hitbox radius (visual stays small)
local HITBOX_RADIUS = 2.6   -- try 2.6�3.2 if you want even chunkier hits

local activeProjectiles = {}

local function sanitize(skillData)
	local rarity = "Common"
	for _, r in ipairs(VALID_RARITIES) do
		if r == skillData.Rarity then
			rarity = r
			break
		end
	end

	-- Use ItemModule values directly with no caps or modifications
	return {
		rarity = rarity,
		speed = tonumber(skillData.Speed) or 80,
		range = tonumber(skillData.Range) or 100,
		explosionRadius = tonumber(skillData.ExplosionRadius) or 8,
		damage = tonumber(skillData.Damage) or 0
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

-- Treat ONLY tagged enemies as enemies; never players
local function isTaggedEnemyModel(model)
	if not model or not model:IsA("Model") then return false end
	-- Player character? Not an enemy.
	if Players:GetPlayerFromCharacter(model) then
		return false
	end
	-- Must be explicitly marked as Enemy via tag or attribute
	if CollectionService:HasTag(model, "Enemy") then return true end
	if model:GetAttribute("IsEnemy") == true then return true end
	return false
end

local function isEnemy(part, selfChar)
	if not part then return false end

	-- If the part *is* a named enemy hitbox, still require owner to be tagged.
	if part.Name == "EnemyHitbox" then
		local ownerModel = part:FindFirstAncestorOfClass("Model")
		return isTaggedEnemyModel(ownerModel)
	end

	local otherChar = getCharacterFromPart(part)
	if not otherChar or otherChar == selfChar then return false end

	if not isTaggedEnemyModel(otherChar) then
		return false
	end

	local h = otherChar:FindFirstChildOfClass("Humanoid")
	return h and h.Health > 0
end

-- Treat these as spawn pads (ignore them)
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

-- "Wall" = Terrain or any CanCollide BasePart not part of caster, but NOT spawn pads
local function isWall(inst, selfChar)
	if not inst then return false end
	if isSpawnPad(inst) then return false end
	if inst:IsA("Terrain") then return true end
	if inst:IsA("BasePart") then
		if inst.CanCollide and not inst:IsDescendantOf(selfChar) then
			return true
		end
	end
	return false
end

local function createProjectile(startPos, p, player)
	local projectile = Instance.new("Part")
	projectile.Name = "Fireball"
	projectile.Shape = Enum.PartType.Ball
	projectile.Size = Vector3.new(2, 2, 2) -- visual only; hitbox is done via overlap sphere
	projectile.CFrame = CFrame.new(startPos)
	projectile.CanCollide = false
	projectile.Anchored = true
	projectile.Material = Enum.Material.Neon
	projectile.Color = Color3.fromRGB(255, 100, 0)
	projectile.Transparency = 0.3
	projectile.CastShadow = false
	projectile.Parent = workspace

	projectile:SetAttribute("OwnerId", player.UserId)
	projectile:SetAttribute("OwnerName", player.Name)
	return projectile
end

local function explode(position, p, casterChar, player)
	FireballEvent:FireAllClients("Explode", position, p.explosionRadius, p.rarity)

	local hitTargets = {}
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {casterChar}

	for _, part in ipairs(workspace:GetPartBoundsInRadius(position, p.explosionRadius, params)) do
		if isEnemy(part, casterChar) then
			local enemyChar = getCharacterFromPart(part)
			if enemyChar and not hitTargets[enemyChar] then
				hitTargets[enemyChar] = true
				local eh = enemyChar:FindFirstChildOfClass("Humanoid")
				if eh and eh.Health > 0 then
					print(string.format("[Fireball] Hitting %s for %.1f damage (HP before: %.1f/%.1f)",
						enemyChar.Name, p.damage, eh.Health, eh.MaxHealth))
					eh:TakeDamage(p.damage)
					print(string.format("[Fireball] Enemy HP after: %.1f/%.1f", eh.Health, eh.MaxHealth))
					local er = enemyChar:FindFirstChild("HumanoidRootPart")
					if er then
						local dir = (er.Position - position)
						if dir.Magnitude > 0 then
							dir = dir.Unit
							local bv = Instance.new("BodyVelocity")
							bv.MaxForce = Vector3.new(50000, 50000, 50000)
							bv.Velocity = dir * 30  -- Constant knockback
							bv.Parent = er
							Debris:AddItem(bv, 0.15)
						end
					end
				end
			end
		end
	end
end

-- Raycast that only accepts enemies or real walls; ignores everything else (incl. spawn pads)
local function castSegment(origin, direction, rayParams, selfChar)
	local tries = 0
	while tries < 8 do
		local result = workspace:Raycast(origin, direction, rayParams)
		if not result then return nil end
		local inst = result.Instance
		if isEnemy(inst, selfChar) or isWall(inst, selfChar) then
			return result
		end
		table.insert(rayParams.FilterDescendantsInstances, inst)
		tries = tries + 1
	end
	return nil
end

-- Find ground and spawn low so we don't overshoot small mobs
local function getGroundSpawn(root, forwardDir)
	local origin = root.Position + Vector3.new(0, 5, 0)
	local dir = Vector3.new(0, -60, 0)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = {root.Parent}
	local result = workspace:Raycast(origin, dir, rp)

	local baseY = root.Position.Y
	if result and result.Position then baseY = result.Position.Y end

	local height = 1.2
	local start = Vector3.new(root.Position.X, baseY + height, root.Position.Z)
	return start + forwardDir * 2
end

-- ? FIXED: Now accepts aimPos as 4th parameter
function Fireball.Activate(player, _skillId, skillData, aimPos)
	local char = player.Character
	if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not (hum and root) or hum.Health <= 0 then return end

	local p = sanitize(skillData)

	-- ? FIXED: Calculate direction from root position to mouse aim position
	local direction
	if aimPos and typeof(aimPos) == "Vector3" then
		-- Use the mouse aim position to calculate direction
		local toMouse = (aimPos - root.Position)
		local horizontal = Vector3.new(toMouse.X, 0, toMouse.Z)
		if horizontal.Magnitude > 0.001 then
			direction = horizontal.Unit
		else
			-- Fallback if mouse position is directly above/below character
			direction = root.CFrame.LookVector
		end
	else
		-- Fallback to character facing direction if no aim position provided
		local look = root.CFrame.LookVector
		local horizontal = Vector3.new(look.X, 0, look.Z)
		direction = horizontal.Magnitude > 0.001 and horizontal.Unit or look
	end

	local startPos = getGroundSpawn(root, direction)
	local projectile = createProjectile(startPos, p, player)

	FireballEvent:FireAllClients("Start", startPos, direction, p.speed, p.rarity, player.UserId)

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {char, projectile}

	-- Enemy overlap params (exclude caster only; we still want to touch enemy models)
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = {char}

	local distanceTraveled = 0
	local lastPos = startPos
	local exploded = false

	local projectileId = tostring(os.clock()) .. "_" .. tostring(player.UserId)
	activeProjectiles[projectileId] = true

	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		if exploded or not projectile.Parent then
			if conn then conn:Disconnect() end
			activeProjectiles[projectileId] = nil
			return
		end

		local moveDistance = p.speed * dt
		distanceTraveled = distanceTraveled + moveDistance
		if distanceTraveled >= p.range then
			exploded = true
			explode(projectile.Position, p, char, player)
			projectile:Destroy()
			FireballEvent:FireAllClients("Stop", player.UserId)
			if conn then conn:Disconnect() end
			activeProjectiles[projectileId] = nil
			return
		end

		-- Step forward
		local newPos = lastPos + direction * moveDistance

		-- 1) Enemy sweep with bigger sphere hitbox (use midpoint and end to avoid tunneling)
		local midPos = (lastPos + newPos) * 0.5
		local function enemyHitAt(pos)
			for _, part in ipairs(workspace:GetPartBoundsInRadius(pos, HITBOX_RADIUS, overlapParams)) do
				if isEnemy(part, char) and not isSpawnPad(part) then
					return part
				end
			end
			return nil
		end

		local enemyPart = enemyHitAt(midPos) or enemyHitAt(newPos)

		if enemyPart then
			exploded = true
			local hitChar = getCharacterFromPart(enemyPart)
			if hitChar and hitChar ~= char and isTaggedEnemyModel(hitChar) then
				local eh = hitChar:FindFirstChildOfClass("Humanoid")
				if eh and eh.Health > 0 then
					eh:TakeDamage(p.damage * 0.5) -- direct-hit bonus
				end
			end
			projectile.Position = newPos
			explode(newPos, p, char, player)
			projectile:Destroy()
			FireballEvent:FireAllClients("Stop", player.UserId)
			if conn then conn:Disconnect() end
			activeProjectiles[projectileId] = nil
			return
		end

		-- 2) Wall ray (still precise for geometry and keeps ignoring spawn pads)
		local hit = castSegment(lastPos, direction * moveDistance, rayParams, char)
		if hit then
			exploded = true
			local hitPos = hit.Position
			projectile.Position = hitPos

			local hitChar = getCharacterFromPart(hit.Instance)
			if hitChar and hitChar ~= char and isTaggedEnemyModel(hitChar) then
				local eh = hitChar:FindFirstChildOfClass("Humanoid")
				if eh and eh.Health > 0 then
					eh:TakeDamage(p.damage * 0.5)
				end
			end

			explode(hitPos, p, char, player)
			projectile:Destroy()
			FireballEvent:FireAllClients("Stop", player.UserId)
			if conn then conn:Disconnect() end
			activeProjectiles[projectileId] = nil
			return
		end

		projectile.Position = newPos
		lastPos = newPos
	end)

	task.delay(p.range / p.speed + 1, function()
		if projectile.Parent and not exploded then
			exploded = true
			explode(projectile.Position, p, char, player)
			projectile:Destroy()
			FireballEvent:FireAllClients("Stop", player.UserId)
			if conn then conn:Disconnect() end
			activeProjectiles[projectileId] = nil
		end
	end)
end

game.Players.PlayerRemoving:Connect(function(player)
	for projectileId, _ in pairs(activeProjectiles) do
		if string.find(projectileId, tostring(player.UserId)) then
			activeProjectiles[projectileId] = nil
		end
	end
	FireballEvent:FireAllClients("Stop", player.UserId)
end)

return Fireball