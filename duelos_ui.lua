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

	-- hitbox
	hb       = true,
	hbPart   = "head",   -- head | torso | all
	hbScale  = 200,      -- 200 = 2.0x
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
local screen = mk("ScreenGui", {
	Name                  = "DuelosUI",
	ResetOnSpawn          = false,
	IgnoreGuiInset        = true,
	DisplayOrder          = 999,
	ZIndexBehavior        = Enum.ZIndexBehavior.Sibling,
})
screen.Parent = player:WaitForChild("PlayerGui")

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
	hb = "onHitbox", hbPart = "onHitbox", hbRevert = "onHitbox", hbScale = "onHitbox",
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
	local l = makeList(aim, y, ROW_H * 3)
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
	y = y + ROW_H * 3 + 10

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
-- API pública (para conectar tu lógica)
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
	getgenv().Duelos = API
end

return API
