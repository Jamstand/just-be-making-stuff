-- HUD: cash, income, drawer contents, lock timer, carry banner, toasts and announcements.
-- Procedural UI (no assets). Mobile-first: big text, nothing near the jump button, one 56 px
-- toggle for the drawer panel.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared:WaitForChild("Util"))
local Config = Shared:WaitForChild("Config")
local RarityConfig = require(Config:WaitForChild("RarityConfig"))
local MutationConfig = require(Config:WaitForChild("MutationConfig"))

local HUD = {}

local player = Players.LocalPlayer
local IS_TOUCH = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

local FONT = Enum.Font.FredokaOne
local FONT_BODY = Enum.Font.GothamBold
local COLOR_PANEL = Color3.fromRGB(28, 26, 40)
local COLOR_CASH = Color3.fromRGB(120, 255, 150)

local gui
local refs = {
	cash = nil :: TextLabel?,
	rate = nil :: TextLabel?,
	waiting = nil :: TextLabel?,
	lock = nil :: TextLabel?,
	drawerTitle = nil :: TextLabel?,
	drawerList = nil :: ScrollingFrame?,
	drawerPanel = nil :: Frame?,
	toggle = nil :: TextButton?,
	carry = nil :: TextLabel?,
	carryFrame = nil :: Frame?,
	toasts = nil :: Frame?,
	announce = nil :: TextLabel?,
	announceFrame = nil :: Frame?,
}
local state = nil
local drawerOpen = not IS_TOUCH

