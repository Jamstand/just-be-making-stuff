--[[
    Short messages (purchases, errors, level ups, party news): dark
    cut-corner chips with a coloured bar by kind and Bangers text, stacked
    at the top centre of SkybrawlToasts (DisplayOrder 50, DeviceSafeInsets,
    kept below the Roblox top bar and the queue banner, and below a party
    invite prompt while one is open, so a toast never covers its text and
    countdown). Each chip fades as a whole inside a CanvasGroup, so the cut
    panel's pieces never show seams.

    Shown in every phase except the title screen: toasts fired while the
    phase is "Title" wait and show once the menu opens.
]]

local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")

local UIKit = require(script.Parent.UIKit)
local Layout = require(script.Parent.Layout)
local ClientState = require(script.Parent.Parent.ClientState)

local T = UIKit.Theme
local make = UIKit.make

local Toasts = {}

local KIND_COLORS = {
	info = T.XP,
	good = T.Good,
	warn = T.Warning,
	error = T.Danger,
}
local TEXT_SIZE = 30 -- design px, Bangers
local SHOW_SECONDS = 3.2
local FADE_SECONDS = 0.3
local MAX_SHOWN = 4
local BASE = UDim2.fromScale(0.5, 0.11) -- below the queue banner (y 0.024 - 0.094)
local PROMPT_NAME = "InvitePrompt" -- PartyBar's card in SkybrawlPrompts (same safe-area canvas)
local PROMPT_GAP = 10 -- design px

local holder = nil
local queued = {}
local order = 0

local function fade(group, to)
	local tween = TweenService:Create(group, TweenInfo.new(FADE_SECONDS), { GroupTransparency = to })
	tween:Play()
	return tween
end

local function show(text, kind)
	if ClientState.phase == "Title" then
		table.insert(queued, { text, kind })
		return
	end
	if not holder or type(text) ~= "string" or text == "" then
		return
	end
	-- oldest first out when the stack is full
	local shown = {}
	for _, child in holder:GetChildren() do
		if child:IsA("CanvasGroup") then
			table.insert(shown, child)
		end
	end
	table.sort(shown, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	for i = 1, #shown - MAX_SHOWN + 1 do
		shown[i]:Destroy()
	end

	local width = math.max(200, holder.AbsoluteSize.X)
	local border = math.max(1, Layout.px(2))
	local padX, padY = Layout.px(22), Layout.px(12)
	local barWidth = math.max(3, Layout.px(8))
	local textSize = math.min(100, Layout.px(TEXT_SIZE))
	local innerWidth = width - 2 * border - barWidth - 2 * padX
	local bounds = TextService:GetTextSize(text, textSize, T.HeadFont, Vector2.new(innerWidth, 10000))
	local height = math.ceil(bounds.Y) + 2 * padY + 2 * border

	order += 1
	local group = make("CanvasGroup", {
		Name = "Toast",
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		Size = UDim2.new(1, 0, 0, height),
		LayoutOrder = order,
		Parent = holder,
	})
	-- inset by the border, which a cut panel draws outside itself (the group would clip it)
	local _, body = UIKit.cutPanel({
		parent = group,
		cut = 14,
		fill = T.Panel,
		border = T.Stroke,
		position = UDim2.fromOffset(border, border),
		size = UDim2.new(1, -2 * border, 1, -2 * border),
	})
	make("Frame", {
		Name = "Bar",
		BackgroundColor3 = KIND_COLORS[kind] or T.XP,
		BorderSizePixel = 0,
		Size = UDim2.new(0, barWidth, 1, 0),
		ZIndex = body.ZIndex + 1,
		Parent = body,
	})
	local label = make("TextLabel", {
		Name = "Text",
		BackgroundTransparency = 1,
		Text = text,
		Font = T.HeadFont,
		TextColor3 = T.Text,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(barWidth + padX, 0),
		Size = UDim2.new(1, -(barWidth + 2 * padX), 1, 0),
		ZIndex = body.ZIndex + 1,
		Parent = body,
	})
	Layout.bindText(label, TEXT_SIZE)
	fade(group, 0)
	task.delay(SHOW_SECONDS, function()
		if group.Parent then
			fade(group, 1).Completed:Wait()
			group:Destroy()
		end
	end)
end

local function flush()
	local pending = queued
	queued = {}
	for _, toast in pending do
		show(toast[1], toast[2])
	end
end

function Toasts.init()
	local gui = Layout.screenGui("SkybrawlToasts", 50, "Safe")
	holder = make("Frame", {
		Name = "Holder",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromScale(if Layout.mode() == "Phone" then 0.62 else 0.4, 0.6),
		Parent = gui,
	})
	Layout.bindListPadding(
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = holder,
		}),
		6
	)
	-- below the queue banner and clear of the Roblox top bar; below an open invite prompt
	local prompts = UIKit.promptsGui()
	local promptConns = {}
	local function place()
		local prompt = prompts:FindFirstChild(PROMPT_NAME)
		local base = BASE
		if prompt and prompt:IsA("GuiObject") and prompt.Visible then
			local bottom = prompt.AbsolutePosition.Y + prompt.AbsoluteSize.Y - prompts.AbsolutePosition.Y
			base = UDim2.new(0.5, 0, 0, math.max(bottom + Layout.px(PROMPT_GAP), 0))
		end
		Layout.clearTop(holder, base)
	end
	local function watchPrompts()
		for _, conn in promptConns do
			conn:Disconnect()
		end
		table.clear(promptConns)
		local prompt = prompts:FindFirstChild(PROMPT_NAME)
		if prompt and prompt:IsA("GuiObject") then
			for _, property in { "AbsolutePosition", "AbsoluteSize", "Visible" } do
				table.insert(promptConns, prompt:GetPropertyChangedSignal(property):Connect(place))
			end
		end
		place()
	end
	prompts.ChildAdded:Connect(watchPrompts)
	prompts.ChildRemoved:Connect(watchPrompts)
	watchPrompts()
	Layout.Changed:Connect(function(mode)
		holder.Size = UDim2.fromScale(if mode == "Phone" then 0.62 else 0.4, 0.6)
	end)
	ClientState.Toast:Connect(show)
	ClientState.PhaseChanged:Connect(function(phase)
		if phase ~= "Title" then
			flush()
		end
	end)
end

return Toasts
