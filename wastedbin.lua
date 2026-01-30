-- wastedbin
-- Tech-styled UI panel, smooth drag/resize, search, toasts, themes (HSV picker), configs.
-- Module version: require() / loadstring(HttpGet()) friendly.

-- Version - v1.2 >rename

-- ChangeLog:

-- v1.2:
-- + renamed sript (old Syndrome)

-- v1.1:
-- + Added new selector (multi/single)
-- + Bugs fixed

local wastedbin = {}
wastedbin.__index = wastedbin

--========================
-- Defaults
--========================
local DEFAULT_CONFIG = {
	Theme = {
		AccentH = 0.60, AccentS = 0.90, AccentV = 1.00,
		Tone = 0.20,
		TintStrength = 0.10,
		PanelAlpha = 0.07,
		StrokeAlpha = 0.32,
		TextBright = 0.06,
		ReduceMotion = false,

		ShadowEnabled = true,
		ShadowTransparency = 0.58,
	},
	Keybinds = {
		ToggleUI = "End",
	},
	Options = {
		EnableToasts = true,
		ToastDuration = 3.0,
		-- Cursor behavior while UI is open:
		--   "Inherit"  = do not touch MouseBehavior / MouseIconEnabled (best for most games)
		--   "Unlock"   = force MouseBehavior.Default + MouseIconEnabled=true
		--   "LockCenter" = force MouseBehavior.LockCenter + MouseIconEnabled=false
		CursorMode = "Inherit",
	},
	__meta = { version = 1010 } -- bumped (dropdown + fixes)
}

--========================
-- Constructor
--========================
function wastedbin.new(options)
	local self = setmetatable({}, wastedbin)
	self.Options = options or {}
	if self.Options.AutoDemo == nil then
		self.Options.AutoDemo = true
	end
	self._connections = {}
	self._unloaded = false
	self._built = false
	return self
end

--========================
-- Internals: connection tracking
--========================
function wastedbin:_track(conn)
	table.insert(self._connections, conn)
	return conn
end

function wastedbin:_disconnectAll()
	for _, c in ipairs(self._connections) do
		pcall(function()
			if typeof(c) == "RBXScriptConnection" then c:Disconnect() end
		end)
	end
	table.clear(self._connections)
end

function wastedbin:_guard()
	return self._unloaded
end

--========================
-- Public: Unload
--========================
function wastedbin:Unload()
	if self._unloaded then return end
	self._unloaded = true
	self:_disconnectAll()
	pcall(function() if self._mainGui then self._mainGui:Destroy() end end)
	pcall(function() if self._toastGui then self._toastGui:Destroy() end end)
	self._mainGui = nil
	self._toastGui = nil
end

-- Basic visibility helpers (will be overridden in CreateWindow with cursor unlock)
function wastedbin:SetVisible(v)
	if self._mainGui then
		self._mainGui.Enabled = (v == true)
	end
end

function wastedbin:ToggleVisible()
	if self._mainGui then
		self._mainGui.Enabled = not self._mainGui.Enabled
	end
end

