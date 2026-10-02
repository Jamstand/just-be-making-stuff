-- Anim: every UI motion, in one place, so the whole game moves the same way.
-- "Playful yet stylish": panels glide and fade on smooth quint curves; buttons, badges and rewards
-- spring with a little overshoot; big moments get confetti, number pops and coins flying into the
-- cash pill. With Reduce motion on (Anim.Reduced) springs lose their overshoot, times shorten and
-- the purely decorative motion (wiggles, sways, shines, confetti) stops.
--
-- Scale animations use a UIScale child named "AnimScale" (Anim.scale creates it), so they never
-- fight layouts. Position animations are only for freely placed things (panels, toasts, banners).
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent:WaitForChild("Theme"))
local UISound = require(script.Parent:WaitForChild("UISound"))

local Anim = {}
Anim.Reduced = false

local SPRINGY = { [Enum.EasingStyle.Back] = true, [Enum.EasingStyle.Elastic] = true, [Enum.EasingStyle.Bounce] = true }

local function info(t: number, style: Enum.EasingStyle?, dir: Enum.EasingDirection?, delay: number?): TweenInfo
	local s = style or Enum.EasingStyle.Quint
	if Anim.Reduced then
		t *= 0.6
		if SPRINGY[s] then
			s = Enum.EasingStyle.Quad
		end
	end
	return TweenInfo.new(t, s, dir or Enum.EasingDirection.Out, 0, false, delay or 0)
end

-- Plays and returns a tween. Default curve: Quint Out (the "sleek" one).
function Anim.tween(inst: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?, delay: number?): Tween
	local tw = TweenService:Create(inst, info(t, style, dir, delay), props)
	tw:Play()
	return tw
end

-- The gui's own animation UIScale (created on first use).
function Anim.scale(gui: GuiObject): UIScale
	local s = gui:FindFirstChild("AnimScale")
	if s and s:IsA("UIScale") then
		return s
	end
	local ui = Instance.new("UIScale")
	ui.Name = "AnimScale"
	ui.Parent = gui
	return ui
end

-- ---------- appear / disappear ----------

-- Springs a gui in from small (and fades a CanvasGroup in). Optional delay for staggers.
function Anim.popIn(gui: GuiObject, delay: number?)
	local s = Anim.scale(gui)
	s.Scale = if Anim.Reduced then 0.94 else 0.5
	gui.Visible = true
	if gui:IsA("CanvasGroup") then
		gui.GroupTransparency = 1
		Anim.tween(gui, 0.2, { GroupTransparency = 0 }, Enum.EasingStyle.Quad, nil, delay)
	end
	Anim.tween(s, 0.45, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, delay)
end

