-- DamageNumbers Module (Clean version with validation)
local TweenService = game:GetService("TweenService")

local DamageNumbers = {}

print("[DamageNumbers] Module loading...")

-- Create and animate a damage number
function DamageNumbers.Show(enemy, damage, isCrit)
	print("[DamageNumbers] Show function called with damage:", damage)

	if not enemy or not enemy:IsA("Model") then
		warn("[DamageNumbers] Enemy is not a model:", enemy)
		return false
	end

	-- Find attachment point (Head or HumanoidRootPart)
	local attachPart = enemy:FindFirstChild("Head") or enemy:FindFirstChild("HumanoidRootPart")
	if not attachPart then
		warn("[DamageNumbers] No attach part found for:", enemy.Name)
		return false
	end

	-- Random offset for multiple hits
	local randomX = (math.random() - 0.5) * 2
	local randomZ = (math.random() - 0.5) * 2

	-- Create BillboardGui
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DamageNumber"
	billboard.Adornee = attachPart
	billboard.Size = UDim2.new(0, 200, 0, 50)
	billboard.StudsOffset = Vector3.new(randomX, 3, randomZ)
	billboard.AlwaysOnTop = true
	billboard.Parent = attachPart

	-- Format damage
	local damageText
	if damage >= 1000 then
		damageText = string.format("%.1fK", damage / 1000)
	else
		damageText = tostring(math.floor(damage))
	end

	-- Color by damage amount
	local color
	if damage >= 500 then
		color = Color3.fromRGB(255, 100, 0) -- Orange
	elseif damage >= 200 then
		color = Color3.fromRGB(255, 200, 0) -- Yellow
	else
		color = Color3.fromRGB(255, 255, 255) -- White
	end

	-- Create TextLabel
	local textLabel = Instance.new("TextLabel")
	textLabel.Name = "DamageText"
	textLabel.Size = UDim2.new(1, 0, 1, 0)
	textLabel.BackgroundTransparency = 1
	textLabel.Font = Enum.Font.FredokaOne
	textLabel.TextSize = isCrit and 72 or 48
	textLabel.TextColor3 = isCrit and Color3.fromRGB(255, 50, 50) or color
	textLabel.Text = isCrit and ("CRIT! " .. damageText) or damageText
	textLabel.TextStrokeTransparency = 0
	textLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	textLabel.Parent = billboard

	-- Float up animation
	local floatTween = TweenService:Create(
		billboard,
		TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{StudsOffset = Vector3.new(randomX, 7, randomZ)}
	)

	-- Fade out animation
	local fadeTween = TweenService:Create(
		textLabel,
		TweenInfo.new(0.6, Enum.EasingStyle.Linear),
		{TextTransparency = 1, TextStrokeTransparency = 1}
	)

	-- Start animations
	floatTween:Play()
	task.delay(0.6, function()
		if textLabel then
			fadeTween:Play()
		end
	end)

	-- Cleanup
	task.delay(1.2, function()
		if billboard then
			billboard:Destroy()
		end
	end)

	print("[DamageNumbers] Successfully created damage number!")
	return true
end

print("[DamageNumbers] Module loaded! Show function exists:", DamageNumbers.Show ~= nil)

return DamageNumbers