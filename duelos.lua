--[[
	duelos · ARCHIVO ÚNICO
	──────────────────────────────────────────────────────────
	Interfaz + lógica (aim / hitbox / ESP / cámara / contador) en un
	solo archivo. Pensado para subirse a GitHub y cargarse desde el
	executor con loadstring(game:HttpGet(...))().

	Uso:
		loadstring(game:HttpGet("https://raw.githubusercontent.com/<user>/<repo>/main/duelos.lua"))()

	NOTA: este archivo se genera con build_single.js a partir de
	duelos_ui.lua, core.lua, mod_*.lua y main_wiring.lua.
	Para cambiar algo, edita los archivos sueltos y vuelve a generarlo:
		node build_single.js
]]

-- ═════════ limpieza de una carga anterior ═════════
-- IMPORTANTE: se detiene la instancia anterior ANTES de registrar los
-- render steps nuevos. Si se hiciera después, el UnbindFromRenderStep de
-- la instancia vieja borraría los nuevos (mismo nombre).
local _prev = (type(getgenv) == "function") and getgenv().DuelosMain or nil
if _prev and type(_prev.stop) == "function" then
	pcall(_prev.stop)
end

local UI = (function()
-- ═════════ INTERFAZ (duelos_ui.lua) ═════════
--[[
	duelos · interfaz "liquid glass" para Delta Executor
	──────────────────────────────────────────────────────────
	Replica del prototipo HTML (perfiles.html) usando solo primitivas de
	GUI de Roblox (Frame, UICorner, UIStroke, UIScale, TweenService).
	Sin CanvasGroup ni UIGradient: algunos executors no los renderizan bien
	(ocultaban los hijos / dejaban rectángulos blancos sólidos).

	ESTE ARCHIVO SOLO CONTIENE LA INTERFAZ:
	- la lógica real (aim / hitbox / cámara / ESP) NO está implementada.
	- todos los valores viven en la tabla `Config` (expuesta en getgenv().Duelos).
	- engancha tu lógica en la tabla `Hooks` o lee `Config` en un bucle.

	Uso: pégalo en el executor, o
	     loadstring(game:HttpGet("https://tu-host/duelos_ui.lua"))()
]]

-- ═══════════════════════════════════════════════════════════════════
-- servicios
-- ═══════════════════════════════════════════════════════════════════
local Players        = game:GetService("Players")
local TweenService   = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local mouse  = player:GetMouse()

-- ═══════════════════════════════════════════════════════════════════
-- CONFIG · valores de la interfaz (aquí conectas tu lógica)
-- ═══════════════════════════════════════════════════════════════════
local Config = {
	-- aim
	aim      = true,
	aimHold  = false,
	aimBone  = "head",   -- head | torso | near
	fov      = 90,
	speed    = 65,
	humanize = true,    -- error de mira + reacción (menos delatable)

	-- hitbox
	hb       = true,
	hbPart   = "head",   -- head | torso | all
	hbScale  = 200,      -- 200 = 2.0x
	hbMax    = 115,      -- tope: 115 = máx x1.15 (0 = sin tope)
	hbRevert = true,

	-- cámara
	cam       = true,
	camAnchor = "head",  -- head | torso | feet
	camSmooth = 40,
	camFov    = 70,

	-- esp
	esp       = false,
	espWall   = true,
	espStyle  = "box",   -- box | dot
	espRange  = 140,
	espAlpha  = 80,
}

-- ganchos vacíos: implementa aquí lo que quieras (todavía no funciona)
local Hooks = {
	onAim    = function(state) end,
	onHitbox = function(state) end,
	onCam    = function(state) end,
	onEsp    = function(state) end,
}

-- ═══════════════════════════════════════════════════════════════════
-- constantes de diseño (taken del HTML)
-- ═══════════════════════════════════════════════════════════════════
local WIN_W   = 392
local PAGE_W  = 360          -- 392 - 16*2
local PAGE_X  = 16
local NAV_H   = 44
local ROW_H   = 44
local LIST_R  = 14
local WIN_R   = 26

local C = {
	label  = Color3.fromRGB(242, 242, 244),
	label2 = Color3.fromRGB(242, 242, 247),
	label3 = Color3.fromRGB(242, 242, 247),
	green  = Color3.fromRGB(48, 209, 88),
	blue   = Color3.fromRGB(10, 132, 255),
	white  = Color3.fromRGB(255, 255, 255),
	panel  = Color3.fromRGB(28, 28, 30),
	black  = Color3.fromRGB(0, 0, 0),
}

local T_LABEL2 = 0.45        -- rgba(242,242,247,.55)
local T_LABEL3 = 0.68        -- rgba(242,242,247,.32)
local T_HAIR   = 0.92        -- rgba(255,255,255,.08)

local SCALE = 1              -- escala actual de la ventana (px de pantalla <-> unidades GUI)
local ZOOM = 1               -- zoom manual del usuario (agarre de la esquina)
local knobDrag = nil         -- arrastre de la perilla de un switch
local prefs = { fabX = nil, fabY = nil, zoom = 1 }  -- preferencias guardadas

local FONT_BODY = Enum.Font.Gotham
local FONT_MED  = Enum.Font.GothamMedium
local FONT_BOLD = Enum.Font.GothamBold
local FONT_SEMI = FONT_MED
do
	local ok, f = pcall(function() return Enum.Font.GothamSemibold end)
	if ok and f then FONT_SEMI = f end
end

-- ═══════════════════════════════════════════════════════════════════
-- helpers
-- ═══════════════════════════════════════════════════════════════════
local function mk(class, props, parent)
	local o = Instance.new(class)
	if props then
		for k, v in pairs(props) do
			-- si el executor no soporta alguna propiedad, se ignora en vez de
			-- abortar la construcción de toda la interfaz
			pcall(function() o[k] = v end)
		end
	end
	if parent then
		o.Parent = parent
	end
	return o
end

local function round(o, r)
	local c = mk("UICorner", {CornerRadius = UDim.new(0, r)})
	c.Parent = o
	return c
end

local function outline(o, color, transparency, thickness)
	local s = mk("UIStroke", {
		Color            = color,
		Transparency     = transparency,
		Thickness        = thickness or 1,
		ApplyStrokeMode  = Enum.ApplyStrokeMode.Border,
	})
	s.Parent = o
	return s
end

local function tween(obj, time, props, style, dir)
	local t = TweenService:Create(obj, TweenInfo.new(
		time or 0.25,
		style or Enum.EasingStyle.Quint,
		dir or Enum.EasingDirection.Out
	), props)
	t:Play()
	return t
end

local function text(parent, x, y, w, h, str, size, color, transparency, font, xalign, yalign, z)
	local t = mk("TextLabel", {
		BackgroundTransparency = 1,
		Position               = UDim2.fromOffset(x, y),
		Size                   = UDim2.fromOffset(w, h),
		Font                   = font or FONT_BODY,
		TextSize               = size or 13,
		Text                   = str or "",
		TextColor3             = color or C.label,
		TextTransparency       = transparency or 0,
		TextXAlignment         = xalign or Enum.TextXAlignment.Left,
		TextYAlignment         = yalign or Enum.TextYAlignment.Center,
		TextTruncate           = Enum.TextTruncate.AtEnd,
		ZIndex                 = z or 5,
	})
	t.Parent = parent
	return t
end

local function button(parent, x, y, w, h, z)
	local b = mk("TextButton", {
		BackgroundTransparency = 1,
		Position               = UDim2.fromOffset(x, y),
		Size                   = UDim2.fromOffset(w, h),
		Text                   = "",
		AutoButtonColor        = false,
		ZIndex                 = z or 3,
	})
	b.Parent = parent
	return b
end

local function hover(b, onAlpha, offAlpha)
	b.MouseEnter:Connect(function()
		tween(b, 0.18, {BackgroundTransparency = onAlpha})
	end)
	b.MouseLeave:Connect(function()
		tween(b, 0.18, {BackgroundTransparency = offAlpha})
	end)
end

local function clamp(v, a, b)
	return math.max(a, math.min(b, v))
end

-- ── iconos vectoriales dibujados con Frames (sin assets) ────────────
-- dir: "left" | "right" | "down"
local function chevron(parent, cx, cy, size, color, transparency, dir, z)
	local th = 1.6
	local half = size * 0.36
	local diag = half * 0.7071

	local function bar(rot, dx, dy)
		local b = mk("Frame", {
			BackgroundColor3    = color,
			BackgroundTransparency = transparency,
			Size                = UDim2.fromOffset(size * 0.72, th),
			Position            = UDim2.fromOffset(dx, dy),
			AnchorPoint         = Vector2.new(0.5, 0.5),
			Rotation            = rot,
			BorderSizePixel     = 0,
			ZIndex              = z or 4,
		})
		round(b, th / 2)
		b.Parent = parent
		return b
	end

	if dir == "left" then
		bar(-45, cx + diag, cy - diag)
		bar(45,  cx + diag, cy + diag)
	elseif dir == "right" then
		bar(-45, cx - diag, cy - diag)
		bar(45,  cx - diag, cy + diag)
	else -- down
		bar(45,  cx - diag, cy - diag)
		bar(-45, cx + diag, cy - diag)
	end
end

-- ═══════════════════════════════════════════════════════════════════
-- ScreenGui
-- ═══════════════════════════════════════════════════════════════════
-- si esta interfaz ya estaba cargada (recarga del script), se borra la
-- anterior para no apilar dos ventanas
local playerGui = player:WaitForChild("PlayerGui")
local oldScreen = playerGui:FindFirstChild("DuelosUI")
if oldScreen then
	pcall(function() oldScreen:Destroy() end)
end

local screen = mk("ScreenGui", {
	Name                  = "DuelosUI",
	ResetOnSpawn          = false,
	IgnoreGuiInset        = true,
	DisplayOrder          = 999,
	ZIndexBehavior        = Enum.ZIndexBehavior.Sibling,
})
screen.Parent = playerGui

-- ═══════════════════════════════════════════════════════════════════
-- toast (avisos internos)
-- ═══════════════════════════════════════════════════════════════════
local toastLabel = text(screen, 0, 0, 320, 34, "", 12.5, C.label, 0,
	FONT_MED, Enum.TextXAlignment.Center, Enum.TextYAlignment.Center, 90)
toastLabel.BackgroundColor3 = C.panel
toastLabel.BackgroundTransparency = 0.15
toastLabel.Visible = false
round(toastLabel, 10)
outline(toastLabel, C.white, 0.86, 1)

local function toast(msg)
	toastLabel.Text = msg
	toastLabel.Visible = true
	local cam = workspace.CurrentCamera
	local vs = cam and cam.ViewportSize or Vector2.new(1920, 1080)
	toastLabel.Position = UDim2.fromOffset((vs.X - 320) / 2, vs.Y - 140)
	toastLabel.TextTransparency = 0
	tween(toastLabel, 0.2, {TextTransparency = 0})
	task.delay(2.2, function()
		tween(toastLabel, 0.3, {TextTransparency = 1})
		task.delay(0.32, function()
			toastLabel.Visible = false
			toastLabel.TextTransparency = 0
		end)
	end)
end

-- ═══════════════════════════════════════════════════════════════════
-- switch (cápsula liquid glass)
-- ═══════════════════════════════════════════════════════════════════
local Switches = {}   -- key -> lista de piezas
local ValueLabels = {} -- id -> TextLabel (etiquetas del inicio)
local clickGuard = {}  -- key -> os.clock() hasta el que se ignora el clic (tras arrastrar)

-- declarations adelantadas (se definen más abajo)
local refreshHomeLabels
local showPage
local applyScale
local savePrefs

local function switchParts(key, root, knobHolder, track)
	Switches[key] = Switches[key] or {}
	table.insert(Switches[key], {root = root, holder = knobHolder})
end

-- a qué hook pertenece cada control (para tu lógica)
local HOOK_BY_KEY = {
	aim = "onAim", aimHold = "onAim", fov = "onAim", speed = "onAim", aimBone = "onAim",
	humanize = "onAim",
	hb = "onHitbox", hbPart = "onHitbox", hbRevert = "onHitbox", hbScale = "onHitbox",
	hbMax = "onHitbox",
	cam = "onCam", camAnchor = "onCam", camSmooth = "onCam", camFov = "onCam",
	esp = "onEsp", espWall = "onEsp", espStyle = "onEsp", espRange = "onEsp", espAlpha = "onEsp",
}

local function fireHook(key)
	local name = HOOK_BY_KEY[key]
	if name and type(Hooks[name]) == "function" then
		pcall(Hooks[name], Config[key], key)
	end
end

local function setSwitch(key, on, instant)
	Config[key] = on
	for _, s in ipairs(Switches[key] or {}) do
		if instant then
			s.root.BackgroundColor3 = on and C.green or C.white
			s.root.BackgroundTransparency = on and 0 or 0.87
			s.holder.Position = UDim2.fromOffset(on and 18 or 0, 0)
		else
			tween(s.root, 0.34, {
				BackgroundColor3      = on and C.green or C.white,
				BackgroundTransparency = on and 0 or 0.87,
			}, Enum.EasingStyle.Quint)
			tween(s.holder, 0.44, {
				Position = UDim2.fromOffset(on and 18 or 0, 0),
			}, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		end
	end
	-- refreshHomeLabels aún puede ser nil mientras se construye la UI
	if refreshHomeLabels then refreshHomeLabels() end
	fireHook(key)
end

-- ── perilla del switch: mover y soltar ───────────────────────────
-- (se usan tanto desde los eventos del propio switch como desde los
--  globales, porque algunos executors no entregan input.Target)
local function knobMove(px)
	if not knobDrag or not px then return end
	local s = (SCALE ~= 0) and SCALE or 1
	local d = (px - knobDrag.startX) / s
	if math.abs(d) > 2 then knobDrag.moved = true end
	if not knobDrag.moved then return end

	local newX = clamp(knobDrag.startPos + d, 0, 18)
	knobDrag.holder.Position = UDim2.fromOffset(newX, 0)
	local on = newX > 9
	if on ~= (knobDrag.root.BackgroundColor3 == C.green) then
		tween(knobDrag.root, 0.14, {
			BackgroundColor3       = on and C.green or C.white,
			BackgroundTransparency = on and 0 or 0.87,
		})
	end
end

local function knobRelease()
	if not knobDrag then return end
	local d = knobDrag
	knobDrag = nil
	if d.knob then
		tween(d.knob, 0.22, {Size = UDim2.fromOffset(22, 22)}, Enum.EasingStyle.Back)
	end
	if d.moved then
		clickGuard[d.key] = os.clock() + 0.4
		setSwitch(d.key, d.holder.Position.X.Offset > 9)
	end
end

local function makeSwitch(parent, key, x, y, on, z)
	local root = button(parent, x, y, 44, 26, z or 5)
	root.BackgroundColor3 = on and C.green or C.white
	root.BackgroundTransparency = on and 0 or 0.87
	round(root, 13)
	root.ClipsDescendants = true
	-- hairline de la cápsula (estilo iOS)
	outline(root, C.white, 0.86, 1)

	-- perilla + sombra ajustada (sin manchas que salgan de la cápsula)
	local holder = mk("Frame", {
		BackgroundTransparency = 1,
		Position               = UDim2.fromOffset(on and 18 or 0, 0),
		Size                   = UDim2.fromOffset(44, 26),
		ZIndex                 = (z or 5) + 1,
	})
	holder.Parent = root

	local shadow = mk("Frame", {
		BackgroundColor3      = C.black,
		BackgroundTransparency = 0.26,
		Size                  = UDim2.fromOffset(20, 20),
		Position              = UDim2.fromOffset(3, 3),
		BorderSizePixel       = 0,
		ZIndex                = (z or 5) + 1,
	})
	round(shadow, 10)
	shadow.Parent = holder

	local knob = mk("TextButton", {
		BackgroundColor3 = C.white,
		Size             = UDim2.fromOffset(22, 22),
		Position         = UDim2.fromOffset(2, 2),
		Text             = "",
		AutoButtonColor  = false,
		BorderSizePixel  = 0,
		ZIndex           = (z or 5) + 2,
	})
	round(knob, 11)
	knob.Parent = holder

	-- ── activar: clic/tap (el evento más fiable en cualquier executor) ──
	local function toggleSwitch()
		local g = clickGuard[key]
		if g and os.clock() < g then return end
		setSwitch(key, not Config[key])
	end

	root.MouseButton1Click:Connect(toggleSwitch)
	-- la perilla también es un botón: si el toque cae justo encima, responde
	knob.MouseButton1Click:Connect(toggleSwitch)

	-- ── arrastrar la perilla, como un deslizador ──
	local function beginKnob(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then return end
		knobDrag = {
			key = key,
			root = root,
			holder = holder,
			knob = knob,
			startX = input.Position.X,
			startPos = holder.Position.X.Offset,
			moved = false,
		}
		-- la perilla se ensancha al presionarla
		tween(knob, 0.24, {Size = UDim2.fromOffset(24, 22)}, Enum.EasingStyle.Back)
	end

	root.InputBegan:Connect(beginKnob)
	knob.InputBegan:Connect(beginKnob)

	-- mientras el dedo siga sobre el switch, lo seguimos aquí
	local function followFinger(input)
		if knobDrag and knobDrag.root == root then
			knobMove(input.Position.X)
		end
	end
	root.InputChanged:Connect(followFinger)
	knob.InputChanged:Connect(followFinger)

	root.InputEnded:Connect(knobRelease)
	knob.InputEnded:Connect(knobRelease)
	root.MouseButton1Up:Connect(knobRelease)
	knob.MouseButton1Up:Connect(knobRelease)

	switchParts(key, root, holder, nil)
	return root
end

-- respaldo global: si al arrastrar la perilla el dedo sale del switch
UserInputService.InputChanged:Connect(function(input)
	if not knobDrag then return end
	if input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch then
		knobMove(input.Position.X)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		knobRelease()
	end
end)

-- ═══════════════════════════════════════════════════════════════════
-- slider
-- ═══════════════════════════════════════════════════════════════════
local Formatters = {
	fov      = function(v) return tostring(v) .. "°" end,
	hbScale  = function(v) return string.format("%.1fx", v / 100) end,
	espRange = function(v) return tostring(v) .. " m" end,
	espAlpha = function(v) return tostring(v) .. "%" end,
}

local function fmtValue(key, v)
	local f = Formatters[key]
	if f then return f(v) end
	return tostring(v)
end

-- etiquetas del inicio: muestran el valor o "apagado" si el switch está off
refreshHomeLabels = function()
	local map = {
		{ id = "aim", key = "aim",  fmt = function() return fmtValue("fov", Config.fov) end,          off = "apagado" },
		{ id = "hb",  key = "hb",   fmt = function() return fmtValue("hbScale", Config.hbScale) end, off = "apagado" },
		{ id = "cam", key = "cam",  fmt = function() return tostring(Config.camSmooth) end,          off = "apagado" },
		{ id = "esp", key = "esp",  fmt = function() return fmtValue("espRange", Config.espRange) end, off = "apagado" },
	}
	for _, m in ipairs(map) do
		local lbl = ValueLabels[m.id]
		if lbl then
			local on = Config[m.key]
			lbl.Text = on and m.fmt() or m.off
			lbl.TextTransparency = on and T_LABEL2 or 0.5
		end
	end
end

local dragging = nil -- {kind="slider", ...}

local function makeSlider(parent, key, x, y, opts, sep)
	local r = mk("Frame", {
		BackgroundTransparency = 1,
		Position               = UDim2.fromOffset(x, y),
		Size                   = UDim2.fromOffset(PAGE_W, ROW_H),
		ZIndex                 = 3,
	})
	r.Parent = parent

	if sep then
		local s = mk("Frame", {
			BackgroundColor3      = C.white,
			BackgroundTransparency = T_HAIR,
			Position              = UDim2.fromOffset(12, 0),
			Size                  = UDim2.new(1, -12, 0, 1),
			BorderSizePixel       = 0,
			ZIndex                = 3,
		})
		s.Parent = r
	end

	local min, max = opts.min, opts.max
	local step = opts.step or 1

	text(r, 12, 0, 74, ROW_H, opts.label, 13, C.label, 0, FONT_BODY)

	local num = text(r, PAGE_W - 12 - 42, 0, 42, ROW_H, "", 12, C.label2, T_LABEL2,
		FONT_BODY, Enum.TextXAlignment.Right)

	-- pista
	local TRACK_X, TRACK_W = 96, 200
	local track = mk("Frame", {
		BackgroundColor3      = C.white,
		BackgroundTransparency = 0.86,
		Position              = UDim2.fromOffset(TRACK_X, ROW_H / 2 - 1.5),
		Size                  = UDim2.fromOffset(TRACK_W, 3),
		BorderSizePixel       = 0,
		ZIndex                = 4,
	})
	round(track, 2)
	track.Parent = r

	local fill = mk("Frame", {
		BackgroundColor3 = Color3.fromRGB(232, 232, 236),
		Size             = UDim2.fromOffset(0, 3),
		Position         = UDim2.fromOffset(TRACK_X, ROW_H / 2 - 1.5),
		BorderSizePixel  = 0,
		ZIndex           = 5,
	})
	round(fill, 2)
	fill.Parent = r

	-- perilla con sombra
	local thumbHolder = mk("Frame", {
		BackgroundTransparency = 1,
		Position               = UDim2.fromOffset(TRACK_X, ROW_H / 2 - 9),
		Size                   = UDim2.fromOffset(22, 22),
		ZIndex                 = 6,
	})
	thumbHolder.Parent = r

	local sh2 = mk("Frame", {
		BackgroundColor3      = C.black,
		BackgroundTransparency = 0.42,
		Size                  = UDim2.fromOffset(21, 21),
		Position              = UDim2.fromOffset(1, 1),
		BorderSizePixel       = 0,
		ZIndex                = 6,
	})
	round(sh2, 11)
	sh2.Parent = thumbHolder

	local thumb = mk("Frame", {
		BackgroundColor3 = C.white,
		Size             = UDim2.fromOffset(18, 18),
		Position         = UDim2.fromOffset(2, 2),
		BorderSizePixel  = 0,
		ZIndex           = 7,
	})
	round(thumb, 9)
	thumb.Parent = thumbHolder

	local pct = 0
	local function apply(v, animate)
		v = clamp(v, min, max)
		if step ~= 0 then
			v = math.floor(v / step + 0.5) * step
		end
		Config[key] = v
		pct = (v - min) / (max - min)
		local shown = fmtValue(key, v)
		num.Text = shown
		fill.Size = UDim2.fromOffset(TRACK_W * pct, 3)
		thumbHolder.Position = UDim2.fromOffset(TRACK_X + TRACK_W * pct - 9, ROW_H / 2 - 9)
		if refreshHomeLabels then refreshHomeLabels() end
		fireHook(key)
		if opts.onChange then opts.onChange(v) end
	end

	local function fromPointer(px)
		local ap, asz = track.AbsolutePosition, track.AbsoluteSize
		if not asz or asz.X <= 0 then return end
		local p = clamp((px - ap.X) / asz.X, 0, 1)
		apply(min + p * (max - min))
	end

	local hit = button(r, TRACK_X - 8, 0, TRACK_W + 16, ROW_H, 6)
	hit.MouseButton1Down:Connect(function()
		dragging = {kind = "slider", apply = fromPointer}
		fromPointer(mouse.X)
	end)

	apply(opts.value or min)

	return r, apply
end

-- ═══════════════════════════════════════════════════════════════════
-- select (dropdown)
-- ═══════════════════════════════════════════════════════════════════
local popup = nil

local function closePopup()
	if popup then
		popup:Destroy()
		popup = nil
	end
end

local function showDropdown(btn, items, current, onPick)
	closePopup()
	local cam = workspace.CurrentCamera
	local vs = cam and cam.ViewportSize or Vector2.new(1920, 1080)

	local w = math.max(btn.AbsoluteSize.X, 104)
	local rh = 26
	local h = rh * #items + 8

	local x = btn.AbsolutePosition.X + btn.AbsoluteSize.X - w
	local y = btn.AbsolutePosition.Y + btn.AbsoluteSize.Y + 4
	if y + h > vs.Y - 8 then
		y = btn.AbsolutePosition.Y - h - 4
	end
	if y < 8 then y = 8 end
	if x + w > vs.X - 8 then x = vs.X - 8 - w end
	if x < 8 then x = 8 end

	local p = mk("Frame", {
		BackgroundColor3 = C.panel,
		Size             = UDim2.fromOffset(w, h),
		Position         = UDim2.fromOffset(x, y),
		BorderSizePixel  = 0,
		ZIndex           = 60,
	})
	p.Parent = screen
	round(p, 10)
	outline(p, C.white, 0.92, 1)
	p.ClipsDescendants = true
	popup = p

	for i, it in ipairs(items) do
		local b = mk("TextButton", {
			BackgroundTransparency = 1,
			Position               = UDim2.fromOffset(4, 4 + (i - 1) * rh),
			Size                   = UDim2.fromOffset(w - 8, rh),
			Text                   = it.label,
			TextColor3             = (it.value == current) and C.green or C.label2,
			TextSize               = 12,
			Font                   = FONT_BODY,
			TextXAlignment         = Enum.TextXAlignment.Left,
			AutoButtonColor        = false,
			ZIndex                 = 61,
		})
		b.Parent = p
		mk("UIPadding", {PaddingLeft = UDim.new(0, 8)}, b)
		hover(b, 0.90, 1)
		b.MouseButton1Click:Connect(function()
			onPick(it.value, it.label)
			closePopup()
		end)
	end
end

local function makeSelect(parent, key, x, y, items, width, z)
	local b = button(parent, x, y, width, 26, z or 5)
	b.BackgroundColor3 = C.white
	b.BackgroundTransparency = 0.92
	round(b, 7)

	local current = items[1]
	for _, it in ipairs(items) do
		if it.value == Config[key] then current = it end
	end

	local lbl = text(b, 9, 0, width - 26, 26, current.label, 12, C.label2, T_LABEL2,
		FONT_BODY, Enum.TextXAlignment.Left)
	chevron(b, width - 13, 13, 4, C.label3, T_LABEL3, "down", (z or 5) + 1)

	local function repaint(val, name)
		for _, it in ipairs(items) do
			if it.value == val then
				lbl.Text = it.label
			end
		end
		Config[key] = val
		fireHook(key)
	end

	b.MouseButton1Click:Connect(function()
		showDropdown(b, items, Config[key], function(val, name)
			repaint(val, name)
		end)
	end)
	hover(b, 0.87, 0.92)
	return b
end

-- ═══════════════════════════════════════════════════════════════════
-- segmentado
-- ═══════════════════════════════════════════════════════════════════
local segments = {}

local function layoutSegment(seg)
	local rec = segments[seg]
	if not rec then return end
	local cursor = 2
	rec.widths = {}
	for _, it in ipairs(rec.items) do
		local b = rec.buttons[it.value]
		local w = b.AbsoluteSize.X
		if w and w > 0 then
			b.Size = UDim2.fromOffset(w, 22)
			b.Position = UDim2.fromOffset(cursor, 2)
			rec.widths[it.value] = w
			cursor = cursor + w
		end
	end
	local total = cursor + 2
	seg.Size = UDim2.fromOffset(total, 26)
	if rec.rightAlign then
		seg.Position = UDim2.fromOffset(PAGE_W - 12 - total, seg.Position.Y.Offset)
	end
	local act = rec.buttons[rec.current]
	if act then
		local aw = rec.widths[rec.current] or act.AbsoluteSize.X
		local ax = act.Position.X.Offset
		if aw and aw > 0 then
			rec.pill.Size = UDim2.fromOffset(aw, 22)
			rec.pill.Position = UDim2.fromOffset(ax, 2)
		end
	end
end

local function makeSegment(parent, key, x, y, items, z, rightAlign)
	local seg = mk("Frame", {
		BackgroundColor3      = C.white,
		BackgroundTransparency = 0.92,
		Position              = UDim2.fromOffset(x, y),
		Size                  = UDim2.fromOffset(80, 26),
		BorderSizePixel       = 0,
		ZIndex                = z or 5,
	})
	round(seg, 8)
	seg.Parent = parent

	local pill = mk("Frame", {
		BackgroundColor3      = C.white,
		BackgroundTransparency = 0.84,
		Size                  = UDim2.fromOffset(0, 22),
		Position              = UDim2.fromOffset(2, 2),
		BorderSizePixel       = 0,
		ZIndex                = (z or 5) + 1,
	})
	round(pill, 6)
	pill.Parent = seg

	local rec = {items = items, buttons = {}, pill = pill, current = Config[key] or items[1].value,
		rightAlign = rightAlign}
	segments[seg] = rec

	for i, it in ipairs(items) do
		local b = mk("TextButton", {
			BackgroundTransparency = 1,
			Size                   = UDim2.fromOffset(0, 22),
			AutomaticSize          = Enum.AutomaticSize.X,
			Text                   = it.label,
			TextSize               = 11.5,
			Font                   = FONT_MED,
			TextColor3             = (it.value == rec.current) and C.label or C.label2,
			TextTransparency       = (it.value == rec.current) and 0 or T_LABEL2,
			AutoButtonColor        = false,
			ZIndex                 = (z or 5) + 2,
		})
		b.Parent = seg
		mk("UIPadding", {PaddingLeft = UDim.new(0, 11), PaddingRight = UDim.new(0, 11)}, b)
		rec.buttons[it.value] = b
		b.MouseButton1Click:Connect(function()
			rec.current = it.value
			Config[key] = it.value
			for _, o in ipairs(items) do
				local ob = rec.buttons[o.value]
				local sel = (o.value == it.value)
				tween(ob, 0.22, {
					TextColor3       = sel and C.label or C.label2,
					TextTransparency = sel and 0 or T_LABEL2,
				})
			end
			layoutSegment(seg)
			local aw = rec.widths[it.value] or rec.buttons[it.value].AbsoluteSize.X
			tween(pill, 0.36, {
				Size     = UDim2.fromOffset(aw, 22),
				Position = UDim2.fromOffset(rec.buttons[it.value].Position.X.Offset, 2),
			}, Enum.EasingStyle.Quint)
		end)
	end

	task.defer(function()
		task.wait()
		layoutSegment(seg)
	end)

	return seg
end

-- ═══════════════════════════════════════════════════════════════════
-- listas y filas
-- ═══════════════════════════════════════════════════════════════════
local function makeList(parent, y, height)
	local l = mk("Frame", {
		BackgroundColor3      = C.white,
		BackgroundTransparency = 0.95,
		Position              = UDim2.fromOffset(PAGE_X, y),
		Size                  = UDim2.fromOffset(PAGE_W, height),
		BorderSizePixel       = 0,
		ZIndex                = 2,
	})
	round(l, LIST_R)
	l.Parent = parent
	-- brillo interior superior
	local hl = mk("Frame", {
		BackgroundColor3      = C.white,
		BackgroundTransparency = 0.91,
		Position              = UDim2.fromOffset(0, 0),
		Size                  = UDim2.fromOffset(PAGE_W, 1),
		BorderSizePixel       = 0,
		ZIndex                = 2,
	})
	hl.Parent = l
	return l
end

local function makeRow(list, index, opts)
	local r = button(list, 0, index * ROW_H, PAGE_W, ROW_H, 3)
	if opts.click then
		r.MouseButton1Click:Connect(opts.click)
	end
	if opts.hoverable then
		hover(r, 0.97, 1)
	end

	if index > 0 then
		local sep = mk("Frame", {
			BackgroundColor3      = C.white,
			BackgroundTransparency = T_HAIR,
			Position              = UDim2.fromOffset(12, 0),
			Size                  = UDim2.new(1, -12, 0, 1),
			BorderSizePixel       = 0,
			ZIndex                = 2,
		})
		sep.Parent = r
	end

	if opts.k then
		text(r, 12, 0, 200, ROW_H, opts.k, 13, C.label, 0, FONT_BODY)
	end

	-- valor a la derecha
	local valueRight = PAGE_W - 12
	if opts.sw then
		valueRight = PAGE_W - 12 - 44 - 8
	end
	local val
	if opts.v then
		val = text(r, valueRight - 120, 0, 120, ROW_H, opts.v, 12.5, C.label2, T_LABEL2,
			FONT_BODY, Enum.TextXAlignment.Right)
		if opts.valueId then
			ValueLabels[opts.valueId] = val
		end
	end

	if opts.sw then
		makeSwitch(r, opts.sw, PAGE_W - 12 - 44, (ROW_H - 26) / 2, Config[opts.sw], 4)
	end

	if opts.select then
		makeSelect(r, opts.select.key, PAGE_W - 12 - opts.select.w, (ROW_H - 26) / 2,
			opts.select.items, opts.select.w, 4)
	end

	return r
end

-- ═══════════════════════════════════════════════════════════════════
-- ventana
-- ═══════════════════════════════════════════════════════════════════
local win = mk("Frame", {
	Name                  = "Window",
	BackgroundColor3      = C.panel,
	BackgroundTransparency = 0.15,
	Size                  = UDim2.fromOffset(WIN_W, NAV_H + 400),
	Position              = UDim2.fromOffset(40, 60),
	BorderSizePixel       = 0,
	Active                = true,
})
win.Parent = screen
round(win, WIN_R)
outline(win, C.white, 0.88, 1)
win.ClipsDescendants = true

local winScale = mk("UIScale", {Scale = 1})
winScale.Parent = win

-- brillo superior del vidrio SIN UIGradient:
-- una sola línea de 1px casi transparente (antes era un rectángulo blanco
-- que, si el executor no aplicaba el gradiente, tapaba media ventana)
local sheen = mk("Frame", {
	BackgroundColor3       = C.white,
	BackgroundTransparency = 0.94,
	Position               = UDim2.fromOffset(0, 0),
	Size                   = UDim2.new(1, 0, 0, 1),
	BorderSizePixel        = 0,
	ZIndex                 = 1,
})
sheen.Parent = win

-- superficie de arrastre: botón invisible que cubre toda la ventana.
-- Así se puede mover el panel desde cualquier zona vacía (barra, márgenes,
-- fondos de las páginas) sin robar clics a botones ni al scroll, porque
-- va por debajo del contenido.
local dragSurface = mk("TextButton", {
	BackgroundTransparency = 1,
	Position               = UDim2.fromOffset(0, 0),
	Size                   = UDim2.new(1, 0, 1, 0),
	Text                   = "",
	AutoButtonColor        = false,
	BorderSizePixel        = 0,
	ZIndex                 = 2,
})
dragSurface.Parent = win

-- ── barra de navegación ──
local nav = mk("Frame", {
	BackgroundTransparency = 1,
	Position               = UDim2.fromOffset(0, 0),
	Size                   = UDim2.fromOffset(WIN_W, NAV_H),
	ZIndex                 = 5,
	Active                 = true,
})
nav.Parent = win

local backBtn = button(nav, 12, 8, 28, 28, 6)
round(backBtn, 14)
local backIcon = mk("Frame", {BackgroundTransparency = 1, Size = UDim2.fromOffset(14, 14),
	Position = UDim2.fromOffset(7, 7), ZIndex = 6})
backIcon.Parent = backBtn
chevron(backIcon, 7, 7, 8, C.label2, T_LABEL2, "left", 7)

local closeBtn = button(nav, WIN_W - 12 - 28, 8, 28, 28, 6)
round(closeBtn, 14)
local closeIcon = mk("Frame", {BackgroundTransparency = 1, Size = UDim2.fromOffset(14, 14),
	Position = UDim2.fromOffset(7, 7), ZIndex = 6})
closeIcon.Parent = closeBtn
local x1 = mk("Frame", {BackgroundColor3 = C.label2, BackgroundTransparency = T_LABEL2,
	Size = UDim2.fromOffset(9, 1.6), Position = UDim2.fromOffset(7 - 4.5, 7 - 0.8),
	AnchorPoint = Vector2.new(0.5, 0.5), Rotation = 45, BorderSizePixel = 0, ZIndex = 7})
round(x1, 0.8); x1.Parent = closeIcon
local x2 = mk("Frame", {BackgroundColor3 = C.label2, BackgroundTransparency = T_LABEL2,
	Size = UDim2.fromOffset(9, 1.6), Position = UDim2.fromOffset(7 + 4.5, 7 + 0.8),
	AnchorPoint = Vector2.new(0.5, 0.5), Rotation = 45, BorderSizePixel = 0, ZIndex = 7})
round(x2, 0.8); x2.Parent = closeIcon

local title = text(nav, 0, 0, WIN_W, NAV_H, "duelos", 13, C.label, 0, FONT_SEMI,
	Enum.TextXAlignment.Center, Enum.TextYAlignment.Center, 7)

-- iconos: hover + press
local function iconHover(b)
	b.MouseEnter:Connect(function()
		tween(b, 0.2, {BackgroundTransparency = 0.92})
		tween(b, 0.2, {BackgroundColor3 = C.white})
	end)
	b.MouseLeave:Connect(function()
		tween(b, 0.2, {BackgroundTransparency = 1})
	end)
end
iconHover(backBtn)
iconHover(closeBtn)

-- ── escenario (páginas) · con scroll cuando no cabe ──
local stage = mk("ScrollingFrame", {
	BackgroundTransparency      = 1,
	Position                    = UDim2.fromOffset(0, NAV_H),
	Size                        = UDim2.fromOffset(WIN_W, 400),
	BorderSizePixel             = 0,
	ClipsDescendants            = true,
	ScrollingDirection          = Enum.ScrollingDirection.Y,
	ScrollBarThickness          = 3,
	ScrollBarImageColor3        = C.white,
	ScrollBarImageTransparency  = 0.78,
	ScrollBarInset              = Enum.ScrollBarInset.None,
	ElasticBehavior             = Enum.ElasticBehavior.WhenScrollable,
	CanvasSize                  = UDim2.fromOffset(WIN_W, 400),
	ZIndex                      = 3,
})
stage.Parent = win

-- ── agarre de redimensión (esquina inferior derecha) ──
local grip = mk("TextButton", {
	BackgroundTransparency = 1,
	Position               = UDim2.new(1, -26, 1, -26),
	Size                   = UDim2.fromOffset(26, 26),
	Text                   = "",
	AutoButtonColor        = false,
	ZIndex                 = 20,
})
grip.Parent = win

for i = 1, 3 do
	local l = mk("Frame", {
		BackgroundColor3      = C.white,
		BackgroundTransparency = 0.7,
		Size                  = UDim2.fromOffset(12, 1.4),
		Position              = UDim2.fromOffset(8 + (i - 1) * 5, 18 - (i - 1) * 5),
		AnchorPoint           = Vector2.new(0.5, 0.5),
		Rotation              = -45,
		BorderSizePixel       = 0,
		ZIndex                = 21,
	})
	round(l, 0.7)
	l.Parent = grip
end

do
	local resizing = false
	local startX, startZoom = 0, 1

	-- eventos del propio agarre (no dependen de input.Target)
	grip.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then return end
		resizing = true
		startX = input.Position.X
		startZoom = ZOOM
	end)

	grip.MouseButton1Down:Connect(function(x)
		if resizing then return end
		resizing = true
		startX = x
		startZoom = ZOOM
	end)

	UserInputService.InputChanged:Connect(function(input)
		if not resizing then return end
		local px
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			px = input.Position.X
		end
		if not px then return end
		ZOOM = clamp(startZoom + (px - startX) / 260, 0.5, 1.4)
		applyScale()
	end)

	UserInputService.InputEnded:Connect(function(input)
		if resizing then
			resizing = false
			prefs.zoom = ZOOM
			savePrefs()
		end
	end)
	grip.InputEnded:Connect(function()
		if resizing then
			resizing = false
			prefs.zoom = ZOOM
			savePrefs()
		end
	end)
	grip.MouseButton1Up:Connect(function()
		if resizing then
			resizing = false
			prefs.zoom = ZOOM
			savePrefs()
		end
	end)
end

-- ═══════════════════════════════════════════════════════════════════
-- páginas
-- ═══════════════════════════════════════════════════════════════════
local pages = {}
local heights = {}
local currentPage = nil
local currentPageId = "home"

local function newPage(id)
	local p = mk("Frame", {
		BackgroundTransparency = 1,
		Position               = UDim2.fromOffset(0, 0),
		Size                   = UDim2.fromOffset(WIN_W, 100),
		BorderSizePixel        = 0,
		Visible                = false,
		ZIndex                 = 3,
	})
	p.Parent = stage
	pages[id] = p
	return p
end

-- ── helpers de contenido ──
local function caption(p, y, str)
	text(p, PAGE_X + 4, y, PAGE_W, 20, str, 11, C.label3, T_LABEL3, FONT_BODY)
	return y + 20
end

-- ═══════════════════════════════════════════════════════════════════
-- HOME
-- ═══════════════════════════════════════════════════════════════════
local home = newPage("home")
do
	local y = 4

	-- perfil
	local me = button(home, PAGE_X + 2, y, PAGE_W - 4, 74, 3)
	local av = mk("Frame", {
		BackgroundColor3 = Color3.fromRGB(58, 58, 62),
		Position         = UDim2.fromOffset(0, 6),
		Size             = UDim2.fromOffset(52, 52),
		BorderSizePixel  = 0,
		ZIndex           = 4,
	})
	round(av, 26)
	outline(av, C.white, 0.80, 1)
	av.Parent = me

	local avInitials = text(av, 0, 0, 52, 52, "AL", 16, C.white, 0.08, FONT_MED,
		Enum.TextXAlignment.Center, Enum.TextYAlignment.Center, 5)

	local avImg = mk("ImageLabel", {
		BackgroundTransparency = 1,
		Position               = UDim2.fromOffset(0, 0),
		Size                   = UDim2.fromOffset(52, 52),
		BorderSizePixel        = 0,
		ScaleType              = Enum.ScaleType.Crop,
		ZIndex                 = 6,
	})
	round(avImg, 26)
	avImg.Parent = av

	local function refreshAvatar()
		pcall(function()
			local id = player.UserId
			if id and id > 0 then
				avImg.Image = ("https://www.roblox.com/headshot-thumbnail/image?userId=%d&width=420&height=420&format=png"):format(id)
			end
		end)
	end
	refreshAvatar()

	text(me, 63, 18, 240, 20, player.Name or "usuario", 15, C.label, 0, FONT_SEMI)
	local meSub = text(me, 63, 38, 240, 16, "detectando…", 11.5, C.label2, T_LABEL2, FONT_BODY)
	meSub.TextSize = 11

	me.MouseButton1Click:Connect(function()
		toast("TODO: aquí se sube la foto de perfil")
		refreshAvatar()
	end)

	y = y + 74

	-- lista principal
	local l1 = makeList(home, y, ROW_H * 5)
	makeRow(l1, 0, {k = "foto de perfil", v = "tocar el avatar", hoverable = true,
		click = function() toast("TODO: aquí se sube la foto de perfil") end})
	makeRow(l1, 1, {k = "aim", v = "90°", sw = "aim", valueId = "aim", hoverable = true,
		click = function() showPage("aim") end})
	makeRow(l1, 2, {k = "hitbox", v = "2.0x", sw = "hb", valueId = "hb", hoverable = true,
		click = function() showPage("hitbox") end})
	makeRow(l1, 3, {k = "cámara", v = "40", sw = "cam", valueId = "cam", hoverable = true,
		click = function() showPage("cam") end})
	makeRow(l1, 4, {k = "esp", v = "140 m", sw = "esp", valueId = "esp", hoverable = true,
		click = function() showPage("esp") end})
	y = y + ROW_H * 5 + 10

	-- detección en partida
	y = caption(home, y, "detectado en la partida")
	local l2 = makeList(home, y, ROW_H * 2)
	makeRow(l2, 0, {k = "enemigos", v = "—", valueId = "enemigos"})
	makeRow(l2, 1, {k = "compañeros", v = "—", valueId = "companeros"})
	y = y + ROW_H * 2

	heights.home = y + 16
end

-- ═══════════════════════════════════════════════════════════════════
-- AIM
-- ═══════════════════════════════════════════════════════════════════
local aim = newPage("aim")
do
	local y = 4
	local l = makeList(aim, y, ROW_H * 4)
	makeRow(l, 0, {k = "activar", sw = "aim"})
	makeRow(l, 1, {k = "mantener presionado", sw = "aimHold"})
	makeRow(l, 2, {k = "parte del cuerpo", select = {
		key = "aimBone", w = 96,
		items = {
			{ value = "head",  label = "cabeza" },
			{ value = "torso", label = "torso" },
			{ value = "near",  label = "más cercano" },
		},
	}})
	makeRow(l, 3, {k = "comportamiento humano", sw = "humanize"})
	y = y + ROW_H * 4 + 10

	makeSlider(aim, "fov", PAGE_X, y, {label = "fov", min = 10, max = 360, step = 5, value = 90})
	y = y + ROW_H
	makeSlider(aim, "speed", PAGE_X, y, {label = "velocidad", min = 1, max = 100, step = 1, value = 65}, true)
	y = y + ROW_H

	heights.aim = y + 16
end

-- ═══════════════════════════════════════════════════════════════════
-- HITBOX
-- ═══════════════════════════════════════════════════════════════════
local hitbox = newPage("hitbox")
do
	local y = 4
	local l = makeList(hitbox, y, ROW_H * 2)
	makeRow(l, 0, {k = "aumentar hitbox", sw = "hb"})
	makeRow(l, 1, {k = "parte", select = {
		key = "hbPart", w = 88,
		items = {
			{ value = "head",  label = "cabeza" },
			{ value = "torso", label = "torso" },
			{ value = "all",   label = "cuerpo" },
		},
	}})
	y = y + ROW_H * 2 + 10

	makeSlider(hitbox, "hbScale", PAGE_X, y, {label = "escala", min = 100, max = 400, step = 10, value = 200})
	y = y + ROW_H
	makeSlider(hitbox, "hbMax", PAGE_X, y, {label = "tope", min = 0, max = 400, step = 5, value = 115}, true)
	y = y + ROW_H + 10

	local l2 = makeList(hitbox, y, ROW_H)
	makeRow(l2, 0, {k = "revertir al salir", sw = "hbRevert"})
	y = y + ROW_H

	heights.hitbox = y + 16
end

-- ═══════════════════════════════════════════════════════════════════
-- CÁMARA
-- ═══════════════════════════════════════════════════════════════════
local cam = newPage("cam")
do
	local y = 4
	local l = makeList(cam, y, ROW_H * 2)
	makeRow(l, 0, {k = "bloquear al objetivo", sw = "cam"})
	makeRow(l, 1, {k = "centro", select = {
		key = "camAnchor", w = 88,
		items = {
			{ value = "head", label = "cabeza" },
			{ value = "torso", label = "torso" },
			{ value = "feet", label = "pies" },
		},
	}})
	y = y + ROW_H * 2 + 10

	makeSlider(cam, "camSmooth", PAGE_X, y, {label = "suavizado", min = 0, max = 100, step = 1, value = 40})
	y = y + ROW_H
	makeSlider(cam, "camFov", PAGE_X, y, {label = "fov", min = 40, max = 120, step = 1, value = 70}, true)
	y = y + ROW_H

	heights.cam = y + 16
end

-- ═══════════════════════════════════════════════════════════════════
-- ESP
-- ═══════════════════════════════════════════════════════════════════
local esp = newPage("esp")
do
	local y = 4
	y = caption(esp, y, "solo enemigos · nunca compañeros")
	local l = makeList(esp, y, ROW_H * 3)
	makeRow(l, 0, {k = "activar", sw = "esp"})
	makeRow(l, 1, {k = "a través de paredes", sw = "espWall"})
	local rowStyle = makeRow(l, 2, {k = "estilo"})
	makeSegment(rowStyle, "espStyle", PAGE_W - 12 - 118, (ROW_H - 26) / 2, {
		{ value = "box", label = "caja" },
		{ value = "dot", label = "punto" },
	}, 5, true)
	y = y + ROW_H * 3 + 10

	makeSlider(esp, "espRange", PAGE_X, y, {label = "rango", min = 20, max = 300, step = 10, value = 140})
	y = y + ROW_H
	makeSlider(esp, "espAlpha", PAGE_X, y, {label = "opacidad", min = 10, max = 100, step = 5, value = 80}, true)
	y = y + ROW_H

	heights.esp = y + 16
end

-- ═══════════════════════════════════════════════════════════════════
-- navegación
-- ═══════════════════════════════════════════════════════════════════
-- cada página mide exactamente lo que ocupa su contenido
for id, p in pairs(pages) do
	p.Size = UDim2.fromOffset(WIN_W, heights[id] or 400)
end

local function setHeight(id, animate)
	local contentH = heights[id] or 400
	local cam = workspace.CurrentCamera
	local vs = cam and cam.ViewportSize or Vector2.new(1920, 1080)

	-- la ventana nunca pasa de la pantalla: si el contenido no cabe, se desplaza
	local maxH = math.max(200, (vs.Y - 80) / math.max(SCALE, 0.1))
	local h = math.min(NAV_H + contentH, maxH)

	stage.CanvasSize = UDim2.fromOffset(WIN_W, contentH)
	stage.CanvasPosition = Vector2.new(0, 0)

	if animate then
		tween(win, 0.3, {Size = UDim2.fromOffset(WIN_W, h)}, Enum.EasingStyle.Quint)
		tween(stage, 0.3, {Size = UDim2.fromOffset(WIN_W, h - NAV_H)}, Enum.EasingStyle.Quint)
	else
		win.Size = UDim2.fromOffset(WIN_W, h)
		stage.Size = UDim2.fromOffset(WIN_W, h - NAV_H)
	end
end

showPage = function(id, back)
	local next = pages[id]
	if not next then return end
	local cur = currentPage

	if cur == next then return end

	if cur then
		cur.Visible = false
	end

	next.Position = UDim2.fromOffset(back and -14 or 16, 0)
	next.Visible = true

	tween(next, 0.3, {
		Position = UDim2.fromOffset(0, 0),
	}, Enum.EasingStyle.Quint)

	currentPage = next
	currentPageId = id
	title.Text = (id == "home") and "duelos" or id
	backBtn.Visible = (id ~= "home")
	setHeight(id, true)

	-- el segmentado necesita el layout para medir el pill
	if id == "esp" then
		task.defer(function()
			task.wait()
			for seg in pairs(segments) do layoutSegment(seg) end
		end)
	end
end

-- ═══════════════════════════════════════════════════════════════════
-- arrastre de la ventana (desde cualquier zona vacía)
-- ═══════════════════════════════════════════════════════════════════
do
	local dragging = false
	local startPos, startMouse, startClock = nil, nil, 0

	-- se arranca con eventos del PROPIO objeto (no dependen de input.Target,
	-- que algunos executors entregan como nil)
	local function beginDrag(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then return end
		if dragging then return end
		startPos = win.Position
		startMouse = Vector2.new(input.Position.X, input.Position.Y)
		startClock = os.clock()
		dragging = true
	end

	dragSurface.InputBegan:Connect(beginDrag)
	nav.InputBegan:Connect(beginDrag)

	local function endDrag()
		dragging = false
	end
	dragSurface.InputEnded:Connect(endDrag)
	nav.InputEnded:Connect(endDrag)

	-- mueve la ventana aplicando el delta desde el punto de agarre
	local function applyDrag(px, py)
		local cam = workspace.CurrentCamera
		local vs = cam and cam.ViewportSize or Vector2.new(1920, 1080)
		local s = (SCALE ~= 0) and SCALE or 1
		local dx = (px - startMouse.X) / s
		local dy = (py - startMouse.Y) / s

		-- los límites se convierten a unidades GUI (vs.X está en píxeles)
		local maxX = vs.X / s - 70
		local maxY = vs.Y / s - 50
		local minX = -(WIN_W - 70)

		win.Position = UDim2.fromOffset(
			clamp(startPos.X.Offset + dx, minX, maxX),
			clamp(startPos.Y.Offset + dy, 0, maxY)
		)
	end

	-- respaldo: si el executor no entrega el InputChanged global, seguimos
	-- el puntero con el evento del propio objeto
	dragSurface.InputChanged:Connect(function(input)
		if not dragging then return end
		applyDrag(input.Position.X, input.Position.Y)
	end)

	UserInputService.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch then return end
		-- seguro: si el executor nunca entrega el InputEnded, no dejamos
		-- el panel pegado al cursor para siempre
		if os.clock() - startClock > 12 then
			dragging = false
			return
		end
		applyDrag(input.Position.X, input.Position.Y)
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

-- ═══════════════════════════════════════════════════════════════════
-- FAB (botón flotante de ojo)
-- ═══════════════════════════════════════════════════════════════════
-- ¿tienes tu propio icono? pega aquí el id: "rbxassetid://123456789"
-- (Roblox no renderiza SVG: usa un PNG. Si lo dejas vacío se dibuja vectorial)
local ICON_EYE = ""

local fab = mk("TextButton", {
	BackgroundColor3      = C.panel,
	BackgroundTransparency = 0.34,
	Size                  = UDim2.fromOffset(40, 40),
	Position              = UDim2.fromOffset(100, 100),
	Text                  = "",
	AutoButtonColor       = false,
	BorderSizePixel       = 0,
	ZIndex                = 30,
})
fab.Parent = screen
round(fab, 20)
outline(fab, C.white, 0.84, 1)

-- ojo: rombo redondeado (la forma real del ojo) con pupila
if ICON_EYE ~= "" then
	local ic = mk("ImageLabel", {
		BackgroundTransparency = 1,
		Position               = UDim2.fromOffset(8, 8),
		Size                   = UDim2.fromOffset(24, 24),
		Image                  = ICON_EYE,
		BackgroundColor3       = C.white,
		ZIndex                 = 31,
	})
	ic.Parent = fab
else
	-- ojo: forma rellena en rombo redondeado + pupila oscura + brillo
	local eye = mk("Frame", {
		BackgroundColor3       = C.white,
		BackgroundTransparency = 0.04,
		Position               = UDim2.fromOffset(10, 10),
		Size                   = UDim2.fromOffset(20, 20),
		Rotation               = 45,
		BorderSizePixel        = 0,
		ZIndex                 = 31,
	})
	round(eye, 7)
	eye.Parent = fab

	local pupil = mk("Frame", {
		BackgroundColor3 = C.panel,
		Size             = UDim2.fromOffset(8.5, 8.5),
		Position         = UDim2.new(0.5, 0, 0.5, 0),
		AnchorPoint      = Vector2.new(0.5, 0.5),
		BorderSizePixel  = 0,
		ZIndex           = 32,
	})
	round(pupil, 4.25)
	pupil.Parent = eye

	local glint = mk("Frame", {
		BackgroundColor3 = C.white,
		Size             = UDim2.fromOffset(2.4, 2.4),
		Position         = UDim2.new(0.5, -1.5, 0.5, -1.5),
		AnchorPoint      = Vector2.new(0.5, 0.5),
		BorderSizePixel  = 0,
		ZIndex           = 33,
	})
	round(glint, 1.2)
	glint.Parent = eye
end

local function fabSave(x, y)
	prefs.fabX = x
	prefs.fabY = y
	savePrefs()
end

local function fabLoad()
	if prefs.fabX then
		return prefs.fabX, prefs.fabY
	end
	return nil, nil
end

-- ═══════════════════════════════════════════════════════════════════
-- preferencias guardadas (posición del ojo + zoom del panel)
-- ═══════════════════════════════════════════════════════════════════
local PREFS_KEY = "duelos.prefs"

savePrefs = function()
	if type(writefile) == "function" then
		pcall(writefile, PREFS_KEY, string.format(
			'{"x":%d,"y":%d,"z":%.2f}',
			prefs.fabX or 0, prefs.fabY or 0, prefs.zoom or 1
		))
	end
end

local function loadPrefs()
	if type(readfile) ~= "function" then return end
	local ok, data = pcall(readfile, PREFS_KEY)
	if not ok or type(data) ~= "string" then return end
	local x = data:match('"x":(%-?%d+)')
	local y = data:match('"y":(%-?%d+)')
	local z = data:match('"z":([%d%.]+)')
	if x then prefs.fabX = tonumber(x) end
	if y then prefs.fabY = tonumber(y) end
	if z then prefs.zoom = tonumber(z) or 1 end
end

loadPrefs()
ZOOM = prefs.zoom or 1

-- ═══════════════════════════════════════════════════════════════════
-- abrir / cerrar la interfaz
-- ═══════════════════════════════════════════════════════════════════
local uiOpen = true
local winTween = nil

-- una sola animación de escala a la vez (abrir/cerrar no se pisan)
local function animWin(target, time, style, dir)
	if winTween then winTween:Cancel() end
	winTween = tween(winScale, time, {Scale = target}, style, dir)
	return winTween
end

local function openUI()
	uiOpen = true
	fab.Visible = false
	win.Visible = true
	setHeight(currentPageId or "home", false)
	-- aparece con un pequeño "pop" de escala (sin CanvasGroup)
	winScale.Scale = SCALE * 0.96
	animWin(SCALE, 0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
end

local function closeUI()
	uiOpen = false
	animWin(SCALE * 0.94, 0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
	task.delay(0.2, function()
		if not uiOpen then
			win.Visible = false
			winScale.Scale = SCALE
			fab.Visible = true
		end
	end)
end

closeBtn.MouseButton1Click:Connect(function()
	closeUI()
end)

backBtn.MouseButton1Click:Connect(function()
	showPage("home", true)
end)

-- ═══════════════════════════════════════════════════════════════════
-- arrastre del FAB + guardar posición
-- ═══════════════════════════════════════════════════════════════════
	do
		local down, moved = false, false
		local sx, sy = 0, 0
		local dx, dy = 0, 0
		local fabClock = 0
		local suppressClickUntil = 0

		-- se arranca con eventos del propio botón: no dependen de input.Target
		local function beginDrag(px, py)
			down = true
			moved = false
			fabClock = os.clock()
			sx, sy = px, py
			dx = px - fab.AbsolutePosition.X
			dy = py - fab.AbsolutePosition.Y
		end

		fab.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1
				and input.UserInputType ~= Enum.UserInputType.Touch then return end
			if down then return end
			beginDrag(input.Position.X, input.Position.Y)
		end)

		fab.MouseButton1Down:Connect(function(x, y)
			if down then return end
			beginDrag(x, y)
		end)

		UserInputService.InputChanged:Connect(function(input)
			if not down then return end
			if input.UserInputType ~= Enum.UserInputType.MouseMovement
				and input.UserInputType ~= Enum.UserInputType.Touch then return end
			-- seguro contra executors que no entregan el InputEnded
			if os.clock() - fabClock > 12 then
				down = false
				return
			end
			local px, py = input.Position.X, input.Position.Y
			if not moved and (math.abs(px - sx) > 8 or math.abs(py - sy) > 8) then
				moved = true
				fab.BackgroundColor3 = Color3.fromRGB(40, 40, 44)
			end
			if not moved then return end
			local cam = workspace.CurrentCamera
			local vs = cam and cam.ViewportSize or Vector2.new(1920, 1080)
			fab.Position = UDim2.fromOffset(
				clamp(px - dx, 6, vs.X - 46),
				clamp(py - dy, 6, vs.Y - 46)
			)
		end)

		local function finishDrag()
			if not down then return end
			down = false
			fab.BackgroundColor3 = C.panel
			if moved then
				-- evita que el clic de después vuelva a abrir/cerrar
				suppressClickUntil = os.clock() + 0.45
				local cam = workspace.CurrentCamera
				local vs = cam and cam.ViewportSize or Vector2.new(1920, 1080)
				fabSave(
					clamp(fab.Position.X.Offset, 6, vs.X - 46),
					clamp(fab.Position.Y.Offset, 6, vs.Y - 46)
				)
			end
		end

		UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				finishDrag()
			end
		end)
		fab.InputEnded:Connect(finishDrag)
		fab.MouseButton1Up:Connect(finishDrag)

		-- abrir con un toque (MouseButton1Click funciona en todo executor)
		fab.MouseButton1Click:Connect(function()
			if os.clock() < suppressClickUntil then return end
			if not uiOpen then openUI() end
		end)
	end

-- ═══════════════════════════════════════════════════════════════════
-- entrada global (arrastre de sliders + cerrar popup)
-- ═══════════════════════════════════════════════════════════════════
UserInputService.InputChanged:Connect(function(input)
	if dragging and dragging.kind == "slider" then
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			dragging.apply(input.Position.X)
		elseif input.UserInputType == Enum.UserInputType.Touch then
			dragging.apply(input.Position.X)
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragging = nil
	end
end)

-- cerrar el desplegable al tocar fuera de él (por posición, sin depender
-- de input.Target, que en algunos executors llega nil)
UserInputService.InputBegan:Connect(function(input)
	if not popup then return end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1
		and input.UserInputType ~= Enum.UserInputType.Touch then return end
	local p = input.Position
	local ap = popup.AbsolutePosition
	local asz = popup.AbsoluteSize
	if p and ap and asz then
		local inside = p.X >= ap.X and p.X <= ap.X + asz.X
			and p.Y >= ap.Y and p.Y <= ap.Y + asz.Y
		if inside then return end
	end
	closePopup()
end)

-- ═══════════════════════════════════════════════════════════════════
-- escala según pantalla
-- ═══════════════════════════════════════════════════════════════════
applyScale = function()
	local cam = workspace.CurrentCamera
	local vs = cam and cam.ViewportSize or Vector2.new(1920, 1080)
	-- se adapta al ancho Y al alto de la pantalla (antes sólo al ancho, y en
	-- móvil el panel acababa ocupando media pantalla)
	local base = math.min(vs.X / 1920, vs.Y / 1080)
	base = clamp(base, 0.60, 1.15)
	SCALE = base * ZOOM
	winScale.Scale = SCALE
	-- recalcular el alto máximo según la pantalla
	if currentPageId then setHeight(currentPageId, false) end
end
applyScale()

local camObj = workspace.CurrentCamera
if camObj then
	camObj:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		applyScale()
		for seg in pairs(segments) do layoutSegment(seg) end
	end)
end
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	local c = workspace.CurrentCamera
	if c then
		c:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			applyScale()
			for seg in pairs(segments) do layoutSegment(seg) end
		end)
	end
end)

