--[[
    Plays Roblox's default locomotion animations (idle, run, jump, fall...)
    on a humanoid. Used for your own character on the client and for bots
    on the server; tracks played there replicate to everyone else.

    The game replaces the default Animate script (see
    StarterCharacterScripts/Animate), so this is the only thing animating
    legs and idle poses. Attack poses are layered on top by the client's
    Visuals controller.
]]

local Locomotion = {}
Locomotion.__index = Locomotion

-- Roblox-owned default animations; usable in any experience.
local IDS = {
	R15 = {
		Idle = "rbxassetid://507766666",
		Walk = "rbxassetid://507777826",
		Run = "rbxassetid://507767714",
		Jump = "rbxassetid://507765000",
		Fall = "rbxassetid://507767968",
		Climb = "rbxassetid://507765644",
		Sit = "rbxassetid://2506281703",
		Swim = "rbxassetid://913384386",
	},
	R6 = {
		Idle = "rbxassetid://180435571",
		Walk = "rbxassetid://180426354",
		Run = "rbxassetid://180426354",
		Jump = "rbxassetid://125750702",
		Fall = "rbxassetid://180436148",
		Climb = "rbxassetid://180436334",
		Sit = "rbxassetid://178130996",
		Swim = "rbxassetid://180426354",
	},
}

local LOOPED = { Idle = true, Walk = true, Run = true, Fall = true, Climb = true, Sit = true, Swim = true }

function Locomotion.new(humanoid, createAnimator)
	local self = setmetatable({}, Locomotion)
	self.humanoid = humanoid
	self.tracks = {}
	self.current = nil

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		if createAnimator then
			animator = Instance.new("Animator")
			animator.Parent = humanoid
		else
			animator = humanoid:WaitForChild("Animator", 5)
		end
	end
	if not animator then
		warn("[Locomotion] no Animator on", humanoid:GetFullName())
		return self
	end
	self.animator = animator

	local ids = humanoid.RigType == Enum.HumanoidRigType.R15 and IDS.R15 or IDS.R6
	for name, id in ids do
		local animation = Instance.new("Animation")
		animation.AnimationId = id
		local ok, track = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		if ok and track then
			track.Priority = Enum.AnimationPriority.Core
			track.Looped = LOOPED[name] == true
			self.tracks[name] = track
		end
	end
	return self
end

function Locomotion:Play(name, speed)
	local track = self.tracks[name]
	if not track then
		return
	end
	if self.current ~= name then
		local previous = self.current and self.tracks[self.current]
		if previous then
			previous:Stop(0.15)
		end
		track:Play(0.15)
		self.current = name
	end
	if speed then
		track:AdjustSpeed(speed)
	end
end

function Locomotion:Stop()
	for _, track in self.tracks do
		track:Stop(0.1)
	end
	self.current = nil
end

function Locomotion:Destroy()
	for _, track in self.tracks do
		track:Stop(0)
		track:Destroy()
	end
	self.tracks = {}
	self.current = nil
end

return Locomotion
