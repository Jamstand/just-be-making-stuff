-- MainMenu: the title screen you land on when you join - a main menu over the live bedroom.
-- The camera glides through a loop of slow cinematic shots of the room (along the clothesline of
-- socks, high over the rug, into the Great Dryer's galaxy, past the row of drawers, up at the giant
-- bed under the moon window) with a soft dip to night between them. On top: the STEAL A SOCK logo
-- (SOCK as four toy blocks, like the blocks in docs/concept/bedroom_keyframe.png, that drop in one
-- by one and bob), two living 3D socks dancing either side of it (SockCard.Viewer; a new pair every
-- shot), sparkles drifting up, the tagline, a big PLAY button and Settings. Its own music: UISound's
-- "title" loop (it starts with the first State, once the saved Music volume is known).
-- Your Sockdex progress: a cream card with the book, "SOCKDEX 12/34", a bar with the milestones
-- marked on it, and what's next ("5 more for 🎁 $100K", or "🎁 $5.0K to claim!" with a red badge
-- when a milestone is waiting). It comes in with the buttons once your data has arrived (the first
-- State) - the count rolls up and the bar fills - and keeps up while the title shows. Tap it to open
-- the Sockdex over the title. It sits bottom-left beside the buttons when there's room, else over
-- PLAY (portrait screens); it shrinks to fit, and stays hidden rather than go under 60% or 44 px tall.
-- PLAY (the button, Enter / Space, gamepad A): the logo flies off, the camera swoops down behind
-- your character, the HUD, menu column and item bar come back, your controls unlock and the music
-- crossfades to the in-game loop.
-- While it shows, the other screens are hidden (SockModal stays, so Settings opens over it, and so
-- do SockHUDTop's toasts and celebrations and SockUIFX), Roblox's player list too, and your
-- character can't move. Reduce motion: no bobbing, hops or sparkles, a still sway-free camera, a
-- short fade instead of the swoop.
-- The shots are world positions from the server's Map.Layout (the rug, clothesline, dryer, drawers
-- and bed); move them here if the map moves. Without the map (workspace.StealASock) the camera
-- circles your character instead.
-- In Studio, set the workspace attribute SkipTitleScreen = true to go straight into the game.
-- API: MainMenu.Show() (once per session), MainMenu.IsOpen(), MainMenu.Play() (as if PLAY was
-- pressed), MainMenu.SetState(state) (the StateView, from init.client: the Sockdex card),
-- MainMenu.Played (fires as PLAY is pressed), MainMenu.Shots (the camera shots).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = require(Shared:WaitForChild("Util"))
local SockConfig = require(Config:WaitForChild("SockConfig"))
local DexConfig = require(Config:WaitForChild("DexConfig"))

local Theme = require(script.Parent:WaitForChild("Theme"))
local Anim = require(script.Parent:WaitForChild("Anim"))
local UISound = require(script.Parent:WaitForChild("UISound"))
local Menu = require(script.Parent:WaitForChild("Menu"))

-- the 3D socks are optional: without SockCard (missing / broken) the logo just has none
local function optional(name: string): any
	local module = script.Parent:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, loaded = pcall(require, module)
	return if ok then loaded else nil
end

local MainMenu = {}

local playedEvent = Instance.new("BindableEvent")
MainMenu.Played = playedEvent.Event

local me = Players.LocalPlayer

local GUI_NAME = "SockTitle"
local DISPLAY_ORDER = 15 -- over the HUD (5), item bar (6) and menu column (10); under SockModal (20: Settings) and SockHUDTop (30: toasts)
-- screens that stay on while the title shows (everything else in PlayerGui is switched off and back)
local KEEP: { [string]: boolean } = { [GUI_NAME] = true, SockModal = true, SockHUDTop = true, SockUIFX = true }
local RENDER_NAME = "SockTitleCamera"
local FOV = 58 -- the menu camera's field of view (a touch longer lens than the game's)
local DIP_IN, DIP_OUT = 0.45, 0.7 -- seconds the dip to night between two shots takes, in and out
local SWOOP = 1.4 -- seconds the camera takes from the title shot down to your character
local NIGHT = Theme.Color.Backdrop

-- The camera's shots: from -> to (camera positions) while looking from fromLook -> toLook, over
-- `time` seconds. World positions from the server's Map.Layout: the rug (440 x 260) round the
-- origin, the clothesline at y 15 from x -160 (in the dryer) to 150 along z 0, the Great Dryer at
-- x -172 facing +x, the drawers at x = +-42 / +-126, z = +-83 facing the line, the bed against the
-- north wall (z -450) with the nightstand lamp at x -192.
type Shot = { name: string, from: Vector3, to: Vector3, fromLook: Vector3, toLook: Vector3, time: number }
local SHOTS: { Shot } = {
	{ name = "clothesline", from = Vector3.new(-120, 13, 30), to = Vector3.new(100, 15, 28), fromLook = Vector3.new(-40, 11, 0), toLook = Vector3.new(160, 10, 0), time = 8 },
	{ name = "overview", from = Vector3.new(-70, 110, 230), to = Vector3.new(70, 135, 225), fromLook = Vector3.new(-10, 8, 0), toLook = Vector3.new(10, 8, 0), time = 7.5 },
	{ name = "dryer", from = Vector3.new(-95, 30, 45), to = Vector3.new(-118, 24, 22), fromLook = Vector3.new(-160, 20, 0), toLook = Vector3.new(-158, 19, 0), time = 7 },
	{ name = "drawers", from = Vector3.new(150, 28, 35), to = Vector3.new(-150, 28, 35), fromLook = Vector3.new(110, 3, 85), toLook = Vector3.new(-110, 3, 85), time = 8.5 },
	{ name = "bedroom", from = Vector3.new(90, 30, 110), to = Vector3.new(-70, 55, 115), fromLook = Vector3.new(10, 70, -380), toLook = Vector3.new(-40, 85, -400), time = 8 },
}
MainMenu.Shots = SHOTS