-- ═══════════════════════════════════════════════════════════════════
-- arranque
-- ═══════════════════════════════════════════════════════════════════
do
	local cam = workspace.CurrentCamera
	local vs = cam and cam.ViewportSize or Vector2.new(1920, 1080)

	-- posición inicial de la ventana (centrada)
	local s = winScale.Scale
	setHeight("home", false)
	local h = win.Size.Y.Offset
	win.Position = UDim2.fromOffset(
		math.max(8, (vs.X - WIN_W * s) / 2),
		math.max(8, (vs.Y - h * s) / 2)
	)

	-- posición del FAB
	local fx, fy = fabLoad()
	if fx then
		fab.Position = UDim2.fromOffset(fx, fy)
	else
		fab.Position = UDim2.fromOffset(vs.X - 64, vs.Y - 96)
	end
	fab.Visible = false -- el ojo sólo aparece con la interfaz cerrada

	refreshHomeLabels()

	-- primera página
	currentPage = home
	home.Visible = true
	home.Position = UDim2.fromOffset(0, 0)
	title.Text = "duelos"
	backBtn.Visible = false

	-- los pills de los segmentados se miden tras el primer layout
	task.defer(function()
		task.wait()
		for seg in pairs(segments) do layoutSegment(seg) end
	end)
end

