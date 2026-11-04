-- Case Opener v4.1  (Roblox / Luau executor)
-- v4.1: ตัดระบบ "พัก" ออกทั้งหมด + แก้บั๊กอ่าน stock ผิด (กล่องไม่จำกัดถูกมองว่า "หมด" ทำให้สลับไปเปิดต่อไม่ได้)
-- v4: แก้อาการ "รอกล่อง/รีสต็อก + พัก" เป็นพักๆ ทั้งที่เงินพอ
--     * แยก "เซิร์ฟคูลดาวน์" ออกจาก "กล่องเสีย": ล้มเหลวใกล้ๆ หลังเปิดสำเร็จ = ปรับจังหวะ ไม่พักกล่อง ไม่เปลี่ยนชื่อ key
--     * จังหวะเปิดปรับเอง (ห่างขั้นต่ำ) เรียนรู้ตามเซิร์ฟ/boost ความเร็วเปิด
--     * ของ Limited เหลือน้อยแล้วโดนแย่ง -> ลองทีละ 1 + อ่าน stock ใหม่
--     * Auto Limited ว่าง (หมด/พัก/รอรีสต็อก) -> เปิดกล่องไม่จำกัดสต็อกที่เลือกไว้แทน (ไม่นั่งรอเฉยๆ)
--     * อ่านราคากล่องที่ไม่มีคำว่า case ได้ถ้าเลือกไว้
-- v3: Auto Limited = สุ่มเฉพาะ 12 กล่องในรายชื่อ LIMITED (แก้ได้ด้านล่าง) โดยอ่านราคา/stock จากหน้า Cases เอง (ไม่ต้องพิมพ์ชื่อ, รีสต็อกก็เจอเอง)
--     เช็ค stock + เงินก่อนยิงทุกครั้ง -> กล่องหมดแล้วไม่ยิงต่อ (Robux ไม่เด้ง)
--     ล้มเหลวจริงติดกันเยอะเกินจะหยุดเองทั้งหมด (กัน Robux เด้ง)
local RS          = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local lp          = game:GetService("Players").LocalPlayer
local OpenRemote  = RS.GameEvents.Cases.Open
local DisplayOpen = RS.GameEvents.Cases.DisplayOpen

local MAX_AMT    = 10               -- เพดานกล่องต่อครั้ง (ถ้าเซิร์ฟรับแค่ 3 สคริปต์จะถอยเป็น 3 เอง)
local SAVE_FILE  = "CaseOpener.json"
local SCAN_EVERY = 0.6              -- อ่าน UI ใหม่ทุกกี่วินาที
local MAX_FAIL   = 8                -- ล้มเหลวจริงติดกันกี่ครั้งถึงหยุดทั้งหมด
local COOL_MAX   = 12               -- ช่วงห่างระหว่างการเปิดสูงสุดที่ยอมให้เรียนรู้ (วินาที)

local running, token, dead = false, 0, false
local sent, okn, total, t0 = 0, 0, 0, 0
local flag, skipOn, hideOn, quickOn, autoOn = false, false, false, false, true
local hidden, selectedCases, cBtns = {}, {}, {}
local learned, keyByNorm = {}, {}   -- learned: ชื่อที่ส่งแล้วสำเร็จจริง / keyByNorm: ชื่อ key ที่รู้จัก
local save = function() end

-- ===== โหลดค่าที่เซฟไว้ =====
local canFile = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
local cfg = {cases = {}, sel = {}, keys = {}, amt = "3", dly = "1", skip = false, hide = false, quick = false, flag = false, auto = true}
if canFile and isfile(SAVE_FILE) then
    local ok, d = pcall(function() return HttpService:JSONDecode(readfile(SAVE_FILE)) end)
    if ok and type(d) == "table" then
        for k, v in pairs(d) do cfg[k] = v end
    end
end
flag, skipOn, hideOn, quickOn = cfg.flag == true, cfg.skip == true, cfg.hide == true, cfg.quick == true
autoOn = cfg.auto ~= false
if type(cfg.keys) == "table" then
    for k, v in pairs(cfg.keys) do
        if type(k) == "string" and type(v) == "string" then learned[k] = v end
    end
end

local gui = Instance.new("ScreenGui")
gui.ResetOnSpawn = false
gui.Parent = (gethui and gethui()) or lp:WaitForChild("PlayerGui")

-- ===== ตัวช่วยอ่านข้อความ/ราคา =====
local function norm(s) return (tostring(s):lower():gsub("[^%w]", "")) end