--========================
-- CreateWindow
--========================
function wastedbin:CreateWindow()
	if self._built then return self end
	self._built = true

	local Players = game:GetService("Players")
	local TweenService = game:GetService("TweenService")
	local UserInputService = game:GetService("UserInputService")
	local HttpService = game:GetService("HttpService")
	local RunService = game:GetService("RunService")
	local CoreGui = game:GetService("CoreGui")

	local player = Players.LocalPlayer
	if not player then
		error("wastedbin ui must be used from a LocalScript (client). Players.LocalPlayer is nil.")
	end
	local playerGui = player:WaitForChild("PlayerGui")

	-- ensure camera is ready (fix: CurrentCamera can be nil on very early init)
	local cam = workspace.CurrentCamera
	if not cam then
		cam = workspace:WaitForChild("Camera", 5)
	end
	cam = cam or workspace.CurrentCamera

	--==================================================
	-- Utils
	local ThemeStrokes = {}
	local function regThemeStroke(stroke)
		if stroke then
			ThemeStrokes[#ThemeStrokes+1] = { stroke = stroke, base = stroke.Transparency }
		end
	end

	local function mk(className, props)
		local obj = Instance.new(className)
		if props then
			for k, v in pairs(props) do
				obj[k] = v
			end
		end
		if className == 'UIStroke' and not (props and props.__NoThemeStroke) then
			regThemeStroke(obj)
		end
		return obj
	end

	local function clamp(x, a, b)
		if x < a then return a end
		if x > b then return b end
		return x
	end

	local function lower(s) return string.lower(s or "") end

	local function safeJsonDecode(str)
		if typeof(str) ~= "string" or #str == 0 then return nil end
		local ok, res = pcall(function() return HttpService:JSONDecode(str) end)
		if ok then return res end
		return nil
	end

	local function safeJsonEncode(tbl)
		local ok, res = pcall(function() return HttpService:JSONEncode(tbl) end)
		if ok then return res end
		return "{}"
	end

	local function deepCopy(t)
		local out = {}
		for k, v in pairs(t) do
			if type(v) == "table" then out[k] = deepCopy(v) else out[k] = v end
		end
		return out
	end

	local function mergeDefaults(dst, defaults)
		for k, v in pairs(defaults) do
			if type(v) == "table" then
				if type(dst[k]) ~= "table" then dst[k] = {} end
				mergeDefaults(dst[k], v)
			else
				if dst[k] == nil then dst[k] = v end
			end
		end
	end

	local function keyCodeFromString(s)
		if typeof(s) ~= "string" then return nil end
		local ok, kc = pcall(function() return Enum.KeyCode[s] end)
		if ok then return kc end
		return nil
	end

	local function track(conn) return self:_track(conn) end
	local function guard() return self:_guard() end

	--==================================================
	-- Config (executor file save if available; fallback PlayerGui attribute)
	--==================================================
	local CONFIG_ATTR = "wastedbin_Config_JSON"

	local function _hasFileIO()
		return (type(isfile) == "function") and (type(readfile) == "function") and (type(writefile) == "function")
	end

	local function _getConfigPath()
		local fileName = (type(self.Options.ConfigFile) == "string" and self.Options.ConfigFile) or "wastedbinConfig.json"
		local folder = (type(self.Options.ConfigFolder) == "string" and self.Options.ConfigFolder) or ""
		if folder ~= "" then
			folder = folder:gsub("\\", "/"):gsub("/+$", "")
			return folder .. "/" .. fileName
		end
		return fileName
	end

	local function _ensureFolderForPath(p)
		if type(p) ~= "string" then return end
		local dir = p:match("^(.*)/[^/]+$")
		if not dir or dir == "" then return end
		if type(isfolder) == "function" and type(makefolder) == "function" then
			local ok, exists = pcall(function() return isfolder(dir) end)
			if ok and not exists then
				pcall(function() makefolder(dir) end)
			end
		elseif type(makefolder) == "function" then
			pcall(function() makefolder(dir) end)
		end
	end

	local Config = deepCopy(DEFAULT_CONFIG)

	local function _loadConfigFromFile(pathOverride)
		if not _hasFileIO() then return nil end
		local p = pathOverride or _getConfigPath()
		local okExists, exists = pcall(function() return isfile(p) end)
		if not okExists or not exists then return nil end
		local okRead, raw = pcall(function() return readfile(p) end)
		if not okRead then return nil end
		return safeJsonDecode(raw)
	end

	local function _loadConfigFromAttribute()
		return safeJsonDecode(playerGui:GetAttribute(CONFIG_ATTR))
	end

	do
		local loaded = _loadConfigFromFile()
		if type(loaded) == "table" then
			Config = loaded
		else
			local attrLoaded = _loadConfigFromAttribute()
			if type(attrLoaded) == "table" then
				Config = attrLoaded
			end
		end
	end

	mergeDefaults(Config, deepCopy(DEFAULT_CONFIG))
	self.Config = Config

	--==================================================
	-- Theme stroke math
	--==================================================
	local function strokeDelta()
		return clamp(tonumber(Config.Theme.StrokeAlpha) or DEFAULT_CONFIG.Theme.StrokeAlpha, 0, 1)
			- clamp(DEFAULT_CONFIG.Theme.StrokeAlpha, 0, 1)
	end

	local function StrokeT(designTransparency)
		return clamp((tonumber(designTransparency) or 0) + strokeDelta(), 0, 1)
	end

	local function saveClientConfig(pathOverride)
		if guard() then return false end
		local encoded = safeJsonEncode(Config)

		if _hasFileIO() then
			local p = pathOverride or _getConfigPath()
			_ensureFolderForPath(p)
			local ok = pcall(function() writefile(p, encoded) end)
			return ok
		end

		playerGui:SetAttribute(CONFIG_ATTR, encoded)
		return true
	end

	function self:SaveConfig(pathOverride)
		return saveClientConfig(pathOverride)
	end

	function self:LoadConfig(pathOverride)
		if guard() then return false end

		local loaded = _loadConfigFromFile(pathOverride)
		if type(loaded) ~= "table" then
			loaded = _loadConfigFromAttribute()
		end
		if type(loaded) ~= "table" then
			return false
		end

		Config = loaded
		mergeDefaults(Config, deepCopy(DEFAULT_CONFIG))
		self.Config = Config

		if type(self.ApplyTheme) == "function" then
			pcall(function() self:ApplyTheme() end)
		end
		return true
	end

	--==================================================
	-- Theme helpers
	--==================================================
	local function accentColor()
		local th = Config.Theme
		return Color3.fromHSV(th.AccentH, th.AccentS, th.AccentV)
	end

	local function panelBg()
		local th = Config.Theme
		local tone = clamp(th.Tone, 0, 1)
		local a = Color3.fromRGB(14, 14, 17)
		local b = Color3.fromRGB(36, 36, 44)
		local base = a:Lerp(b, 1 - tone)
		local k = clamp(th.TintStrength, 0, 0.25)
		return base:Lerp(accentColor(), k)
	end

	local function panelInsetBg()
		return panelBg():Lerp(Color3.fromRGB(0,0,0), 0.20)
	end

	local function TI(dur, style, dir)
		style = style or Enum.EasingStyle.Quint
		dir = dir or Enum.EasingDirection.Out
		if Config.Theme.ReduceMotion then dur = 0 end
		return TweenInfo.new(dur, style, dir)
	end

	local function tween(inst, ti, props)
		local t = TweenService:Create(inst, ti, props)
		t:Play()
		return t
	end

	--==================================================
	-- ScreenGuis (CoreGui per your requirement)
	--==================================================
	local mainGui = mk("ScreenGui", {
		Name = "wastedbin_Main",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = CoreGui,
	})

	local toastGui = mk("ScreenGui", {
		Name = "wastedbin_Toasts",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = CoreGui,
	})

	self._mainGui = mainGui
	self._toastGui = toastGui

	--==================================================
	-- Root
	--==================================================
	local rootW, rootH = 690, 450
	local vp = (cam and cam.ViewportSize) or Vector2.new(1280, 720)
	local rootX = math.floor((vp.X - rootW) / 2)
	local rootY = math.floor((vp.Y - rootH) / 2)

	local function shadowOffsetA() return 10 end
	local function shadowOffsetB() return 17 end

	local shadowA = mk("Frame", {
		Parent = mainGui,
		AnchorPoint = Vector2.new(0,0),
		Position = UDim2.fromOffset(rootX - shadowOffsetA(), rootY - shadowOffsetA()),
		Size = UDim2.fromOffset(rootW + 20, rootH + 20),
		BackgroundColor3 = Color3.fromRGB(0,0,0),
		BackgroundTransparency = 0.58,
		BorderSizePixel = 0,
	})
	shadowA.ZIndex = 1

	local shadowB = mk("Frame", {
		Parent = mainGui,
		AnchorPoint = Vector2.new(0,0),
		Position = UDim2.fromOffset(rootX - shadowOffsetB(), rootY - shadowOffsetB()),
		Size = UDim2.fromOffset(rootW + 34, rootH + 34),
		BackgroundColor3 = Color3.fromRGB(0,0,0),
		BackgroundTransparency = 0.75,
		BorderSizePixel = 0,
	})
	shadowB.ZIndex = 1

	local root = mk("Frame", {
		Parent = mainGui,
		AnchorPoint = Vector2.new(0,0),
		Position = UDim2.fromOffset(rootX, rootY),
		Size = UDim2.fromOffset(rootW, rootH),
		BackgroundColor3 = panelBg(),
		BackgroundTransparency = clamp(Config.Theme.PanelAlpha, 0, 0.35),
		BorderSizePixel = 0,
		ClipsDescendants = true,
	})
	root.ZIndex = 2

	mk("UIStroke", {
		Parent = root,
		Thickness = 1,
		Transparency = clamp(DEFAULT_CONFIG.Theme.StrokeAlpha, 0, 1),
		Color = Color3.fromRGB(255,255,255),
	})

	local rootGrad = mk("UIGradient", {
		Parent = root,
		Rotation = 30,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255,255,255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(180,180,190)),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.80),
			NumberSequenceKeypoint.new(1, 1.00),
		}),
	})

	local inset = mk("Frame", {
		Parent = root,
		Position = UDim2.fromOffset(1,1),
		Size = UDim2.new(1, -2, 1, -2),
		BackgroundColor3 = panelInsetBg(),
		BackgroundTransparency = 0.0,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	})
	inset.ZIndex = 3

	mk("UIStroke", {
		Parent = inset,
		Thickness = 1,
		Transparency = clamp(DEFAULT_CONFIG.Theme.StrokeAlpha + 0.18, 0, 1),
		Color = Color3.fromRGB(255,255,255),
	})

	mk("UIGradient", {
		Parent = inset,
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.10),
			NumberSequenceKeypoint.new(1, 0.35),
		}),
	})

	-- bottom brackets
	local brackets = {}
	do
		local function mkBracket(pos, flipRight)
			local br = mk("Frame", {
				Parent = inset,
				Position = pos,
				Size = UDim2.fromOffset(18,18),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
			})
			br.ZIndex = 6

			local A
			if flipRight then
				A = mk("Frame", { Parent = br, Position = UDim2.new(1,-2,0,0), Size = UDim2.fromOffset(2,18), BackgroundColor3 = accentColor(), BorderSizePixel=0, BackgroundTransparency=0.10 })
			else
				A = mk("Frame", { Parent = br, Size = UDim2.fromOffset(2,18), BackgroundColor3 = accentColor(), BorderSizePixel=0, BackgroundTransparency=0.10 })
			end
			local B = mk("Frame", { Parent = br, Position = UDim2.new(0,0,1,-2), Size = UDim2.fromOffset(18,2), BackgroundColor3 = accentColor(), BorderSizePixel=0, BackgroundTransparency=0.10 })
			A.ZIndex, B.ZIndex = 7, 7
			table.insert(brackets, {A=A, B=B})
		end

		mkBracket(UDim2.new(0, 8, 1, -26), false)
		mkBracket(UDim2.new(1,-26,1,-26), true)
	end

	--==================================================
	-- Title bar
	--==================================================
	local titleBar = mk("Frame", {
		Parent = inset,
		Position = UDim2.fromOffset(0,0),
		Size = UDim2.new(1,0,0,34),
		BackgroundColor3 = Color3.fromRGB(0,0,0),
		BackgroundTransparency = 0.58,
		BorderSizePixel = 0,
	})
	titleBar.ZIndex = 10

	mk("UIGradient", {
		Parent = titleBar,
		Rotation = 0,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.20),
			NumberSequenceKeypoint.new(1, 0.60),
		})
	})

	local titleText = mk("TextLabel", {
		Parent = titleBar,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 7),
		Size = UDim2.new(1, -160, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "wastedbin recode // Premium // V1",
		Font = Enum.Font.GothamSemibold,
		TextSize = 14,
		TextColor3 = Color3.fromRGB(245,245,255),
		TextTransparency = clamp(Config.Theme.TextBright, 0, 0.35),
	})
	titleText.ZIndex = 11

	local btnMin = mk("TextButton", {
		Parent = titleBar,
		Position = UDim2.new(1, -74, 0, 6),
		Size = UDim2.fromOffset(28, 22),
		Text = "–",
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		TextColor3 = Color3.fromRGB(245,245,255),
		TextTransparency = 0.18,
		BackgroundColor3 = Color3.fromRGB(0,0,0),
		BackgroundTransparency = 0.52,
		BorderSizePixel = 0,
		AutoButtonColor = false,
	})
	btnMin.ZIndex = 12
	local btnMinStroke = mk("UIStroke", { Parent = btnMin, Thickness = 1, Transparency = 0.78, Color = Color3.fromRGB(255,255,255) })

	local btnClose = mk("TextButton", {
		Parent = titleBar,
		Position = UDim2.new(1, -40, 0, 6),
		Size = UDim2.fromOffset(28, 22),
		Text = "x",
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = Color3.fromRGB(255,255,255),
		TextTransparency = 0.18,
		BackgroundColor3 = Color3.fromRGB(90, 20, 25),
		BackgroundTransparency = 0.22,
		BorderSizePixel = 0,
		AutoButtonColor = false,
	})
	btnClose.ZIndex = 12
	local btnCloseStroke = mk("UIStroke", { Parent = btnClose, Thickness = 1, Transparency = 0.72, Color = Color3.fromRGB(255,255,255) })

	-- scan line
	local scan = mk("Frame", {
		Parent = inset,
		Position = UDim2.fromOffset(0, 34),
		Size = UDim2.new(1,0,0,1),
		BackgroundColor3 = accentColor(),
		BorderSizePixel = 0,
	})
	scan.ZIndex = 10

	local scanGrad = mk("UIGradient", {
		Parent = scan,
		Rotation = 0,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(1,1,1)),
			ColorSequenceKeypoint.new(1, Color3.new(1,1,1)),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1.00),
			NumberSequenceKeypoint.new(0.45, 0.35),
			NumberSequenceKeypoint.new(0.55, 0.35),
			NumberSequenceKeypoint.new(1, 1.00),
		})
	})

	--==================================================
	-- Tab bar + search
	--==================================================
	local tabBar = mk("Frame", {
		Parent = inset,
		Position = UDim2.fromOffset(10, 42),
		Size = UDim2.new(1, -20, 0, 32),
		BackgroundColor3 = Color3.fromRGB(0,0,0),
		BackgroundTransparency = 0.68,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	})
	tabBar.ZIndex = 10
	mk("UIStroke", { Parent = tabBar, Thickness = 1, Transparency = 0.78, Color = Color3.fromRGB(255,255,255) })
	mk("UIGradient", { Parent = tabBar, Rotation = 0, Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.20),
		NumberSequenceKeypoint.new(1, 0.55),
	})})

	local searchWrap = mk("Frame", {
		Parent = tabBar,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.fromOffset(200, 20),
		BackgroundColor3 = Color3.fromRGB(0,0,0),
		BackgroundTransparency = 0.58,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	})
	searchWrap.ZIndex = 12
	local searchStroke = mk("UIStroke", { Parent = searchWrap, Thickness = 1, Transparency = 0.80, Color = Color3.fromRGB(255,255,255) })
	mk("UIGradient", { Parent = searchWrap, Rotation = 0, Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0,  0.25),
		NumberSequenceKeypoint.new(1,  0.60),
	})})

	local searchBox = mk("TextBox", {
		Parent = searchWrap,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(6, 0),
		Size = UDim2.new(1, -30, 1, 0),
		ClearTextOnFocus = false,
		Text = "",
		PlaceholderText = "search...",
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(240,240,255),
		PlaceholderColor3 = Color3.fromRGB(190,190,210),
	})
	searchBox.ZIndex = 13

	local clearBtn = mk("TextButton", {
		Parent = searchWrap,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -2, 0.5, 0),
		Size = UDim2.fromOffset(20, 18),
		BackgroundColor3 = Color3.fromRGB(0,0,0),
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Text = "x",
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = Color3.fromRGB(240,240,255),
		TextTransparency = 0.25,
		AutoButtonColor = false,
	})
	clearBtn.ZIndex = 14
	local clearStroke = mk("UIStroke", { Parent = clearBtn, Thickness = 1, Transparency = 0.82, Color = Color3.fromRGB(255,255,255) })

	local tabsScroll = mk("ScrollingFrame", {
		Parent = tabBar,
		Position = UDim2.fromOffset(6, 3),
		Size = UDim2.new(1, -220, 1, -6),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ElasticBehavior = Enum.ElasticBehavior.Never,
		ScrollBarThickness = 0,
		ScrollBarImageTransparency = 1,
		CanvasSize = UDim2.fromOffset(0, 0),
	})
	tabsScroll.ZIndex = 12

	local tabsHolder = mk("Frame", { Parent = tabsScroll, Size = UDim2.fromScale(1,1), BackgroundTransparency = 1 })
	tabsHolder.ZIndex = 13

	mk("UIPadding", { Parent = tabsHolder, PaddingLeft = UDim.new(0, 2), PaddingTop = UDim.new(0, 1), PaddingBottom = UDim.new(0, 1) })
	local tabsLayout = mk("UIListLayout", { Parent = tabsHolder, FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder })

	local function updateTabsCanvas()
		if guard() then return end
		RunService.Heartbeat:Wait()
		tabsScroll.CanvasSize = UDim2.fromOffset(tabsLayout.AbsoluteContentSize.X + 8, 0)
	end
	track(tabsLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateTabsCanvas))

	--==================================================
	-- Content area
	--==================================================
	local content = mk("Frame", {
		Parent = inset,
		Position = UDim2.fromOffset(10, 78),
		Size = UDim2.new(1, -20, 1, -88),
		BackgroundColor3 = Color3.fromRGB(0,0,0),
		BackgroundTransparency = 0.74,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	})
	content.ZIndex = 10
	local contentStroke = mk("UIStroke", { Parent = content, Thickness = 1, Transparency = 0.78, Color = Color3.fromRGB(255,255,255) })
	mk("UIGradient", { Parent = content, Rotation = 90, Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.30),
		NumberSequenceKeypoint.new(1, 0.55),
	})})

	-- resize handle
	local resizeHandle = mk("Frame", {
		Parent = inset,
		Size = UDim2.fromOffset(18, 18),
		Position = UDim2.new(1, -26, 1, -26),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	})
	resizeHandle.ZIndex = 30

	local resizeGlyph = mk("TextLabel", {
		Parent = resizeHandle,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1,1),
		Text = "///",
		Font = Enum.Font.GothamBold,
		TextSize = 10,
		TextColor3 = Color3.fromRGB(240,240,255),
		TextTransparency = 0.42,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextYAlignment = Enum.TextYAlignment.Bottom,
	})
	resizeGlyph.ZIndex = 31

	--==================================================
	-- Toasts
	--==================================================
	local toastHost = mk("Frame", { Parent = toastGui, Size = UDim2.fromScale(1,1), BackgroundTransparency = 1 })
	toastHost.ZIndex = 100
	mk("UIPadding", { Parent = toastHost, PaddingRight = UDim.new(0, 16), PaddingBottom = UDim.new(0, 16) })
	mk("UIListLayout", { Parent = toastHost, HorizontalAlignment = Enum.HorizontalAlignment.Right, VerticalAlignment = Enum.VerticalAlignment.Bottom, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder })

	local function Notify(head, msg, duration)
		if guard() then return end
		if not Config.Options.EnableToasts then return end

		local configured = tonumber(Config.Options.ToastDuration) or 3.0
		if duration == nil then duration = configured end
		duration = clamp(tonumber(duration) or configured, 0.8, 12) -- FIX: robust duration parsing

		local ac = accentColor()

		local card = mk("Frame", {
			Parent = toastHost,
			Size = UDim2.fromOffset(320, 66),
			BackgroundColor3 = panelInsetBg(),
			BackgroundTransparency = 0.06,
			BorderSizePixel = 0,
			ClipsDescendants = true,
		})
		card.ZIndex = 101

		local cStroke = mk("UIStroke", { Parent = card, Thickness = 1, Transparency = 0.58, Color = Color3.fromRGB(255,255,255) })
		mk("UIGradient", { Parent = card, Rotation = 90, Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.22),
			NumberSequenceKeypoint.new(1, 0.55),
		})})

		local timerLine = mk("Frame", {
			Parent = card,
			Position = UDim2.new(0,0,1,-2),
			Size = UDim2.new(1,0,0,2),
			BackgroundColor3 = ac,
			BackgroundTransparency = 0.10,
			BorderSizePixel = 0,
		})
		timerLine.ZIndex = 102

		mk("UIGradient", {
			Parent = timerLine,
			Rotation = 0,
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1.00),
				NumberSequenceKeypoint.new(0.50, 0.20),
				NumberSequenceKeypoint.new(1.00, 1.00),
			})
		})

		local h = mk("TextLabel", {
			Parent = card,
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(10, 8),
			Size = UDim2.new(1, -40, 0, 16),
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = head or "notice",
			Font = Enum.Font.GothamSemibold,
			TextSize = 13,
			TextColor3 = Color3.fromRGB(245,245,255),
			TextTransparency = 0.10,
		})
		h.ZIndex = 103

		local b = mk("TextLabel", {
			Parent = card,
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(10, 26),
			Size = UDim2.new(1, -40, 0, 34),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
			Text = msg or "",
			Font = Enum.Font.Gotham,
			TextSize = 12,
			TextColor3 = Color3.fromRGB(220,220,235),
			TextTransparency = 0.28,
		})
		b.ZIndex = 103

		local x = mk("TextButton", {
			Parent = card,
			AnchorPoint = Vector2.new(1,0),
			Position = UDim2.new(1, -8, 0, 8),
			Size = UDim2.fromOffset(20, 20),
			Text = "x",
			Font = Enum.Font.GothamBold,
			TextSize = 12,
			TextColor3 = Color3.fromRGB(240,240,255),
			TextTransparency = 0.28,
			BackgroundColor3 = Color3.fromRGB(0,0,0),
			BackgroundTransparency = 0.62,
			BorderSizePixel = 0,
			AutoButtonColor = false,
		})
		x.ZIndex = 104
		local xStroke = mk("UIStroke", { Parent = x, Thickness = 1, Transparency = 0.82, Color = Color3.fromRGB(255,255,255) })

		-- animate in
		card.AnchorPoint = Vector2.new(1,1)
		card.Position = UDim2.new(1, 380, 1, -16)
		card.BackgroundTransparency = 0.30
		cStroke.Transparency = StrokeT(0.90)
		h.TextTransparency = 0.35
		b.TextTransparency = 0.55
		tween(card, TI(0.26), { Position = UDim2.new(1, -16, 1, -16), BackgroundTransparency = 0.06 })
		tween(cStroke, TI(0.26), { Transparency = StrokeT(0.58) })
		tween(h, TI(0.20), { TextTransparency = 0.10 })
		tween(b, TI(0.20), { TextTransparency = 0.28 })

		local timerTween = TweenService:Create(timerLine, TweenInfo.new(Config.Theme.ReduceMotion and 0 or duration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out), {
			Size = UDim2.new(0, 0, 0, 2)
		})
		timerTween:Play()

		local dead = false
		local function kill()
			if dead then return end
			dead = true
			pcall(function() timerTween:Cancel() end)
			tween(card, TI(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {
				Position = UDim2.new(1, 400, 1, -16),
				BackgroundTransparency = 0.38
			})
			tween(cStroke, TI(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.In), { Transparency = 1 })
			task.delay(0.2, function()
				if card then card:Destroy() end
			end)
		end

		track(x.MouseEnter:Connect(function()
			tween(x, TI(0.10), { BackgroundTransparency = 0.45 })
			tween(xStroke, TI(0.10), { Transparency = StrokeT(0.70) })
		end))
		track(x.MouseLeave:Connect(function()
			tween(x, TI(0.12), { BackgroundTransparency = 0.62 })
			tween(xStroke, TI(0.12), { Transparency = StrokeT(0.82) })
		end))

		track(x.Activated:Connect(kill))
		task.delay(duration, kill)
	end

	self.Notify = function(_, head, msg, duration)
		Notify(head, msg, duration)
	end

	--==================================================
	-- Theme registry
	--==================================================
	local AccentFills = {}
	local AccentStrokes = {}
	local ActiveTabGradients = {}

	local function regFill(inst) table.insert(AccentFills, inst) end
	local function regStroke(st) table.insert(AccentStrokes, st) end

	local function updateActiveTabGradientColors()
		local ac = accentColor()
		for _, g in ipairs(ActiveTabGradients) do
			if g and g.Parent then
				g.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0.00, ac:Lerp(Color3.new(1,1,1), 0.35)),
					ColorSequenceKeypoint.new(0.33, ac),
					ColorSequenceKeypoint.new(0.66, ac:Lerp(Color3.new(0,0,0), 0.20)),
					ColorSequenceKeypoint.new(1.00, ac:Lerp(Color3.new(1,1,1), 0.35)),
				})
			end
		end
	end

	-- forward-declared (created later)
	local closeCard, closeLine

	local function applyTheme()
		local ac = accentColor()

		root.BackgroundColor3 = panelBg()
		root.BackgroundTransparency = clamp(Config.Theme.PanelAlpha, 0, 0.35)
		inset.BackgroundColor3 = panelInsetBg()
		scan.BackgroundColor3 = ac

		titleText.TextTransparency = clamp(Config.Theme.TextBright, 0, 0.35)

		-- Theme-wide stroke alpha (affects all UIStroke created by this library)
		local deltaStroke = clamp(Config.Theme.StrokeAlpha, 0, 1) - clamp(DEFAULT_CONFIG.Theme.StrokeAlpha, 0, 1)
		for _, rec in ipairs(ThemeStrokes) do
			local st = rec.stroke
			if st and st.Parent then
				st.Transparency = clamp((rec.base or 0) + deltaStroke, 0, 1)
			end
		end

		for _, b in ipairs(brackets) do
			if b.A then b.A.BackgroundColor3 = ac end
			if b.B then b.B.BackgroundColor3 = ac end
		end
		for _, f in ipairs(AccentFills) do
			if f and f.Parent and f:IsA("Frame") then
				f.BackgroundColor3 = ac
			end
		end
		for _, s in ipairs(AccentStrokes) do
			if s and s.Parent then s.Color = ac end
		end

		if closeCard then closeCard.BackgroundColor3 = panelInsetBg() end
		if closeLine then closeLine.BackgroundColor3 = ac end

		btnClose.BackgroundColor3 = ac:Lerp(Color3.fromRGB(0,0,0), 0.60)

		-- Shadows
		local enabled = (Config.Theme.ShadowEnabled == true)
		local tA = clamp(tonumber(Config.Theme.ShadowTransparency) or 0.58, 0, 1)
		local tB = clamp(tA + 0.17, 0, 1)

		if enabled then
			shadowA.Visible = true
			shadowB.Visible = true
			shadowA.BackgroundTransparency = tA
			shadowB.BackgroundTransparency = tB
		else
			shadowA.Visible = false
			shadowB.Visible = false
		end

		updateActiveTabGradientColors()
	end

	function self:ApplyTheme()
		if guard() then return end
		applyTheme()
	end

	--==================================================
	-- Pages / Tabs / Search
	--==================================================
	local Tabs = {}
	local ActiveTab = nil
	local PageIndex = {} -- page -> {group,leftCol,rightCol,sections={} }

	local function createPage()
		local page = mk("ScrollingFrame", {
			Parent = content,
			Position = UDim2.fromOffset(0,0),
			Size = UDim2.fromScale(1,1),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 5,
			ScrollBarImageTransparency = 0.55,
			Visible = false,
			CanvasSize = UDim2.fromOffset(0,0),
		})
		page.ZIndex = 20

		local group = mk("Frame", {
			Parent = page,
			Size = UDim2.fromScale(1,1),
			BackgroundTransparency = 1,
		})
		group.ZIndex = 21

		mk("UIPadding", {
			Parent = group,
			PaddingTop = UDim.new(0, 10),
			PaddingBottom = UDim.new(0, 10),
			PaddingLeft = UDim.new(0, 10),
			PaddingRight = UDim.new(0, 10),
		})

		local columns = mk("Frame", { Parent = group, Size = UDim2.fromScale(1,1), BackgroundTransparency = 1 })
		columns.ZIndex = 22

		local leftCol = mk("Frame", { Parent = columns, Size = UDim2.new(0.46, -6, 1, 0), BackgroundTransparency = 1 })
		leftCol.ZIndex = 22

		local rightCol = mk("Frame", { Parent = columns, Position = UDim2.new(0.54, 6, 0, 0), Size = UDim2.new(0.46, -6, 1, 0), BackgroundTransparency = 1 })
		rightCol.ZIndex = 22

		local lLayout = mk("UIListLayout", { Parent = leftCol, Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder })
		local rLayout = mk("UIListLayout", { Parent = rightCol, Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder })

		local function updateCanvas()
			if guard() then return end
			RunService.Heartbeat:Wait()
			local h = math.max(lLayout.AbsoluteContentSize.Y, rLayout.AbsoluteContentSize.Y)
			page.CanvasSize = UDim2.fromOffset(0, h + 30)
		end
		track(lLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateCanvas))
		track(rLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateCanvas))

		local empty = mk("TextLabel", {
			Name = "EmptyState",
			Parent = group,
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(10, 10),
			Size = UDim2.new(1, -20, 0, 24),
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "no results",
			Font = Enum.Font.GothamMedium,
			TextSize = 13,
			TextColor3 = Color3.fromRGB(220,220,235),
			TextTransparency = 0.55,
			Visible = false,
		})
		empty.ZIndex = 23

		PageIndex[page] = { group = group, leftCol = leftCol, rightCol = rightCol, sections = {} }
		return page
	end

	local function makeTabButton(text, order)
		local b = mk("TextButton", {
			Parent = tabsHolder,
			Size = UDim2.fromOffset(86, 22),
			BackgroundColor3 = Color3.fromRGB(0,0,0),
			BackgroundTransparency = 0.62,
			BorderSizePixel = 0,
			Text = text,
			Font = Enum.Font.GothamSemibold,
			TextSize = 12,
			TextColor3 = Color3.fromRGB(240,240,255),
			TextTransparency = 0.15,
			AutoButtonColor = false,
			LayoutOrder = order,
		})
		b.ZIndex = 30

		local st = mk("UIStroke", { Parent = b, Thickness = 1, Transparency = 0.82, Color = Color3.fromRGB(255,255,255) })
		mk("UIGradient", { Parent = b, Rotation = 0, Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.22),
			NumberSequenceKeypoint.new(1, 0.60),
		})})

		local outline = mk("Frame", { Parent = b, BackgroundTransparency = 1, Size = UDim2.new(1,0,1,0), Visible = false })
		outline.ZIndex = 32
		outline.Position = UDim2.fromOffset(1, 1)        -- FIX: avoid stroke clipping
		outline.Size = UDim2.new(1, -2, 1, -2)
		outline.ClipsDescendants = false

		local outlineStroke = mk("UIStroke", { Parent = outline, Thickness = 1, Transparency = 0.10, Color = Color3.new(1,1,1) })
		pcall(function() outlineStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border end)

		local outlineGrad = mk("UIGradient", { Parent = outlineStroke, Rotation = 0 })
		table.insert(ActiveTabGradients, outlineGrad)

		track(b.MouseEnter:Connect(function()
			tween(b, TI(0.10), { BackgroundTransparency = 0.44 })
			tween(st, TI(0.10), { Transparency = StrokeT(0.68) })
		end))
		track(b.MouseLeave:Connect(function()
			local on = ActiveTab and ActiveTab.btn == b
			tween(b, TI(0.12), { BackgroundTransparency = on and 0.34 or 0.62 })
			tween(st, TI(0.12), { Transparency = on and StrokeT(0.58) or StrokeT(0.82) })
		end))

		return b, st, outline, outlineGrad
	end

	local function registerSection(page, secObj)
		if not page or not PageIndex[page] then return end
		if type(secObj) ~= "table" then return end
		secObj.frame = secObj.frame or secObj.holder
		secObj.holder = secObj.holder or secObj.frame
		secObj.title = secObj.title or "section"
		secObj.subtitle = secObj.subtitle or ""
		secObj.items = (type(secObj.items) == "table") and secObj.items or {}
		secObj.openState = (secObj.openState ~= nil) and secObj.openState or true
		secObj.setOpen = (type(secObj.setOpen) == "function") and secObj.setOpen or function() end
		secObj.side = (secObj.side == "right") and "right" or "left"
		table.insert(PageIndex[page].sections, secObj)
	end

	local function applySearchToPage(page, query)
		local pi = (PageIndex and PageIndex[page]) or nil
		if not pi or type(pi.sections) ~= "table" then return end

		local q = string.lower(tostring(query or ""))
		local anyVisible, anyLeft, anyRight = false, false, false

		for _, sec in pairs(pi.sections) do
			if type(sec) == "table" then
				sec.openState = (sec.openState ~= nil) and sec.openState or true
				sec.items = (type(sec.items) == "table") and sec.items or {}
				sec.title = tostring(sec.title or "")
				sec.subtitle = tostring(sec.subtitle or "")
				sec.side = (sec.side == "right") and "right" or "left"
				if type(sec.setOpen) ~= "function" then
					sec.setOpen = function() end
				end

				local sectionTitle = string.lower(sec.title .. " " .. sec.subtitle)
				local titleHit = (q ~= "") and (string.find(sectionTitle, q, 1, true) ~= nil)

				local itemHit = false
				for _, it in ipairs(sec.items) do
					if type(it) == "table" and it.root and it.root.Parent then
						local hay = tostring(it.text or "")
						local ok = (q == "") or (string.find(hay, q, 1, true) ~= nil)
						it.root.Visible = ok
						if ok then itemHit = true end
					end
				end

				local showSection = (q == "") or titleHit or itemHit
				if sec.frame and sec.frame.Parent then
					sec.frame.Visible = showSection
				end

				if showSection then
					anyVisible = true
					if sec.side == "right" then anyRight = true else anyLeft = true end
				end

				if q ~= "" then
					if sec.lastOpenBeforeSearch == nil then
						sec.lastOpenBeforeSearch = (sec.openState ~= false)
					end
					local wantOpen = (titleHit or itemHit)
					pcall(function() sec.setOpen(wantOpen, true) end)
					sec.openState = wantOpen
				else
					if sec.lastOpenBeforeSearch ~= nil then
						local restore = sec.lastOpenBeforeSearch
						sec.lastOpenBeforeSearch = nil
						pcall(function() sec.setOpen(restore, true) end)
						sec.openState = restore
					end
				end
			end
		end

		if q ~= "" then
			if pi.leftCol then pi.leftCol.Visible = anyLeft end
			if pi.rightCol then pi.rightCol.Visible = anyRight end
		else
			if pi.leftCol then pi.leftCol.Visible = true end
			if pi.rightCol then pi.rightCol.Visible = true end
		end

		local empty = pi.group and pi.group:FindFirstChild("EmptyState")
		if empty and empty:IsA("TextLabel") then
			empty.Visible = (q ~= "") and (not anyVisible)
		end
	end

	local function setActiveTab(tab)
		if ActiveTab == tab then return end
		if ActiveTab then
			ActiveTab.page.Visible = false
			if ActiveTab.outline then ActiveTab.outline.Visible = false end
		end
		ActiveTab = tab
		tab.page.Visible = true
		if tab.outline then tab.outline.Visible = true end

		local g = PageIndex[tab.page].group
		if g and g:IsA("CanvasGroup") then
			g.GroupTransparency = 1
			tween(g, TI(0.16), { GroupTransparency = 0 })
		end

		for _, t in ipairs(Tabs) do
			local on = (t == tab)
			tween(t.btn, TI(0.12), { BackgroundTransparency = on and 0.34 or 0.62 })
			tween(t.stroke, TI(0.12), { Transparency = on and StrokeT(0.58) or StrokeT(0.82) })
		end

		applySearchToPage(tab.page, searchBox.Text)
	end

	local function createTab(label)
		local page = createPage()
		local btn, st, outline, outlineGrad = makeTabButton(label, #Tabs + 1)
		local tab = { label = label, page = page, btn = btn, stroke = st, outline = outline, outlineGrad = outlineGrad }
		table.insert(Tabs, tab)
		track(btn.Activated:Connect(function()
			setActiveTab(tab)
		end))
		return tab
	end

	-- Search events
	track(searchBox.Focused:Connect(function() tween(searchStroke, TI(0.10), { Transparency = StrokeT(0.55) }) end))
	track(searchBox.FocusLost:Connect(function() tween(searchStroke, TI(0.12), { Transparency = StrokeT(0.80) }) end))
	track(searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		if ActiveTab then applySearchToPage(ActiveTab.page, searchBox.Text) end
	end))
	track(clearBtn.MouseEnter:Connect(function()
		tween(clearBtn, TI(0.10), { BackgroundTransparency = 0.30 })
		tween(clearStroke, TI(0.10), { Transparency = StrokeT(0.70) })
	end))
	track(clearBtn.MouseLeave:Connect(function()
		tween(clearBtn, TI(0.12), { BackgroundTransparency = 0.45 })
		tween(clearStroke, TI(0.12), { Transparency = StrokeT(0.82) })
	end))
	track(clearBtn.Activated:Connect(function()
		searchBox.Text = ""
		if ActiveTab then applySearchToPage(ActiveTab.page, "") end
	end))

	--==================================================
	-- Controls / Sections
	--==================================================
	local function makeGroupBox(parentCol, title, subtitle, side)
		local box = mk("Frame", {
			Parent = parentCol,
			Size = UDim2.new(1, 0, 0, subtitle and 68 or 54),
			BackgroundColor3 = Color3.fromRGB(0,0,0),
			BackgroundTransparency = 0.70,
			BorderSizePixel = 0,
			ClipsDescendants = true,
		})
		box.ZIndex = 50

		local st = mk("UIStroke", { Parent = box, Thickness = 1, Transparency = 0.80, Color = Color3.fromRGB(255,255,255) })
		mk("UIGradient", { Parent = box, Rotation = 90, Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.24),
			NumberSequenceKeypoint.new(1, 0.60),
		})})

		local top = mk("Frame", {
			Parent = box,
			Position = UDim2.fromOffset(0,0),
			Size = UDim2.new(1,0,0,1),
			BackgroundColor3 = accentColor(),
			BorderSizePixel = 0,
			BackgroundTransparency = 0.10,
		})
		top.ZIndex = 52
		regFill(top)

		local headerBtn = mk("TextButton", {
			Parent = box,
			Position = UDim2.fromOffset(0,0),
			Size = UDim2.new(1,0,0, subtitle and 36 or 30),
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
		})
		headerBtn.ZIndex = 53

		local titleLbl = mk("TextLabel", {
			Parent = box,
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(10, 7),
			Size = UDim2.new(1, -46, 0, 16),
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = title,
			Font = Enum.Font.GothamSemibold,
			TextSize = 12,
			TextColor3 = Color3.fromRGB(245,245,255),
			TextTransparency = 0.12,
		})
		titleLbl.ZIndex = 54

		if subtitle then
			local sub = mk("TextLabel", {
				Parent = box,
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(10, 22),
				Size = UDim2.new(1, -46, 0, 14),
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = subtitle,
				Font = Enum.Font.Gotham,
				TextSize = 11,
				TextColor3 = Color3.fromRGB(210,210,225),
				TextTransparency = 0.55,
			})
			sub.ZIndex = 54
		end

		local caret = mk("TextLabel", {
			Parent = box,
			BackgroundTransparency = 1,
			Position = UDim2.new(1, -26, 0, 7),
			Size = UDim2.fromOffset(16, 16),
			Text = "v",
			Font = Enum.Font.GothamBold,
			TextSize = 12,
			TextColor3 = Color3.fromRGB(245,245,255),
			TextTransparency = 0.35,
		})
		caret.ZIndex = 54

		local holder = mk("Frame", {
			Parent = box,
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(8, subtitle and 40 or 34),
			Size = UDim2.new(1, -16, 0, 0),
			ClipsDescendants = true,
		})
		holder.ZIndex = 53

		local layout = mk("UIListLayout", { Parent = holder, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder })

		local open = true
		local headerH = subtitle and 68 or 54
		local contentH = 0

		local EXTRA_H = 4
		local function recalc()
			if guard() then return end
			RunService.Heartbeat:Wait()
			contentH = layout.AbsoluteContentSize.Y
			if open then
				holder.Size = UDim2.new(1, -16, 0, contentH + EXTRA_H)
				box.Size = UDim2.new(1, 0, 0, headerH + contentH + 10 + EXTRA_H)
			else
				holder.Size = UDim2.new(1, -16, 0, 0)
				box.Size = UDim2.new(1, 0, 0, headerH)
			end
		end
		track(layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(recalc))

		local function setOpen(v, instant)
			open = v
			local dur = instant and 0 or 0.18
			if open then
				caret.Text = "v"
				if dur == 0 then
					holder.Size = UDim2.new(1, -16, 0, contentH + EXTRA_H)
					box.Size = UDim2.new(1, 0, 0, headerH + contentH + 10 + EXTRA_H)
				else
					tween(holder, TI(dur), { Size = UDim2.new(1, -16, 0, contentH + EXTRA_H) })
					tween(box, TI(dur), { Size = UDim2.new(1, 0, 0, headerH + contentH + 10 + EXTRA_H) })
				end
			else
				caret.Text = ">"
				if dur == 0 then
					holder.Size = UDim2.new(1, -16, 0, 0)
					box.Size = UDim2.new(1, 0, 0, headerH)
				else
					tween(holder, TI(dur), { Size = UDim2.new(1, -16, 0, 0) })
					tween(box, TI(dur), { Size = UDim2.new(1, 0, 0, headerH) })
				end
			end
		end

		track(headerBtn.MouseEnter:Connect(function() tween(st, TI(0.12), { Transparency = StrokeT(0.66) }) end))
		track(headerBtn.MouseLeave:Connect(function() tween(st, TI(0.14), { Transparency = StrokeT(0.80) }) end))
		track(headerBtn.Activated:Connect(function() setOpen(not open, false) end))

		recalc()
		setOpen(true, true)

		local sec = {
			frame = box,
			holder = holder,
			title = title,
			subtitle = subtitle or "",
			side = side or "left",
			items = {},
			openState = true,
			lastOpenBeforeSearch = nil,
			setOpen = function(v, instant)
				setOpen(v, instant)
				sec.openState = v
			end
		}

		local function registerItem(rootObj, keywords)
			table.insert(sec.items, { root = rootObj, text = lower(keywords) })
		end

		local api = {}
		api._sec = sec

		-- numeric helpers
		local function fmtNumber(v, decimals)
			v = tonumber(v) or 0
			decimals = tonumber(decimals)
			if decimals == nil then decimals = 2 end
			if decimals <= 0 then
				return tostring(math.floor(v + 0.5))
			end
			if math.abs(v - math.floor(v)) < 1e-9 then
				return tostring(math.floor(v))
			end
			return string.format("%." .. tostring(decimals) .. "f", v)
		end

		local function isNumericText(t)
			t = tostring(t or "")
			return (t ~= "") and (t:find("[^0-9%+%-%.,]", 1) == nil)
		end

		local function parseNumberText(t)
			if not isNumericText(t) then return nil end
			t = tostring(t):gsub(",", ".")
			local n = tonumber(t)
			return n
		end

		local function makeValueChip(parent, size, pos)
			local chip = mk("Frame", {
				Parent = parent,
				Size = size,
				Position = pos,
				BackgroundColor3 = Color3.fromRGB(0,0,0),
				BackgroundTransparency = 0.68,
				BorderSizePixel = 0,
				ClipsDescendants = false,
			})
			chip.ZIndex = 61
			mk("UIStroke", { Parent = chip, Thickness = 1, Transparency = 0.84, Color = Color3.fromRGB(255,255,255) })
			mk("UIGradient", { Parent = chip, Rotation = 0, Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.25),
				NumberSequenceKeypoint.new(1, 0.62),
			})})
			return chip
		end

		function api:AddButton(labelText, callback)
			local b = mk("TextButton", {
				Parent = holder,
				Size = UDim2.new(1, 0, 0, 24),
				BackgroundColor3 = Color3.fromRGB(0,0,0),
				BackgroundTransparency = 0.58,
				BorderSizePixel = 0,
				Text = labelText,
				Font = Enum.Font.GothamSemibold,
				TextSize = 12,
				TextColor3 = Color3.fromRGB(240,240,255),
				TextTransparency = 0.15,
				AutoButtonColor = false,
			})
			b.ZIndex = 60
			local bst = mk("UIStroke", { Parent = b, Thickness = 1, Transparency = 0.82, Color = Color3.fromRGB(255,255,255) })
			mk("UIGradient", { Parent = b, Rotation = 0, Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.24),
				NumberSequenceKeypoint.new(1, 0.62),
			})})

			local tick = mk("Frame", {
				Parent = b,
				Position = UDim2.fromOffset(0,0),
				Size = UDim2.fromOffset(1, 24),
				BackgroundColor3 = accentColor(),
				BackgroundTransparency = 0.25,
				BorderSizePixel = 0,
			})
			tick.ZIndex = 61
			regFill(tick)

			track(b.MouseEnter:Connect(function()
				tween(b, TI(0.10), { BackgroundTransparency = 0.42 })
				tween(bst, TI(0.10), { Transparency = StrokeT(0.68) })
			end))
			track(b.MouseLeave:Connect(function()
				tween(b, TI(0.12), { BackgroundTransparency = 0.58 })
				tween(bst, TI(0.12), { Transparency = StrokeT(0.82) })
			end))

			track(b.Activated:Connect(function()
				tween(b, TI(0.08), { BackgroundTransparency = 0.34 })
				task.delay(Config.Theme.ReduceMotion and 0 or 0.06, function()
					if b and b.Parent then tween(b, TI(0.12), { BackgroundTransparency = 0.42 }) end
				end)
				if callback then callback() end
			end))

			registerItem(b, labelText)
			return b
		end

		function api:AddToggle(labelText, default, callback)
			local row = mk("Frame", { Parent = holder, Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1 })
			row.ZIndex = 60

			local boxBtn = mk("TextButton", {
				Parent = row,
				Position = UDim2.fromOffset(0, 2),
				Size = UDim2.fromOffset(18, 18),
				BackgroundColor3 = Color3.fromRGB(0,0,0),
				BackgroundTransparency = 0.55,
				BorderSizePixel = 0,
				Text = "",
				AutoButtonColor = false,
			})
			boxBtn.ZIndex = 61
			local bbSt = mk("UIStroke", { Parent = boxBtn, Thickness = 1, Transparency = 0.80, Color = Color3.fromRGB(255,255,255) })

			local check = mk("Frame", {
				Parent = boxBtn,
				Position = UDim2.fromOffset(3,3),
				Size = UDim2.fromOffset(12,12),
				BackgroundColor3 = accentColor(),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
			})
			check.ZIndex = 62
			regFill(check)

			local text = mk("TextLabel", {
				Parent = row,
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(24, 0),
				Size = UDim2.new(1, -24, 1, 0),
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = labelText,
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextColor3 = Color3.fromRGB(240,240,255),
				TextTransparency = 0.15,
			})
			text.ZIndex = 61

			local state = (default == true)
			local function setState(v, instant)
				state = (v == true)
				if instant then
					check.BackgroundTransparency = state and 0.0 or 1.0
				else
					tween(check, TI(0.14), { BackgroundTransparency = state and 0.0 or 1.0 })
					tween(bbSt, TI(0.14), { Transparency = state and StrokeT(0.62) or StrokeT(0.80) })
				end
				if callback then callback(state) end
			end

			track(boxBtn.MouseEnter:Connect(function() tween(boxBtn, TI(0.10), { BackgroundTransparency = 0.42 }) end))
			track(boxBtn.MouseLeave:Connect(function() tween(boxBtn, TI(0.12), { BackgroundTransparency = 0.55 }) end))
			track(boxBtn.Activated:Connect(function() setState(not state, false) end))

			registerItem(row, labelText)
			setState(state, true)
			return { Get = function() return state end, Set = function(v) setState(v, false) end }
		end

		function api:AddSlider(labelText, minV, maxV, defaultV, callback, opts)
			opts = type(opts) == "table" and opts or {}
			local decimals = tonumber(opts.Decimals)
			if decimals == nil then decimals = 2 end

			local row = mk("Frame", { Parent = holder, Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1 })
			row.ZIndex = 60

			local valueBoxW = tonumber(opts.ValueBoxWidth) or 36

			local lbl = mk("TextLabel", {
				Parent = row,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, -(valueBoxW + 12), 0, 16),
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = labelText,
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextColor3 = Color3.fromRGB(240,240,255),
				TextTransparency = 0.15,
			})
			lbl.ZIndex = 61

			local chip = makeValueChip(row, UDim2.fromOffset(valueBoxW, 16), UDim2.new(1, -(valueBoxW + 2), 0, 21))

			local val = mk("TextBox", {
				Parent = chip,
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(4, 0),
				Size = UDim2.new(1, -8, 1, 0),
				ClearTextOnFocus = false,
				Text = tostring(defaultV),
				Font = Enum.Font.GothamMedium,
				TextSize = 10,
				TextXAlignment = Enum.TextXAlignment.Right,
				TextColor3 = Color3.fromRGB(210,210,225),
				TextTransparency = 0.30,
			})
			val.ZIndex = 62

			local trackF = mk("Frame", {
				Parent = row,
				Position = UDim2.fromOffset(0, 22),
				Size = UDim2.new(1, -(valueBoxW + 12), 0, 14),
				BackgroundColor3 = Color3.fromRGB(0,0,0),
				BackgroundTransparency = 0.62,
				BorderSizePixel = 0,
				ClipsDescendants = true,
			})
			trackF.ZIndex = 60
			local trSt = mk("UIStroke", { Parent = trackF, Thickness = 1, Transparency = 0.82, Color = Color3.fromRGB(255,255,255) })
			mk("UIGradient", { Parent = trackF, Rotation = 0, Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.24),
				NumberSequenceKeypoint.new(1, 0.62),
			})})

			local fill = mk("Frame", {
				Parent = trackF,
				Size = UDim2.fromScale(0, 1),
				BackgroundColor3 = accentColor(),
				BackgroundTransparency = 0.18,
				BorderSizePixel = 0,
			})
			fill.ZIndex = 61
			regFill(fill)

			local knob = mk("Frame", {
				Parent = trackF,
				Size = UDim2.fromOffset(10, 14),
				Position = UDim2.new(0, -5, 0, 0),
				BackgroundColor3 = Color3.fromRGB(255,255,255),
				BackgroundTransparency = 0.78,
				BorderSizePixel = 0,
			})
			knob.ZIndex = 62
			local kst = mk("UIStroke", { Parent = knob, Thickness = 1, Transparency = 0.55, Color = accentColor() })
			regStroke(kst)

			local dragging = false
			local editingVal = false
			local current = tonumber(defaultV) or minV

			local targetA = 0
			local displayA = 0
			local smoothConn = nil

			local function applyAlpha(a)
				a = clamp(a, 0, 1)
				fill.Size = UDim2.new(a, 0, 1, 0)
				knob.Position = UDim2.new(a, -5, 0, 0)
			end

			local function ensureSmooth()
				if smoothConn then return end
				smoothConn = track(RunService.RenderStepped:Connect(function(dt)
					if guard() then return end
					local k = 1 - math.pow(0.001, dt * 10)
					displayA = displayA + (targetA - displayA) * k
					applyAlpha(displayA)
					if math.abs(targetA - displayA) < 0.001 then
						displayA = targetA
						applyAlpha(displayA)
						if smoothConn then smoothConn:Disconnect() end
						smoothConn = nil
					end
				end))
			end

			local function setValue(v, instant)
				current = clamp(tonumber(v) or minV, minV, maxV)
				local denom = (maxV - minV)
				if denom == 0 then denom = 1 end
				local a = (current - minV) / denom
				if a ~= a then a = 0 end
				targetA = clamp(a, 0, 1)
				if instant then
					displayA = targetA
					applyAlpha(displayA)
				else
					ensureSmooth()
				end

				if not editingVal then
					val.Text = fmtNumber(current, decimals)
				end
				if callback then callback(current) end
			end

			local function updateFromX(x, instant)
				local w = trackF.AbsoluteSize.X
				if w <= 0 then return end -- FIX: avoid division by 0 during resize/layout
				local rel = (x - trackF.AbsolutePosition.X) / w
				rel = clamp(rel, 0, 1)
				setValue(minV + rel * (maxV - minV), instant)
			end

			track(trackF.MouseEnter:Connect(function() tween(trSt, TI(0.10), { Transparency = StrokeT(0.70) }) end))
			track(trackF.MouseLeave:Connect(function() tween(trSt, TI(0.12), { Transparency = StrokeT(0.82) }) end))

			track(trackF.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					dragging = true
					updateFromX(input.Position.X, false)
				end
			end))
			track(UserInputService.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
			end))
			track(UserInputService.InputChanged:Connect(function(input)
				if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
					updateFromX(input.Position.X, false)
				end
			end))

			track(chip.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					val.Text = ""
					val:CaptureFocus()
				end
			end))

			track(val.Focused:Connect(function()
				editingVal = true
				val.Text = ""
				tween(chip, TI(0.10), { BackgroundTransparency = 0.55 })
			end))

			track(val:GetPropertyChangedSignal("Text"):Connect(function()
				if not editingVal then return end
				local n = parseNumberText(val.Text)
				if n == nil then return end
				setValue(n, false)
			end))

			track(val.FocusLost:Connect(function()
				editingVal = false
				tween(chip, TI(0.12), { BackgroundTransparency = 0.68 })
				local n = parseNumberText(val.Text)
				if n == nil then
					setValue(current, true)
				else
					setValue(n, false)
				end
			end))

			registerItem(row, labelText)
			setValue(defaultV, true)
			return { Get = function() return current end, Set = function(v) setValue(v, false) end }
		end

		--==================================================
		-- NEW: Dropdown / Multi-select
		--==================================================
		-- labelText: left label
		-- options: array of strings
		-- default: string or {strings} or nil
		-- callback: function(selectedList, selectedSet, live)
		-- opts = { Multi = true/false, Placeholder = "choose...", CloseOnSelect = true/false }
		function api:AddSelect(labelText, options, default, callback, opts)
			opts = type(opts) == "table" and opts or {}
			local multi = (opts.Multi == true)
			local placeholder = tostring(opts.Placeholder or "choose...")
			local closeOnSelect = (opts.CloseOnSelect ~= false) -- default true

			options = type(options) == "table" and options or {}

			local wrap = mk("Frame", {
				Parent = holder,
				Size = UDim2.new(1, 0, 0, 26),
				BackgroundTransparency = 1,
				ClipsDescendants = true,
			})
			wrap.ZIndex = 60

			local lbl = mk("TextLabel", {
				Parent = wrap,
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(0, 0),
				Size = UDim2.new(1, -170, 0, 16),
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = tostring(labelText or "select"),
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextColor3 = Color3.fromRGB(240,240,255),
				TextTransparency = 0.15,
			})
			lbl.ZIndex = 61

			local btn = mk("TextButton", {
				Parent = wrap,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 0),
				Size = UDim2.fromOffset(160, 22),
				BackgroundColor3 = Color3.fromRGB(0,0,0),
				BackgroundTransparency = 0.58,
				BorderSizePixel = 0,
				Text = placeholder,
				Font = Enum.Font.GothamMedium,
				TextSize = 12,
				TextColor3 = Color3.fromRGB(240,240,255),
				TextTransparency = 0.15,
				AutoButtonColor = false,
			})
			btn.ZIndex = 61
			local btnSt = mk("UIStroke", { Parent = btn, Thickness = 1, Transparency = 0.82, Color = Color3.fromRGB(255,255,255) })
			mk("UIGradient", { Parent = btn, Rotation = 0, Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.24),
				NumberSequenceKeypoint.new(1, 0.62),
			})})

			local caret = mk("TextLabel", {
				Parent = btn,
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -6, 0.5, 0),
				Size = UDim2.fromOffset(14, 14),
				Text = "v",
				Font = Enum.Font.GothamBold,
				TextSize = 12,
				TextColor3 = Color3.fromRGB(240,240,255),
				TextTransparency = 0.25,
			})
			caret.ZIndex = 62

			local drop = mk("Frame", {
				Parent = wrap,
				Position = UDim2.fromOffset(0, 24),
				Size = UDim2.new(1, 0, 0, 0),
				BackgroundColor3 = Color3.fromRGB(0,0,0),
				BackgroundTransparency = 0.68,
				BorderSizePixel = 0,
				ClipsDescendants = true,
			})
			drop.ZIndex = 60
			local dropSt = mk("UIStroke", { Parent = drop, Thickness = 1, Transparency = 0.84, Color = Color3.fromRGB(255,255,255) })
			mk("UIGradient", { Parent = drop, Rotation = 90, Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.22),
				NumberSequenceKeypoint.new(1, 0.60),
			})})

			mk("UIPadding", { Parent = drop, PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) })
			local list = mk("Frame", { Parent = drop, Size = UDim2.fromScale(1,1), BackgroundTransparency = 1 })
			list.ZIndex = 61
			local listLayout = mk("UIListLayout", { Parent = list, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder })

			local open = false
			local contentH = 0

			local selectedSet = {}
			local function toSelectedList()
				local out = {}
				for _, name in ipairs(options) do
					if selectedSet[name] then table.insert(out, name) end
				end
				return out
			end

			local function setButtonText()
				local sel = toSelectedList()
				if #sel == 0 then
					btn.Text = placeholder
				else
					btn.Text = table.concat(sel, ", ")
				end
			end

			local function fire(live)
				if callback then
					local sel = toSelectedList()
					callback(sel, selectedSet, live == true)
				end
			end

			local function recalc()
				if guard() then return end
				RunService.Heartbeat:Wait()
				contentH = listLayout.AbsoluteContentSize.Y
				if open then
					local h = contentH + 16
					drop.Size = UDim2.new(1, 0, 0, h)
					wrap.Size = UDim2.new(1, 0, 0, 26 + h)
				else
					drop.Size = UDim2.new(1, 0, 0, 0)
					wrap.Size = UDim2.new(1, 0, 0, 26)
				end
			end
			track(listLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(recalc))

			local function setOpen(v, instant)
				open = (v == true)
				local dur = instant and 0 or 0.16
				caret.Text = open and "v" or ">"
				local h = contentH + 16
				if open then
					if dur == 0 then
						drop.Size = UDim2.new(1, 0, 0, h)
						wrap.Size = UDim2.new(1, 0, 0, 26 + h)
					else
						tween(drop, TI(dur), { Size = UDim2.new(1, 0, 0, h) })
						tween(wrap, TI(dur), { Size = UDim2.new(1, 0, 0, 26 + h) })
					end
				else
					if dur == 0 then
						drop.Size = UDim2.new(1, 0, 0, 0)
						wrap.Size = UDim2.new(1, 0, 0, 26)
					else
						tween(drop, TI(dur), { Size = UDim2.new(1, 0, 0, 0) })
						tween(wrap, TI(dur), { Size = UDim2.new(1, 0, 0, 26) })
					end
				end
			end

			local optionButtons = {}

			local function setSelected(name, v, live)
				if not multi then
					for k in pairs(selectedSet) do selectedSet[k] = nil end
					selectedSet[name] = (v == true)
				else
					selectedSet[name] = (v == true)
				end
				for _, rec in ipairs(optionButtons) do
					local on = selectedSet[rec.name] == true
					rec.check.BackgroundTransparency = on and 0.0 or 1.0
					tween(rec.stroke, TI(0.12), { Transparency = on and StrokeT(0.62) or StrokeT(0.82) })
				end
				setButtonText()
				fire(live)
			end

			for i, name in ipairs(options) do
				name = tostring(name)
				local opt = mk("TextButton", {
					Parent = list,
					Size = UDim2.new(1, 0, 0, 22),
					BackgroundColor3 = Color3.fromRGB(0,0,0),
					BackgroundTransparency = 0.58,
					BorderSizePixel = 0,
					Text = "",
					AutoButtonColor = false,
				})
				opt.ZIndex = 61

				local optSt = mk("UIStroke", { Parent = opt, Thickness = 1, Transparency = 0.82, Color = Color3.fromRGB(255,255,255) })
				mk("UIGradient", { Parent = opt, Rotation = 0, Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.24),
					NumberSequenceKeypoint.new(1, 0.62),
				})})

				local boxBtn = mk("Frame", {
					Parent = opt,
					Position = UDim2.fromOffset(6, 2),
					Size = UDim2.fromOffset(18, 18),
					BackgroundColor3 = Color3.fromRGB(0,0,0),
					BackgroundTransparency = 0.55,
					BorderSizePixel = 0,
				})
				boxBtn.ZIndex = 62
				mk("UIStroke", { Parent = boxBtn, Thickness = 1, Transparency = 0.80, Color = Color3.fromRGB(255,255,255) })

				local check = mk("Frame", {
					Parent = boxBtn,
					Position = UDim2.fromOffset(3,3),
					Size = UDim2.fromOffset(12,12),
					BackgroundColor3 = accentColor(),
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
				})
				check.ZIndex = 63
				regFill(check)

				local t = mk("TextLabel", {
					Parent = opt,
					BackgroundTransparency = 1,
					Position = UDim2.fromOffset(30, 0),
					Size = UDim2.new(1, -36, 1, 0),
					TextXAlignment = Enum.TextXAlignment.Left,
					Text = name,
					Font = Enum.Font.Gotham,
					TextSize = 12,
					TextColor3 = Color3.fromRGB(240,240,255),
					TextTransparency = 0.15,
				})
				t.ZIndex = 62

				track(opt.MouseEnter:Connect(function()
					tween(opt, TI(0.10), { BackgroundTransparency = 0.42 })
					tween(optSt, TI(0.10), { Transparency = StrokeT(0.68) })
				end))
				track(opt.MouseLeave:Connect(function()
					tween(opt, TI(0.12), { BackgroundTransparency = 0.58 })
					tween(optSt, TI(0.12), { Transparency = StrokeT(0.82) })
				end))

				track(opt.Activated:Connect(function()
					local now = not (selectedSet[name] == true)
					setSelected(name, now, true)
					if (not multi) and closeOnSelect then
						setOpen(false, false)
					end
				end))

				table.insert(optionButtons, { name = name, check = check, stroke = optSt })
			end

			track(btn.MouseEnter:Connect(function()
				tween(btn, TI(0.10), { BackgroundTransparency = 0.42 })
				tween(btnSt, TI(0.10), { Transparency = StrokeT(0.68) })
			end))
			track(btn.MouseLeave:Connect(function()
				tween(btn, TI(0.12), { BackgroundTransparency = 0.58 })
				tween(btnSt, TI(0.12), { Transparency = StrokeT(0.82) })
			end))
			track(btn.Activated:Connect(function()
				setOpen(not open, false)
			end))

			-- defaults
			do
				if type(default) == "string" then
					selectedSet[tostring(default)] = true
				elseif type(default) == "table" then
					for _, n in ipairs(default) do
						selectedSet[tostring(n)] = true
						if not multi then break end
					end
				end
				if not multi then
					-- ensure single selection only
					local found = nil
					for _, name in ipairs(options) do
						if selectedSet[name] then found = name break end
					end
					for k in pairs(selectedSet) do selectedSet[k] = nil end
					if found then selectedSet[found] = true end
				end

				for _, rec in ipairs(optionButtons) do
					local on = selectedSet[rec.name] == true
					rec.check.BackgroundTransparency = on and 0.0 or 1.0
					rec.stroke.Transparency = on and StrokeT(0.62) or StrokeT(0.82)
				end
				setButtonText()
			end

			recalc()
			setOpen(false, true)
			fire(false)

			-- searchable keywords include all options
			local keywords = tostring(labelText or "") .. " select dropdown "
			for _, n in ipairs(options) do
				keywords ..= tostring(n) .. " "
			end
			registerItem(wrap, keywords)

			return {
				Root = wrap,
				Open = function(v) setOpen(v, false) end,
				Get = function() return toSelectedList() end,
				Set = function(v)
					for k in pairs(selectedSet) do selectedSet[k] = nil end
					if type(v) == "string" then
						selectedSet[tostring(v)] = true
					elseif type(v) == "table" then
						for _, n in ipairs(v) do
							selectedSet[tostring(n)] = true
							if not multi then break end
						end
					end
					if not multi then
						local found = nil
						for _, name in ipairs(options) do
							if selectedSet[name] then found = name break end
						end
						for k in pairs(selectedSet) do selectedSet[k] = nil end
						if found then selectedSet[found] = true end
					end
					for _, rec in ipairs(optionButtons) do
						local on = selectedSet[rec.name] == true
						rec.check.BackgroundTransparency = on and 0.0 or 1.0
						rec.stroke.Transparency = on and StrokeT(0.62) or StrokeT(0.82)
					end
					setButtonText()
					fire(false)
				end,
			}
		end

		function api:AddNumberBox(labelText, minV, maxV, defaultV, callback, opts)
			opts = type(opts) == "table" and opts or {}
			local decimals = tonumber(opts.Decimals)
			if decimals == nil then decimals = 2 end
			local boxW = tonumber(opts.BoxWidth) or 70

			local row = mk("Frame", { Parent = holder, Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1 })
			row.ZIndex = 60

			local lbl = mk("TextLabel", {
				Parent = row,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, -(boxW + 12), 1, 0),
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = labelText,
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextColor3 = Color3.fromRGB(240,240,255),
				TextTransparency = 0.15,
			})
			lbl.ZIndex = 61

			local chip = makeValueChip(row, UDim2.fromOffset(boxW, 20), UDim2.new(1, -(boxW + 4), 0.5, -10))
			chip.ZIndex = 61

			local inp = mk("TextBox", {
				Parent = chip,
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(6, 1),
				Size = UDim2.new(1, -12, 1, -2),
				ClearTextOnFocus = false,
				Text = tostring(defaultV),
				Font = Enum.Font.GothamMedium,
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Right,
				TextColor3 = Color3.fromRGB(235,235,245),
				TextTransparency = 0.15,
			})
			inp.ZIndex = 62

			local editing = false
			local current = clamp(tonumber(defaultV) or minV, minV, maxV)

			local function setValue(v, silentText)
				current = clamp(tonumber(v) or minV, minV, maxV)
				if not silentText then
					inp.Text = fmtNumber(current, decimals)
				end
				if callback then callback(current) end
			end

			track(chip.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					inp.Text = ""
					inp:CaptureFocus()
				end
			end))

			track(inp.Focused:Connect(function()
				editing = true
				inp.Text = ""
				tween(chip, TI(0.10), { BackgroundTransparency = 0.55 })
			end))

			track(inp:GetPropertyChangedSignal("Text"):Connect(function()
				if not editing then return end
				local n = parseNumberText(inp.Text)
				if n == nil then return end
				setValue(n, true)
			end))

			track(inp.FocusLost:Connect(function()
				editing = false
				tween(chip, TI(0.12), { BackgroundTransparency = 0.68 })
				local n = parseNumberText(inp.Text)
				if n == nil then
					setValue(current, false)
				else
					setValue(n, false)
				end
			end))

			registerItem(row, labelText)
			setValue(defaultV, false)
			return { Get = function() return current end, Set = function(v) setValue(v, false) end }
		end

		function api:AddNumberInput(labelText, defaultV, callback, opts)
			opts = type(opts) == "table" and opts or {}
			local boxW = tonumber(opts.BoxWidth) or 150

			local row = mk("Frame", { Parent = holder, Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1 })
			row.ZIndex = 60

			local lbl = mk("TextLabel", {
				Parent = row,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, -(boxW + 12), 1, 0),
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = labelText,
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextColor3 = Color3.fromRGB(240,240,255),
				TextTransparency = 0.15,
			})
			lbl.ZIndex = 61

			local chip = makeValueChip(row, UDim2.fromOffset(boxW, 20), UDim2.new(1, -(boxW + 4), 0.5, -10))
			chip.ZIndex = 61

			local inp = mk("TextBox", {
				Parent = chip,
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(6, 1),
				Size = UDim2.new(1, -12, 1, -2),
				ClearTextOnFocus = false,
				Text = tostring(defaultV or ""),
				Font = Enum.Font.GothamMedium,
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Right,
				TextColor3 = Color3.fromRGB(235,235,245),
				TextTransparency = 0.15,
			})
			inp.ZIndex = 62

			local editing = false
			local function currentValue()
				local t = tostring(inp.Text or "")
				if t == "" then return nil end
				if t:find("[^0-9]", 1) then return nil end
				return tonumber(t)
			end

			local function fire()
				if callback then
					local v = currentValue()
					callback(inp.Text, v)
				end
			end

			track(chip.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					inp.Text = ""
					inp:CaptureFocus()
				end
			end))

			track(inp.Focused:Connect(function()
				editing = true
				inp.Text = ""
				tween(chip, TI(0.10), { BackgroundTransparency = 0.55 })
			end))

			track(inp:GetPropertyChangedSignal("Text"):Connect(function()
				if not editing then return end
				if inp.Text ~= "" and inp.Text:find("[^0-9]", 1) then return end
				fire()
			end))

			track(inp.FocusLost:Connect(function()
				editing = false
				tween(chip, TI(0.12), { BackgroundTransparency = 0.68 })
				fire()
			end))

			registerItem(row, labelText .. " input textbox")
			fire()
			return { GetText = function() return inp.Text end, SetText = function(t) inp.Text = tostring(t or "") fire() end }
		end

		function api:AddInfo(head, bodyText)
			local box2 = mk("Frame", {
				Parent = holder,
				Size = UDim2.new(1, 0, 0, 64),
				BackgroundColor3 = Color3.fromRGB(0,0,0),
				BackgroundTransparency = 0.68,
				BorderSizePixel = 0,
				ClipsDescendants = true,
			})
			box2.ZIndex = 60
			local st2 = mk("UIStroke", { Parent = box2, Thickness = 1, Transparency = 0.84, Color = Color3.fromRGB(255,255,255) })
			mk("UIGradient", { Parent = box2, Rotation = 90, Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.22),
				NumberSequenceKeypoint.new(1, 0.60),
			})})

			local bar = mk("Frame", {
				Parent = box2,
				Size = UDim2.new(0, 1, 1, 0),
				BackgroundColor3 = accentColor(),
				BackgroundTransparency = 0.25,
				BorderSizePixel = 0,
			})
			bar.ZIndex = 61
			regFill(bar)

			local h = mk("TextLabel", {
				Parent = box2,
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(8, 6),
				Size = UDim2.new(1, -16, 0, 16),
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = head,
				Font = Enum.Font.GothamSemibold,
				TextSize = 12,
				TextColor3 = Color3.fromRGB(245,245,255),
				TextTransparency = 0.12,
			})
			h.ZIndex = 61

			local b = mk("TextLabel", {
				Parent = box2,
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(8, 22),
				Size = UDim2.new(1, -16, 0, 38),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				TextWrapped = true,
				Text = bodyText,
				Font = Enum.Font.Gotham,
				TextSize = 11,
				TextColor3 = Color3.fromRGB(220,220,235),
				TextTransparency = 0.30,
			})
			b.ZIndex = 61

			track(box2.MouseEnter:Connect(function() tween(st2, TI(0.10), { Transparency = StrokeT(0.70) }) end))
			track(box2.MouseLeave:Connect(function() tween(st2, TI(0.12), { Transparency = StrokeT(0.84) }) end))

			registerItem(box2, head .. " " .. bodyText)
			return box2
		end

		-- HSV Color Picker (unchanged)
		function api:AddColorPicker(titleText, defaultColor, callback)
			-- (same implementation as your original; kept intact)
			local box = mk("Frame", {
				Parent = holder,
				Size = UDim2.new(1, 0, 0, 210),
				BackgroundColor3 = Color3.fromRGB(0,0,0),
				BackgroundTransparency = 0.70,
				BorderSizePixel = 0,
				ClipsDescendants = true,
			})
			box.ZIndex = 60
			mk("UIStroke", { Parent = box, Thickness = 1, Transparency = 0.80, Color = Color3.fromRGB(255,255,255) })
			mk("UIGradient", { Parent = box, Rotation = 90, Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.22),
				NumberSequenceKeypoint.new(1, 0.60),
			})})

			local top = mk("Frame", { Parent = box, Size = UDim2.new(1,0,0,1), BackgroundColor3 = accentColor(), BorderSizePixel=0, BackgroundTransparency=0.10 })
			top.ZIndex = 61
			regFill(top)

			local hdr = mk("TextLabel", {
				Parent = box,
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(10, 6),
				Size = UDim2.new(1, -20, 0, 16),
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = titleText or "Color Picker",
				Font = Enum.Font.GothamSemibold,
				TextSize = 12,
				TextColor3 = Color3.fromRGB(245,245,255),
				TextTransparency = 0.12,
			})
			hdr.ZIndex = 61

			local H, S, V
			do
				if typeof(defaultColor) == "Color3" then
					H, S, V = defaultColor:ToHSV()
				elseif type(defaultColor) == "table" then
					H = tonumber(defaultColor.H or defaultColor.h or defaultColor[1])
					S = tonumber(defaultColor.S or defaultColor.s or defaultColor[2])
					V = tonumber(defaultColor.V or defaultColor.v or defaultColor[3])
				end
				if H == nil or S == nil or V == nil then
					H, S, V = Config.Theme.AccentH, Config.Theme.AccentS, Config.Theme.AccentV
				end
				H, S, V = clamp(H,0,1), clamp(S,0,1), clamp(V,0,1)
			end

			local sv = mk("Frame", {
				Parent = box,
				Position = UDim2.fromOffset(10, 28),
				Size = UDim2.fromOffset(120, 120),
				BackgroundColor3 = Color3.fromHSV(H, 1, 1),
				BorderSizePixel = 0,
				ClipsDescendants = true,
			})
			sv.ZIndex = 61
			mk("UIStroke", { Parent = sv, Thickness = 1, Transparency = 0.80, Color = Color3.fromRGB(255,255,255) })

			local satLayer = mk("Frame", { Parent = sv, Size = UDim2.fromScale(1,1), BackgroundColor3 = Color3.new(1,1,1), BorderSizePixel=0, BackgroundTransparency = 0 })
			satLayer.ZIndex = 62
			mk("UIGradient", { Parent = satLayer, Rotation = 0, Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(1, 1),
			})})

			local valLayer = mk("Frame", { Parent = sv, Size = UDim2.fromScale(1,1), BackgroundColor3 = Color3.new(0,0,0), BorderSizePixel=0, BackgroundTransparency = 0 })
			valLayer.ZIndex = 63
			mk("UIGradient", { Parent = valLayer, Rotation = 90, Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(1, 0),
			})})

			local marker = mk("Frame", { Parent = sv, Size = UDim2.fromOffset(10,10), BackgroundTransparency = 1, BorderSizePixel = 0 })
			marker.ZIndex = 64
			local ring = mk("Frame", { Parent = marker, Size = UDim2.fromScale(1,1), BackgroundTransparency=1, BorderSizePixel=0 })
			ring.ZIndex = 65
			mk("UIStroke", { Parent = ring, Thickness = 1, Transparency = 0.15, Color = Color3.fromRGB(255,255,255) })

			local hue = mk("Frame", {
				Parent = box,
				Position = UDim2.fromOffset(10, 154),
				Size = UDim2.new(1, -20, 0, 14),
				BackgroundColor3 = Color3.fromRGB(255,255,255),
				BackgroundTransparency = 0.88,
				BorderSizePixel = 0,
				ClipsDescendants = true,
			})
			hue.ZIndex = 61
			mk("UIStroke", { Parent = hue, Thickness = 1, Transparency = 0.80, Color = Color3.fromRGB(255,255,255) })

			local hueGrad = mk("UIGradient", { Parent = hue, Rotation = 0 })
			do
				local keys = {}
				for i = 0, 6 do
					local hh = i / 6
					keys[#keys + 1] = ColorSequenceKeypoint.new(hh, Color3.fromHSV(hh, 1, 1))
				end
				hueGrad.Color = ColorSequence.new(keys)
			end

			local hueKnob = mk("Frame", {
				Parent = hue,
				Size = UDim2.fromOffset(10, 14),
				BackgroundColor3 = Color3.fromRGB(255,255,255),
				BackgroundTransparency = 0.70,
				BorderSizePixel = 0,
			})
			hueKnob.ZIndex = 62
			mk("UIStroke", { Parent = hueKnob, Thickness = 1, Transparency = 0.55, Color = Color3.fromRGB(0,0,0) })

			local preview = mk("Frame", {
				Parent = box,
				Position = UDim2.fromOffset(140, 28),
				Size = UDim2.new(1, -150, 0, 40),
				BackgroundColor3 = Color3.fromHSV(H,S,V),
				BorderSizePixel = 0,
			})
			preview.ZIndex = 61
			mk("UIStroke", { Parent = preview, Thickness = 1, Transparency = 0.78, Color = Color3.fromRGB(255,255,255) })
			mk("UIGradient", { Parent = preview, Rotation = 0, Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.10),
				NumberSequenceKeypoint.new(1, 0.30),
			})})

			local readout = mk("TextLabel", {
				Parent = box,
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(140, 74),
				Size = UDim2.new(1, -150, 0, 16),
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = "",
				Font = Enum.Font.GothamMedium,
				TextSize = 12,
				TextColor3 = Color3.fromRGB(220,220,235),
				TextTransparency = 0.30,
			})
			readout.ZIndex = 61

			local function fire(liveOnly)
				if callback then
					local col = Color3.fromHSV(H,S,V)
					pcall(function() callback(col, H, S, V, liveOnly == true) end)
				end
			end

			local function updateUI()
				sv.BackgroundColor3 = Color3.fromHSV(H, 1, 1)
				local col = Color3.fromHSV(H,S,V)
				preview.BackgroundColor3 = col
				readout.Text = string.format("H %.2f  S %.2f  V %.2f", H, S, V)

				local sx, sy = sv.AbsoluteSize.X, sv.AbsoluteSize.Y
				if sx > 0 and sy > 0 then
					local mx = clamp(S,0,1) * sx
					local my = (1 - clamp(V,0,1)) * sy
					marker.Position = UDim2.fromOffset(mx - 5, my - 5)
				end

				local hxw = hue.AbsoluteSize.X
				if hxw > 0 then
					local hx = clamp(H,0,1) * hxw
					hueKnob.Position = UDim2.fromOffset(hx - 5, 0)
				end
			end

			local function setHSV(hh, ss, vv, liveOnly)
				H, S, V = clamp(hh,0,1), clamp(ss,0,1), clamp(vv,0,1)
				updateUI()
				fire(liveOnly)
			end

			local draggingSV, draggingHue = false, false

			local function setFromSV(pos)
				local relX = clamp((pos.X - sv.AbsolutePosition.X) / sv.AbsoluteSize.X, 0, 1)
				local relY = clamp((pos.Y - sv.AbsolutePosition.Y) / sv.AbsoluteSize.Y, 0, 1)
				S = relX
				V = 1 - relY
				updateUI()
				fire(true)
			end

			local function setFromHue(pos)
				local relX = clamp((pos.X - hue.AbsolutePosition.X) / hue.AbsoluteSize.X, 0, 1)
				H = relX
				updateUI()
				fire(true)
			end

			track(sv.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					draggingSV = true
					setFromSV(input.Position)
				end
			end))
			track(hue.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					draggingHue = true
					setFromHue(input.Position)
				end
			end))

			track(UserInputService.InputChanged:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseMovement then
					if draggingSV then setFromSV(input.Position) end
					if draggingHue then setFromHue(input.Position) end
				end
			end))

			track(UserInputService.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					local was = draggingSV or draggingHue
					draggingSV, draggingHue = false, false
					if was then fire(false) end
				end
			end))

			task.defer(function()
				updateUI()
				fire(false)
			end)

			registerItem(box, (titleText or "color picker") .. " color picker hsv hue saturation value")
			return {
				Root = box,
				Get = function() return Color3.fromHSV(H,S,V) end,
				GetHSV = function() return H,S,V end,
				Set = function(v)
					if typeof(v) == "Color3" then
						local hh, ss, vv = v:ToHSV()
						setHSV(hh, ss, vv, false)
					elseif type(v) == "table" then
						local hh = tonumber(v.H or v.h or v[1]) or H
						local ss = tonumber(v.S or v.s or v[2]) or S
						local vv = tonumber(v.V or v.v or v[3]) or V
						setHSV(hh, ss, vv, false)
					end
				end,
			}
		end

		return api
	end

	--==================================================
	-- Public-ish builders
	--==================================================
	local function addSectionTo(tab, side, title, subtitle)
		local pi = PageIndex[tab.page]
		local col = (side == "right") and pi.rightCol or pi.leftCol
		local api = makeGroupBox(col, title, subtitle, side)
		registerSection(tab.page, api._sec)
		return api
	end

	local function wrapTab(tab)
		local TabAPI = {}
		function TabAPI:Show()
			setActiveTab(tab)
			return self
		end
		function TabAPI:AddSection(side, title, subtitle)
			return addSectionTo(tab, side, title, subtitle)
		end
		TabAPI._tab = tab
		return TabAPI
	end

	function self:NewTab(label)
		local t = createTab(label)
		local api = wrapTab(t)
		if #Tabs == 1 then
			setActiveTab(t)
		end
		updateTabsCanvas()
		return api
	end

	function self:SetActiveTab(tabApi)
		if tabApi and tabApi._tab then
			setActiveTab(tabApi._tab)
		end
	end

	--==================================================
	-- Close confirmation modal
	--==================================================
	local closeOverlay = mk("Frame", {
		Parent = mainGui,
		Size = UDim2.fromScale(1,1),
		BackgroundColor3 = Color3.fromRGB(0,0,0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Visible = false,
	})
	closeOverlay.ZIndex = 500

	closeCard = mk("Frame", {
		Parent = closeOverlay,
		AnchorPoint = Vector2.new(0.5,0.5),
		Position = UDim2.fromScale(0.5,0.5),
		Size = UDim2.fromOffset(360, 130),
		BackgroundColor3 = panelInsetBg(),
		BackgroundTransparency = 0.06,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	})
	closeCard.ZIndex = 501
	mk("UIStroke", { Parent = closeCard, Thickness = 1, Transparency = 0.58, Color = Color3.fromRGB(255,255,255) })
	mk("UIGradient", { Parent = closeCard, Rotation = 90, Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.22),
		NumberSequenceKeypoint.new(1, 0.60),
	})})

	closeLine = mk("Frame", {
		Parent = closeCard,
		Size = UDim2.new(1,0,0,1),
		BackgroundColor3 = accentColor(),
		BorderSizePixel = 0,
		BackgroundTransparency = 0.10,
	})
	closeLine.ZIndex = 502
	regFill(closeLine)

	local closeTitle = mk("TextLabel", {
		Parent = closeCard,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Close wastedbin?",
		Font = Enum.Font.GothamSemibold,
		TextSize = 13,
		TextColor3 = Color3.fromRGB(245,245,255),
		TextTransparency = 0.10,
	})
	closeTitle.ZIndex = 502

	local closeHint = mk("TextLabel", {
		Parent = closeCard,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(10, 34),
		Size = UDim2.new(1, -20, 0, 40),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		Text = "Are you sure you want to shut down wastedbin? (You can reopen with End)",
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = Color3.fromRGB(220,220,235),
		TextTransparency = 0.30,
	})
	closeHint.ZIndex = 502

	local rowBtns = mk("Frame", { Parent = closeCard, BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 86), Size = UDim2.new(1, -20, 0, 30) })
	rowBtns.ZIndex = 502
	mk("UIListLayout", { Parent = rowBtns, FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8) })

	local function modalBtn(text)
		local b = mk("TextButton", {
			Parent = rowBtns,
			Size = UDim2.new(0.5, -4, 1, 0),
			BackgroundColor3 = Color3.fromRGB(0,0,0),
			BackgroundTransparency = 0.58,
			BorderSizePixel = 0,
			Text = text,
			Font = Enum.Font.GothamSemibold,
			TextSize = 12,
			TextColor3 = Color3.fromRGB(240,240,255),
			TextTransparency = 0.15,
			AutoButtonColor = false,
		})
		b.ZIndex = 503
		local st = mk("UIStroke", { Parent = b, Thickness = 1, Transparency = 0.82, Color = Color3.fromRGB(255,255,255) })
		mk("UIGradient", { Parent = b, Rotation = 0, Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.24),
			NumberSequenceKeypoint.new(1, 0.62),
		})})

		track(b.MouseEnter:Connect(function()
			tween(b, TI(0.10), { BackgroundTransparency = 0.42 })
			tween(st, TI(0.10), { Transparency = StrokeT(0.68) })
		end))
		track(b.MouseLeave:Connect(function()
			tween(b, TI(0.12), { BackgroundTransparency = 0.58 })
			tween(st, TI(0.12), { Transparency = StrokeT(0.82) })
		end))
		return b
	end

	local confirmYes = modalBtn("yes")
	local confirmNo = modalBtn("no")

	local function showCloseConfirm()
		closeOverlay.Visible = true
		closeOverlay.BackgroundTransparency = 1
		closeCard.BackgroundTransparency = 0.25
		closeCard.Position = UDim2.fromScale(0.5, 0.48)
		tween(closeOverlay, TI(0.14), { BackgroundTransparency = 0.55 })
		tween(closeCard, TI(0.18), { BackgroundTransparency = 0.06, Position = UDim2.fromScale(0.5,0.5) })
	end

	local function hideCloseConfirm()
		tween(closeOverlay, TI(0.12, Enum.EasingStyle.Quint, Enum.EasingDirection.In), { BackgroundTransparency = 1 })
		tween(closeCard, TI(0.12, Enum.EasingStyle.Quint, Enum.EasingDirection.In), { BackgroundTransparency = 0.25, Position = UDim2.fromScale(0.5, 0.48) })
		task.delay(0.13, function()
			if closeOverlay then closeOverlay.Visible = false end
		end)
	end

	--==================================================
	-- Drag + Resize
	--==================================================
	local minimized = false
	local savedSize = root.Size

	local function hoverTop(btn, stroke, normalBT, normalStrokeT)
		track(btn.MouseEnter:Connect(function()
			tween(btn, TI(0.10), { BackgroundTransparency = math.max(btn.BackgroundTransparency - 0.14, 0) })
			tween(stroke, TI(0.10), { Transparency = math.max(stroke.Transparency - 0.12, 0) })
		end))
		track(btn.MouseLeave:Connect(function()
			tween(btn, TI(0.12), { BackgroundTransparency = normalBT })
			tween(stroke, TI(0.12), { Transparency = StrokeT(normalStrokeT) })
		end))
	end
	hoverTop(btnMin, btnMinStroke, 0.52, 0.78)
	hoverTop(btnClose, btnCloseStroke, 0.22, 0.72)

	local dragging = false
	local dragStart = Vector2.zero
	local startPos = Vector2.zero
	local targetPos = Vector2.new(root.Position.X.Offset, root.Position.Y.Offset)
	local currentPos = Vector2.new(root.Position.X.Offset, root.Position.Y.Offset)

	track(titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and not closeOverlay.Visible then
			dragging = true
			dragStart = input.Position
			startPos = Vector2.new(root.Position.X.Offset, root.Position.Y.Offset)
		end
	end))

	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end))

	track(UserInputService.InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			local delta = input.Position - dragStart
			targetPos = Vector2.new(startPos.X + delta.X, startPos.Y + delta.Y)
		end
	end))

	local resizing = false
	local resizeStartMouse = Vector2.zero
	local resizeStartSize = Vector2.zero
	local MIN_W, MIN_H = 560, 360
	local MAX_W, MAX_H = 980, 760

	track(resizeHandle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and not minimized then
			resizing = true
			resizeStartMouse = input.Position
			resizeStartSize = Vector2.new(root.Size.X.Offset, root.Size.Y.Offset)
			tween(contentStroke, TI(0.10), { Transparency = StrokeT(0.62) })
		end
	end))

	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if resizing then
				resizing = false
				savedSize = root.Size
				tween(contentStroke, TI(0.12), { Transparency = StrokeT(0.78) })
			end
		end
	end))

	track(UserInputService.InputChanged:Connect(function(input)
		if resizing and input.UserInputType == Enum.UserInputType.MouseMovement then
			local delta = input.Position - resizeStartMouse
			local w = clamp(resizeStartSize.X + delta.X, MIN_W, MAX_W)
			local h = clamp(resizeStartSize.Y + delta.Y, MIN_H, MAX_H)
			w, h = math.floor(w), math.floor(h)

			root.Size = UDim2.fromOffset(w, h)
			inset.Size = UDim2.new(1, -2, 1, -2)

			shadowA.Size = UDim2.fromOffset(w + 20, h + 20)
			shadowB.Size = UDim2.fromOffset(w + 34, h + 34)
		end
	end))

	-- responsive top layout
	local function updateTopLayout()
		if guard() then return end
		local w = tabBar.AbsoluteSize.X
		local desired = 200
		local minSearch = 120
		local maxSearch = 240
		local tabsMin = 260

		local computed = clamp(desired, minSearch, maxSearch)
		if w - computed < tabsMin then
			computed = clamp(w - tabsMin, minSearch, maxSearch)
		end

		searchWrap.Size = UDim2.fromOffset(computed, 20)
		tabsScroll.Size = UDim2.new(1, -(computed + 18), 1, -6)
		searchBox.Size = UDim2.new(1, -30, 1, 0)
	end
	track(tabBar:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateTopLayout))
	track(root:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateTopLayout))

	--==================================================

	--==================================================
	-- Close / Toggle / Minimize
	--==================================================
	-- Optional cursor behavior while UI is open.
	-- IMPORTANT: this runs only on show/hide (not every frame) to avoid fighting your camera scripts.
	local cursor = {
		active = false,
		prevBehavior = nil,
		prevIcon = nil,
	}

	local function applyCursorMode(open)
		open = (open == true)
		local mode = tostring((Config.Options and Config.Options.CursorMode) or "Inherit")

		if not open then
			if cursor.active then
				cursor.active = false
				pcall(function()
					if cursor.prevBehavior then
						UserInputService.MouseBehavior = cursor.prevBehavior
					end
					if cursor.prevIcon ~= nil then
						UserInputService.MouseIconEnabled = cursor.prevIcon
					end
				end)
			end
			return
		end

		-- Inherit = don't touch mouse at all
		if mode == "Inherit" then
			return
		end

		-- store previous once
		if not cursor.active then
			cursor.active = true
			cursor.prevBehavior = UserInputService.MouseBehavior
			cursor.prevIcon = UserInputService.MouseIconEnabled
		end

		if mode == "Unlock" then
			pcall(function()
				UserInputService.MouseBehavior = Enum.MouseBehavior.Default
				UserInputService.MouseIconEnabled = true
			end)
		elseif mode == "LockCenter" then
			pcall(function()
				UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
				UserInputService.MouseIconEnabled = false
			end)
		end
	end

	local function setMainVisible(v)
		mainGui.Enabled = (v == true)
		applyCursorMode(mainGui.Enabled)
	end

	function self:SetVisible(v)
		if self._mainGui then
			setMainVisible(v == true)
		end
	end

	function self:ToggleVisible()
		if self._mainGui then
			setMainVisible(not mainGui.Enabled)
		end
	end

	local _oldUnload = self.Unload
	function self:Unload()
		pcall(function() applyCursorMode(false) end)
		return _oldUnload(self)
	end

	track(btnClose.Activated:Connect(function()
		if not closeOverlay.Visible then
			showCloseConfirm()
		end
	end))

	track(confirmNo.Activated:Connect(function() hideCloseConfirm() end))
	track(confirmYes.Activated:Connect(function()
		hideCloseConfirm()
		Notify("ui", "hidden", nil)
		setMainVisible(false)
	end))

	track(btnMin.Activated:Connect(function()
		minimized = not minimized
		if minimized then
			savedSize = root.Size
			local w = root.Size.X.Offset
			local targetH = 110
			tween(root, TI(0.18), { Size = UDim2.fromOffset(w, targetH) })
			tween(shadowA, TI(0.18), { Size = UDim2.fromOffset(w + 20, targetH + 20) })
			tween(shadowB, TI(0.18), { Size = UDim2.fromOffset(w + 34, targetH + 34) })
			task.delay(Config.Theme.ReduceMotion and 0 or 0.12, function()
				if content then content.Visible = false end
				if resizeHandle then resizeHandle.Visible = false end
			end)
		else
			local w, h = savedSize.X.Offset, savedSize.Y.Offset
			if content then content.Visible = true end
			if resizeHandle then resizeHandle.Visible = true end
			tween(root, TI(0.18), { Size = UDim2.fromOffset(w, h) })
			tween(shadowA, TI(0.18), { Size = UDim2.fromOffset(w + 20, h + 20) })
			tween(shadowB, TI(0.18), { Size = UDim2.fromOffset(w + 34, h + 34) })
		end
	end))

	track(UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
		local kc = keyCodeFromString(Config.Keybinds.ToggleUI)
		if kc and input.KeyCode == kc then
			setMainVisible(not mainGui.Enabled)
		end
	end))

	--==================================================
	-- Animated shimmer + active tab gradient rotate + smooth drag follow
	--==================================================
	local shimmerT = 0
	track(RunService.RenderStepped:Connect(function(dt)
		if guard() then return end


		shimmerT += dt * 0.55
		scanGrad.Offset = Vector2.new(math.sin(shimmerT) * 0.5, 0)
		rootGrad.Offset = Vector2.new(math.sin(shimmerT*0.35)*0.08, math.cos(shimmerT*0.28)*0.06)

		if ActiveTab and ActiveTab.outlineGrad and ActiveTab.outline and ActiveTab.outline.Visible then
			ActiveTab.outlineGrad.Rotation = (shimmerT * 18) % 360
		end

		local alpha = 1 - math.pow(0.001, dt)
		local follow = dragging and 0.22 or 0.18
		local k = clamp(follow + alpha*0.03, 0.10, 0.35)
		currentPos = currentPos + (targetPos - currentPos) * k

		local px = math.floor(currentPos.X)
		local py = math.floor(currentPos.Y)

		root.Position = UDim2.fromOffset(px, py)
		shadowA.Position = UDim2.fromOffset(px - shadowOffsetA(), py - shadowOffsetA())
		shadowB.Position = UDim2.fromOffset(px - shadowOffsetB(), py - shadowOffsetB())
	end))

	--==================================================
	-- Optional AutoDemo (kept mostly intact, now includes AddSelect example)
	--==================================================
	local function BuildDefaultDemo()
		local tabMain   = createTab("main")
		local tabThemes = createTab("themes")
		local tabInputs = createTab("inputs")
		local tabInfo   = createTab("info")

		do
			local a = addSectionTo(tabMain, "left", "Quick Actions", "buttons / toggles / toasts")
			a:AddButton("show toast (default)", function()
				Notify("toast", "uses ToastDuration setting", nil)
			end)
			a:AddButton("show toast (2s)", function()
				Notify("toast", "forced duration = 2", 2)
			end)
			a:AddToggle("enable notifications", Config.Options.EnableToasts, function(v)
				Config.Options.EnableToasts = v
				saveClientConfig()
			end)
			a:AddSlider("toast duration", 1, 12, tonumber(Config.Options.ToastDuration) or 3, function(v)
				Config.Options.ToastDuration = v
				saveClientConfig()
			end, { Decimals = 0 })

			local cfg = addSectionTo(tabMain, "right", "Config", "save / load / reset")
			cfg:AddButton("save config", function()
				self:SaveConfig()
				Notify("config", "saved", 2)
			end)
			cfg:AddButton("load config", function()
				local ok = self:LoadConfig()
				Notify("config", ok and "loaded" or "no config found", 2)
			end)
			cfg:AddButton("reset to defaults", function()
				Config = deepCopy(DEFAULT_CONFIG)
				mergeDefaults(Config, deepCopy(DEFAULT_CONFIG))
				self.Config = Config
				applyTheme()
				saveClientConfig()
				Notify("config", "reset", 2)
			end)
		end

		do
			local s1 = addSectionTo(tabThemes, "left", "Panel & Style", "alpha / strokes / tint")
			s1:AddSlider("panel alpha", 0, 0.25, Config.Theme.PanelAlpha, function(v)
				Config.Theme.PanelAlpha = v
				applyTheme()
				saveClientConfig()
			end)
			s1:AddSlider("stroke alpha", 0.05, 0.95, Config.Theme.StrokeAlpha, function(v)
				Config.Theme.StrokeAlpha = v
				applyTheme()
				saveClientConfig()
			end)
			s1:AddSlider("tone", 0, 1, Config.Theme.Tone, function(v)
				Config.Theme.Tone = v
				applyTheme()
				saveClientConfig()
			end)
			s1:AddSlider("tint strength", 0, 0.25, Config.Theme.TintStrength, function(v)
				Config.Theme.TintStrength = v
				applyTheme()
				saveClientConfig()
			end)
			s1:AddSlider("text bright", 0, 0.35, Config.Theme.TextBright, function(v)
				Config.Theme.TextBright = v
				applyTheme()
				saveClientConfig()
			end)
			s1:AddToggle("reduce motion", Config.Theme.ReduceMotion, function(v)
				Config.Theme.ReduceMotion = v
				applyTheme()
				saveClientConfig()
			end)

			local s2 = addSectionTo(tabThemes, "right", "Effects", "shadow / accent")
			s2:AddToggle("shadow enabled", Config.Theme.ShadowEnabled, function(v)
				Config.Theme.ShadowEnabled = v
				applyTheme()
				saveClientConfig()
			end)
			s2:AddSlider("shadow transparency", 0.20, 0.98, tonumber(Config.Theme.ShadowTransparency) or 0.58, function(v)
				Config.Theme.ShadowTransparency = v
				applyTheme()
				saveClientConfig()
			end)
			s2:AddColorPicker("Accent (HSV)", Color3.fromHSV(Config.Theme.AccentH, Config.Theme.AccentS, Config.Theme.AccentV), function(col, h,s,v, live)
				Config.Theme.AccentH, Config.Theme.AccentS, Config.Theme.AccentV = h,s,v
				applyTheme()
				if not live then saveClientConfig() end
			end)
		end

		do
			local s1 = addSectionTo(tabInputs, "left", "Ranged numeric", "type values (min/max like sliders)")
			s1:AddNumberBox("panel alpha (type)", 0.00, 0.25, Config.Theme.PanelAlpha, function(v)
				Config.Theme.PanelAlpha = v
				applyTheme()
				saveClientConfig()
			end)
			s1:AddNumberBox("tone (type)", 0.00, 1.00, Config.Theme.Tone, function(v)
				Config.Theme.Tone = v
				applyTheme()
				saveClientConfig()
			end)

			local s2 = addSectionTo(tabInputs, "right", "Dropdown", "single / multi select")
			s2:AddSelect("pick one", {"Head","Torso","Left Arm","Right Arm"}, "Head", function(sel) end, { Multi = false })
			s2:AddSelect("pick many", {"Head","Torso","Left Arm","Right Arm","Left Leg","Right Leg"}, {"Head","Torso"}, function(sel) end, { Multi = true })
		end

		do
			local s1 = addSectionTo(tabInfo, "left", "Help", nil)
			s1:AddInfo("controls", "drag: title bar\nresize: bottom-right\nminimize: [-]\nclose: [x]\nkeybind: End")
			local s2 = addSectionTo(tabInfo, "right", "Search", nil)
			s2:AddInfo("search", "search filters BOTH columns and items.\ncolumns hide when there are no matches.\nclear restores.")
			s2:AddInfo("try", "Try searching: 'alpha', 'shadow', 'head', 'torso'")
		end

		updateActiveTabGradientColors()
		applyTheme()
		setActiveTab(tabMain)
		updateTabsCanvas()
	end

	--==================================================
	-- Init
	--==================================================
	applyTheme()
	updateActiveTabGradientColors()
	updateTabsCanvas()
	updateTopLayout()

	if self.Options.AutoDemo then
		BuildDefaultDemo()
	end

	Notify("wastedbin", "press End to toggle UI", nil)
	return self