-- Shrinks a gui away, then hides it and calls onDone.
function Anim.popOut(gui: GuiObject, onDone: (() -> ())?)
	local s = Anim.scale(gui)
	local tw = Anim.tween(s, 0.16, { Scale = 0.7 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	if gui:IsA("CanvasGroup") then
		Anim.tween(gui, 0.16, { GroupTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	end
	tw.Completed:Once(function(playbackState)
		if playbackState ~= Enum.PlaybackState.Completed then
			return -- a newer popIn took over: stay visible
		end
		gui.Visible = false
		s.Scale = 1
		if onDone then
			onDone()
		end
	end)
end

-- Pops a list of guis in one after another.
function Anim.stagger(guis: { GuiObject }, gap: number?)
	for i, g in ipairs(guis) do
		Anim.popIn(g, (i - 1) * (gap or 0.035))
	end
end

-- Slides a freely placed gui in from an offset (reference px) to where it is now.
function Anim.slideIn(gui: GuiObject, from: Vector2, t: number?, delay: number?)
	local target = gui.Position
	gui.Position = target + UDim2.fromOffset(from.X, from.Y)
	gui.Visible = true
	Anim.tween(gui, t or 0.45, { Position = target }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, delay)
end

-- ---------- attention ----------

-- Quick grow-and-settle (a number changed, a coin landed).
function Anim.bump(gui: GuiObject, amount: number?)
	local s = Anim.scale(gui)
	local up = Anim.tween(s, 0.07, { Scale = amount or 1.12 }, Enum.EasingStyle.Quad)
	up.Completed:Once(function()
		Anim.tween(s, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	end)
end

-- A no-no shake (can't afford it, not allowed). Reduced motion: a small bump instead.
function Anim.wiggle(gui: GuiObject, degrees: number?)
	if Anim.Reduced then
		Anim.bump(gui, 1.05)
		return
	end
	local d = degrees or 8
	task.spawn(function()
		for _, k in ipairs({ -1, 0.85, -0.6, 0.35, 0 }) do
			local tw = Anim.tween(gui, 0.06, { Rotation = d * k }, Enum.EasingStyle.Sine)
			tw.Completed:Wait()
		end
	end)
end

local loops = {} :: { [Instance]: { [string]: Tween } }

local function loop(inst: Instance, key: string, tw: Tween)
	local mine = loops[inst]
	if not mine then
		mine = {}
		loops[inst] = mine
		inst.Destroying:Once(function()
			loops[inst] = nil
		end)
	end
	if mine[key] then
		mine[key]:Cancel()
	end
	mine[key] = tw
	tw:Play()
end

-- Stops a looping animation started by pulse / sway.
function Anim.stop(inst: Instance, key: string)
	local mine = loops[inst]
	if mine and mine[key] then
		mine[key]:Cancel()
		mine[key] = nil
	end
end

-- Breathing scale loop (something is claimable / new). Stop with Anim.stop(gui, "pulse").
function Anim.pulse(gui: GuiObject, amount: number?, period: number?)
	if Anim.Reduced then
		return
	end
	local s = Anim.scale(gui)
	s.Scale = 1
	loop(gui, "pulse", TweenService:Create(s, TweenInfo.new((period or 1.1) / 2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Scale = amount or 1.08 }))
end

-- Gentle rocking loop (badges, NEW tags, featured cards). Stop with Anim.stop(gui, "sway").
function Anim.sway(gui: GuiObject, degrees: number?, period: number?)
	if Anim.Reduced then
		return
	end
	local d = degrees or 4
	gui.Rotation = -d
	loop(gui, "sway", TweenService:Create(gui, TweenInfo.new((period or 1.6) / 2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Rotation = d }))
end

-- A diagonal light sweep across a gui every `period` seconds (buy buttons, featured store cards).
function Anim.shine(gui: GuiObject, period: number?)
	local sheen = Instance.new("Frame")
	sheen.Name = "Sheen"
	sheen.BackgroundColor3 = Color3.new(1, 1, 1)
	sheen.BorderSizePixel = 0
	sheen.Size = UDim2.fromScale(1, 1)
	sheen.ZIndex = gui.ZIndex + 2
	local corner = gui:FindFirstChildOfClass("UICorner")
	if corner then
		corner:Clone().Parent = sheen
	end
	local g = Instance.new("UIGradient")
	g.Rotation = 20
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.42, 1),
		NumberSequenceKeypoint.new(0.5, 0.45),
		NumberSequenceKeypoint.new(0.58, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	g.Offset = Vector2.new(-1, 0)
	g.Parent = sheen
	sheen.Parent = gui
	task.spawn(function()
		while sheen.Parent do
			if not Anim.Reduced and gui.Visible then
				g.Offset = Vector2.new(-1, 0)
				TweenService:Create(g, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), { Offset = Vector2.new(1, 0) }):Play()
			end
			task.wait((period or 3) + math.random() * 0.8)
		end
	end)
end

-- ---------- buttons ----------

-- Press springs + sounds for any button: hover grows it a touch (desktop), pressing squashes it,
-- letting go springs it back with a little overshoot, and every click plays `sound` ("click").
function Anim.button(btn: GuiButton, sound: string?)
	local s = Anim.scale(btn)
	local hovering, pressed = false, false
	local function settle()
		Anim.tween(s, 0.4, { Scale = if hovering then 1.06 else 1 }, Enum.EasingStyle.Back)
	end
	btn.MouseEnter:Connect(function()
		hovering = true
		if not pressed then
			Anim.tween(s, 0.2, { Scale = 1.06 }, Enum.EasingStyle.Back)
			UISound.Play("hover")
		end
	end)
	btn.MouseLeave:Connect(function()
		hovering = false
		if not pressed then
			settle()
		end
	end)
	btn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			pressed = true
			Anim.tween(s, 0.08, { Scale = 0.9 }, Enum.EasingStyle.Quad)
		end
	end)
	btn.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			pressed = false
			if UserInputService.TouchEnabled and input.UserInputType == Enum.UserInputType.Touch then
				hovering = false
			end
			settle()
		end
	end)
	btn.Activated:Connect(function()
		UISound.Play(sound or "click")
	end)
end

-- ---------- numbers ----------

local counters = {} :: { [TextLabel]: { value: NumberValue, format: (number) -> string } }

-- Rolls a label's number up/down to `value` (cash pill, prices, totals). The first call just sets it.
function Anim.countTo(label: TextLabel, value: number, format: (number) -> string, t: number?)
	local c = counters[label]
	if not c then
		local nv = Instance.new("NumberValue")
		nv.Value = value
		local entry = { value = nv, format = format }
		counters[label] = entry
		nv.Changed:Connect(function(v)
			label.Text = entry.format(v)
		end)
		label.Destroying:Once(function()
			counters[label] = nil
			nv:Destroy()
		end)
		label.Text = format(value)
		return
	end
	c.format = format
	if c.value.Value == value then
		label.Text = format(value)
		return
	end
	if Anim.Reduced or t == 0 then
		c.value.Value = value
		return
	end
	Anim.tween(c.value, t or 0.6, { Value = value }, Enum.EasingStyle.Quart)
end

-- ---------- effects layer (coins, confetti, number pops) ----------

local fxRoot: Frame? = nil
local function fx(): Frame
	if not fxRoot then
		local _, root = Theme.screen("SockUIFX", 60)
		fxRoot = root
	end
	return fxRoot :: Frame
end

-- Absolute screen px (as GuiObject.AbsolutePosition reports) -> a position inside the FX layer.
local function toRef(p: Vector2): UDim2
	local s = Theme.Scale()
	return UDim2.fromOffset(p.X / s, p.Y / s)
end

-- Where reward coins fly to: the HUD registers its cash pill coin here, everyone else reads it
-- (so screens don't have to require the HUD).
local cashTarget: GuiObject? = nil
function Anim.SetCashTarget(gui: GuiObject)
	cashTarget = gui
end
function Anim.CashTarget(): GuiObject?
	return cashTarget
end

-- The centre of a gui, in absolute screen px.
function Anim.centerOf(gui: GuiObject): Vector2
	return gui.AbsolutePosition + gui.AbsoluteSize / 2
end

-- A world point -> absolute screen px (nil when behind the camera).
function Anim.worldToScreen(position: Vector3): Vector2?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local v, onScreen = camera:WorldToViewportPoint(position)
	if not onScreen then
		return nil
	end
	return Vector2.new(v.X, v.Y) - GuiService:GetGuiInset()
end

-- Floating text that rises and fades ("+$500", "LEVEL 3!"). `at` in absolute screen px.
function Anim.numberPop(text: string, at: Vector2, color: Color3?, size: number?)
	local t = Theme.label(fx(), text, size or 30, color or Theme.Color.White)
	t.AnchorPoint = Vector2.new(0.5, 0.5)
	t.Size = UDim2.fromOffset(300, (size or 30) + 10)
	t.Position = toRef(at)
	t.ZIndex = 20
	Theme.textStroke(t, Theme.Color.Ink, 2.5)
	Anim.popIn(t)
	local rise = Anim.tween(t, 1.1, { Position = t.Position - UDim2.fromOffset(0, 70) }, Enum.EasingStyle.Quad)
	Anim.tween(t, 0.4, { TextTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0.7)
	rise.Completed:Once(function()
		t:Destroy()
	end)
end

-- Coins fly from `from` (absolute px, or a gui's centre) along little arcs into `to`; `to` bumps
-- and clinks as each lands. Use for collecting, cash packs, sales and rewards.
function Anim.flyCoins(from: Vector2 | GuiObject, to: GuiObject, count: number?, glyph: string?)
	local start = if typeof(from) == "Vector2" then from else Anim.centerOf(from)
	local n = if Anim.Reduced then 3 else math.clamp(count or 8, 1, 16)
	for i = 1, n do
		task.delay((i - 1) * 0.045, function()
			if not to.Parent then
				return
			end
			local coin = Theme.label(fx(), glyph or "🪙", 30, Theme.Color.White)
			coin.AnchorPoint = Vector2.new(0.5, 0.5)
			coin.Size = UDim2.fromOffset(34, 34)
			coin.ZIndex = 21
			local jitter = Vector2.new(math.random(-40, 40), math.random(-30, 30))
			coin.Position = toRef(start)
			local mid = start + jitter + Vector2.new(0, -60 - math.random() * 50)
			local out = Anim.tween(coin, 0.22, { Position = toRef(mid) }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			out.Completed:Once(function()
				local target = Anim.centerOf(to)
				local fly = Anim.tween(coin, 0.38, { Position = toRef(target), Rotation = math.random(-180, 180) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
				fly.Completed:Once(function()
					coin:Destroy()
					Anim.bump(to, 1.08)
					UISound.Play("coin", 0.9 + i * 0.03)
				end)
			end)
		end)
	end
end

local CONFETTI = {
	Color3.fromRGB(255, 120, 120), Color3.fromRGB(255, 210, 90), Color3.fromRGB(120, 220, 130),
	Color3.fromRGB(110, 190, 255), Color3.fromRGB(196, 136, 255), Color3.fromRGB(255, 255, 255),
}

-- A burst of paper confetti from `origin` (absolute px; default: top centre of the screen).
function Anim.confetti(origin: Vector2?, count: number?)
	if Anim.Reduced then
		return
	end
	local layer = fx()
	local s = Theme.Scale()
	local o = origin or Vector2.new(layer.AbsoluteSize.X / 2, layer.AbsoluteSize.Y * 0.18)
	local bits = {}
	for _ = 1, math.clamp(count or 60, 1, 120) do
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.BackgroundColor3 = CONFETTI[math.random(#CONFETTI)]
		f.Size = UDim2.fromOffset(math.random(7, 11), math.random(12, 18))
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.ZIndex = 22
		f.Parent = layer
		local a = math.random() * math.pi * 2
		local speed = 260 + math.random() * 520
		table.insert(bits, {
			f = f,
			p = o / s,
			v = Vector2.new(math.cos(a) * speed * 0.7, -math.abs(math.sin(a)) * speed - 120) / s,
			r = math.random(0, 360),
			vr = math.random(-540, 540),
			life = 1.6 + math.random() * 0.9,
		})
	end
	local age = 0
	local conn
	conn = RunService.RenderStepped:Connect(function(dt)
		age += dt
		local alive = false
		for _, b in ipairs(bits) do
			if age < b.life then
				alive = true
				b.v = Vector2.new(b.v.X * 0.985, b.v.Y + 900 / s * dt)
				b.p += b.v * dt
				b.r += b.vr * dt
				b.f.Position = UDim2.fromOffset(b.p.X, b.p.Y)
				b.f.Rotation = b.r
				b.f.BackgroundTransparency = math.clamp((age - (b.life - 0.4)) / 0.4, 0, 1)
			elseif b.f.Parent then
				b.f:Destroy()
			end
		end
		if not alive then
			conn:Disconnect()
		end
	end)
end

return Anim