-- กล่อง Limited ที่ Auto จะสุ่ม (ตามหน้า Limited Cases) — ถ้าเกมเพิ่ม/เปลี่ยนกล่อง แก้รายชื่อตรงนี้
local LIMITED = {
    "Common Case", "Serpent Case", "Candy Case", "Epic Case",
    "Polar Case", "Arcade Case", "Legendary Case", "Great Waves Case",
    "Royal Case", "Mythic Case", "Secret Case", "Godly Case",
}
local limitedSet = {}
for _, n in ipairs(LIMITED) do limitedSet[norm(n)] = true end

local function clean(s)
    s = tostring(s or ""):gsub("<[^>]+>", "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local MULT = {k = 1e3, m = 1e6, b = 1e9}
local function parsePrice(t)
    local n, suf = t:match("^%$%s*([%d,%.]+)%s*([KkMmBb]?)$")
    if not n then return nil end
    local v = tonumber((n:gsub(",", "")))
    if not v then return nil end
    return v * (MULT[suf:lower()] or 1)
end

-- อ่านหน้า Cases ทั้งหมดจาก PlayerGui: การ์ดกล่อง (ชื่อ/ราคา/stock) + เงิน BALANCE
-- การ์ด = กลุ่ม UI ที่มี "ราคา $..." 1 ราคา + ชื่อที่มีคำว่า case (+ Stock: Nx ถ้าเป็น Limited)
local function scanUI()
    local cards, bal = {}, nil
    local pg = lp:FindFirstChild("PlayerGui")
    if not pg then return cards, bal end

    -- ชื่อกล่องที่เลือกไว้ แต่ไม่มีคำว่า case (เช่น Operation Breakout, ... Collection) ก็อ่านราคาได้
    local selNorm = {}
    for n in pairs(selectedCases) do selNorm[norm(n)] = true end
    local function isName(X)
        return X.l:find("case", 1, true) ~= nil or selNorm[norm(X.t)] == true
    end

    local lab, list, stockLbls = {}, {}, {}
    for _, o in ipairs(pg:GetDescendants()) do
        if (o:IsA("TextLabel") or o:IsA("TextButton")) and not o:IsDescendantOf(gui) then
            local t = clean(o.Text)
            if t ~= "" then
                local lo = t:lower()
                local L = {o = o, t = t, l = lo, price = parsePrice(t)}
                -- ต้องขึ้นต้นด้วย "stock" เท่านั้น (ป้าย "Restock in 00m 00s" ห้ามนับเป็น stock = 0)
                L.stock = tonumber(lo:match("^stock%D*(%d+)"))
                if L.stock == nil and lo:match("^sold%s*out") then L.stock = 0 end
                lab[o] = L
                list[#list + 1] = L
                if L.stock ~= nil then stockLbls[#stockLbls + 1] = L end
            end
        end
    end

    -- ตรวจกลุ่ม UI หนึ่งก้อน: ราคาที่ไม่ซ้ำ / ชื่อที่มีคำว่า case / stock
    local function inspect(root)
        local prices, nPrice, price = {}, 0, nil
        local names, nNames, name, nameObj = {}, 0, nil, nil
        local stock, bad, cnt = nil, false, 0
        for _, d in ipairs(root:GetDescendants()) do
            cnt += 1
            if cnt > 300 then bad = true; break end
            local X = lab[d]
            if X then
                if X.price then
                    if not prices[X.price] then
                        prices[X.price] = true; nPrice += 1; price = X.price
                    end
                elseif X.stock ~= nil then
                    stock = X.stock
                elseif X.l:find("balance", 1, true) or X.l:find("net worth", 1, true) then
                    bad = true
                elseif isName(X) then
                    if not names[X.l] then names[X.l] = true; nNames += 1 end
                    if not name or #X.t < #name then name = X.t; nameObj = X.o end
                end
            end
            if nPrice > 1 then break end
        end
        return {nPrice = nPrice, price = price, nNames = nNames, name = name,
                nameObj = nameObj, stock = stock, bad = bad}
    end

    local done = {}
    for _, L in ipairs(list) do
        if L.price then
            local cur = L.o.Parent
            for _ = 1, 5 do
                if not cur or cur == pg or done[cur] then break end
                local info = inspect(cur)
                if info.bad or info.nPrice > 1 then break end
                if info.nPrice == 1 and info.name then
                    done[cur] = true
                    local stock = info.stock
                    -- ป้าย Stock อาจอยู่คนละกลุ่มกับชื่อ/ราคา: ไต่ขึ้นอีก 2 ชั้นตราบที่ยังเป็นการ์ดใบเดียว
                    if stock == nil then
                        local up = cur.Parent
                        for _ = 1, 2 do
                            if not up or up == pg then break end
                            local i2 = inspect(up)
                            if i2.bad or i2.nPrice ~= 1 or i2.nNames ~= 1 then break end
                            if i2.stock ~= nil then stock = i2.stock; break end
                            up = up.Parent
                        end
                    end
                    local nm = norm(info.name)
                    local old = cards[nm]
                    if not old or (old.stock == nil and stock ~= nil) then
                        cards[nm] = {norm = nm, disp = info.name, stock = stock, price = info.price,
                                     inst = cur.Name, nameObj = info.nameObj,
                                     stockSrc = stock ~= nil and "group" or nil}
                    end
                    break
                end
                cur = cur.Parent
            end
        end
    end

    -- สำรอง: ยังหา stock ไม่เจอ -> ใช้ตำแหน่งบนจอ (ป้าย Stock อยู่เหนือชื่อกล่อง และซ้อนกันในแนวนอน)
    for _, c in pairs(cards) do
        if c.stock == nil and c.nameObj then
            local np, ns = c.nameObj.AbsolutePosition, c.nameObj.AbsoluteSize
            local bestD = math.huge
            for _, S in ipairs(stockLbls) do
                local sp, ss = S.o.AbsolutePosition, S.o.AbsoluteSize
                local dyC = (np.Y + ns.Y / 2) - (sp.Y + ss.Y / 2)
                local overlap = sp.X < np.X + ns.X and np.X < sp.X + ss.X
                if overlap and dyC > 0 and dyC < math.max(ss.Y * 3, 150) and dyC < bestD then
                    bestD = dyC; c.stock = S.stock; c.stockSrc = "pos"
                end
            end
        end
    end

    -- BALANCE: ตัวเลขเงินที่อยู่ใกล้ใต้ป้าย BALANCE ที่สุด (เฉพาะที่มองเห็นอยู่ และมากกว่า 0)
    -- อ่านไม่ได้ = nil -> ข้ามการเช็คเงิน (ไม่บล็อกการเปิด)
    local function shown(o)
        local cur = o
        while cur and cur ~= pg do
            if cur:IsA("GuiObject") and not cur.Visible then return false end
            if cur:IsA("ScreenGui") and not cur.Enabled then return false end
            cur = cur.Parent
        end
        return true
    end
    for _, L in ipairs(list) do
        if L.l:match("^balance") and shown(L.o) then
            local bp = L.o.AbsolutePosition
            local bd = math.huge
            for _, P in ipairs(list) do
                if P.price and P.price > 0 then
                    local pp = P.o.AbsolutePosition
                    local dy = pp.Y - bp.Y
                    if dy > -4 then
                        local d = dy + math.abs(pp.X - bp.X) * 2
                        if d < bd and d < 600 and shown(P.o) then bd = d; bal = P.price end
                    end
                end
            end
            if bal then break end
        end
    end
    return cards, bal
end

local pats = {"reel","spin","opening","animation","unbox"}
local function matches(n) n=n:lower(); for _,p in ipairs(pats) do if n:find(p,1,true) then return true end end end
local function hideAnim()
    for _,o in ipairs(lp.PlayerGui:GetDescendants()) do
        if not o:IsDescendantOf(gui) and matches(o.Name) then
            if o:IsA("ScreenGui") and o.Enabled then hidden[o]=true; o.Enabled=false
            elseif o:IsA("GuiObject") and o.Visible then hidden[o]=true; o.Visible=false end
        end
    end
end
local function restore()
    for o in pairs(hidden) do pcall(function() if o:IsA("ScreenGui") then o.Enabled=true else o.Visible=true end end) end
    hidden={}
end
local function setSkip(on)
    if not getconnections then return end
    for _,c in ipairs(getconnections(DisplayOpen.OnClientEvent)) do
        pcall(function() if on then c:Disable() else c:Enable() end end)
    end
end

-- ===== UI =====
local W = 192
local frame = Instance.new("Frame")
frame.Size = UDim2.new(0,W,0,398)
frame.Position = UDim2.new(0,4,0.08,0)
frame.BackgroundColor3 = Color3.fromRGB(18,18,18)
frame.BackgroundTransparency = 0.1
frame.BorderSizePixel = 0
frame.Parent = gui

local tb = Instance.new("Frame")
tb.Size=UDim2.new(1,0,0,22); tb.BackgroundColor3=Color3.fromRGB(0,80,180); tb.BorderSizePixel=0; tb.Parent=frame
local tl = Instance.new("TextLabel")
tl.Size=UDim2.new(1,0,1,0); tl.BackgroundTransparency=1
tl.Text="🎁 Case Opener v4.1"; tl.TextColor3=Color3.new(1,1,1); tl.TextSize=13; tl.Parent=tb

local function Btn(txt,y,col,xs,ws)
    local b=Instance.new("TextButton")
    b.Size=UDim2.new(ws or 1,(ws and -6 or -8),0,26)
    b.Position=UDim2.new(xs or 0,(xs and xs~=0 and 2 or 4),0,y)
    b.BackgroundColor3=col or Color3.fromRGB(50,50,50)
    b.TextColor3=Color3.new(1,1,1); b.TextSize=12; b.BorderSizePixel=0
    b.Text=txt; b.Parent=frame; return b
end
local function Fld(ph,def,y,xs,ws)
    local t=Instance.new("TextBox")
    t.Size=UDim2.new(ws or 1,(ws and -6 or -8),0,26)
    t.Position=UDim2.new(xs or 0,(xs and xs~=0 and 2 or 4),0,y)
    t.PlaceholderText=ph; t.Text=def; t.TextSize=12; t.ClearTextOnFocus=false
    t.BackgroundColor3=Color3.fromRGB(32,32,32); t.TextColor3=Color3.new(1,1,1); t.BorderSizePixel=0
    t.Parent=frame; return t
end

local scanBtn=Btn("🔍 Scan ชื่อกล่อง (โหมดเลือกเอง)",24,Color3.fromRGB(0,80,160))
scanBtn.TextSize=11

local scroll=Instance.new("ScrollingFrame")
scroll.Size=UDim2.new(1,-8,0,84); scroll.Position=UDim2.new(0,4,0,52)
scroll.BackgroundColor3=Color3.fromRGB(26,26,26); scroll.BorderSizePixel=0
scroll.ScrollBarThickness=4; scroll.CanvasSize=UDim2.new(0,0,0,0); scroll.Parent=frame
local ull=Instance.new("UIListLayout")
ull.Padding=UDim.new(0,2); ull.SortOrder=Enum.SortOrder.LayoutOrder; ull.Parent=scroll
ull:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    scroll.CanvasSize=UDim2.new(0,0,0,ull.AbsoluteContentSize.Y+4)
end)

local SEL=Color3.fromRGB(0,110,55); local DEF=Color3.fromRGB(44,44,44)
local function addCase(name,autoSel)
    if dead or type(name)~="string" or name:sub(1,2)=="__" then return end
    local nm = norm(name)
    if nm == "" then return end
    if keyByNorm[nm] == nil then keyByNorm[nm] = name end
    local b=cBtns[name]
    if b then
        if autoSel then selectedCases[name]=true; b.BackgroundColor3=SEL; b.TextColor3=Color3.new(1,1,1) end
        return
    end
    b=Instance.new("TextButton")
    b.Size=UDim2.new(1,-2,0,24); b.BackgroundColor3=DEF
    b.TextColor3=Color3.fromRGB(180,180,180); b.TextSize=11; b.BorderSizePixel=0
    b.Text="  "..name; b.TextXAlignment=Enum.TextXAlignment.Left; b.Parent=scroll
    cBtns[name]=b
    if autoSel then selectedCases[name]=true; b.BackgroundColor3=SEL; b.TextColor3=Color3.new(1,1,1) end
    b.MouseButton1Click:Connect(function()
        local isSel=not selectedCases[name]
        selectedCases[name]=isSel or nil
        b.BackgroundColor3=isSel and SEL or DEF
        b.TextColor3=isSel and Color3.new(1,1,1) or Color3.fromRGB(180,180,180)
        save()
    end)
end

-- โหลดรายชื่อกล่อง + ที่เลือกไว้จากไฟล์
local savedSel = {}
if type(cfg.sel) == "table" then
    for _, n in ipairs(cfg.sel) do if type(n) == "string" then savedSel[n] = true end end
end
if type(cfg.cases) == "table" then
    for _, n in ipairs(cfg.cases) do
        if type(n) == "string" then addCase(n, savedSel[n]) end
    end
end
for n in pairs(savedSel) do addCase(n, true) end

-- Scan: หาชื่อกล่องจากโมดูลใน ReplicatedStorage + นับการ์ดกล่องที่อ่านได้จากหน้า UI
scanBtn.MouseButton1Click:Connect(function()
    scanBtn.Text="scanning..."
    task.spawn(function()
        local found={}
        local function isRemote(o)
            return o:IsA("RemoteEvent") or o:IsA("RemoteFunction")
                or o:IsA("BindableEvent") or o:IsA("BindableFunction")
        end
        local function fromTable(t)
            for k,v in pairs(t) do
                if type(k)=="string" and type(v)=="table" then found[k]=true
                elseif type(v)=="table" and type(v.Name)=="string" then found[v.Name]=true end
            end
        end
        for _,o in ipairs(RS:GetDescendants()) do
            pcall(function()
                if isRemote(o) or not o.Name:lower():find("case",1,true) then return end
                if o:IsA("ModuleScript") then
                    local ok,t=pcall(require,o)
                    if ok and type(t)=="table" then
                        fromTable(t)
                        for k,v in pairs(t) do
                            if type(k)=="string" and k:lower():find("case",1,true) and type(v)=="table" then
                                fromTable(v)
                            end
                        end
                    end
                elseif o:IsA("Folder") or o:IsA("Configuration") then
                    for _,c in ipairs(o:GetChildren()) do
                        if not isRemote(c) and not c:IsA("LuaSourceContainer") then found[c.Name]=true end
                    end
                elseif not o:IsA("LuaSourceContainer") then
                    found[o.Name]=true
                end
            end)
        end
        local n=0
        for k in pairs(found) do
            if type(k)=="string" and k:sub(1,1)~="_" then addCase(k); n+=1 end
        end
        local u=0
        local okU, cards = pcall(scanUI)
        if okU and type(cards)=="table" then for nm in pairs(cards) do if limitedSet[nm] then u+=1 end end end
        scanBtn.Text=string.format("✓ โมดูล %d | Limited ใน UI %d/%d", n, u, #LIMITED)
        save()
    end)
end)

local manBox=Fld("ชื่อกล่อง...","",140,0,0.73)
local addBtn=Btn("Add",140,Color3.fromRGB(0,100,50),0.73,0.27)
addBtn.MouseButton1Click:Connect(function()
    local n=manBox.Text:match("^%s*(.-)%s*$")
    if n~="" then addCase(n,true); manBox.Text=""; save() end
end)

local amtBox=Fld("amt(1-"..MAX_AMT..")",tostring(cfg.amt),168,0,0.5)
local thrBox=Fld("delay(s)",tostring(cfg.dly),168,0.5,0.5)  -- ช่องขวา = delay วินาที

local ON_C=Color3.fromRGB(0,100,180); local OFF_C=Color3.fromRGB(50,50,50)
local skipBtn =Btn("Skip: OFF", 196,nil,0,0.5)
local hideBtn =Btn("Hide: OFF", 196,nil,0.5,0.5)
local quickBtn=Btn("Quick: OFF",224,nil,0,0.5)
local flagBtn =Btn("Flag: false",224,nil,0.5,0.5)
local autoBtn =Btn("Auto Limited: ON",252)
local goBtn   =Btn("▶ Start",280,Color3.fromRGB(0,130,55))
goBtn.Size=UDim2.new(1,-8,0,28)

local stLbl=Instance.new("TextLabel")
stLbl.Size=UDim2.new(1,-8,0,82); stLbl.Position=UDim2.new(0,4,0,312)
stLbl.BackgroundTransparency=1; stLbl.TextColor3=Color3.fromRGB(200,200,200)
stLbl.TextSize=10; stLbl.TextWrapped=true
stLbl.TextXAlignment=Enum.TextXAlignment.Left; stLbl.TextYAlignment=Enum.TextYAlignment.Top
stLbl.Text="หยุดอยู่"; stLbl.Parent=frame

local function paint()
    skipBtn.Text  = skipOn  and "Skip: ON"  or "Skip: OFF";  skipBtn.BackgroundColor3  = skipOn  and ON_C or OFF_C
    hideBtn.Text  = hideOn  and "Hide: ON"  or "Hide: OFF";  hideBtn.BackgroundColor3  = hideOn  and ON_C or OFF_C
    quickBtn.Text = quickOn and "Quick: ON" or "Quick: OFF"; quickBtn.BackgroundColor3 = quickOn and ON_C or OFF_C
    flagBtn.Text  = "Flag: "..tostring(flag);                flagBtn.BackgroundColor3  = flag    and ON_C or OFF_C
    autoBtn.Text  = autoOn and "🎲 Auto Limited: ON" or "Auto Limited: OFF"
    autoBtn.TextSize = 11
    autoBtn.BackgroundColor3 = autoOn and ON_C or OFF_C
end
if skipOn then
    if getconnections then setSkip(true) else skipOn=false end
end
paint()

-- เซฟทุกอย่างลงไฟล์ (ต้องใช้ executor ที่มี writefile)
save = function()
    if not canFile then return end
    local names, sel = {}, {}
    for n in pairs(cBtns) do names[#names+1]=n end
    for n in pairs(selectedCases) do sel[#sel+1]=n end
    table.sort(names); table.sort(sel)
    local data = {cases=names, sel=sel, keys=learned, amt=amtBox.Text, dly=thrBox.Text,
                  skip=skipOn, hide=hideOn, quick=quickOn, flag=flag, auto=autoOn}
    pcall(function() writefile(SAVE_FILE, HttpService:JSONEncode(data)) end)
end
amtBox.FocusLost:Connect(function() save() end)
thrBox.FocusLost:Connect(function() save() end)

local function fB(txt,yo,fn)
    local b=Instance.new("TextButton")
    b.Size=UDim2.new(0,44,0,24); b.Position=UDim2.new(0,4,0.08,yo)
    b.Text=txt; b.TextSize=12; b.Parent=gui; b.MouseButton1Click:Connect(fn)
end
fB("เมนู",-28,function() frame.Visible=not frame.Visible end)
fB("X",-56,function()
    running=false; dead=true; save()
    if skipOn then setSkip(false) end
    restore(); gui:Destroy()
end)

skipBtn.MouseButton1Click:Connect(function()
    if not getconnections then stLbl.Text="executor ไม่รองรับ Skip"; return end
    skipOn=not skipOn; setSkip(skipOn); paint(); save()
end)
hideBtn.MouseButton1Click:Connect(function()
    hideOn=not hideOn; paint(); if not hideOn then restore() end; save()
end)
quickBtn.MouseButton1Click:Connect(function()
    quickOn=not quickOn; paint(); save()
end)
flagBtn.MouseButton1Click:Connect(function()
    flag=not flag; paint(); save()
end)
autoBtn.MouseButton1Click:Connect(function()
    autoOn=not autoOn; paint(); save()
end)

-- จับชื่อกล่องอัตโนมัติ: เปิดกล่องเองในเกม 1 ครั้ง ชื่อที่เกมส่งจริงจะถูกจำไว้ใช้เป็น key
pcall(function()
    if not (hookmetamethod and getnamecallmethod) then return end
    local old
    old = hookmetamethod(game, "__namecall", (newcclosure or function(f) return f end)(function(self, ...)
        if not dead and not running and self == OpenRemote
            and getnamecallmethod() == "InvokeServer"
            and not (checkcaller and checkcaller()) then
            local n, a, f = ...
            if type(n) == "string" then
                task.defer(function()
                    addCase(n, true)
                    learned[norm(n)] = n
                    save()
                    stLbl.Text = "จำกล่องแล้ว: "..n.."\nเกมส่ง ×"..tostring(a)..", arg3="..tostring(f)
                end)
            end
        end
        return old(self, ...)
    end))
end)

-- เลือกชื่อ key ที่จะส่งให้เซิร์ฟ: ชื่อที่เคยสำเร็จ > key ที่รู้จัก > ชื่อบนการ์ด > ตัวเล็ก > ชื่อ Instance
local function candsFor(e)
    local list, seen = {}, {}
    local function add(n)
        if type(n) == "string" and n ~= "" and not seen[n] then
            seen[n] = true; list[#list + 1] = n
        end
    end
    add(learned[e.norm]); add(e.key); add(keyByNorm[e.norm])
    add(e.disp); add(e.disp:lower()); add(e.inst)
    return list
end

goBtn.MouseButton1Click:Connect(function()
    if running then
        running=false; goBtn.Text="▶ Start"
        goBtn.BackgroundColor3=Color3.fromRGB(0,130,55); return
    end
    if not autoOn then
        local any=false
        for _ in pairs(selectedCases) do any=true; break end
        if not any then stLbl.Text="⚠ แตะชื่อกล่องเพื่อเลือกก่อน (หรือเปิด Auto Limited)"; return end
    end
    save()
    running=true; token+=1; local my=token
    goBtn.Text="■ Stop"; goBtn.BackgroundColor3=Color3.fromRGB(160,40,40)
    sent,okn,total,t0=0,0,0,os.clock()

    local amt = math.clamp(math.floor(tonumber(amtBox.Text) or 3), 1, MAX_AMT)
    local dly = math.max(tonumber(thrBox.Text) or 1, 0.05)
    local failRun, bigOk, bigFail = 0, 0, 0
    local okType, lastGot, note = "-", 0, ""
    local failN, cdN, tryIdx, estimate, probe = {}, {}, {}, {}, {}
    local cards, bal, lastScan = {}, nil, 0
    local errCount = 0
    -- จังหวะเซิร์ฟ: cool = ช่วงห่างขั้นต่ำระหว่างการเปิดสำเร็จ 2 ครั้ง (เรียนรู้เอง ขึ้น/ลงตาม boost ความเร็วเปิด)
    local cool, lastOk = 0.3, os.clock()

    local function step()
        -- 1) อ่านหน้า UI ใหม่ (stock/ราคา/เงิน) ทุก SCAN_EVERY วินาที
        if os.clock() - lastScan >= SCAN_EVERY then
            local okS, c, b = pcall(scanUI)
            if okS and type(c) == "table" then
                cards, bal = c, b
                local t = os.clock()
                for nm, cd in pairs(cards) do
                    -- UI อัปเดตช้ากว่าที่เราเปิดไป -> ใช้ค่าประมาณของเราแทนช่วง 3 วิแรก
                    local est = estimate[nm]
                    if est and cd.stock and t - est.t < 3 and cd.stock > est.v then cd.stock = est.v end
                end
            end
            lastScan = os.clock()
        end

        -- 2) สร้างรายการกล่องที่เปิดได้ตอนนี้ (มี stock, เงินพอ)
        local pool, st = {}, {total = 0, empty = 0, poor = 0}
        local function consider(e)
            st.total += 1
            if e.stock and e.stock <= 0 then st.empty += 1; return end
            local a = amt
            if probe[e.norm] then a = 1 end
            if e.stock then a = math.min(a, e.stock) end
            if bal and e.price and e.price > 0 then a = math.min(a, math.floor(bal / e.price)) end
            if a < 1 then st.poor += 1; return end
            e.a = a
            pool[#pool + 1] = e
        end
        -- กล่องที่เลือกเอง (onlyUnlimited = ข้ามกล่องที่อยู่ใน LIMITED เพราะ Auto จัดการให้แล้ว)
        local function considerSelected(onlyUnlimited)
            for n in pairs(selectedCases) do
                local nm = norm(n)
                if not (onlyUnlimited and limitedSet[nm]) then
                    local c = cards[nm]
                    local stk = c and c.stock
                    -- กล่องไม่จำกัดไม่มี stock: เชื่อ stock เฉพาะที่อ่านจากในการ์ดของมันเอง ไม่เอาป้ายที่เดาจากตำแหน่ง
                    if stk ~= nil and not limitedSet[nm] and c.stockSrc ~= "group" then stk = nil end
                    consider({norm = nm, disp = n, key = n, stock = stk,
                              price = c and c.price, inst = c and c.inst, fb = onlyUnlimited})
                end
            end
        end
        if autoOn then
            -- LIMITED ต้องอ่าน stock ได้ (ไม่รู้ stock = ไม่ยิง กัน Robux เด้ง)
            for nm in pairs(limitedSet) do
                local c = cards[nm]
                if c and c.stock ~= nil then consider(c) end
            end
            -- Limited ว่าง (หมด/เงินไม่พอ/รอรีสต็อก) -> เปิดกล่องไม่จำกัดสต็อกที่เลือกไว้แทน
            if #pool == 0 then considerSelected(true) end
        else
            considerSelected(false)
        end

        local balTxt = bal and string.format("$%.0f", bal) or "?"

        -- ไม่มีกล่องให้เปิด -> รอ (รีสต็อกมาแล้วเริ่มเองอัตโนมัติ)
        if #pool == 0 then
            if autoOn and st.total == 0 then
                stLbl.Text = "ไม่เจอการ์ดกล่อง Limited ใน UI\nเปิดหน้า Cases ค้างไว้ แล้วกด Scan ดูจำนวน"
            else
                stLbl.Text = string.format(
                    "รอกล่อง/รีสต็อก...\nUI %d | หมด %d | เงินไม่พอ %d\n💰%s | ส่ง %d ✓%d ได้ %d",
                    st.total, st.empty, st.poor, balTxt, sent, okn, total)
            end
            task.wait(0.5)
            return
        end

        -- 3) สุ่ม 1 กล่องแล้วยิง
        local e = pool[math.random(#pool)]
        local a = e.a
        local cl = candsFor(e)
        local key = cl[((tryIdx[e.norm] or 0) % #cl) + 1]

        local ok, res = pcall(function() return OpenRemote:InvokeServer(key, a, flag) end)
        local t1 = os.clock()
        sent += 1
        if hideOn then hideAnim() end
        local good = ok and res ~= nil and res ~= false
        local nextWait = dly

        if good then
            local got = a
            if type(res) == "table" and #res > 0 then got = #res end
            okType, lastGot = typeof(res), got
            okn += 1; total += got; failRun = 0; note = ""
            if learned[e.norm] ~= key then learned[e.norm] = key; save() end
            tryIdx[e.norm] = 0; failN[e.norm] = 0; cdN[e.norm] = 0; probe[e.norm] = nil
            if a > 3 then bigOk += 1 end
            if e.stock then
                local nv = math.max(0, e.stock - got)
                estimate[e.norm] = {v = nv, t = os.clock()}
                e.stock = nv
                local c = cards[e.norm]
                if c then c.stock = nv end
            end
            if bal and e.price then bal = math.max(0, bal - e.price * got) end
            -- เปิดผ่าน -> ลองถี่ขึ้นทีละนิด (ถ้าเซิร์ฟเร็วขึ้น เช่นตอนมี boost) ถ้าชนอีกก็ถอยเอง
            cool = cool * 0.95
            if cool < 0.1 then cool = 0 end
            lastOk = t1
            nextWait = quickOn and math.max(0.05, cool) or math.max(dly, cool)
        else
            local since = t1 - lastOk
            local proven = learned[e.norm] ~= nil
            local inWin = cool < COOL_MAX and since < math.max(cool * 1.5, 4)
            local cdLimit = proven and 4 or 1   -- กี่ครั้งติดกันที่ยอมนับว่าเป็นคูลดาวน์ (เกินนี้ = ล้มเหลวจริง)
            if inWin and (cdN[e.norm] or 0) < cdLimit then
                -- ล้มเหลวใกล้ๆ หลังเปิดสำเร็จ = เซิร์ฟยังคูลดาวน์ ไม่ใช่กล่องเสีย
                -- -> ไม่เปลี่ยนชื่อ key แค่ขยายช่วงห่างแล้วรอ
                cdN[e.norm] = (cdN[e.norm] or 0) + 1
                if e.stock and e.stock <= 3 and cdN[e.norm] == 1 then
                    probe[e.norm] = true; nextWait = 0.3
                    note = "\nของเหลือน้อย โดนแย่ง? → ลองทีละ 1"
                else
                    cool = math.min(math.max(cool * 1.4, since + 0.25), COOL_MAX)
                    nextWait = math.max(0.25, lastOk + cool - t1)
                    note = string.format("\nเซิร์ฟคูลดาวน์ → ห่างเป็น %.1fs", cool)
                end
            else
                -- ล้มเหลวนอกช่วงคูลดาวน์ = ล้มเหลวจริง (ชื่อ key ผิด / stock หมด / เงินไม่พอ ฯลฯ)
                failRun += 1
                failN[e.norm] = (failN[e.norm] or 0) + 1
                if a > 1 then probe[e.norm] = true end
                if not learned[e.norm] then tryIdx[e.norm] = (tryIdx[e.norm] or 0) + 1 end
                note = "\nล้มเหลว: "..(ok and "false/nil" or tostring(res))
            end
            if a > 3 then
                bigFail += 1
                if bigOk == 0 and bigFail >= 8 then
                    amt = 3; note = note.."\nเซิร์ฟไม่รับ >3 → ใช้ 3 แทน"
                end
            end
            lastScan = 0   -- อ่าน stock ใหม่ทันที
        end

        -- 4) สถานะ
        local per = total / math.max(os.clock() - t0, 1) * 60
        local rate = math.floor(okn / math.max(sent, 1) * 100)
        stLbl.Text = string.format(
            "ส่ง %d | ✓%d (%d%%) | ได้ %d\n%.0f/min | UI%d พร้อม%d หมด%d\n💰%s | ห่าง %.1fs | ok:%s ×%d\n%s%s ขอ×%d%s",
            sent, okn, rate, total, per, st.total, #pool, st.empty,
            balTxt, cool, okType, lastGot, e.fb and "[สำรอง] " or "", e.disp, a, note)

        if failRun >= MAX_FAIL then
            stLbl.Text = stLbl.Text.."\n⛔ ล้มเหลวติดกัน "..MAX_FAIL.." ครั้ง — หยุดกัน Robux เด้ง (เช็คชื่อกล่อง/เงิน)"
            running = false
            return
        end

        task.wait(nextWait)
    end

    task.spawn(function()
        while running and token == my and not dead do
            local okI, err = pcall(step)
            if not okI then
                errCount += 1
                stLbl.Text = "⚠ บั๊ก: "..tostring(err)
                if errCount >= 15 then running = false end
                task.wait(1)
            end
        end
        if token == my then
            running = false
            goBtn.Text = "▶ Start"
            goBtn.BackgroundColor3 = Color3.fromRGB(0,130,55)
            restore()
        end
    end)
end)