local function corner(inst: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = inst
end

local function label(parent: Instance, text: string, size: number, color: Color3?, font: Enum.Font?): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Font = font or FONT
	t.TextSize = size
	t.TextColor3 = color or Color3.new(1, 1, 1)
	t.TextStrokeTransparency = 0.5
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.Text = text
	t.Parent = parent
	return t
end

function HUD.Init()
	gui = Instance.new("ScreenGui")
	gui.Name = "SockHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Top-left: cash / rate / waiting / lock
	local top = Instance.new("Frame")
	top.Name = "Top"
	top.Size = UDim2.fromOffset(300, 132)
	top.Position = UDim2.fromOffset(12, 8)
	top.BackgroundColor3 = COLOR_PANEL
	top.BackgroundTransparency = 0.25
	top.Parent = gui
	corner(top, 14)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingTop = UDim.new(0, 6)
	pad.Parent = top
	refs.cash = label(top, "$0", 36, COLOR_CASH)
	refs.cash.Size = UDim2.new(1, 0, 0, 40)
	refs.rate = label(top, "+$0/s", 20, Color3.fromRGB(200, 255, 210), FONT_BODY)
	refs.rate.Position = UDim2.fromOffset(0, 42)
	refs.rate.Size = UDim2.new(1, 0, 0, 24)
	refs.waiting = label(top, "$0 waiting on your Collect pad", 16, Color3.fromRGB(255, 230, 150), FONT_BODY)
	refs.waiting.Position = UDim2.fromOffset(0, 68)
	refs.waiting.Size = UDim2.new(1, 0, 0, 22)
	refs.lock = label(top, "Drawer open", 16, Color3.fromRGB(180, 190, 220), FONT_BODY)
	refs.lock.Position = UDim2.fromOffset(0, 94)
	refs.lock.Size = UDim2.new(1, 0, 0, 22)

	-- Right: drawer panel + toggle
	local toggle = Instance.new("TextButton")
	toggle.Name = "DrawerToggle"
	toggle.Size = UDim2.fromOffset(150, 56)
	toggle.Position = UDim2.fromOffset(12, 150) -- under the cash panel; the top-right belongs to Roblox's player list
	toggle.BackgroundColor3 = Color3.fromRGB(255, 190, 60)
	toggle.Font = FONT
	toggle.TextSize = 22
	toggle.TextColor3 = Color3.fromRGB(40, 30, 10)
	toggle.Text = "🧦 DRAWER"
	toggle.AutoButtonColor = true
	toggle.Parent = gui
	corner(toggle, 12)
	refs.toggle = toggle

	local panel = Instance.new("Frame")
	panel.Name = "Drawer"
	panel.Size = UDim2.new(0, 300, 1, -230) -- fills down to just above the bottom edge on any screen
	panel.Position = UDim2.fromOffset(12, 214)
	panel.BackgroundColor3 = COLOR_PANEL
	panel.BackgroundTransparency = 0.2
	panel.Visible = drawerOpen
	panel.Parent = gui
	corner(panel, 14)
	refs.drawerPanel = panel
	refs.drawerTitle = label(panel, "YOUR DRAWER 0/8", 20)
	refs.drawerTitle.Position = UDim2.fromOffset(12, 6)
	refs.drawerTitle.Size = UDim2.new(1, -24, 0, 28)
	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.Position = UDim2.fromOffset(8, 40)
	list.Size = UDim2.new(1, -16, 1, -48)
	list.BackgroundTransparency = 1
	list.ScrollBarThickness = 6
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	refs.drawerList = list

	toggle.Activated:Connect(function()
		drawerOpen = not drawerOpen
		panel.Visible = drawerOpen
	end)

	-- Bottom-centre carry banner (kept above the bottom edge and away from the jump button)
	local carryFrame = Instance.new("Frame")
	carryFrame.Name = "Carry"
	carryFrame.Size = UDim2.fromOffset(420, 52)
	carryFrame.AnchorPoint = Vector2.new(0.5, 1)
	carryFrame.Position = UDim2.new(0.5, 0, 1, -24)
	carryFrame.BackgroundColor3 = Color3.fromRGB(200, 60, 80)
	carryFrame.Visible = false
	carryFrame.Parent = gui
	corner(carryFrame, 12)
	refs.carryFrame = carryFrame
	refs.carry = label(carryFrame, "", 20)
	refs.carry.Size = UDim2.fromScale(1, 1)
	refs.carry.TextXAlignment = Enum.TextXAlignment.Center
	refs.carry.TextScaled = true
	local carrySizer = Instance.new("UITextSizeConstraint")
	carrySizer.MaxTextSize = 20
	carrySizer.Parent = refs.carry

	-- Toasts (top-centre stack)
	local toasts = Instance.new("Frame")
	toasts.Name = "Toasts"
	toasts.Size = UDim2.fromOffset(460, 200)
	toasts.AnchorPoint = Vector2.new(0.5, 0)
	toasts.Position = UDim2.new(0.5, 0, 0, 70)
	toasts.BackgroundTransparency = 1
	toasts.Parent = gui
	local toastLayout = Instance.new("UIListLayout")
	toastLayout.Padding = UDim.new(0, 6)
	toastLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	toastLayout.SortOrder = Enum.SortOrder.LayoutOrder
	toastLayout.Parent = toasts
	refs.toasts = toasts

	-- Announcement banner (top-centre, above toasts)
	local announceFrame = Instance.new("Frame")
	announceFrame.Name = "Announce"
	announceFrame.Size = UDim2.fromOffset(560, 52)
	announceFrame.AnchorPoint = Vector2.new(0.5, 0)
	announceFrame.Position = UDim2.new(0.5, 0, 0, 12)
	announceFrame.BackgroundColor3 = Color3.fromRGB(40, 30, 70)
	announceFrame.Visible = false
	announceFrame.Parent = gui
	corner(announceFrame, 12)
	refs.announceFrame = announceFrame
	refs.announce = label(announceFrame, "", 22)
	refs.announce.Size = UDim2.fromScale(1, 1)
	refs.announce.TextXAlignment = Enum.TextXAlignment.Center
	refs.announce.TextScaled = true
	local annSizer = Instance.new("UITextSizeConstraint")
	annSizer.MaxTextSize = 22
	annSizer.Parent = refs.announce

	-- Lock countdown ticks locally between server pushes
	RunService.Heartbeat:Connect(function()
		HUD.RefreshLock()
	end)
end

function HUD.RefreshLock()
	if not state or not refs.lock then
		return
	end
	local now = workspace:GetServerTimeNow()
	if state.lockedUntil > now then
		refs.lock.Text = "🔒 LOCKED " .. math.ceil(state.lockedUntil - now) .. "s"
		refs.lock.TextColor3 = Color3.fromRGB(255, 120, 120)
	elseif state.lockCooldownUntil > now then
		refs.lock.Text = "Slam ready in " .. math.ceil(state.lockCooldownUntil - now) .. "s"
		refs.lock.TextColor3 = Color3.fromRGB(200, 200, 220)
	else
		refs.lock.Text = "Drawer open - Slam button locks it"
		refs.lock.TextColor3 = Color3.fromRGB(180, 190, 220)
	end
end

local function slotRow(index: number, view)
	local row = Instance.new("Frame")
	row.Name = "Slot" .. index
	row.Size = UDim2.new(1, 0, 0, 44)
	row.BackgroundColor3 = Color3.fromRGB(45, 42, 62)
	row.LayoutOrder = index
	corner(row, 8)
	local num = label(row, tostring(index), 16, Color3.fromRGB(150, 150, 170), FONT_BODY)
	num.Position = UDim2.fromOffset(8, 0)
	num.Size = UDim2.fromOffset(22, 44)
	if view then
		local tier = RarityConfig.Tiers[view.rarity]
		local m = MutationConfig.Table[view.mutation]
		local name = label(row, view.name, 16, tier and tier.color or Color3.new(1, 1, 1))
		name.Position = UDim2.fromOffset(32, 2)
		name.Size = UDim2.new(1, -110, 0, 22)
		name.TextTruncate = Enum.TextTruncate.AtEnd
		local subText = Util.SideLabel(view.side)
		if m and m.display ~= "" then
			subText ..= " • " .. m.display
		end
		if view.perfect then
			subText ..= " • PERFECT PAIR"
		elseif view.paired then
			subText ..= " • PAIRED"
		end
		local sub = label(row, subText, 13, if view.paired then Color3.fromRGB(120, 255, 160) else Color3.fromRGB(190, 190, 210), FONT_BODY)
		sub.Position = UDim2.fromOffset(32, 24)
		sub.Size = UDim2.new(1, -110, 0, 18)
		sub.TextTruncate = Enum.TextTruncate.AtEnd
		local income = label(row, "$" .. Util.FormatRate(view.income) .. "/s", 15, COLOR_CASH, FONT_BODY)
		income.AnchorPoint = Vector2.new(1, 0)
		income.Position = UDim2.new(1, -8, 0, 0)
		income.Size = UDim2.fromOffset(76, 44)
		income.TextXAlignment = Enum.TextXAlignment.Right
	else
		local empty = label(row, "empty", 15, Color3.fromRGB(120, 120, 140), FONT_BODY)
		empty.Position = UDim2.fromOffset(32, 0)
		empty.Size = UDim2.new(1, -40, 1, 0)
	end
	return row
end

function HUD.SetState(newState)
	state = newState
	if not refs.cash then
		return
	end
	refs.cash.Text = "$" .. Util.FormatCash(state.cash)
	refs.rate.Text = "+$" .. Util.FormatRate(state.rate) .. "/s"
	refs.waiting.Text = "$" .. Util.FormatCash(math.floor(state.uncollected)) .. " waiting on your Collect pad"
	HUD.RefreshLock()

	local filled = 0
	for _ in pairs(state.slots) do
		filled += 1
	end
	refs.drawerTitle.Text = "YOUR DRAWER " .. filled .. "/" .. state.slotCount
	local list = refs.drawerList
	for _, child in ipairs(list:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	for i = 1, state.slotCount do
		slotRow(i, state.slots[i]).Parent = list
	end
	HUD.SetCarry(state.carrying)
end

function HUD.SetCarry(view)
	if not refs.carryFrame then
		return
	end
	if view then
		local tier = RarityConfig.Tiers[view.rarity]
		refs.carryFrame.Visible = true
		refs.carryFrame.BackgroundColor3 = tier and tier.color:Lerp(Color3.new(0, 0, 0), 0.45) or Color3.fromRGB(200, 60, 80)
		refs.carry.Text = "🧦 Carrying " .. view.name .. " - run to YOUR drawer to keep it!"
	else
		refs.carryFrame.Visible = false
	end
end

function HUD.Toast(text: string, kind: string?)
	if not refs.toasts then
		return
	end
	local colors = {
		good = Color3.fromRGB(40, 120, 70),
		bad = Color3.fromRGB(150, 50, 60),
		info = Color3.fromRGB(50, 60, 100),
	}
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(440, 40)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundColor3 = colors[kind or "info"] or colors.info
	frame.BackgroundTransparency = 0.1
	frame.LayoutOrder = math.floor(os.clock() * 1000)
	corner(frame, 10)
	local t = label(frame, text, 18, nil, FONT_BODY)
	t.Size = UDim2.new(1, -20, 0, 40)
	t.Position = UDim2.fromOffset(10, 0)
	t.TextXAlignment = Enum.TextXAlignment.Center
	t.TextWrapped = true
	frame.Parent = refs.toasts
	-- keep at most 4
	local shown = {}
	for _, child in ipairs(refs.toasts:GetChildren()) do
		if child:IsA("Frame") then
			table.insert(shown, child)
		end
	end
	table.sort(shown, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	while #shown > 4 do
		local oldest = table.remove(shown, 1)
		if oldest then
			oldest:Destroy()
		end
	end
	task.delay(3.2, function()
		if frame.Parent then
			TweenService:Create(frame, TweenInfo.new(0.4), { BackgroundTransparency = 1 }):Play()
			TweenService:Create(t, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
			task.wait(0.45)
			frame:Destroy()
		end
	end)
end

local announceToken = 0
function HUD.Announce(text: string, color: Color3?)
	if not refs.announceFrame then
		return
	end
	announceToken += 1
	local token = announceToken
	refs.announce.Text = text
	refs.announce.TextColor3 = color or Color3.new(1, 1, 1)
	refs.announceFrame.Visible = true
	task.delay(5, function()
		if token == announceToken then
			refs.announceFrame.Visible = false
		end
	end)
end

return HUD