-- ═══════════════════════════════════════════════════════════════════
-- API pública
-- (para conectar tu lógica)
-- ═══════════════════════════════════════════════════════════════════
local API = {
	Config = Config,
	Hooks  = Hooks,
	Window = win,
	show   = showPage,
	toast  = toast,
	setSwitch = setSwitch,
	refreshHomeLabels = refreshHomeLabels,

	-- etiquetas del contador de jugadores (las rellena mod_playercount)
	CountLabels = {
		enemigos   = ValueLabels["enemigos"],
		companeros = ValueLabels["companeros"],
	},

	-- abrir / cerrar desde tu código (teclas, botones, etc.)
	open  = openUI,
	close = closeUI,
	toggle = function()
		if uiOpen then closeUI() else openUI() end
	end,
	isOpen = function() return uiOpen end,

	-- zoom del panel (0.5 = pequeño, 1.4 = grande)
	setZoom = function(z)
		ZOOM = clamp(z or 1, 0.5, 1.4)
		prefs.zoom = ZOOM
		applyScale()
		savePrefs()
	end,
	getZoom = function() return ZOOM end,
}

if type(getgenv) == "function" then
	-- FUSIONA en la tabla compartida en vez de reemplazarla: si el
	-- núcleo ya se cargó antes, sus campos (_core, _esp…) se conservan.
	local g = getgenv()
	local shared = type(g.Duelos) == "table" and g.Duelos or {}
	for k, v in pairs(API) do
		shared[k] = v
	end
	g.Duelos = shared
