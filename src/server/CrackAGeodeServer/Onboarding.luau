-- OnboardingService: the first-60-seconds flow.
--   1. First crack in seconds — a glowing Starter Geode spawns in front of the
--      player with a "TAP TO CRACK!" callout, within immediate reach.
--   2. A rare drop early — the Starter Geode is a GUARANTEED Emerald (rare tier).
--   3. What to work toward — a stepped "NEXT GOAL" tracker (sent in the snapshot)
--      that guides them from first crack → 5 cracks → first upgrade → first Rebirth,
--      with small Gem bonuses for momentum.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Onboarding = {}
local S, Config, Data, Econ, Remotes
local starterOf = {}
local STEPS
local RARE_TIER = 4 -- Emerald (first "rare" tier)

local function buildSteps()
	STEPS = {
		{ text = "⛏️ Tap the glowing geode to crack it!",
		  done = function(p) return (p.cracks or 0) >= 1 end, reward = 0 },
		{ text = "Crack 5 geodes to collect Gems",
		  progress = function(p) return math.min(p.cracks or 0, 5) end, target = function() return 5 end,
		  done = function(p) return (p.cracks or 0) >= 5 end, reward = 100 },
		{ text = "Buy a Power upgrade at the ⛏️ pedestal",
		  done = function(p) return (p.power or 0) >= 1 end, reward = 150 },
		{ text = "Save Gems, then Recrystallize — your first Rebirth! 🔄",
		  progress = function(p) return math.min(p.gems or 0, Config.RebirthCost(p.rebirths or 0)) end,
		  target = function(p) return Config.RebirthCost(p.rebirths or 0) end,
		  done = function(p) return (p.rebirths or 0) >= 1 end, reward = 0 },
	}
end

-- Objective data embedded in the client snapshot (nil once onboarding is done).
function Onboarding.SnapshotData(player)
	if not (Data and STEPS) then return nil end
	local p = Data.Cache[player]
	if not p or p.onboardDone then return nil end
	local step = STEPS[(p.onboardStep or 0) + 1]
	if not step then return nil end
	return {
		text = step.text,
		index = (p.onboardStep or 0) + 1,
		total = #STEPS,
		progress = step.progress and step.progress(p) or nil,
		target = step.target and step.target(p) or nil,
	}
end

-- Advance through any completed steps, granting bonuses.
function Onboarding.Check(player)
	if not (Data and STEPS) then return end
	local p = Data.Cache[player]
	if not p or p.onboardDone then return end
	local advanced = false
	while true do
		local step = STEPS[(p.onboardStep or 0) + 1]
		if not step then
			p.onboardDone = true
			advanced = true
			Remotes.Announce:FireClient(player, {
				kind = "onboard", text = "🎉 You've got it! Keep cracking, rebirthing & ascending!",
				color = Color3.fromRGB(255, 220, 120),
			})
			break
		end
		if step.done(p) then
			p.onboardStep = (p.onboardStep or 0) + 1
			if step.reward and step.reward > 0 then
				Econ.AwardRaw(player, step.reward)
				Remotes.Announce:FireClient(player, {
					kind = "onboard", text = "✅ Goal complete!  +" .. step.reward .. " 💎",
					color = Color3.fromRGB(120, 255, 170),
				})
			end
			advanced = true
		else
			break
		end
	end
	if advanced then
		if Data.SaveSoon then Data.SaveSoon(player) end
		Econ.Push(player)
	end
end

