-- ServerScriptService/SkillSystem/Skills/Cyclone.lua
-- Cyclone AoE: damages ONLY tagged enemies (ignores players).
-- Requires enemy models to be tagged "Enemy" (or have IsEnemy=true attribute).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local ItemModule = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("ItemModule"))
local CycloneEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("SkillRemotes"):WaitForChild("Cyclone")

local Cyclone = {}

-- Limits
local MAX_RADIUS, MAX_DURATION, MAX_DAMAGE = 20, 10, 200
local VALID_RARITIES = {"Common","Uncommon","Rare","Epic","Legendary","Mythic"}
local TICK_RATE = 0.2

local active = {} -- [Player] = {connection=..., duration=..., startTime=...}

local function sanitize(skillData)
	local rarity = table.find(VALID_RARITIES, skillData.Rarity) and skillData.Rarity or "Common"
	local mult = (ItemModule.Rarities[rarity] and ItemModule.Rarities[rarity].ValueMultiplier) or 1
	local radius   = math.min((tonumber(skillData.Radius)   or 8) * mult, MAX_RADIUS)
	local duration = math.min(tonumber(skillData.Duration) or 3, MAX_DURATION)
	local damage   = math.min((tonumber(skillData.Damage)   or 10) * mult, MAX_DAMAGE)
	return {rarity=rarity, radius=radius, duration=duration, damage=damage}
end

-- Helpers
local function getCharacterFromPart(part)
	if not part then return nil end
	local model = part:FindFirstAncestorOfClass("Model")
	if model and model:FindFirstChildOfClass("Humanoid") then
		return model
	end
	return nil
end

-- Only treat explicitly tagged models as enemies; never players
local function isTaggedEnemyModel(model)
	if not model or not model:IsA("Model") then return false end
	-- Player char? Not an enemy
	if Players:GetPlayerFromCharacter(model) then
		return false
	end
	-- Explicit marks only
	if CollectionService:HasTag(model, "Enemy") then return true end
	if model:GetAttribute("IsEnemy") == true then return true end
	return false
end

local function isEnemy(part, selfChar)
	if not part then return false end

	-- Direct enemy hitbox? Still require owner to be tagged.
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

function Cyclone.Activate(player, _skillId, skillData)
	if active[player] then return end

	local char = player.Character
	if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not (hum and root) or hum.Health <= 0 then return end

	local p = sanitize(skillData)

	-- Broadcast so ALL clients render VFX on the caster
	CycloneEvent:FireAllClients("Start", p.rarity, p.duration, p.radius, player.UserId)

	local elapsed, lastTick = 0, 0
	local hitCD = {}

	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		elapsed += dt

		if elapsed >= p.duration or not char.Parent or hum.Health <= 0 then
			conn:Disconnect()
			CycloneEvent:FireAllClients("Stop", player.UserId)
			active[player] = nil
			return
		end

		if elapsed - lastTick >= TICK_RATE then
			lastTick = elapsed
			table.clear(hitCD)

			local params = OverlapParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = {char}

			for _, part in ipairs(workspace:GetPartBoundsInRadius(root.Position, p.radius, params)) do
				if isEnemy(part, char) then
					local enemyChar = getCharacterFromPart(part) or part.Parent
					if enemyChar and not hitCD[enemyChar] then
						hitCD[enemyChar] = true

						local eh = enemyChar:FindFirstChildOfClass("Humanoid")
						if eh and eh.Health > 0 then
							eh:TakeDamage(p.damage)

							local er = enemyChar:FindFirstChild("HumanoidRootPart")
							if er then
								local dir = (er.Position - root.Position)
								if dir.Magnitude > 0 then
									dir = dir.Unit
									local bv = Instance.new("BodyVelocity")
									bv.MaxForce = Vector3.new(100000, 0, 100000)
									bv.Velocity = dir * 10 * ((ItemModule.Rarities[p.rarity] and ItemModule.Rarities[p.rarity].ValueMultiplier) or 1)
									bv.Parent = er
									Debris:AddItem(bv, 0.1)
								end
							end
						end
					end
				end
			end
		end
	end)

	active[player] = {connection = conn, duration = p.duration, startTime = tick()}
end

game.Players.PlayerRemoving:Connect(function(player)
	local entry = active[player]
	if entry then
		if entry.connection then entry.connection:Disconnect() end
		CycloneEvent:FireAllClients("Stop", player.UserId)
		active[player] = nil
	end
end)

return Cyclone