end

return API
end)()

local Core = (function()
-- ═════════ NÚCLEO (core.lua) ═════════
--[[
	duelos · core
	──────────────────────────────────────────────────────────
	Estado compartido entre los módulos (cámara / hitbox / ESP /
	contador) + utilidades de robustez.

	Publica un ÚNICO objeto global (getgenv().Duelos) para no dejar
	basura en el entorno del executor. La interfaz (duelos_ui.lua) se
	 fusiona en esa misma tabla, así que da igual el orden de carga.

	Orden de carga recomendado:
		core.lua → mod_camera.lua → mod_hitbox.lua → mod_esp.lua → mod_playercount.lua
]]

local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local UserInputService  = game:GetService("UserInputService")

local Core = {}

Core.Players          = Players
Core.Workspace        = Workspace
Core.UserInputService = UserInputService
Core.LocalPlayer      = Players.LocalPlayer

-- ═══════════════════════════════════════════════════════════════════
-- espacio de nombres único
-- ═══════════════════════════════════════════════════════════════════
-- Devuelve la tabla compartida getgenv().Duelos, creándola si hace
-- falta. Todos los módulos publican ahí dentro, así que el executor
-- queda con un solo global en vez de seis.
function Core.api()
	local g = (type(getgenv) == "function") and getgenv() or nil
	if not g then return {} end
	local t = g.Duelos
	if type(t) ~= "table" then
		t = {}
		g.Duelos = t
	end
	return t
end

-- ═══════════════════════════════════════════════════════════════════
-- CONFIG · valor por defecto (si la interfaz no está cargada)
-- ═══════════════════════════════════════════════════════════════════
Core.DefaultConfig = {
	-- aim
	aim       = true,
	aimHold   = false,
	aimBone   = "head",
	fov       = 90,
	speed     = 65,
	humanize  = true,   -- error de mira, reacción y sobrepaso

	-- hitbox
	hb       = true,
	hbPart   = "head",
	hbScale  = 200,   -- 200 = 2.0x  (la interfaz usa %)
	hbMax    = 115,   -- tope: 115 = máx x1.15 (0 = sin tope)
	hbRevert = true,

	-- cámara
	cam       = true,
	camAnchor = "head",
	camSmooth = 40,
	camFov    = 70,

	-- esp
	esp      = false,
	espWall  = true,
	espStyle = "box",
	espRange = 140,
	espAlpha = 80,
}

-- config viva de la interfaz (misma tabla que getgenv().Duelos.Config)
function Core.getConfig()
	local api = Core.api()
	if type(api.Config) == "table" then
		return api.Config
	end
	return Core.DefaultConfig
end

-- ═══════════════════════════════════════════════════════════════════
-- robustez
-- ═══════════════════════════════════════════════════════════════════
-- Errores silenciados: un error por frame llenaría la consola del
-- executor (y algunos anti-cheats leen el log). Aquí se cuentan y
-- se descartan.
Core.errors = 0

function Core.silent(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a, b = pcall(fn, ...)
	if not ok then
		Core.errors += 1
		return nil
	end
	return a, b
end

-- Ejecuta fn como máximo una vez cada `interval` segundos.
-- Se usa para el ESP: no necesita ir a 60 Hz y así el motor no
-- instancia/destruye objetos en cada frame.
local _last = {}
function Core.throttle(key, interval, fn)
	local now = os.clock()
	local last = _last[key]
	if last and (now - last) < interval then
		return false
	end
	_last[key] = now
	fn()
	return true
end

-- ═══════════════════════════════════════════════════════════════════
-- cámara
-- ═══════════════════════════════════════════════════════════════════
function Core.getCamera()
	local cam = Core.LocalPlayer and Core.LocalPlayer.Camera
	if not cam then
		cam = Workspace.CurrentCamera
	end
	return cam
end

-- FOV original del jugador (para restaurarlo al apagar 'cam')
Core.originalFov = nil

-- ═══════════════════════════════════════════════════════════════════
-- huesos / partes
-- ═══════════════════════════════════════════════════════════════════
local BONES = {
	head         = { "Head" },
	torso        = { "Torso", "UpperTorso" },
	["upper torso"] = { "UpperTorso" },
	chest        = { "UpperTorso", "Torso" },
	["lower torso"] = { "LowerTorso" },
	waist        = { "LowerTorso" },
	root         = { "HumanoidRootPart" },
	humanoid     = { "HumanoidRootPart" },
	feet         = { "LeftFoot", "RightFoot" },
	legs         = { "LeftLeg", "RightLeg" },
	arms         = { "LeftArm", "RightArm" },
}

-- "Head" | "head" | "Torso" | "UpperTorso" | "all" | "near"
function Core.resolveBone(name)
	if type(name) ~= "string" or name == "" then
		return { "Head" }
	end
	local key = name:lower():gsub("%s+", " ")
	local list = BONES[key]
	if list then
		return list
	end
	-- nombre directo de parte ("UpperTorso", "HumanoidRootPart", ...)
	return { name }
end

-- "near" → la parte del cuerpo más cercana a la cámara
local function nearestPart(model)
	local cam = Core.getCamera()
	if not cam then return nil end
	local camPos = cam.CFrame.Position
	local best, bestDist = nil, math.huge
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local dist = (d.Position - camPos).Magnitude
			if dist < bestDist then
				bestDist = dist
				best = d
			end
		end
	end
	return best
end

-- devuelve una BasePart del modelo según el hueso pedido
function Core.getPart(model, bone)
	if not model then return nil end
	if type(bone) == "string" and bone:lower() == "near" then
		return nearestPart(model)
	end
	for _, n in ipairs(Core.resolveBone(bone)) do
		local p = model:FindFirstChild(n)
		if p and p:IsA("BasePart") then
			return p
		end
	end
	-- R15 no tiene "Torso": cae a UpperTorso
	if type(bone) == "string" and bone:lower():find("torso") then
		local up = model:FindFirstChild("UpperTorso")
		if up then return up end
	end
	return model:FindFirstChild("HumanoidRootPart")
end

-- devuelve la lista de partes a modificar ("all" = todas las BasePart)
function Core.getParts(model, bone)
	if not model then return {} end
	local key = (type(bone) == "string") and bone:lower() or ""
	if key == "all" then
		local out = {}
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				out[#out + 1] = d
			end
		end
		return out
	end
	local p = Core.getPart(model, bone)
	if p then return { p } end
	return {}
end

-- ¿el personaje está vivo?
function Core.isAlive(model)
	if not model then return false end
	local hum = model:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0
end

-- ═══════════════════════════════════════════════════════════════════
-- recorrido de jugadores (siempre excluye al LocalPlayer)
-- ═══════════════════════════════════════════════════════════════════
function Core.eachPlayer(fn)
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= Core.LocalPlayer then
			fn(plr, plr.Character)
		end
	end
end

-- ═══════════════════════════════════════════════════════════════════
-- normalizadores (aceptan 2.0 / 200 y 0.8 / 80)
-- ═══════════════════════════════════════════════════════════════════
-- 200 (interfaz, %) -> 2.0   |   2.0 (config) -> 2.0
function Core.normalizeScale(value)
	local v = tonumber(value)
	if v == nil then return 1 end
	if v == 0 then return 0 end        -- 0 significa "sin tope"
	if v >= 100 then v = v / 100 end
	if v < 0.1 then v = 0.1 end
	return v
end

function Core.normalizeAlpha(value)
	local v = tonumber(value)
	if v == nil then return 0.8 end
	if v > 1 then v = v / 100 end
	return math.clamp(v, 0, 1)
end

-- ═══════════════════════════════════════════════════════════════════
-- utilidades
-- ═══════════════════════════════════════════════════════════════════
function Core.clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

-- distancia (studs) de una posición a la cámara
function Core.distanceToCam(pos)
	local cam = Core.getCamera()
	if not cam then return math.huge end
	return (pos - cam.CFrame.Position).Magnitude
end

-- ángulo en grados entre la mirada de la cámara y una posición
function Core.angleTo(cf, pos)
	local dir = pos - cf.Position
	if dir.Magnitude < 0.001 then return 0 end
	local dot = Core.clamp(cf.LookVector:Dot(dir.Unit), -1, 1)
	return math.deg(math.acos(dot))
end

-- suavizado independiente del framerate:
-- speed = 65  ->  alpha = 1 - (1 - 0.65)^(dt*60)
--
-- NOTA: un alpha alto hace que la cámara "salte" de golpe al objetivo.
-- El servidor ve la rotación del personaje, así que un salto grande
-- en un solo frame es la señal más obvia de un aimbot. Bajar 'speed'
-- / 'camSmooth' (o subir el número de pasos) suaviza ese salto.
function Core.smoothAlpha(percent, dt)
	local p = Core.clamp((tonumber(percent) or 50) / 100, 0.01, 1)
	local frames = math.max(dt, 1 / 240) * 60
	return 1 - ((1 - p) ^ frames)
end

-- ═══════════════════════════════════════════════════════════════════
-- limpieza (al cerrar o recargar el script)
-- ═══════════════════════════════════════════════════════════════════
-- Registro de funciones de limpieza. Se ejecutan en orden inverso
-- al llamar a Core.runCleanups(), para no dejar objetos huérfanos
-- (Highlights en el mundo, hitboxes deformadas, FOV alterado).
local cleanups = {}

function Core.onCleanup(fn)
	if type(fn) == "function" then
		cleanups[#cleanups + 1] = fn
	end
end

function Core.runCleanups()
	for i = #cleanups, 1, -1 do
		pcall(cleanups[i])
		cleanups[i] = nil
	end
end

-- ═══════════════════════════════════════════════════════════════════
-- publicación
-- ═══════════════════════════════════════════════════════════════════
-- TODO cuelga de la tabla compartida Duelos (no de un global propio)
do
	local api = Core.api()
	api._core = Core
	-- la interfaz puede haberse cargado antes o después: se preserva
	-- su Config sin pisarla con la de por defecto
	if type(api.Config) ~= "table" then
		api.Config = Core.DefaultConfig
	end
end

return Core
end)()

local Hardening = (function()
-- ═════════ HARDENING (mod_hardening.lua) ═════════
--[[
	duelos · hardening
	──────────────────────────────────────────────────────────
	Capa de robustez que envuelve a los módulos para dejar el menor
	rastro posible en el cliente.

	QUÉ HACE Y POR QUÉ
	──────────────────
	1) ERRORES SILENCIADOS
	   Un `error()` dentro de un bucle de render llena la consola del
	   executor con decenas de líneas por segundo. Eso no lo ve el
	   servidor, pero delata el script ante cualquier captura de
	   pantalla o diagnóstico. Aquí los errores se cuentan y se
	   descartan.

	2) UN SOLO GLOBAL
	   Cada módulo publicaba su propio global (DuelosCore, DuelosESP,
	   DuelosCamera...). Seis globals con nombres propios del script son
	   una firma fácil de detectar. Ahora todo vive bajo `Duelos`.

	3) LIMPIEZA AL CERRAR
	   Al recargar el script, la instancia anterior debe soltarlo todo:
	   restore de hitboxes, destrucción de ESP, FOV original. Sin esto
	   se quedan Highlights en el mundo y tamaños deformados.

	4) ESCRITURAS ESPACIAS
	   Escribir Size o CFrame en cada frame satura la cola de
	   replicación. Los módulos sólo escriben cuando el valor cambia.

	5) SIN PAUTAS EN EL RENDER LOOP
	   El ESP y el contador corren a baja frecuencia (12 Hz y 1 Hz).
	   El render loop sólo hace trabajo cuando hay algo que cambiar.

	Requiere core.lua cargado antes.
]]