local function spawnStarter(player)
	local p = Data.WaitFor(player, 12)
	if not p or p.onboardDone or (p.onboardStep or 0) > 0 then return end
	local char = player.Character or player.CharacterAdded:Wait()
	char:WaitForChild("HumanoidRootPart", 10)
	if starterOf[player] then return end

	-- just in front of the spawn pad, within immediate reach
	local spawnLoc = workspace:FindFirstChildOfClass("SpawnLocation")
	local ang = ((player.UserId % 5) - 2) * 3
	local base = spawnLoc and (spawnLoc.CFrame * CFrame.new(ang, 0, -10)) or CFrame.new(ang, 3.5, -60)
	local pos = Vector3.new(base.Position.X, 3.5, base.Position.Z)

	local size = 6.5
	local color = Config.Rarities[RARE_TIER].color
	local model = Instance.new("Model")
	model.Name = "StarterGeode_" .. player.UserId

	local rock = Instance.new("Part")
	rock.Shape = Enum.PartType.Ball
	rock.Size = Vector3.new(size, size, size)
	rock.CFrame = CFrame.new(pos)
	rock.Anchored = true
	rock.Material = Enum.Material.Rock
	rock.Color = Color3.fromRGB(80, 74, 104)
	rock.Parent = model
	local pl = Instance.new("PointLight")
	pl.Color = color; pl.Range = 24; pl.Brightness = 2.6; pl.Parent = rock

	local seam = Instance.new("Part")
	seam.Shape = Enum.PartType.Cylinder
	seam.Size = Vector3.new(0.5, size + 0.4, size + 0.4)
	seam.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
	seam.Anchored = true; seam.CanCollide = false
	seam.Material = Enum.Material.Neon; seam.Color = color; seam.Transparency = 0.2
	seam.Parent = model
	TweenService:Create(seam, TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Transparency = 0.7 }):Play()

	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromScale(11, 3); bb.StudsOffset = Vector3.new(0, size, 0)
	bb.AlwaysOnTop = true; bb.MaxDistance = 200; bb.Parent = rock
	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.fromScale(1, 1); tl.BackgroundTransparency = 1
	tl.Text = "👆 TAP TO CRACK!"
	tl.TextColor3 = Color3.fromRGB(255, 235, 130); tl.TextStrokeTransparency = 0
	tl.TextScaled = true; tl.Font = Enum.Font.GothamBlack; tl.Parent = bb
	local uis = Instance.new("UIScale"); uis.Parent = tl
	TweenService:Create(uis, TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Scale = 1.12 }):Play()

	local opened = false
	local function crack(clicker)
		if clicker ~= player or opened then return end
		opened = true
		p.cracks = (p.cracks or 0) + 1
		local gained, newEntry = Econ.RegisterFind(player, RARE_TIER, 1) -- guaranteed rare Emerald
		if S.Geodes and S.Geodes.CrackFX then S.Geodes.CrackFX(pos, size, RARE_TIER, 1) end
		Remotes.CrackFX:FireAllClients({
			rarity = RARE_TIER, mutation = 1, gained = gained,
			userId = player.UserId, name = player.DisplayName, pos = pos, newEntry = newEntry,
		})
		Remotes.Announce:FireClient(player, {
			kind = "rare",
			text = "✨ Your first crystal — a RARE " .. Config.Rarities[RARE_TIER].name .. "!",
			color = color,
		})
		Econ.Push(player)
		Onboarding.Check(player)
		model:Destroy()
		starterOf[player] = nil
	end
	local click = Instance.new("ClickDetector")
	click.MaxActivationDistance = 26
	click.Parent = rock
	click.MouseClick:Connect(crack)

	model.Parent = workspace.CrackAGeode.Nodes
	starterOf[player] = model
end

function Onboarding.Init(services)
	S = services
	Config, Data, Econ, Remotes = S.Config, S.Data, S.Econ, S.Remotes
	buildSteps()

	local function onJoin(player)
		task.spawn(spawnStarter, player)
	end
	Players.PlayerAdded:Connect(onJoin)
	task.defer(function()
		for _, p in ipairs(Players:GetPlayers()) do onJoin(p) end
	end)

	Players.PlayerRemoving:Connect(function(player)
		if starterOf[player] then
			starterOf[player]:Destroy()
			starterOf[player] = nil
		end
	end)

	-- periodic objective checker (advances steps + grants bonuses)
	task.spawn(function()
		while true do
			task.wait(1)
			for _, player in ipairs(Players:GetPlayers()) do
				Onboarding.Check(player)
			end
		end
	end)
end

return Onboarding