end

return wastedbin

--==================================================
-- wastedbin Usage
--==================================================
-- 1) Load the module (choose method):
--
--   -- A) loadstring + HttpGet
--   local wastedbin = loadstring(game:HttpGet(https://raw.githubusercontent.com/wastedbin/ui/main/wastedbin.lua))()
--
--   -- B) ModuleScript require 
--   -- Put this file as a ModuleScript, e.g. ReplicatedStorage/wastedbinUI_Premium_V1
--   local wastedbin = require(game:GetService("ReplicatedStorage"):WaitForChild("wastedbinUI_Premium_V1"))
--
--
-- 2) Create the UI window:
--
--   local ui = wastedbin.new({
--     AutoDemo = false,                   -- true = library builds demo tabs automatically
--     ConfigFile = "wastedbinConfig.json", -- (optional) file name if file IO exists
--     ConfigFolder = "wastedbinUI",        -- (optional) folder if file IO exists
--   }):CreateWindow()
--
--
-- 3) Tabs + Sections:
--
--   local tabMain = ui:NewTab("main")
--   local left  = tabMain:AddSection("left",  "Actions", "buttons / toggles / toasts")
--   local right = tabMain:AddSection("right", "Config",  "save / load")
--
--
-- 4) Basic controls:
--
--   left:AddButton("Hello", function()
--     ui:Notify("hi", "works", 2) -- head, message, duration seconds (optional)
--   end)
--
--   local t = left:AddToggle("God Mode", false, function(on)
--     print("toggle:", on)
--   end)
--   -- t:Get() -> bool
--   -- t:Set(true/false)
--
--   local s = left:AddSlider("WalkSpeed", 0, 100, 16, function(v)
--     print("slider:", v)
--   end, { Decimals = 0, ValueBoxWidth = 44 })
--   -- s:Get() -> number
--   -- s:Set(number)
--
--   local nb = left:AddNumberBox("Volume", 0, 10, 5, function(v)
--     print("numberbox:", v)
--   end, { Decimals = 1, BoxWidth = 80 })
--   -- nb:Get() -> number
--   -- nb:Set(number)
--
--   local ni = left:AddNumberInput("SoundId", "", function(text, num)
--     -- text = raw string, num = tonumber(text) if valid else nil
--     print("text:", text, "num:", num)
--   end, { BoxWidth = 160 })
--   -- ni:GetText() -> string
--   -- ni:SetText("123456")
--
--   left:AddInfo("Tip", "Use search bar at top to filter items & sections.")
--
--
-- 5) Theme controls (HSV ColorPicker):
--
--   local themes = tabMain:AddSection("right", "Theme", "accent / style")
--   local cp = themes:AddColorPicker("Accent (HSV)", Color3.fromRGB(0, 170, 255), function(col, h, s, v, live)
--     -- live == true while dragging, false on release
--     print("accent:", col, h, s, v, "live:", live)
--   end)
--   -- cp:Get() -> Color3
--   -- cp:GetHSV() -> H,S,V
--   -- cp:Set(Color3 or {H=,S=,V=})
--
--
-- 6) Select / Dropdown (single or multi select):
--
--   -- Single-select (choose only one)
--   local single = left:AddSelect(
--     "Choose one",
--     {"Head","Torso","Left Arm","Right Arm","Left Leg","Right Leg"},
--     "Head", -- default (string or 1-based index)
--     function(selectedList, selectedSet, live)
--       -- selectedList = {"Head"}
--       -- selectedSet  = { Head=true }
--       print("single:", table.concat(selectedList, ", "))
--     end,
--     { Multi = false }
--   )
--
--   -- Multi-select (choose many)
--   local multi = left:AddSelect(
--     "Select your character body parts",
--     {"Head","Torso","Left Arm","Right Arm","Left Leg","Right Leg"},
--     {"Head","Torso"}, -- default (array of strings or indices)
--     function(selectedList, selectedSet, live)
--       -- selectedList e.g. {"Head","Torso"}
--       -- selectedSet  e.g. { Head=true, Torso=true }
--       print("multi:", table.concat(selectedList, ", "))
--     end,
--     { Multi = true }
--   )
--
--   -- Returned API:
--   -- single:Get() -> selectedList, selectedSet
--   -- single:Set("Head") or single:Set(1)
--   -- multi:Set({"Head","Torso"}) or multi:Set({1,2})
--
--   -- UI behavior:
--   -- - Right side has the main dropdown button.
--   -- - Clicking opens a list of buttons below.
--   -- - In multi mode the main button shows "Head, Torso, ..."
--
--
-- 7) Config:
--
--   ui:SaveConfig()                -- saves to file (if available), else PlayerGui attribute
--   ui:LoadConfig()                -- loads from file/attribute, applies theme
--
--
-- 8) Visibility + Unload:
--
--   ui:SetVisible(true/false)
--   ui:ToggleVisible()
--   ui:Unload() -- destroys GUIs + disconnects connections
--
--
-- Note:
-- - Default keybind to toggle UI is "End" (Config.Keybinds.ToggleUI).
--==================================================--

-- Special thanks to ChatGPT (5.2) for helping me organize the code and with the usage guide (yes, I was too lazy to write the usage guide)

--============================================={  Thank you for using!  }=============================================--

--By @luaudocumentation/@luauapi