local Mod = {}
Mod.__name = "Hardening"

-- ═══════════════════════════════════════════════════════════════════
-- 1) errores silenciados
-- ═══════════════════════════════════════════════════════════════════
-- Contador de errores. Si sube mucho, el módulo está fallando;
-- se puede consultar con getgenv().Duelos._errors.
Core.errors = 0

-- Ejecuta fn sin propagar el error. Devuelve nil si falló.
function Mod.guard(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a, b = pcall(fn, ...)
	if not ok then
		Core.errors += 1
		return nil
	end
	return a, b
end

-- ═══════════════════════════════════════════════════════════════════
-- 2) escrituras sólo cuando cambian
-- ═══════════════════════════════════════════════════════════════════
-- Escribe una propiedad sólo si su valor es distinto al anterior.
-- Evita el tráfico de replicación continuo.
function Mod.setProp(obj, prop, value)
	if not obj then return false end
	local cur = obj[prop]
	if cur == value then return false end
	local ok = pcall(function()
		obj[prop] = value
	end)
	return ok
end

-- ═══════════════════════════════════════════════════════════════════
-- 3) limpieza al cerrar / recargar
-- ═══════════════════════════════════════════════════════════════════
-- El registro de limpiezas vive en Core (Core.onCleanup /
-- Core.runCleanups), para que cualquier módulo pueda enganchar la
-- suya y todas se ejecuten juntas al cerrar.

-- ═══════════════════════════════════════════════════════════════════
-- 4) instalación
-- ═══════════════════════════════════════════════════════════════════
-- Se llama desde duelos_main / el archivo único. Registra la limpieza
-- global y deja el estado limpio.
function Mod.install(api)
	api = api or Core.api()

	-- una sola tabla global
	api._hardening = Mod
	api._errors = 0

	-- al apagar 'cam' o al cerrar, el FOV vuelve al original
	Core.onCleanup(function()
		local cam = Core.getCamera()
		if cam and Core.originalFov then
			pcall(function()
				cam.FieldOfView = Core.originalFov
			end)
			Core.originalFov = nil
		end
	end)

	return Mod
end

-- ═══════════════════════════════════════════════════════════════════
-- publicación (tabla compartida Duelos)
-- ═══════════════════════════════════════════════════════════════════
Core.api()._hardening = Mod

return Mod
end)()

local Trace = (function()
-- ═════════ RASTRO (mod_trace.lua) ═════════
--[[
	duelos · rastro (control de señales visibles)
	──────────────────────────────────────────────────────────
	Ajusta el COMPORTAMIENTO del script para reducir las señales que
	el servidor (y cualquier anti-cheat del juego) puede observar.

	QUÉ OBSERVA EL SERVIDOR Y CÓMO SE AFECTA
	──────────────────────────────────────────
	· La ORIENTACIÓN del personaje. El servidor ve el
	  HumanoidRootPart girando. Si el aim rota el cuerpo de golpe
	  (180° en un frame), es físicamente imposible con un ratón y es
	  la señal más obvia de un aimbot.

	    → 'speed' / 'camSmooth' bajos = giros graduales.
	    → Mod.MAX_TURN limita cuántos grados puede girar por frame.

	· LA VELOCIDAD DE ESCRITURA. Cada cambio de CFrame o de Size
	  genera tráfico replicado. Escribir 60 veces por segundo satura
	  la cola.

	    → Mod.MAX_TURN + suavizado = muchas menos escrituras.
	    → El ESP va a 12 Hz, no a 60.
	    → El Size del hitbox sólo se escribe cuando cambia la escala.

	· LOS OBJETOS EN EL MUNDO. Un Highlight dentro del modelo de otro
	  jugador es una señal trivial (no hay ningún Highlight legítimo
	  ahí). Este script los cuelga de un contenedor propio.

	· EL FOV DE LA CÁMARA. Se guarda el original y se restaura.

	NO PUEDE OCULTARSE
	──────────────────
	Un aimbot SIEMPRE deja rastro: el servidor ve a dónde apunta el
	jugador y a quién mata. Este módulo reduce el ruido, no lo
	elimina. La detección por patrones de puntería (la más común)
	depende del servidor comparando la mira del jugador con el
	objetivo: por eso el suavizado gradual importa más que cualquier
	truco de ofuscación.

	Requiere core.lua cargado antes.
]]

local Mod = {}
Mod.__name = "Trace"

-- ═══════════════════════════════════════════════════════════════════
-- LÍMITES
-- ═══════════════════════════════════════════════════════════════════
-- Grados máximos de giro por frame. 12°/frame a 60 Hz ≈ 720°/s:
-- rápido pero físicamente posible con un ratón. Subirlo hace el
-- aim más instantáneo y más detectable.
Mod.MAX_TURN = 12

-- Frames sin escribir la cámara cuando el objetivo no se movió.
-- Aunque el objetivo esté quieto, el torso del jugador se mueve por
-- el movimiento del ratón: no hace falta reescribir cada frame.
Mod.IDLE_SKIP = 2

-- ═══════════════════════════════════════════════════════════════════
-- estado
-- ═══════════════════════════════════════════════════════════════════
local lastWrite = nil      -- último CFrame escrito
local idleFrames = 0
local lastTargetPart = nil

-- ═══════════════════════════════════════════════════════════════════
-- limitar el giro por frame
-- ═══════════════════════════════════════════════════════════════════
-- Devuelve el CFrame deseado pero limitado a MAX_TURN grados de
-- diferencia respecto al actual.
function Mod.limitTurn(current, desired)
	local maxRad = math.rad(Mod.MAX_TURN)

	-- ángulo entre la mirada actual y la deseada
	local dot = Core.clamp(current.LookVector:Dot(desired.LookVector), -1, 1)
	local ang = math.acos(dot)
	if ang <= maxRad then return desired end
	if ang < 1e-6 then return desired end

	-- eje de rotación
	local axis = current.LookVector:Cross(desired.LookVector)
	if axis.Magnitude < 1e-6 then
		-- Caso antiparalelo (el objetivo está exactamente detrás):
		-- el producto vectorial es nulo, así que se elige cualquier eje
		-- perpendicular a la mirada actual.
		local v = current.LookVector
		if math.abs(v.X) < 0.9 then
			axis = v:Cross(Vector3.new(1, 0, 0))
		else
			axis = v:Cross(Vector3.new(0, 1, 0))
		end
		if axis.Magnitude < 1e-6 then return desired end
	end
	axis = axis.Unit

	-- fórmula de Rodrigues: rota current.LookVector maxRad alrededor
	-- del eje, en el sentido del objetivo
	local k = axis
	local v = current.LookVector
	local c, s = math.cos(maxRad), math.sin(maxRad)
	local kv = Vec.new(
		k.Y * v.Z - k.Z * v.Y,
		k.Z * v.X - k.X * v.Z,
		k.X * v.Y - k.Y * v.X
	)
	local kd = k.X * v.X + k.Y * v.Y + k.Z * v.Z
	local look = Vec.new(
		v.X * c + kv.X * s + k.X * kd * (1 - c),
		v.Y * c + kv.Y * s + k.Y * kd * (1 - c),
		v.Z * c + kv.Z * s + k.Z * kd * (1 - c)
	).Unit

	return CFrame.lookAt(current.Position, current.Position + look)
end

-- ═══════════════════════════════════════════════════════════════════
-- ¿hace falta escribir?
-- ═══════════════════════════════════════════════════════════════════
-- Devuelve true si la cámara se ha movido lo suficiente como para
-- justifies una escritura. Evita tráfico de replicación inútil.
function Mod.shouldWrite(current, desired, target)
	-- el objetivo cambió: hay que escribir sí o sí
	if target ~= lastTargetPart then
		lastTargetPart = target
		idleFrames = 0
		return true
	end

	-- el objetivo es el mismo: compara la orientación
	if not lastWrite then return true end
	local moved = (desired.LookVector - current.LookVector).Magnitude
	if moved > 0.0015 then
		idleFrames = 0
		return true
	end

	-- lleva varios frames sin escribir: escribe uno de vez en cuando
	-- para no perder el control del FOV / del ancla
	idleFrames += 1
	if idleFrames >= Mod.IDLE_SKIP then
		idleFrames = 0
		return true
	end
	return false
end

function Mod.markWritten(cf)
	lastWrite = cf
end

-- ═══════════════════════════════════════════════════════════════════
-- instalación
-- ═══════════════════════════════════════════════════════════════════
function Mod.install(api)
	api = api or Core.api()
	api._trace = Mod
	Core.trace = Mod
	return Mod
end

-- se engancha al core en tiempo de carga para que la cámara lo vea
Core.trace = Mod

return Mod
end)()