-- the socks dancing beside the logo, a new pair every shot (SockConfig ids; unknown ones are skipped)
local PAIRS = {
	{ "Argylo", "DJDryer" },
	{ "Sockula", "Socktopus" },
	{ "Tubolino", "Dragonzola" },
	{ "Merlino", "PolkaDottie" },
	{ "Sockbeard", "Shockini" },
}

-- SOCK as toy blocks (the concept's red / yellow / blue / red), each a little askew
local BLOCKS = {
	{ letter = "S", style = "red", tilt = -7 },
	{ letter = "O", style = "gold", tilt = 4 },
	{ letter = "C", style = "blue", tilt = -3 },
	{ letter = "K", style = "coral", tilt = 6 },
}
local BLOCK = 96 -- block size (reference px)
local BLOCK_GAP = 10
local LOGO_W = #BLOCKS * BLOCK + (#BLOCKS - 1) * BLOCK_GAP
local LOGO_H = 200 -- "STEAL A" over the blocks
local SOCK_SIZE = 190 -- the 3D socks either side of the logo (their square; the sock fills ~70%)
local SPARKLES = 14
-- the Sockdex card (reference px) and the book's size: every sock type, as in DexUI
local DEX_W, DEX_H = 260, 90
local DEX_TOTAL = #SockConfig.List
local COUNT_TAN = Color3.fromRGB(214, 160, 110) -- the HUD drawer's "3/8"

-- ---------- state ----------

local shown = false -- Show() ran (it only runs once)
local open = false -- the title is up (until PLAY)
local leaving = false -- PLAY was pressed: the swoop is on
local gui: ScreenGui? = nil
local root: Frame? = nil
local ui: { [string]: any } = {}
local hidden: { [ScreenGui]: boolean } = {}
local conns: { RBXScriptConnection } = {}
local controls: any = nil -- the PlayerModule's controls, switched off while the title shows
local playerListWas: boolean? = nil
local savedFov: number? = nil

local shotIndex = 1
local shotTime = 0
local dipping = false
local clock = 0
local pairIndex = 1

-- ---------- small helpers ----------

local function smooth(u: number): number
	u = math.clamp(u, 0, 1)
	return u * u * u * (u * (u * 6 - 15) + 10)
end

local function reduced(): boolean
	return Anim.Reduced == true
end

local function camera(): Camera?
	return workspace.CurrentCamera
end

local function characterRoot(): BasePart?
	local character = me.Character
	local r = character and character:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

local function hasMap(): boolean
	return workspace:FindFirstChild("StealASock") ~= nil
end

local function connect(signal: RBXScriptSignal, fn: (...any) -> ())
	table.insert(conns, signal:Connect(fn))
end

-- ---------- the other screens, Roblox's player list, your controls ----------

local function hideGui(g: Instance)
	if g:IsA("ScreenGui") and not KEEP[g.Name] and g.Enabled then
		hidden[g] = true
		g.Enabled = false
	end
end

local function hideOthers()
	local playerGui = me:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end
	for _, g in ipairs(playerGui:GetChildren()) do
		hideGui(g)
	end
	-- screens made later (the item bar once its engine loads, Roblox's touch controls) hide too
	connect(playerGui.ChildAdded, function(g)
		if open then
			task.defer(hideGui, g)
		end
	end)
	-- Roblox's player list (retried: early in a session the CoreGui may not accept it yet)
	task.spawn(function()
		for _ = 1, 20 do
			if not open or leaving then
				return
			end
			local ok = pcall(function()
				local was = StarterGui:GetCoreGuiEnabled(Enum.CoreGuiType.PlayerList)
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
				playerListWas = was
			end)
			if ok then
				return
			end
			task.wait(0.2)
		end
	end)
end

local function showOthers()
	for g in pairs(hidden) do
		if g.Parent then
			g.Enabled = true
		end
	end
	table.clear(hidden)
	if playerListWas == true then
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, true)
		end)
	end
	playerListWas = nil
end

-- your character stands still while the title shows (the PlayerModule loads a moment after us)
local function lockControls()
	task.spawn(function()
		for _ = 1, 50 do
			if not open then
				return
			end
			local scripts = me:FindFirstChild("PlayerScripts")
			local module = scripts and scripts:FindFirstChild("PlayerModule")
			if module then
				local ok, c = pcall(function()
					return (require(module) :: any):GetControls()
				end)
				if ok and c then
					controls = c
					pcall(function()
						c:Disable()
					end)
				end
				return
			end
			task.wait(0.1)
		end
	end)
end

local function unlockControls()
	local c = controls
	controls = nil
	if c then
		pcall(function()
			c:Enable()
		end)
	end
end

-- ---------- building ----------

local function frame(parent: Instance, name: string, size: UDim2, position: UDim2?, anchor: Vector2?): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundTransparency = 1
	f.Size = size
	f.Position = position or UDim2.new()
	f.AnchorPoint = anchor or Vector2.zero
	f.Parent = parent
	return f
end

-- a band of night fading out from one screen edge (top or bottom): the vignette that lifts the logo
-- and the buttons off the busy room
local function shade(parent: Instance, name: string, top: boolean, height: number, strength: number)
	local f = frame(parent, name, UDim2.fromScale(1, height), if top then UDim2.new() else UDim2.fromScale(0, 1), if top then Vector2.zero else Vector2.new(0, 1))
	f.BackgroundColor3 = NIGHT
	f.BackgroundTransparency = 0
	f.BorderSizePixel = 0
	local g = Instance.new("UIGradient")
	g.Rotation = if top then 90 else -90
	g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1 - strength), NumberSequenceKeypoint.new(1, 1) })
	g.Parent = f
	return f
end