local Humanize = (function()
-- ═════════ HUMANIZACIÓN (mod_humanize.lua) ═════════
--[[
	duelos · humanización
	──────────────────────────────────────────────────────────
	Hace que el script se comporte como un jugador humano en lugar de
	como un robot. Reduce la huella porque:

	· Un aimbot perfecto es matemáticamente detectable: la mira cae
	  EXACTAMENTE sobre el centro de la cabeza, sin error, sin
	  oscilación, sin sobrepasos. Ningún ratón humano hace eso.
	· Un giro instantáneo de 180° es físicamente imposible con el
	  brazo humano. Un humano tarda ~150-250 ms en un flick.

	LO QUE HACE ESTE MÓDULO
	────────────────────────
	1) ERROR DE MIRA (jitter)
	   La mira no va al píxel exacto: hay una dispersión de ~0.5° que
	   cambia cada ~50 ms, como el temblor de una mano sobre el ratón.

	2) SOBREPASO Y CORRECCIÓN
	   Al llegar al objetivo la mira se pasa un poco y vuelve. Eso es
	   exactamente lo que hace un humano al "clicar" sobre un blanco.

	3) TIEMPO DE REACCIÓN
	   Al cambiar de objetivo hay una pausa de 90-220 ms antes de
	  empezar a girar. Un humano no reacciona instantáneamente.

	4) CURVA DE ACELERACIÓN
	   El giro no es lineal: arranca rápido, acelera y frena al llegar
	   (curva ease-out), igual que un movimiento de brazo.

	Requiere core.lua cargado antes.
]]

local Mod = {}
Mod.__name = "Humanize"

-- ═══════════════════════════════════════════════════════════════════
-- parámetros
-- ═══════════════════════════════════════════════════════════════════
-- Cada cuánto cambia el error de mira (segundos).
Mod.JITTER_INTERVAL = 0.05

-- Magnitud del error de mira, en grados. 0.55° a 30 studs ≈ 0.3 studs
-- de error: suficiente para no ser perfecto, poco para no fallar.
Mod.JITTER_DEGREES = 0.55

-- Sobrepaso al llegar al objetivo (fracción del ángulo restante).
Mod.OVERSHOOT = 0.15

-- Umbral de ángulo restante para considerar "llegado" (grados).
Mod.ARRIVE_DEGREES = 4

-- Tiempo de reacción ante un objetivo nuevo (segundos).
Mod.REACTION_MIN = 0.09
Mod.REACTION_MAX = 0.22

-- Tiempo que dura el sobrepaso antes de corregirse (segundos).
Mod.OVERSHOOT_TIME = 0.09

-- Curva de aceleración: 0 = lineal, 1 = frenado marcado.
Mod.EASE = 0.72

-- Grados en los que empieza a frenar (el último tramo se recorre lento).
Mod.BRAKE_DEGREES = 25

-- Frenada mínima (multiplicador del alpha cuando ya está encima).
Mod.MIN_BRAKE = 0.25

-- ═══════════════════════════════════════════════════════════════════
-- estado
-- ═══════════════════════════════════════════════════════════════════
local jitter = { x = 0, y = 0 }
local jitterTimer = 0

local lastTarget = nil
local reactionTimer = 0

-- estado del sobrepaso: "idle" | "overshoot" | "settle"
local phase = "idle"
local phaseTimer = 0
local extraAngle = 0

local function randRange(a, b)
	return a + (b - a) * math.random()
end

-- ═══════════════════════════════════════════════════════════════════
-- 1) error de mira
-- ═══════════════════════════════════════════════════════════════════
-- Devuelve una dirección perturbada por el error actual.
function Mod.jitterDirection(dir)
	if Mod.JITTER_DEGREES <= 0 then return dir end

	local right = dir:Cross(Vector3.new(0, 1, 0))
	if right.Magnitude < 1e-6 then
		right = dir:Cross(Vector3.new(1, 0, 0))
	end
	if right.Magnitude < 1e-6 then return dir end
	right = right.Unit
	local realUp = right:Cross(dir).Unit

	local a = math.tan(math.rad(jitter.x))
	local b = math.tan(math.rad(jitter.y))
	return (dir + right * a + realUp * b).Unit
end

-- ═══════════════════════════════════════════════════════════════════
-- 2) sobrepaso
-- ═══════════════════════════════════════════════════════════════════
-- Ángulo extra a aplicar en este frame (grados). 0 si no hay sobrepaso.
function Mod.extraAngle()
	return extraAngle
end

-- ═══════════════════════════════════════════════════════════════════
-- 3) reacción
-- ═══════════════════════════════════════════════════════════════════
-- ¿Ya pasó el tiempo de reacción desde que cambió el objetivo?
function Mod.readyToMove(target, dt)
	if target ~= lastTarget then
		lastTarget = target
		reactionTimer = randRange(Mod.REACTION_MIN, Mod.REACTION_MAX)
		phase = "idle"
		extraAngle = 0
		return false
	end
	if reactionTimer > 0 then
		reactionTimer = reactionTimer - dt
		return false
	end
	return true
end

-- ═══════════════════════════════════════════════════════════════════
-- 4) curva de aceleración
-- ═══════════════════════════════════════════════════════════════════
-- Curva ease-out estándar: avanza rápido al principio y frena al
-- final. easeOut(0) = 0, easeOut(1) = 1.
function Mod.easeOut(alpha)
	local e = Core.clamp(Mod.EASE, 0, 1)
	if e <= 0 then return alpha end
	-- 1 - (1-a)^(1+2e) : arranca rápido y frena
	return 1 - ((1 - alpha) ^ (1 + e * 2))
end

-- Factor de frenada: 1 cuando falta mucho, pequeño cuando ya está
-- encima del objetivo. Así el último tramo se recorre despacio, como
-- un humano que corrige la puntería.
function Mod.brakeFactor(remaining)
	if remaining == nil then return 1 end
	if remaining >= Mod.BRAKE_DEGREES then return 1 end
	local t = Core.clamp(remaining / Mod.BRAKE_DEGREES, 0, 1)
	return Mod.MIN_BRAKE + (1 - Mod.MIN_BRAKE) * Mod.easeOut(t)
end

-- ═══════════════════════════════════════════════════════════════════
-- actualización por frame
-- ═══════════════════════════════════════════════════════════════════
-- remaining = ángulo (grados) que falta para llegar al objetivo.
function Mod.update(dt, remaining)
	-- 1) refresco del jitter
	jitterTimer += dt
	if jitterTimer >= Mod.JITTER_INTERVAL then
		jitterTimer = 0
		jitter.x = randRange(-Mod.JITTER_DEGREES, Mod.JITTER_DEGREES)
		jitter.y = randRange(-Mod.JITTER_DEGREES, Mod.JITTER_DEGREES)
	end

	-- 2) máquina de estados del sobrepaso
	if phase == "overshoot" then
		phaseTimer = phaseTimer - dt
		if phaseTimer <= 0 then
			phase = "settle"
			phaseTimer = Mod.OVERSHOOT_TIME
			extraAngle = 0
		end
	elseif phase == "settle" then
		phaseTimer = phaseTimer - dt
		if phaseTimer <= 0 then
			phase = "idle"
		end
	else
		-- 3) ¿hemos llegado? entonces se prepara el sobrepaso
		if remaining ~= nil and remaining < Mod.ARRIVE_DEGREES and remaining > 0.05 then
			phase = "overshoot"
			phaseTimer = Mod.OVERSHOOT_TIME
			extraAngle = remaining * Mod.OVERSHOOT
		end
	end
end

-- ═══════════════════════════════════════════════════════════════════
-- instalación
-- ═══════════════════════════════════════════════════════════════════
function Mod.install(api)
	api = api or Core.api()
	api._humanize = Mod
	Core.humanize = Mod
	return Mod
end

Core.humanize = Mod

return Mod
end)()

local Humanize = (function()
-- ═════════ HUMANIZACIÓN (mod_humanize.lua) ═════════
--[[
	duelos · humanización
	──────────────────────────────────────────────────────────
	Hace que el script se comporte como un jugador humano en lugar de
	como un robot. Reduce la huella porque:

	· Un aimbot perfecto es matemáticamente detectable: la mira cae
	  EXACTAMENTE sobre el centro de la cabeza, sin error, sin
	  oscilación, sin sobrepasos. Ningún ratón humano hace eso.
	· Un giro instantáneo de 180° es físicamente imposible con el
	  brazo humano. Un humano tarda ~150-250 ms en un flick.

	LO QUE HACE ESTE MÓDULO
	────────────────────────
	1) ERROR DE MIRA (jitter)
	   La mira no va al píxel exacto: hay una dispersión de ~0.5° que
	   cambia cada ~50 ms, como el temblor de una mano sobre el ratón.

	2) SOBREPASO Y CORRECCIÓN
	   Al llegar al objetivo la mira se pasa un poco y vuelve. Eso es
	   exactamente lo que hace un humano al "clicar" sobre un blanco.

	3) TIEMPO DE REACCIÓN
	   Al cambiar de objetivo hay una pausa de 90-220 ms antes de
	  empezar a girar. Un humano no reacciona instantáneamente.

	4) CURVA DE ACELERACIÓN
	   El giro no es lineal: arranca rápido, acelera y frena al llegar
	   (curva ease-out), igual que un movimiento de brazo.

	Requiere core.lua cargado antes.
]]

local Mod = {}
Mod.__name = "Humanize"

-- ═══════════════════════════════════════════════════════════════════
-- parámetros
-- ═══════════════════════════════════════════════════════════════════
-- Cada cuánto cambia el error de mira (segundos).
Mod.JITTER_INTERVAL = 0.05

-- Magnitud del error de mira, en grados. 0.55° a 30 studs ≈ 0.3 studs
-- de error: suficiente para no ser perfecto, poco para no fallar.
Mod.JITTER_DEGREES = 0.55

-- Sobrepaso al llegar al objetivo (fracción del ángulo restante).
Mod.OVERSHOOT = 0.15

-- Umbral de ángulo restante para considerar "llegado" (grados).
Mod.ARRIVE_DEGREES = 4

-- Tiempo de reacción ante un objetivo nuevo (segundos).
Mod.REACTION_MIN = 0.09
Mod.REACTION_MAX = 0.22

-- Tiempo que dura el sobrepaso antes de corregirse (segundos).
Mod.OVERSHOOT_TIME = 0.09

-- Curva de aceleración: 0 = lineal, 1 = frenado marcado.
Mod.EASE = 0.72

-- Grados en los que empieza a frenar (el último tramo se recorre lento).
Mod.BRAKE_DEGREES = 25

-- Frenada mínima (multiplicador del alpha cuando ya está encima).
Mod.MIN_BRAKE = 0.25

-- ═══════════════════════════════════════════════════════════════════
-- estado
-- ═══════════════════════════════════════════════════════════════════
local jitter = { x = 0, y = 0 }
local jitterTimer = 0

local lastTarget = nil
local reactionTimer = 0

-- estado del sobrepaso: "idle" | "overshoot" | "settle"
local phase = "idle"
local phaseTimer = 0
local extraAngle = 0

local function randRange(a, b)
	return a + (b - a) * math.random()
end

-- ═══════════════════════════════════════════════════════════════════
-- 1) error de mira
-- ═══════════════════════════════════════════════════════════════════
-- Devuelve una dirección perturbada por el error actual.
function Mod.jitterDirection(dir)
	if Mod.JITTER_DEGREES <= 0 then return dir end

	local right = dir:Cross(Vector3.new(0, 1, 0))
	if right.Magnitude < 1e-6 then
		right = dir:Cross(Vector3.new(1, 0, 0))
	end
	if right.Magnitude < 1e-6 then return dir end
	right = right.Unit
	local realUp = right:Cross(dir).Unit

	local a = math.tan(math.rad(jitter.x))
	local b = math.tan(math.rad(jitter.y))
	return (dir + right * a + realUp * b).Unit
end

-- ═══════════════════════════════════════════════════════════════════
-- 2) sobrepaso
-- ═══════════════════════════════════════════════════════════════════
-- Ángulo extra a aplicar en este frame (grados). 0 si no hay sobrepaso.
function Mod.extraAngle()
	return extraAngle
end

-- ═══════════════════════════════════════════════════════════════════
-- 3) reacción
-- ═══════════════════════════════════════════════════════════════════
-- ¿Ya pasó el tiempo de reacción desde que cambió el objetivo?
function Mod.readyToMove(target, dt)
	if target ~= lastTarget then
		lastTarget = target
		reactionTimer = randRange(Mod.REACTION_MIN, Mod.REACTION_MAX)
		phase = "idle"
		extraAngle = 0
		return false
	end
	if reactionTimer > 0 then
		reactionTimer = reactionTimer - dt
		return false
	end
	return true
end

-- ═══════════════════════════════════════════════════════════════════
-- 4) curva de aceleración
-- ═══════════════════════════════════════════════════════════════════
-- Curva ease-out estándar: avanza rápido al principio y frena al
-- final. easeOut(0) = 0, easeOut(1) = 1.
function Mod.easeOut(alpha)
	local e = Core.clamp(Mod.EASE, 0, 1)
	if e <= 0 then return alpha end
	-- 1 - (1-a)^(1+2e) : arranca rápido y frena
	return 1 - ((1 - alpha) ^ (1 + e * 2))
end

-- Factor de frenada: 1 cuando falta mucho, pequeño cuando ya está
-- encima del objetivo. Así el último tramo se recorre despacio, como
-- un humano que corrige la puntería.
function Mod.brakeFactor(remaining)
	if remaining == nil then return 1 end
	if remaining >= Mod.BRAKE_DEGREES then return 1 end
	local t = Core.clamp(remaining / Mod.BRAKE_DEGREES, 0, 1)
	return Mod.MIN_BRAKE + (1 - Mod.MIN_BRAKE) * Mod.easeOut(t)
end

-- ═══════════════════════════════════════════════════════════════════
-- actualización por frame
-- ═══════════════════════════════════════════════════════════════════
-- remaining = ángulo (grados) que falta para llegar al objetivo.
function Mod.update(dt, remaining)
	-- 1) refresco del jitter
	jitterTimer += dt
	if jitterTimer >= Mod.JITTER_INTERVAL then
		jitterTimer = 0
		jitter.x = randRange(-Mod.JITTER_DEGREES, Mod.JITTER_DEGREES)
		jitter.y = randRange(-Mod.JITTER_DEGREES, Mod.JITTER_DEGREES)
	end

	-- 2) máquina de estados del sobrepaso
	if phase == "overshoot" then
		phaseTimer = phaseTimer - dt
		if phaseTimer <= 0 then
			phase = "settle"
			phaseTimer = Mod.OVERSHOOT_TIME
			extraAngle = 0
		end
	elseif phase == "settle" then
		phaseTimer = phaseTimer - dt
		if phaseTimer <= 0 then
			phase = "idle"
		end
	else
		-- 3) ¿hemos llegado? entonces se prepara el sobrepaso
		if remaining ~= nil and remaining < Mod.ARRIVE_DEGREES and remaining > 0.05 then
			phase = "overshoot"
			phaseTimer = Mod.OVERSHOOT_TIME
			extraAngle = remaining * Mod.OVERSHOOT
		end
	end
end

-- ═══════════════════════════════════════════════════════════════════
-- instalación
-- ═══════════════════════════════════════════════════════════════════
function Mod.install(api)
	api = api or Core.api()
	api._humanize = Mod
	Core.humanize = Mod
	return Mod
end

Core.humanize = Mod

return Mod
end)()

local Camera = (function()
-- ═════════ CÁMARA / AIM (mod_camera.lua) ═════════
--[[
	duelos · cámara / aim
	──────────────────────────────────────────────────────────
	Orienta el CFrame de la cámara del LocalPlayer hacia la parte
	seleccionada (aimBone / camAnchor) del personaje más cercano.

	· aim      → gira la cámara hacia el objetivo usando 'speed'
	· aimHold  → sólo con el botón derecho pulsado
	· cam      → ancla la cámara a camAnchor y aplica camFov + camSmooth
	· fov      → radio (en grados) del círculo de captura de objetivos

	NOTAS DE RASTRO:
	· La cámara sólo se escribe cuando el objetivo cambia o cuando
	  todavía está "en camino". Escribir CFrame a 60 Hz de forma
	  constante es lo más fácil de detectar: el servidor ve el
	  HumanoidRootPoint girando a velocidad imposible para un ratón.
	· 'speed' y 'camSmooth' controlan ese salto: valores bajos hacen
	  que el giro sea gradual (menos señal) pero menos preciso.
	· Se respeta un ángulo máximo de giro por frame. Si el objetivo
	  está detrás, la cámara " Barre " en vez de teletransportarse.
	· El FOV real de la cámara se guarda una vez (Core.originalFov) y
	  se restaura al apagar 'cam', para no dejar el FOV del jugador
	  alterado al cerrar el script.

	Requiere core.lua cargado antes.
]]

-- El módulo de rastro es opcional: si está cargado (Core.trace),
-- limita el giro por frame y evita escrituras inútiles de CFrame.
-- Se resuelve en tiempo de llamada para que funcione tanto en el
-- archivo único como en multi-archivo.

local UserInputService = Core.UserInputService
local Workspace        = Core.Workspace

local Mod = {}
Mod.__name = "Camera"

-- estado público
Mod.target    = nil      -- { player, part, distance }
Mod.lastAim   = false
Mod.lastCam   = false

-- Objetivo al que se está girando ahora (para no reescribir el
-- CFrame si no ha cambiado).
local lastTarget = nil

-- ═══════════════════════════════════════════════════════════════════
-- búsqueda del objetivo
-- ═══════════════════════════════════════════════════════════════════
-- devuelve el personaje más cercano DENTRO del radio de FOV
function Mod.findTarget(cfg, cam, bone)
	local radius = tonumber(cfg.fov) or 90
	if radius > 180 then radius = 180 end
	local maxDist = tonumber(cfg.aimRange) or 1000

	local best, bestDist = nil, math.huge

	Core.eachPlayer(function(plr, char)
		if char and Core.isAlive(char) then
			local part = Core.getPart(char, bone or cfg.aimBone or "head")
			if part then
				local dist = (part.Position - cam.CFrame.Position).Magnitude
				if dist <= maxDist then
					-- sólo entra en el círculo de FOV
					local ang = Core.angleTo(cam.CFrame, part.Position)
					if ang <= radius and dist < bestDist then
						bestDist = dist
						best = {
							player    = plr,
							character = char,
							part      = part,
							distance  = dist,
							angle     = ang,
						}
					end
				end
			end
		end
	end)

	return best
end

-- ¿está el aim activo ahora mismo (según aimHold)?
function Mod.aimActive(cfg)
	if not cfg.aim then return false end
	if cfg.aimHold then
		return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
	end
	return true
end

-- ═══════════════════════════════════════════════════════════════════
-- actualización por frame
-- ═══════════════════════════════════════════════════════════════════
function Mod.update(dt)
	local cfg = Core.getConfig()
	local cam = Core.getCamera()
	if not cam then return end

	local aimOn = Mod.aimActive(cfg)
	local camOn = cfg.cam == true
	Mod.lastAim = aimOn
	Mod.lastCam = camOn

	-- ── FOV real de la cámara ────────────────────────────────────────
	if camOn then
		local want = tonumber(cfg.camFov) or 70
		if not Core.originalFov then
			Core.originalFov = cam.FieldOfView   -- se guarda una sola vez
		end
		if math.abs(cam.FieldOfView - want) > 0.05 then
			cam.FieldOfView = want
		end
	elseif Core.originalFov then
		-- restaurar el FOV que tenía el jugador antes de tocarlo
		if math.abs(cam.FieldOfView - Core.originalFov) > 0.05 then
			cam.FieldOfView = Core.originalFov
		end
		Core.originalFov = nil
	end

	if not aimOn and not camOn then
		Mod.target = nil
		lastTarget = nil
		return
	end

	-- ── objetivo ─────────────────────────────────────────────────────
	-- con 'cam' el anclaje define a qué parte se apunta; si no, aimBone
	local bone = camOn and (cfg.camAnchor or cfg.aimBone) or (cfg.aimBone or "head")
	local target = Mod.findTarget(cfg, cam, bone)
	Mod.target = target

	-- ── ancla de la cámara (parte del personaje LOCAL) ────────────────
	local anchor = nil
	if camOn then
		local lchar = Core.LocalPlayer and Core.LocalPlayer.Character
		if lchar then
			anchor = Core.getPart(lchar, cfg.camAnchor or "head")
		end
	end

	-- posición deseada: pegada al ancla (cam) o donde esté la cámara (aim)
	local wantPos = cam.CFrame.Position
	if anchor then
		local off = cam.CFrame.Position - anchor.Position
		if off.Magnitude < 0.05 then
			off = -cam.CFrame.LookVector * 3
		end
		-- la cámara se acerca al ancla (efecto "silent cam")
		local dist = math.min(off.Magnitude, 5)
		wantPos = anchor.Position + off.Unit * dist
	end

	-- punto al que mirar
	local lookAt = nil
	if target then
		lookAt = target.part.Position
	elseif anchor then
		lookAt = anchor.Position + anchor.CFrame.LookVector * 100
	end
	if not lookAt then return end

	-- ── aplicar ──────────────────────────────────────────────────────
	local desired = CFrame.lookAt(wantPos, lookAt)
	local targetPart = target and target.part or nil

	-- ── humanización ──────────────────────────────────────────────────
	-- Aplica error de mira, tiempo de reacción y sobrepaso. Sin esto
	-- la mira cae EXACTA sobre el centro de la cabeza, cosa que ningún
	-- ratón humano hace (y que el servidor puede detectar).
	local Humanize = Core.humanize
	if Humanize and cfg.humanize ~= false then
		local remaining = Core.angleTo(cam.CFrame, lookAt)
		Humanize.update(dt, remaining)

		-- tiempo de reacción: si el objetivo acaba de cambiar, la
		-- cámara no se mueve todavía
		if not Humanize.readyToMove(targetPart, dt) then
			return
		end

		-- error de mira: se perturba la dirección
		local dir = Humanize.jitterDirection(desired.LookVector)
		desired = CFrame.lookAt(wantPos, wantPos + dir)

		-- sobrepaso: al llegar, la mira se pasa un poco y vuelve
		local extra = Humanize.extraAngle()
		if extra ~= 0 then
			local axis = desired.LookVector:Cross(Vector3.new(0, 1, 0))
			if axis.Magnitude > 1e-6 then
				local past = CFrame.new() * CFrame.fromAxisAngle(
					axis.Unit, math.rad(extra)
				)
				desired = CFrame.lookAt(wantPos, wantPos + (past * desired.LookVector))
			end
		end
	end

	-- ── rastro ───────────────────────────────────────────────────────
	-- Limita el salto por frame y evita escrituras inútiles de CFrame.
	local Trace = Core.trace
	if Trace then
		desired = Trace.limitTurn(cam.CFrame, desired)
	end

	if Trace and not Trace.shouldWrite(cam.CFrame, desired, targetPart) then
		return
	end

	-- ── aplicar ──────────────────────────────────────────────────────
	local alpha
	if camOn then
		alpha = Core.smoothAlpha(cfg.camSmooth, dt)
	elseif aimOn and target then
		alpha = Core.smoothAlpha(cfg.speed, dt)
	else
		return
	end

	-- curva de aceleración: arranca rápido y frena al llegar
	if Humanize then
		local remaining = Core.angleTo(cam.CFrame, lookAt)
		alpha = alpha * Humanize.brakeFactor(remaining)
	end

	cam.CFrame = cam.CFrame:Lerp(desired, alpha)

	if Trace then
		Trace.markWritten(cam.CFrame)
	end

	lastTarget = target
end

-- ═══════════════════════════════════════════════════════════════════
-- publicación (tabla compartida Duelos)
-- ═══════════════════════════════════════════════════════════════════
Core.api()._camera = Mod

return Mod
end)()

local Hitbox = (function()
-- ═════════ HITBOX (mod_hitbox.lua) ═════════
--[[
	duelos · hitbox
	──────────────────────────────────────────────────────────
	Modifica el Size de la parte elegida (hbPart) en los modelos de
	los demás jugadores.

	· hbScale  → factor de escala (2.0 = 2x, 200 = 2.0x)
	· hbMax    → tope de escala (1.15 = máx x1.15). 0 = sin tope
	· hbRevert → al desactivar el hitbox se restaura el Size original
	· hbPart   → "Head" | "Torso" | "all" (todas las partes del cuerpo)

	El Size original se guarda una sola vez por parte (en `originals`)
	para poder restaurarlo aunque el jugador reaparezca o el script
	lleve un rato corriendo.

	NOTAS IMPORTANTES (y son la clave de por qué no te expulsan)
	──────────────────────────────────────────────────────────────
	· `part.Size = ...` en el modelo de OTRO jugador NO se replica al
	  servidor: un cliente sólo puede replicar cambios en las
	  instancias que posee (su propio personaje). Por eso el hitbox
	  expandido sólo sirve si el juego calcula los impactos en el
	  CLIENTE.

	· El servidor sí puede detectar el cheat de otra forma: cuando el
	  juego revalida los disparos del cliente (raycast propio desde
	  la posición del jugador), si el cliente afirma haber impactado
	  a alguien a una distancia que el servidor no reproduce, es un
	  impacto imposible. Cuanto MÁS grande es la expansión, más
	  часто el cliente "impacta" a alguien fuera de alcance real.

	· Por eso el tope por defecto es x1.15 en vez de x2: una
	  expansión del 10-15% apenas cambia los impactos imposibles y
	  es indistinguible de la variación normal de un modelo.

	· El Size se escribe UNA vez por cambio de escala, no en cada
	  frame. Escribir Size a 60 Hz satura la cola de replicación.

	· Al salir un jugador se restaura su tamaño inmediatamente, para
	  no dejar a nadie con hitbox deforme si el script se recarga.

	Requiere core.lua cargado antes.
]]

local Mod = {}
Mod.__name = "Hitbox"

-- Size original por parte (clave = la propia BasePart)
Mod.originals = {}
-- escala actualmente aplicada por parte
Mod.applied   = {}

-- ═══════════════════════════════════════════════════════════════════
-- helpers
-- ═══════════════════════════════════════════════════════════════════
-- devuelve el Size original de una parte (guardándolo la primera vez)
local function getOriginal(part)
	local orig = Mod.originals[part]
	if not orig then
		orig = part.Size
		Mod.originals[part] = orig
	end
	return orig
end

-- restaura el Size original de una parte
local function restore(part)
	local orig = Mod.originals[part]
	if orig and part.Parent then
		pcall(function()
			part.Size = orig
		end)
	end
	Mod.applied[part] = nil
end

-- ═══════════════════════════════════════════════════════════════════
-- aplicación / reversión
-- ═══════════════════════════════════════════════════════════════════
function Mod.apply(part, scale)
	if not part or not part.Parent then return end
	local orig = getOriginal(part)
	if orig.Magnitude <= 0 then return end
	if Mod.applied[part] == scale then return end   -- ya está aplicado
	pcall(function()
		part.Size = orig * scale
	end)
	Mod.applied[part] = scale
end

-- restaura todo lo que este módulo tocó
function Mod.revertAll()
	for part in pairs(Mod.originals) do
		restore(part)
	end
	Mod.originals = {}
	Mod.applied = {}
end

-- ═══════════════════════════════════════════════════════════════════
-- loop principal (llamar cada frame)
-- ═══════════════════════════════════════════════════════════════════
function Mod.update()
	local cfg = Core.getConfig()
	local enabled = cfg.hb == true
	local scale = Core.normalizeScale(cfg.hbScale)
	local bone = cfg.hbPart or "head"

	-- tope de seguridad: una expansión grande produce impactos
	-- imposibles que el servidor puede revalidar y descartar.
	-- hbMax = 0 desactiva el tope. Acepta 115 (115%) o 1.15 (factor).
	local maxScale = Core.normalizeScale(cfg.hbMax)
	if cfg.hbMax == nil then maxScale = 1.15 end
	if maxScale > 0 and scale > maxScale then
		scale = maxScale
	end

	if not enabled then
		-- si hbRevert está activo se deshace el cambio; si no, se deja puesto
		if cfg.hbRevert then
			Mod.revertAll()
		end
		return
	end

	Core.eachPlayer(function(plr, char)
		if not char then return end
		local parts = Core.getParts(char, bone)
		for _, part in ipairs(parts) do
			Mod.apply(part, scale)
		end
	end)
end

-- ═══════════════════════════════════════════════════════════════════
-- limpieza (jugador se va / CharacterRemoving)
-- ═══════════════════════════════════════════════════════════════════
function Mod.cleanupCharacter(char)
	if not char then return end
	for part in pairs(Mod.originals) do
		if part.Parent == nil or part:IsDescendantOf(char) then
			restore(part)
			Mod.originals[part] = nil
		end
	end
end

do
	local Players = Core.Players
	Players.PlayerRemoving:Connect(function(plr)
		local char = plr.Character
		if char then
			Mod.cleanupCharacter(char)
		end
	end)
	Players.PlayerAdded:Connect(function(plr)
		plr.CharacterAdded:Connect(function(char)
			-- el modelo nuevo no hereda tamaños: se limpian referencias viejas
			for part in pairs(Mod.originals) do
				if part.Parent == nil then
					Mod.originals[part] = nil
					Mod.applied[part] = nil
				end
			end
		end)
	end)
end

-- ═══════════════════════════════════════════════════════════════════
-- publicación (tabla compartida Duelos)
-- ═══════════════════════════════════════════════════════════════════
Core.api()._hitbox = Mod

return Mod
end)()