local function buildLogo(parent: Instance)
	local logo = frame(parent, "Logo", UDim2.fromOffset(LOGO_W, LOGO_H), UDim2.new(0.5, 0, 0, 64), Vector2.new(0.5, 0))
	logo.ZIndex = 5
	local fit = Instance.new("UIScale")
	fit.Name = "Fit"
	fit.Parent = logo
	ui.logo, ui.logoFit = logo, fit

	-- "STEAL A": white with a warm gold sheen and a thick plum outline, tipped a little
	local steal = Theme.label(logo, "STEAL A", 54, Theme.Color.White)
	steal.Name = "Steal"
	steal.AnchorPoint = Vector2.new(0.5, 0)
	steal.Position = UDim2.fromScale(0.5, 0)
	steal.Size = UDim2.new(1, 0, 0, 64)
	steal.Rotation = -3
	steal.ZIndex = 7
	Theme.textStroke(steal, Theme.Color.Stroke, 4)
	Theme.gradient(steal, Color3.fromRGB(255, 252, 236), Theme.Color.Gold)
	steal.Visible = false
	ui.steal = steal

	ui.blocks = {}
	for i, spec in ipairs(BLOCKS) do
		-- `slot` keeps the block's place (it drops in and flies off); `bob` inside it idles
		local x = (i - 1) * (BLOCK + BLOCK_GAP)
		local slot = frame(logo, "Block" .. i, UDim2.fromOffset(BLOCK, BLOCK), UDim2.fromOffset(x, LOGO_H - BLOCK))
		local bob = Instance.new("Frame")
		bob.Name = "Bob"
		bob.Size = UDim2.fromScale(1, 1)
		bob.Rotation = spec.tilt
		bob.ZIndex = 6
		Theme.candy(bob, spec.style, 18, 4)
		Theme.gloss(bob, 18)
		bob.Parent = slot
		local st = Theme.Styles[spec.style] or Theme.Styles.red
		local letter = Theme.label(bob, spec.letter, 76, st.text)
		letter.Name = "Letter"
		letter.Size = UDim2.fromScale(1, 1)
		letter.ZIndex = 9
		Theme.textStroke(letter, if Theme.IsLight(st.text) then Theme.Color.Ink else st.stroke, 3)
		slot.Visible = false
		table.insert(ui.blocks, { slot = slot, bob = bob, home = slot.Position, tilt = spec.tilt, hop = 0 })
	end

	local tagline = Theme.label(parent, "Steal socks  •  Snap thieves  •  Fill your drawer!", 22, Theme.Color.White, Theme.FontBody)
	tagline.Name = "Tagline"
	tagline.AnchorPoint = Vector2.new(0.5, 0)
	tagline.Size = UDim2.fromOffset(680, 28)
	tagline.ZIndex = 6
	tagline.TextScaled = true -- shrinks to fit narrow screens (up to 22)
	tagline.TextTransparency = 1
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = 22
	cap.MinTextSize = 11
	cap.Parent = tagline
	Theme.textStroke(tagline, Theme.Color.Ink, 2).Transparency = 1
	ui.tagline = tagline
end

local function buildSocks(parent: Instance)
	ui.viewers = {}
	local SockCard = optional("SockCard")
	if not SockCard or type(SockCard.Viewer) ~= "function" then
		return
	end
	for i = 1, 2 do
		local ok, viewer = pcall(SockCard.Viewer, parent, nil, if i == 1 then "R" else "L", { size = SOCK_SIZE, roomy = true, rarityGlow = true, zIndex = 4 })
		if ok and viewer and viewer.Frame then
			viewer.Frame.Name = "Sock" .. i
			viewer.Frame.AnchorPoint = Vector2.new(0.5, 0.5)
			viewer.Frame.Visible = false
			table.insert(ui.viewers, viewer)
		end
	end
end