local ESP = (function()
-- ═════════ ESP (mod_esp.lua) ═════════
--[[
	duelos · ESP (Highlight)
	──────────────────────────────────────────────────────────
	Crea y administra objetos Highlight sobre los personajes de los
	demás jugadores.

	· espWall  → true  = AlwaysOnTop (se ve a través de las paredes)
	             false = Occluded (sólo donde hay línea de visión)
	· espStyle → "box" (Highlight + contorno de caja)
	             "dot" (Highlight + punto sobre la cabeza)
	             "text"/"name" (Highlight + nombre y distancia)
	· espRange → distancia máxima en studs
	· espAlpha → opacidad (0.8 o 80)

	NOTAS DE RASTREO (por qué este módulo es discreto):
	· Los Highlight se cuelgan de un contenedor local dentro de
	  workspace, NO del modelo del rival. Meterlos dentro del otro
	  jugador es una señal evidente para cualquier revisión del juego.
	· El contenedor se destruye entero al apagar el ESP, así que no
	  quedan objetos huérfanos en la partida.
	· Los objetos se crean una sola vez por jugador y se reutilizan:
	  no se instancia/destruye en cada frame.
	· La actualización va a baja frecuencia (ESP_TICK), no a 60 Hz.

	Requiere core.lua cargado antes.
]]

local Players = Core.Players
local Workspace = Core.Workspace

local Mod = {}
Mod.__name = "ESP"

-- por jugador: { highlight, box, billboard, root, head }
Mod.objects = {}

-- contenedor local: los adornos cuelgan de aquí, no del rival
local container = nil

-- frecuencia de actualización (segundos). 0.08 ≈ 12 Hz: suficiente
-- para que el ESP se vea fluido sin churning de instancias.
local ESP_TICK = 0.08

-- ═══════════════════════════════════════════════════════════════════
-- contenedor
-- ═══════════════════════════════════════════════════════════════════
local function getContainer()
	if container and container.Parent then
		return container
	end
	local ok, c = pcall(function()
		local f = Instance.new("Folder")
		f.Name = "DuelosESP"
		f.Parent = Workspace
		return f
	end)
	container = ok and c or nil
	return container
end

local function destroyContainer()
	if container and container.Parent then
		pcall(function()
			container:Destroy()
		end)
	end
	container = nil
end

-- ═══════════════════════════════════════════════════════════════════
-- profundidad (a través de paredes)
-- ═══════════════════════════════════════════════════════════════════
local function setDepthMode(hl, wall)
	local mode
	if wall then
		mode = Enum.HighlightMode and Enum.HighlightMode.AlwaysOnTop or "AlwaysOnTop"
	else
		mode = Enum.HighlightMode and Enum.HighlightMode.Occluded or "Occluded"
	end
	pcall(function()
		hl.DepthMode = mode
	end)
end

-- ═══════════════════════════════════════════════════════════════════
-- construcción de los objetos
-- ═══════════════════════════════════════════════════════════════════
local COL_FILL    = Color3.fromRGB(255, 70, 70)
local COL_OUTLINE = Color3.fromRGB(255, 255, 255)
local COL_TEXT    = Color3.fromRGB(255, 255, 255)

local function makeHighlight(char, alpha)
	local ok, hl = pcall(function()
		local h = Instance.new("Highlight")
		h.Name = "DuelosESP"
		h.Adornee = char          -- adorna al rival, pero NO vive en su modelo
		h.FillColor = COL_FILL
		h.OutlineColor = COL_OUTLINE
		h.FillTransparency = 1 - alpha
		h.OutlineTransparency = 1 - (alpha * 0.8)
		h.Enabled = true
		h.Parent = getContainer()
		return h
	end)
	return ok and hl or nil
end

local function makeBox(char, alpha)
	local ok, box = pcall(function()
		local b = Instance.new("BoxHandleAdornment")
		b.Name = "DuelosESPBox"
		b.Adornee = char
		b.AlwaysOnTop = false
		b.Transparency = 1 - alpha
		b.Color = COL_OUTLINE
		b.Size = char:GetExtentsSize()
		b.Parent = getContainer()
		return b
	end)
	return ok and box or nil
end

local function makeBillboard(head, style, alpha)
	local ok, gui = pcall(function()
		local bg = Instance.new("BillboardGui")
		bg.Name = "DuelosESPText"
		bg.Adornee = head
		bg.AlwaysOnTop = true
		bg.Size = UDim2.fromOffset(120, 24)
		bg.StudsOffsetWorldSpace = Vector3.new(0, 2.2, 0)
		bg.MaxDistance = 1000
		bg.Parent = getContainer()

		if style == "dot" then
			local dot = Instance.new("Frame")
			dot.Name = "Dot"
			dot.AnchorPoint = Vector2.new(0.5, 0.5)
			dot.Position = UDim2.fromScale(0.5, 0.5)
			dot.Size = UDim2.fromOffset(6, 6)
			dot.BackgroundColor3 = COL_FILL
			dot.BackgroundTransparency = 1 - alpha
			dot.BorderSizePixel = 0
			dot.Parent = bg
			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(1, 0)
			c.Parent = dot
		else
			local lbl = Instance.new("TextLabel")
			lbl.Name = "Label"
			lbl.Size = UDim2.fromScale(1, 1)
			lbl.BackgroundTransparency = 1
			lbl.Text = ""
			lbl.TextColor3 = COL_TEXT
			lbl.TextStrokeTransparency = 0.5
			lbl.TextScaled = true
			lbl.Font = Enum.Font.GothamBold
			lbl.Parent = bg
		end
		return bg
	end)
	return ok and gui or nil
end

-- ═══════════════════════════════════════════════════════════════════
-- crear / destruir
-- ═══════════════════════════════════════════════════════════════════
-- IMPORTANTE: sólo se destruyen los objetos que creó este módulo
-- (highlight / box / billboard). `root` y `head` son partes del OTRO
-- jugador: destruirlas las borraría de la partida (y del servidor).
function Mod.destroyFor(plr)
	local o = Mod.objects[plr]
	if not o then return end
	for _, key in ipairs({ "highlight", "box", "billboard" }) do
		local obj = o[key]
		if obj and obj.Parent then
			pcall(function()
				obj:Destroy()
			end)
		end
	end
	Mod.objects[plr] = nil
end

function Mod.destroyAll()
	for plr in pairs(Mod.objects) do
		Mod.destroyFor(plr)
	end
	Mod.objects = {}
	destroyContainer()
end

-- ═══════════════════════════════════════════════════════════════════
-- loop principal
-- ═══════════════════════════════════════════════════════════════════
function Mod.update()
	local cfg = Core.getConfig()
	local enabled = cfg.esp == true
	local alpha = Core.normalizeAlpha(cfg.espAlpha)
	local maxRange = tonumber(cfg.espRange) or 140
	local style = (type(cfg.espStyle) == "string" and cfg.espStyle:lower()) or "box"
	local wall = cfg.espWall ~= false

	if not enabled then
		-- el contenedor se destruye entero: no quedan restos
		if next(Mod.objects) or container then
			Mod.destroyAll()
		end
		return
	end

	local parent = getContainer()
	if not parent then return end

	-- limpia los que ya no sirven (jugador se fue)
	for plr in pairs(Mod.objects) do
		if plr.Parent ~= Players then
			Mod.destroyFor(plr)
		end
	end

	Core.eachPlayer(function(plr, char)
		if not char then
			Mod.destroyFor(plr)
			return
		end

		local root = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Head")
		if not root then
			Mod.destroyFor(plr)
			return
		end

		-- distancia máxima en studs
		local dist = Core.distanceToCam(root.Position)
		if dist > maxRange then
			Mod.destroyFor(plr)
			return
		end

		local o = Mod.objects[plr]
		if not o then
			local head = char:FindFirstChild("Head") or root
			o = {
				highlight = makeHighlight(char, alpha),
				box      = (style == "box") and makeBox(char, alpha) or nil,
				billboard = (style ~= "box") and makeBillboard(head, style, alpha) or nil,
				root     = root,
				head     = head,
			}
			Mod.objects[plr] = o
		end

		-- refresca color / alpha / profundidad
		if o.highlight then
			pcall(function()
				o.highlight.FillTransparency = 1 - alpha
				o.highlight.OutlineTransparency = 1 - (alpha * 0.8)
			end)
			setDepthMode(o.highlight, wall)
		end
		if o.box then
			pcall(function()
				o.box.Transparency = 1 - alpha
			end)
		end

		-- texto: nombre + distancia
		if o.billboard then
			local lbl = o.billboard:FindFirstChild("Label")
			if lbl then
				lbl.Text = ("%s  %d studs"):format(plr.DisplayName or plr.Name, math.floor(dist))
			end
		end
	end)
end

-- ═══════════════════════════════════════════════════════════════════
-- limpieza al salir un jugador
-- ═══════════════════════════════════════════════════════════════════
Players.PlayerRemoving:Connect(function(plr)
	Mod.destroyFor(plr)
end)

-- ═══════════════════════════════════════════════════════════════════
-- publicación (tabla compartida Duelos)
-- ═══════════════════════════════════════════════════════════════════
Core.api()._esp = Mod

return Mod
end)()

local Count = (function()
-- ═════════ CONTADOR (mod_playercount.lua) ═════════
--[[
	duelos · contador de jugadores
	──────────────────────────────────────────────────────────
	Lee Players:GetPlayers() y clasifica a los jugadores:
		· total      → todos los jugadores de la partida
		· vivos      → con personaje y Humanoid.Health > 0
		· muertos    → con personaje y Humanoid.Health <= 0
		· inGame     → tienen personaje spawneado (vivos o muertos)
		· enEspera   → sin personaje todavía
		· otros      → todo lo que no sea el LocalPlayer
		· enemigos   → en partida y de otro equipo
		· equipo     → en partida y del mismo equipo

	Publica el resultado en:
		· getgenv().Duelos._count  → módulo con el estado
		· Hooks.onCount(state)     → callback para la interfaz
		· las etiquetas "enemigos" / "compañeros" del inicio

	NOTAS DE RASTRO:
	· El refresco es a 1 Hz, no por frame. El contador no necesita más.
	· Los eventos PlayerAdded / PlayerRemoving disparan un refresco
	  inmediato, así que el número es correcto sin polling constante.
	· Los errores se silencian: un fallo en un evento no debe imprimir
	  ruido en la consola del executor.

	Requiere core.lua cargado antes.
]]

local Players = Core.Players

local Mod = {}
Mod.__name = "PlayerCount"

-- estado actual
Mod.state = {
	total     = 0,
	vivos     = 0,
	muertos   = 0,
	inGame    = 0,
	enEspera  = 0,
	otros     = 0,
	enemigos  = 0,
	equipo    = 0,
}

-- callbacks externos
Mod.callbacks = {}

-- ═══════════════════════════════════════════════════════════════════
-- lectura y clasificación
-- ═══════════════════════════════════════════════════════════════════
-- ¿el jugador es compañero de equipo? (nil si no hay Teams /Neutral)
local function sameTeam(plr)
	local lp = Core.LocalPlayer
	if not lp or not plr then return false end
	local lt, pt = lp.Team, plr.Team
	if not lt or not pt then return false end
	if not lt.Neutral or not pt.Neutral then
		return lt == pt
	end
	return false
end

function Mod.read()
	local s = {
		total    = 0,
		vivos    = 0,
		muertos  = 0,
		inGame   = 0,
		enEspera = 0,
		otros    = 0,
		enemigos = 0,
		equipo   = 0,
	}

	for _, plr in ipairs(Players:GetPlayers()) do
		s.total += 1

		if plr == Core.LocalPlayer then
			s.otros += 1
		else
			local char = plr.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if not hum then
				s.enEspera += 1
			else
				s.inGame += 1
				if hum.Health > 0 then
					s.vivos += 1
				else
					s.muertos += 1
				end
				-- enemigo / compañero
				if sameTeam(plr) then
					s.equipo += 1
				else
					s.enemigos += 1
				end
			end
		end
	end

	-- los que no son el LocalPlayer (jugadores "rival")
	s.otros = s.total - 1
	if s.otros < 0 then s.otros = 0 end

	return s
end

-- ═══════════════════════════════════════════════════════════════════
-- actualización + notificación
-- ═══════════════════════════════════════════════════════════════════
function Mod.update()
	local s = Mod.read()
	Mod.state = s

	-- texto para la interfaz
	local text = ("%d en partida · %d vivos"):format(s.total, s.vivos)
	Mod.text = text

	-- callback propio
	for _, cb in ipairs(Mod.callbacks) do
		pcall(cb, s, text)
	end

	-- hook de la interfaz (duelos_ui.lua)
	local g = (type(getgenv) == "function") and getgenv() or nil
	local api = g and g.Duelos
	if api and type(api.Hooks) == "table" and type(api.Hooks.onCount) == "function" then
		pcall(api.Hooks.onCount, s, text)
	end

	-- etiquetas del inicio: enemigos / compañeros
	if api and type(api.CountLabels) == "table" then
		local labels = api.CountLabels
		if labels.enemigos then
			pcall(function()
				labels.enemigos.Text = tostring(s.enemigos)
			end)
		end
		if labels.companeros then
			pcall(function()
				labels.companeros.Text = tostring(s.equipo)
			end)
		end
	end

	return s
end

-- registra un callback: fn(state, text)
function Mod.onUpdate(fn)
	if type(fn) == "function" then
		table.insert(Mod.callbacks, fn)
	end
	return function()  -- devuelve un unsubscribe
		for i, cb in ipairs(Mod.callbacks) do
			if cb == fn then
				table.remove(Mod.callbacks, i)
				break
			end
		end
	end
end

-- ═══════════════════════════════════════════════════════════════════
-- arranque: eventos + refresco periódico
-- ═══════════════════════════════════════════════════════════════════
Players.PlayerAdded:Connect(function()
	task.defer(function()
		pcall(Mod.update)
	end)
end)

Players.PlayerRemoving:Connect(function()
	task.defer(function()
		pcall(Mod.update)
	end)
end)

if Core.LocalPlayer and Core.LocalPlayer.CharacterAdded then
	Core.LocalPlayer.CharacterAdded:Connect(function()
		task.defer(function()
			pcall(Mod.update)
		end)
	end)
end

-- refresco cada segundo por si un personaje aparece/desaparece sin evento
task.spawn(function()
	while true do
		task.wait(1)
		pcall(Mod.update)
	end
end)

-- primera lectura
task.defer(function()
	pcall(Mod.update)
end)

-- ═══════════════════════════════════════════════════════════════════
-- publicación (tabla compartida Duelos)
-- ═══════════════════════════════════════════════════════════════════
Core.api()._count = Mod

return Mod
end)()

local Main = (function()
-- ═════════ CONEXIÓN (main_wiring.lua) ═════════
--[[
	duelos · wiring (conexión de los módulos con la interfaz)
	──────────────────────────────────────────────────────────
	Este archivo NO se carga solo: lo incrusta duelos_main.lua
	(multi-archivo) o el generador build_single.js (archivo único).

	Da por hecho que en el ámbito actual existen:
		Core, Camera, Hitbox, ESP, Count, Hardening
	(y que la interfaz ya publicó getgenv().Duelos con su Config).
]]

local RunService = game:GetService("RunService")

-- ═══════════════════════════════════════════════════════════════════
-- enganche con los hooks de la interfaz
-- ═══════════════════════════════════════════════════════════════════
local g = (type(getgenv) == "function") and getgenv() or nil
local api = (g and g.Duelos) or {}
local API = api

if type(API.Hooks) ~= "table" then
	API.Hooks = {}
end

-- instala el hardening y el control de rastro
local Hardening = api._hardening
local Trace = api._trace
local Humanize = api._humanize
if Hardening and type(Hardening.install) == "function" then
	Hardening.install(api)
end
if Trace and type(Trace.install) == "function" then
	Trace.install(api)
end
if Humanize and type(Humanize.install) == "function" then
	Humanize.install(api)
end

-- aim: al apagar se restaura el FOV si la cámara también está apagada
API.Hooks.onAim = function(state)
	if not state then
		local cam = Core.getCamera()
		if cam and Core.originalFov and not Core.getConfig().cam then
			cam.FieldOfView = Core.originalFov
			Core.originalFov = nil
		end
	end
end

-- hitbox: al apagar se revierte (si hbRevert está activo)
API.Hooks.onHitbox = function(state, key)
	if not state and key == "hb" then
		if Core.getConfig().hbRevert then
			Hitbox.revertAll()
		end
	end
end

-- esp: al apagar se destruyen los highlights
API.Hooks.onEsp = function(state, key)
	if not state and key == "esp" then
		ESP.destroyAll()
	end
end

-- cam: al apagar se restaura el FOV original
API.Hooks.onCam = function(state, key)
	if not state and key == "cam" then
		local cam = Core.getCamera()
		if cam and Core.originalFov then
			cam.FieldOfView = Core.originalFov
			Core.originalFov = nil
		end
	end
end

-- contador de jugadores
API.Hooks.onCount = function(state, text)
	-- aquí puedes pintar el texto en cualquier otro sitio de tu interfaz
end

-- ═══════════════════════════════════════════════════════════════════
-- bucle principal
-- ═══════════════════════════════════════════════════════════════════
-- Todo el trabajo va envuelto en guard(): si un módulo falla, el
-- error se cuenta pero no llena la consola del executor.
RunService:BindToRenderStep("Duelos_Camera", Enum.RenderPriority.Camera.Value - 1, function(dt)
	Hardening.guard(Camera.update, dt)
end)

RunService:BindToRenderStep("Duelos_ESP", Enum.RenderPriority.Character.Value, function()
	Hardening.guard(ESP.update)
end)

RunService.Heartbeat:Connect(function()
	Hardening.guard(Hitbox.update)
end)

-- ═══════════════════════════════════════════════════════════════════
-- API pública
-- ═══════════════════════════════════════════════════════════════════
local Main = {
	Core      = Core,
	Camera    = Camera,
	Hitbox    = Hitbox,
	ESP       = ESP,
	Count     = Count,
	Hardening = Hardening,

	-- contador listo para consultar (refresca y devuelve el estado actual)
	getCount = function()
		return Count.update()
	end,

	-- errores silenciados (sube si algo falla)
	getErrors = function()
		return Core.errors
	end,

	-- parar todo y limpiar
	stop = function()
		RunService:UnbindFromRenderStep("Duelos_Camera")
		RunService:UnbindFromRenderStep("Duelos_ESP")
		Hitbox.revertAll()
		ESP.destroyAll()
		Core.runCleanups()
		local cam = Core.getCamera()
		if cam and Core.originalFov then
			cam.FieldOfView = Core.originalFov
			Core.originalFov = nil
		end
	end,
}

if type(getgenv) == "function" then
	-- un único global: todo bajo Duelos
	local t = (g.Duelos or {})
	t.Main = Main
	t._core = Core
	t._camera = Camera
	t._hitbox = Hitbox
	t._esp = ESP
	t._count = Count
	g.Duelos = t
end

return Main
end)()

-- ═════════ construcción / publicación ═════════
local _g = (type(getgenv) == "function") and getgenv() or nil

-- el hardening se instala con la API compartida
Hardening.install(_g and _g.Duelos or nil)
Trace.install(_g and _g.Duelos or nil)
Humanize.install(_g and _g.Duelos or nil)

if _g then
	-- un ÚNICO global: todo cuelga de Duelos
	local _t = _g.Duelos or {}
	_t.UI = UI
	_t.Main = Main
	_g.Duelos = _t
end

return Main