-- the pair for the current shot (skipping ids SockConfig doesn't know)
local function showPair(pop: boolean)
	local pair = PAIRS[pairIndex]
	for i, viewer in ipairs(ui.viewers) do
		local typeId = pair[i]
		if SockConfig.ById[typeId] then
			pcall(function()
				viewer:SetSock(typeId, if i == 1 then "R" else "L")
				viewer:SetAnimated(not reduced())
			end)
			if pop and viewer.Frame.Visible then
				Anim.popIn(viewer.Frame, (i - 1) * 0.08)
			end
		end
	end
end

local function buildSparkles(parent: Instance)
	ui.sparkles = {}
	local rng = Random.new(7)
	for i = 1, SPARKLES do
		local s = Theme.label(parent, if i % 3 == 0 then "★" else "✦", rng:NextInteger(12, 26), if i % 4 == 0 then Theme.Color.Gold else Theme.Color.White)
		s.Name = "Sparkle"
		s.AnchorPoint = Vector2.new(0.5, 0.5)
		s.Size = UDim2.fromOffset(30, 30)
		s.ZIndex = 3
		s.TextTransparency = 1
		table.insert(ui.sparkles, { label = s, x = rng:NextNumber(0.04, 0.96), y = rng:NextNumber(0, 1), speed = rng:NextNumber(0.018, 0.045), phase = rng:NextNumber(0, math.pi * 2) })
	end
end

local function buildButtons(parent: Instance)
	local box = frame(parent, "Buttons", UDim2.fromOffset(300, 170), UDim2.new(0.5, 0, 1, -24), Vector2.new(0.5, 1))
	box.ZIndex = 8
	ui.buttons = box
	local play = Theme.button(box, "▶  PLAY", "green", UDim2.fromOffset(300, 92), 48)
	play.Name = "Play"
	play.AnchorPoint = Vector2.new(0.5, 0)
	play.Position = UDim2.fromScale(0.5, 0)
	play.ZIndex = 8
	play.Visible = false
	Anim.button(play, "click")
	ui.play = play
	local settings = Theme.button(box, "⚙  Settings", "cream", UDim2.fromOffset(220, 62), 26)
	settings.Name = "Settings"
	settings.AnchorPoint = Vector2.new(0.5, 1)
	settings.Position = UDim2.fromScale(0.5, 1)
	settings.ZIndex = 8
	settings.Visible = false
	Anim.button(settings, "click")
	ui.settings = settings
	play.Activated:Connect(function()
		MainMenu.Play()
	end)
	settings.Activated:Connect(function()
		if open and not leaving then
			Menu.Open("Settings")
		end
	end)
end

-- ---------- the Sockdex card ----------

local function dexCountText(n: number): string
	return string.format("%d/%d", math.floor(n + 0.5), DEX_TOTAL)
end

local function buildDex(parent: Instance)
	-- `holder` is placed and fitted by relayout; `card` inside it springs (popIn, press, bump)
	local holder = frame(parent, "Sockdex", UDim2.fromOffset(DEX_W, DEX_H), UDim2.new(), Vector2.new(0, 1))
	holder.ZIndex = 8
	holder.Visible = false
	local fit = Instance.new("UIScale")
	fit.Name = "Fit"
	fit.Parent = holder
	ui.dex, ui.dexFit = holder, fit

	local card = Theme.button(holder, "", "cream", UDim2.fromScale(1, 1))
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5) -- its springs grow from the middle
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.ZIndex = 8
	card.Visible = false
	Anim.button(card, "click")
	ui.dexCard = card

	-- the book: the Sockdex's own blue tile and 📖, as on its menu button
	local book = Instance.new("Frame")
	book.Name = "Book"
	book.AnchorPoint = Vector2.new(0, 0.5)
	book.Position = UDim2.new(0, 10, 0.5, 0)
	book.Size = UDim2.fromOffset(62, 62)
	book.ZIndex = 11
	Theme.candy(book, "blue", 14, 2.5)
	Theme.gloss(book, 14)
	book.Parent = card
	local glyph = Theme.label(book, "📖", 36, Theme.Color.White)
	glyph.Name = "Glyph"
	glyph.Size = UDim2.fromScale(1, 1)
	glyph.ZIndex = 13

	-- "SOCKDEX" (coral) and "12/34" (tan), like the HUD's "YOUR DRAWER 3/8"
	local title = Theme.label(card, "SOCKDEX", 20, Theme.Color.Title)
	title.Name = "Title"
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Position = UDim2.fromOffset(82, 8)
	title.Size = UDim2.new(1, -92, 0, 24)
	title.ZIndex = 11
	local count = Theme.label(card, dexCountText(0), 22, COUNT_TAN)
	count.Name = "Count"
	count.TextXAlignment = Enum.TextXAlignment.Right
	count.Position = UDim2.fromOffset(82, 8)
	count.Size = UDim2.new(1, -98, 0, 24) -- ends a little short of the corner, clear of the badge
	count.ZIndex = 11
	ui.dexCount = count

	-- the bar: green candy in a dark track, a notch at each milestone, the percent on top
	local track = Instance.new("Frame")
	track.Name = "Bar"
	track.Position = UDim2.fromOffset(82, 38)
	track.Size = UDim2.new(1, -92, 0, 18)
	track.BackgroundColor3 = Theme.Color.InsetDark
	track.BorderSizePixel = 0
	track.ZIndex = 11
	Theme.corner(track, UDim.new(0.5, 0))
	Theme.stroke(track, Theme.Color.Stroke, 2)
	track.Parent = card
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.ZIndex = 12
	fill.Visible = false
	Theme.candy(fill, "green", 9, 0)
	local fillStroke = fill:FindFirstChildOfClass("UIStroke")
	if fillStroke then
		fillStroke.Enabled = false
	end
	Theme.gloss(fill, 9)
	local fillMin = Instance.new("UISizeConstraint")
	fillMin.MinSize = Vector2.new(18, 0) -- a round pill even for 1 type (its corners stay inside the track)
	fillMin.Parent = fill
	fill.Parent = track
	ui.dexFill = fill
	for _, m in ipairs(DexConfig.Milestones) do
		if m.percent < 100 then
			-- a short tick in from the top and the bottom edge (the percent text sits between them)
			for _, edge in ipairs({ 0, 1 }) do
				local notch = Instance.new("Frame")
				notch.Name = "Milestone"
				notch.AnchorPoint = Vector2.new(0.5, edge)
				notch.Position = UDim2.fromScale(m.percent / 100, edge)
				notch.Size = UDim2.fromOffset(2, 4)
				notch.BackgroundColor3 = Theme.Color.Stroke
				notch.BackgroundTransparency = 0.4
				notch.BorderSizePixel = 0
				notch.ZIndex = 14
				notch.Parent = track
			end
		end
	end
	local percent = Theme.label(track, "0%", 13, Theme.Color.White)
	percent.Name = "Percent"
	percent.Size = UDim2.fromScale(1, 1)
	percent.ZIndex = 15
	Theme.textStroke(percent, Theme.Color.Ink, 1.5)
	ui.dexPercent = percent

	-- what's next: the next milestone's reward, or the rewards waiting to be claimed
	local nextLine = Theme.label(card, "", 14, Theme.Color.Muted, Theme.FontBody)
	nextLine.Name = "Next"
	nextLine.TextXAlignment = Enum.TextXAlignment.Left
	nextLine.Position = UDim2.fromOffset(82, 61)
	nextLine.Size = UDim2.new(1, -92, 0, 20)
	nextLine.ZIndex = 11
	nextLine.TextScaled = true -- shrinks rather than spill out of the card
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = 14
	cap.MinTextSize = 9
	cap.Parent = nextLine
	ui.dexNext = nextLine

	-- a red bubble while a milestone is waiting to be claimed (like the Sockdex menu button's)
	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(0.5, 0.5)
	badge.Position = UDim2.new(1, 6, 0, -6) -- on the card's corner, clear of the count
	badge.Size = UDim2.fromOffset(30, 30)
	badge.ZIndex = 16
	badge.Visible = false
	Theme.candy(badge, "red", 15, 2)
	local badgeText = Theme.label(badge, "!", 18, Theme.Color.White)
	badgeText.Name = "Text"
	badgeText.Size = UDim2.fromScale(1, 1)
	badgeText.ZIndex = 17
	Theme.textStroke(badgeText, Theme.Styles.red.stroke, 1.5)
	badge.Parent = card
	ui.dexBadge, ui.dexBadgeText = badge, badgeText

	card.Activated:Connect(function()
		if not open or leaving then
			return
		end
		Menu.Open("Sockdex")
		if Menu.Current() ~= "Sockdex" then
			Anim.wiggle(card, 6) -- the Sockdex didn't load: nothing to open
		end
	end)
end

local function build()
	local g, r = Theme.screen(GUI_NAME, DISPLAY_ORDER)
	g.IgnoreGuiInset = true -- the night dip covers the whole screen, top bar included
	gui, root = g, r
	shade(r, "ShadeTop", true, 0.42, 0.62)
	shade(r, "ShadeBottom", false, 0.4, 0.7)
	buildSparkles(r)
	buildSocks(r)
	buildLogo(r)
	buildButtons(r)
	buildDex(r)
	-- the night between two shots (and at the very start): over the 3D room and the vignette, under
	-- the sparkles, socks, logo and buttons, which stay up through it
	local dip = frame(r, "Dip", UDim2.fromScale(1, 1))
	dip.BackgroundColor3 = NIGHT
	dip.BackgroundTransparency = 0
	dip.BorderSizePixel = 0
	dip.ZIndex = 2
	ui.dip = dip
end

-- fits the logo, socks, tagline and buttons to the screen (reference px: Theme's Root is scaled)
local function relayout()
	if not root or not ui.logo then
		return
	end
	local s = math.max(Theme.Scale(), 0.01)
	local w = root.AbsoluteSize.X / s
	local h = root.AbsoluteSize.Y / s
	-- the logo fills at most 88% of the width and 34% of the height (phones in portrait shrink it)
	local fit = math.min(1, (w * 0.88) / LOGO_W, (h * 0.34) / LOGO_H)
	ui.logoFit.Scale = fit
	local top = math.clamp(h * 0.06, 16, 72) + 36 -- under Roblox's top bar (the inset is ignored)
	ui.logo.Position = UDim2.new(0.5, 0, 0, top)
	local logoBottom = top + LOGO_H * fit
	ui.tagline.Position = UDim2.new(0.5, 0, 0, logoBottom + 10)
	ui.tagline.Size = UDim2.fromOffset(math.min(680, w - 24), 28)
	-- the socks either side of the logo: only when there's room for them
	local room = (w - LOGO_W * fit) / 2
	local sockSize = math.min(SOCK_SIZE, room - 20)
	local sockY = top + (LOGO_H - BLOCK / 2) * fit -- level with the middle of the blocks
	for i, viewer in ipairs(ui.viewers or {}) do
		local f = viewer.Frame
		f.Size = UDim2.fromOffset(SOCK_SIZE, SOCK_SIZE)
		local scale = f:FindFirstChild("Fit") or Instance.new("UIScale")
		scale.Name = "Fit"
		scale.Scale = math.max(sockSize, 0) / SOCK_SIZE
		scale.Parent = f
		local side = if i == 1 then -1 else 1
		f.Position = UDim2.new(0.5, side * (LOGO_W * fit / 2 + sockSize / 2 + 12), 0, sockY)
		ui["sockRoom" .. i] = sockSize >= 90
		if not ui.entered then
			continue
		end
		f.Visible = sockSize >= 90 and not leaving
	end
	-- buttons: their full size, centred at the bottom (screens under 420 reference px tall shrink them)
	local bfit = math.min(1, h / 420)
	local bscale = ui.buttons:FindFirstChild("Fit") or Instance.new("UIScale")
	bscale.Name = "Fit"
	bscale.Scale = bfit
	bscale.Parent = ui.buttons
	local gap = math.clamp(h * 0.05, 14, 40)
	ui.buttons.Position = UDim2.new(0.5, 0, 1, -gap)
	-- the Sockdex card: bottom-left, level with the buttons, when there's room beside PLAY (landscape
	-- phones and tablets, desktops); else over PLAY (portrait screens); clear of the tagline and socks
	if ui.dex then
		local boxBottom = h - gap
		local boxTop = boxBottom - 170 * bfit
		local above = logoBottom + 38 -- the tagline's bottom
		if #(ui.viewers or {}) > 0 and sockSize >= 90 then
			above = math.max(above, sockY + sockSize / 2)
		end
		above += 22 -- (the claim badge pokes 21 px above the card)
		-- clear of the notch / rounded corners on touch screens (60 px at every UI size)
		local margin = if Theme.IsTouch then math.max(16, 60 / s) else 24
		local playLeft = w / 2 - 150 * bfit
		-- (16 px from PLAY, plus the claim badge poking 21 px out of the card's right side)
		local cornerFit = math.min(bfit, (playLeft - 38 - margin) / DEX_W, (boxBottom - above) / DEX_H)
		local stackFit = math.min(bfit, (w - 24) / DEX_W, (boxTop - 16 * bfit - above) / DEX_H)
		local corner = cornerFit >= 0.8 or cornerFit >= stackFit
		local dexFit = if corner then cornerFit else stackFit
		if corner then
			ui.dex.AnchorPoint = Vector2.new(0, 1)
			ui.dex.Position = UDim2.new(0, margin, 0, boxBottom)
		else
			ui.dex.AnchorPoint = Vector2.new(0.5, 1)
			ui.dex.Position = UDim2.new(0.5, 0, 0, boxTop - 16 * bfit)
		end
		ui.dexFit.Scale = math.max(dexFit, 0.01)
		-- too small to tap comfortably (under 44 px tall on screen): leave it out
		ui.dexRoom = dexFit >= 0.6 and DEX_H * dexFit * s >= 44
		ui.dex.Visible = ui.dexShown == true and ui.dexRoom
	end
end

-- ---------- the Sockdex card's numbers ----------

type DexData = { found: number, ready: number, readyCash: number, nextMilestone: any, sig: string }

-- The Sockdex as DexUI counts it: a type is found once it has an entry (unknown ids don't count);
-- a milestone is ready once reached and not claimed yet.
local function readDex(state: any): DexData
	local dex = if type(state.dex) == "table" then state.dex else {}
	local claimed = if type(state.dexClaimed) == "table" then state.dexClaimed else {}
	local found = 0
	for typeId in pairs(dex) do
		if SockConfig.ById[typeId] then
			found += 1
		end
	end
	local ready, readyCash, nextMilestone = 0, 0, nil
	for _, m in ipairs(DexConfig.Milestones) do
		if found * 100 >= m.percent * DEX_TOTAL then
			if claimed[m.key] ~= true then
				ready += 1
				readyCash += m.cash
			end
		elseif not nextMilestone then
			nextMilestone = m
		end
	end
	return { found = found, ready = ready, readyCash = readyCash, nextMilestone = nextMilestone, sig = found .. ":" .. ready .. ":" .. readyCash }
end

local function dexLine(d: DexData): (string, Color3)
	if d.ready > 0 then
		return "🎁 $" .. Util.FormatCash(d.readyCash) .. " to claim!", Theme.Color.Money
	end
	local m = d.nextMilestone
	if m then
		local need = math.ceil(m.percent * DEX_TOTAL / 100) - d.found
		return string.format("%d more for 🎁 $%s", need, Util.FormatCash(m.cash)), Theme.Color.Muted
	end
	return "★ Sock Master! ★", Theme.Color.Gold2
end

local function setDexBadge(ready: number)
	local badge = ui.dexBadge
	ui.dexBadgeText.Text = if ready > 1 then tostring(ready) else "!"
	local show = ready > 0
	if show == (ui.dexBadgeOn == true) then
		return
	end
	ui.dexBadgeOn = show
	if show then
		Anim.popIn(badge)
		Anim.sway(badge, 8, 1.2)
		UISound.Play("pop")
	else
		Anim.stop(badge, "sway")
		badge.Rotation = 0
		Anim.popOut(badge)
	end
end

local function paintDex(animate: boolean)
	local d = ui.dexData
	if not d or not ui.dexShown then
		return
	end
	local pct = if DEX_TOTAL > 0 then d.found / DEX_TOTAL else 0
	Anim.countTo(ui.dexCount, d.found, dexCountText)
	ui.dexPercent.Text = tostring(math.floor(pct * 100 + 0.5)) .. "%"
	local text, color = dexLine(d)
	ui.dexNext.Text = text
	ui.dexNext.TextColor3 = color
	if ui.dexPct ~= pct then
		ui.dexPct = pct
		ui.dexFill.Visible = pct > 0
		if animate then
			Anim.tween(ui.dexFill, 0.7, { Size = UDim2.fromScale(pct, 1) })
		else
			ui.dexFill.Size = UDim2.fromScale(pct, 1)
		end
	end
	setDexBadge(d.ready)
end

-- The card springs in once the numbers are known (with the buttons, or later when the data is slow);
-- the count rolls up from 0 and the bar fills.
local function revealDex(delay: number)
	if ui.dexRevealing or not ui.dexData then
		return
	end
	ui.dexRevealing = true
	task.delay(delay, function()
		if not open or leaving then
			return
		end
		ui.dexShown = true
		Anim.countTo(ui.dexCount, 0, dexCountText) -- the first call only sets it
		ui.dexFill.Size = UDim2.fromScale(0, 1)
		ui.dexFill.Visible = false
		ui.dexPct = 0
		relayout()
		Anim.popIn(ui.dexCard)
		task.delay(0.15, function()
			if open and not leaving then
				paintDex(true)
			end
		end)
	end)
end

-- ---------- the camera ----------

local function shotFrame(shot: Shot, u: number): CFrame
	local e = smooth(u)
	local pos = shot.from:Lerp(shot.to, e)
	local look = shot.fromLook:Lerp(shot.toLook, e)
	if not reduced() then
		-- a gentle handheld drift
		pos += Vector3.new(math.sin(clock * 0.6) * 0.5, math.sin(clock * 0.85) * 0.35, math.cos(clock * 0.5) * 0.4)
	end
	return CFrame.lookAt(pos, look)
end

-- no map: circle the character (or the origin) slowly
local function orbitFrame(): CFrame
	local r = characterRoot()
	local centre = if r then r.Position else Vector3.new(0, 3, 0)
	local a = clock * 0.18
	local pos = centre + Vector3.new(math.cos(a) * 22, 8, math.sin(a) * 22)
	return CFrame.lookAt(pos, centre + Vector3.new(0, 2, 0))
end

local function streamAround(shot: Shot)
	task.spawn(function()
		pcall(function()
			me:RequestStreamAroundAsync(shot.toLook)
		end)
	end)
end

local function nextShot()
	shotIndex = shotIndex % #SHOTS + 1
	shotTime = 0
	pairIndex = pairIndex % #PAIRS + 1
	showPair(true)
	streamAround(SHOTS[shotIndex])
	streamAround(SHOTS[shotIndex % #SHOTS + 1])
end

local function stepCamera(dt: number)
	local cam = camera()
	if not cam then
		return
	end
	cam.CameraType = Enum.CameraType.Scriptable
	cam.FieldOfView = FOV
	if not hasMap() then
		cam.CFrame = orbitFrame()
		return
	end
	local shot = SHOTS[shotIndex]
	shotTime += dt * (if reduced() then 0.75 else 1)
	-- the dip to night: in over DIP_IN s, done a beat before the shot ends (the cut happens in full
	-- night), out over the first DIP_OUT s of the next
	if not dipping and shotTime >= shot.time - DIP_IN - 0.1 then
		dipping = true
		Anim.tween(ui.dip, DIP_IN, { BackgroundTransparency = 0 }, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
	end
	if shotTime >= shot.time then
		nextShot()
		shot = SHOTS[shotIndex]
		dipping = false
		Anim.tween(ui.dip, DIP_OUT, { BackgroundTransparency = 1 }, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
	end
	cam.CFrame = shotFrame(shot, shotTime / shot.time)
end

-- ---------- idle motion ----------

local function stepIdle(dt: number)
	local still = reduced()
	if ui.still ~= still then
		-- Reduce motion arrives with the saved settings (the first State), after the title is up
		ui.still = still
		for _, viewer in ipairs(ui.viewers or {}) do
			pcall(function()
				viewer:SetAnimated(not still)
			end)
		end
		if ui.dexBadgeOn then
			if still then
				Anim.stop(ui.dexBadge, "sway")
				ui.dexBadge.Rotation = 0
			else
				Anim.sway(ui.dexBadge, 8, 1.2)
			end
		end
	end
	for i, b in ipairs(ui.blocks or {}) do
		if b.hop > 0 then
			b.hop = math.max(0, b.hop - dt)
		end
		local hopU = if b.hop > 0 then 1 - b.hop / 0.55 else 0
		local hopY = if b.hop > 0 then -math.sin(hopU * math.pi) * 26 else 0
		local spin = if b.hop > 0 then smooth(hopU) * 360 else 0
		if still then
			b.bob.Position = UDim2.new()
			b.bob.Rotation = b.tilt
		else
			b.bob.Position = UDim2.fromOffset(0, math.sin(clock * 2.1 + i * 0.8) * 4 + hopY)
			b.bob.Rotation = b.tilt + math.sin(clock * 1.5 + i * 1.3) * 2.5 + spin
		end
	end
	-- now and then one block hops and spins
	if not still and ui.entered and math.floor(clock / 4.5) ~= math.floor((clock - dt) / 4.5) then
		local b = ui.blocks[((math.floor(clock / 4.5) - 1) % #ui.blocks) + 1]
		if b and b.hop <= 0 then
			b.hop = 0.55
		end
	end
	for _, sp in ipairs(ui.sparkles or {}) do
		if still or not ui.entered then
			sp.label.TextTransparency = 1
		else
			sp.y -= sp.speed * dt
			if sp.y < -0.05 then
				sp.y = 1.05
			end
			sp.label.Position = UDim2.fromScale(sp.x + math.sin(clock * 0.7 + sp.phase) * 0.01, sp.y)
			sp.label.TextTransparency = 0.25 + 0.6 * (0.5 + 0.5 * math.sin(clock * 2.3 + sp.phase))
		end
	end
end

local function step(dt: number)
	clock += dt
	if leaving then
		return -- the swoop drives the camera
	end
	stepCamera(dt)
	stepIdle(dt)
end

-- ---------- coming in ----------

local function enter()
	local fast = reduced()
	-- out of the night: the first shot fades up
	Anim.tween(ui.dip, if fast then 0.5 else 1.1, { BackgroundTransparency = 1 }, Enum.EasingStyle.Sine)
	task.delay(if fast then 0.1 else 0.35, function()
		if open and not leaving then
			Anim.popIn(ui.steal)
		end
	end)
	-- the toy blocks drop in one by one and bounce
	for i, b in ipairs(ui.blocks) do
		local delay = (if fast then 0.15 else 0.55) + (i - 1) * (if fast then 0.04 else 0.13)
		task.delay(delay, function()
			if not open or leaving then
				return
			end
			b.slot.Visible = true
			if fast then
				b.slot.Position = b.home
				return
			end
			b.slot.Position = b.home - UDim2.fromOffset(0, 440)
			Anim.tween(b.slot, 0.75, { Position = b.home }, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out)
			task.delay(0.42, UISound.Play, "pop", 0.8 + i * 0.07) -- the first bounce lands
		end)
	end
	local after = if fast then 0.35 else 1.15
	task.delay(after, function()
		if not open or leaving then
			return
		end
		ui.entered = true
		Anim.tween(ui.tagline, 0.5, { TextTransparency = 0 }, Enum.EasingStyle.Sine)
		local stroke = ui.tagline:FindFirstChildOfClass("UIStroke")
		if stroke then
			Anim.tween(stroke, 0.5, { Transparency = 0 }, Enum.EasingStyle.Sine)
		end
		for i, viewer in ipairs(ui.viewers) do
			if ui["sockRoom" .. i] then
				Anim.popIn(viewer.Frame, (i - 1) * 0.1)
			end
		end
		Anim.popIn(ui.play, 0.2)
		Anim.popIn(ui.settings, 0.32)
		revealDex(0.44) -- the Sockdex card, if the data is here (else when it arrives)
		task.delay(0.8, function()
			if open and not leaving then
				Anim.pulse(ui.play, 1.05, 1.3)
				Anim.shine(ui.play, 2.6)
			end
		end)
	end)
end

-- ---------- PLAY ----------

local function finish()
	RunService:UnbindFromRenderStep(RENDER_NAME)
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
	for _, viewer in ipairs(ui.viewers or {}) do
		pcall(function()
			viewer:Destroy()
		end)
	end
	local cam = camera()
	if cam then
		cam.FieldOfView = savedFov or 70
		cam.CameraType = Enum.CameraType.Custom
		local character = me.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			cam.CameraSubject = humanoid
		end
	end
	showOthers()
	unlockControls()
	open = false
	if gui then
		gui:Destroy()
	end
	gui, root = nil, nil
	ui = {}
end

-- where the game's own camera will pick up: behind and above your character, looking at it
local function behindCharacter(): CFrame?
	local r = characterRoot()
	if not r then
		return nil
	end
	local look = r.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	return CFrame.lookAt(r.Position - flat * 13 + Vector3.new(0, 5.5, 0), r.Position + Vector3.new(0, 1.5, 0))
end

local function leave()
	local fast = reduced()
	-- the logo flies off, the buttons and socks pop away
	Anim.stop(ui.play, "pulse")
	Anim.popOut(ui.play)
	Anim.popOut(ui.settings)
	if ui.dexShown then
		Anim.stop(ui.dexBadge, "sway")
		Anim.popOut(ui.dexCard)
		-- and gone for sure (a press spring or a bump on the same scale could cancel the popOut)
		ui.dexShown = false
		local holder = ui.dex
		task.delay(0.2, function()
			if holder.Parent then
				holder.Visible = false
			end
		end)
	end
	Anim.popOut(ui.steal)
	for _, viewer in ipairs(ui.viewers) do
		if viewer.Frame.Visible then
			Anim.popOut(viewer.Frame)
		end
	end
	Anim.tween(ui.tagline, 0.25, { TextTransparency = 1 }, Enum.EasingStyle.Quad)
	local stroke = ui.tagline:FindFirstChildOfClass("UIStroke")
	if stroke then
		Anim.tween(stroke, 0.25, { Transparency = 1 }, Enum.EasingStyle.Quad)
	end
	for i, b in ipairs(ui.blocks) do
		Anim.tween(b.slot, 0.45, { Position = b.home - UDim2.fromOffset(0, 520) }, Enum.EasingStyle.Back, Enum.EasingDirection.In, (i - 1) * 0.05)
	end
	for _, sp in ipairs(ui.sparkles) do
		Anim.tween(sp.label, 0.3, { TextTransparency = 1 }, Enum.EasingStyle.Quad)
	end
	Anim.tween(ui.dip, 0.2, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad)
	for _, name in ipairs({ "ShadeTop", "ShadeBottom" }) do
		local shadeFrame = root and root:FindFirstChild(name)
		if shadeFrame then
			Anim.tween(shadeFrame, 0.9, { BackgroundTransparency = 1 }, Enum.EasingStyle.Sine)
		end
	end
	-- the camera swoops down behind your character (Reduce motion: a quick fade through night)
	local cam = camera()
	local target = behindCharacter()
	if not cam or not target then
		task.delay(0.5, finish)
		return
	end
	if fast then
		Anim.tween(ui.dip, 0.25, { BackgroundTransparency = 0 }, Enum.EasingStyle.Sine)
		task.delay(0.3, function()
			cam.CFrame = target
			finish()
		end)
		return
	end
	local start = cam.CFrame
	local startLook = start.Position + start.LookVector * 40
	local lift = Vector3.new(0, math.max(start.Position.Y, target.Position.Y) * 0.4 + 12, 0)
	local mid = (start.Position + target.Position) / 2 + lift
	local endLook = target.Position + target.LookVector * 13
	local t = 0
	local startFov = cam.FieldOfView
	local endFov = savedFov or 70
	RunService:UnbindFromRenderStep(RENDER_NAME)
	RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt)
		t += dt
		local u = smooth(t / SWOOP)
		-- a curved flight (a quadratic Bezier through a raised middle) that eases in and out
		local a = start.Position:Lerp(mid, u)
		local b = mid:Lerp(target.Position, u)
		local pos = a:Lerp(b, u)
		local look = startLook:Lerp(endLook, u)
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CFrame = CFrame.lookAt(pos, look)
		cam.FieldOfView = startFov + (endFov - startFov) * u
		if t >= SWOOP then
			finish()
		end
	end)
end

-- As if PLAY was pressed: into the game.
function MainMenu.Play()
	if not open or leaving then
		return
	end
	leaving = true
	UISound.Play("whoosh")
	UISound.SetTrack("music") -- the title loop crossfades to the game's
	playedEvent:Fire()
	leave()
end

function MainMenu.IsOpen(): boolean
	return open
end

-- The StateView (init.client, every second): keeps the Sockdex card up to date while the title shows.
function MainMenu.SetState(state: any)
	if not open or leaving or not ui.dex or type(state) ~= "table" then
		return
	end
	local d = readDex(state)
	local before = ui.dexData
	if before and before.sig == d.sig then
		return
	end
	ui.dexData = d
	if not ui.dexShown then
		if ui.entered then
			revealDex(0.1) -- the data came after the buttons
		end
		return
	end
	paintDex(true)
	if before and d.found > before.found then
		Anim.bump(ui.dexCard, 1.06) -- a new type found while the title shows
	end
end

-- Puts the title screen up (once per session; not in Studio with workspace.SkipTitleScreen).
function MainMenu.Show()
	if shown then
		return
	end
	shown = true
	if RunService:IsStudio() and workspace:GetAttribute("SkipTitleScreen") == true then
		return
	end
	open = true
	UISound.SetTrack("title")
	build()
	hideOthers()
	lockControls()
	local cam = camera()
	if cam then
		savedFov = cam.FieldOfView
	end
	if hasMap() then
		streamAround(SHOTS[1])
		streamAround(SHOTS[2])
	end
	showPair(false)
	relayout()
	task.defer(relayout)
	if root then
		connect(root:GetPropertyChangedSignal("AbsoluteSize"), relayout)
		local uiScale = root:FindFirstChild("SettingsScale")
		if uiScale and uiScale:IsA("UIScale") then
			connect(uiScale:GetPropertyChangedSignal("Scale"), relayout)
		end
	end
	RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 1, step)
	connect(UserInputService.InputBegan, function(input, processed)
		if processed or not open or leaving or Menu.Current() ~= nil then
			return
		end
		local code = input.KeyCode
		if code == Enum.KeyCode.Return or code == Enum.KeyCode.KeypadEnter or code == Enum.KeyCode.Space or code == Enum.KeyCode.ButtonA then
			MainMenu.Play()
		end
	end)
	enter()
end

return MainMenu
