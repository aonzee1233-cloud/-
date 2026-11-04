-- Case Opener v3  (Roblox / Luau executor)
-- v3: Auto Limited = สุ่มเฉพาะ 12 กล่องในรายชื่อ LIMITED (แก้ได้ด้านล่าง) โดยอ่านราคา/stock จากหน้า Cases เอง (ไม่ต้องพิมพ์ชื่อ, รีสต็อกก็เจอเอง)
--     เช็ค stock + เงินก่อนยิงทุกครั้ง -> กล่องหมดแล้วไม่ยิงต่อ (Robux ไม่เด้ง)
--     กล่องที่ล้มเหลวซ้ำจะถูกพักชั่วคราว / ล้มเหลวติดกันเยอะเกินจะหยุดเอง
local RS          = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local lp          = game:GetService("Players").LocalPlayer
local OpenRemote  = RS.GameEvents.Cases.Open
local DisplayOpen = RS.GameEvents.Cases.DisplayOpen

local MAX_AMT    = 10               -- เพดานกล่องต่อครั้ง (ถ้าเซิร์ฟรับแค่ 3 สคริปต์จะถอยเป็น 3 เอง)
local SAVE_FILE  = "CaseOpener.json"
local SCAN_EVERY = 0.6              -- อ่าน UI ใหม่ทุกกี่วินาที
local BLOCK_SECS = 30               -- พักกล่องที่ล้มเหลวซ้ำกี่วินาที (ถ้า stock เพิ่ม/รีสต็อก จะปลดเอง)
local MAX_FAIL   = 8                -- ล้มเหลวติดกันกี่ครั้งถึงหยุดทั้งหมด

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

    local lab, list = {}, {}
    for _, o in ipairs(pg:GetDescendants()) do
        if (o:IsA("TextLabel") or o:IsA("TextButton")) and not o:IsDescendantOf(gui) then
            local t = clean(o.Text)
            if t ~= "" then
                local L = {o = o, t = t, l = t:lower(), price = parsePrice(t)}
                lab[o] = L
                list[#list + 1] = L
            end
        end
    end

    local done = {}
    for _, L in ipairs(list) do
        if L.price then
            local cur = L.o.Parent
            for _ = 1, 5 do
                if not cur or cur == pg or done[cur] then break end
                local prices, nPrice, name, stock, price = {}, 0, nil, nil, nil
                local bad, cnt = false, 0
                for _, d in ipairs(cur:GetDescendants()) do
                    cnt += 1
                    if cnt > 150 then bad = true; break end
                    local X = lab[d]
                    if X then
                        if X.price then
                            if not prices[X.price] then
                                prices[X.price] = true; nPrice += 1; price = X.price
                            end
                        else
                            local sn = X.l:match("stock%D*(%d+)")
                            if sn then
                                stock = tonumber(sn)
                            elseif X.l:find("sold%s*out") then
                                stock = 0
                            elseif X.l:find("balance", 1, true) or X.l:find("net worth", 1, true) then
                                bad = true
                            elseif X.l:find("case", 1, true) and (not name or #X.t < #name) then
                                name = X.t
                            end
                        end
                    end
                    if nPrice > 1 then break end
                end
                if bad or nPrice > 1 then break end
                if nPrice == 1 and name then
                    done[cur] = true
                    local nm = norm(name)
                    local old = cards[nm]
                    if not old or (old.stock == nil and stock ~= nil) then
                        cards[nm] = {norm = nm, disp = name, stock = stock, price = price, inst = cur.Name}
                    end
                    break
                end
                cur = cur.Parent
            end
        end
    end

    -- BALANCE: เอาตัวเลขเงินที่อยู่ใกล้ใต้ป้าย BALANCE ที่สุด
    for _, L in ipairs(list) do
        if L.l:match("^balance") then
            local bp, bd = L.o.AbsolutePosition, math.huge
            for _, P in ipairs(list) do
                if P.price then
                    local pp = P.o.AbsolutePosition
                    local dy = pp.Y - bp.Y
                    if dy > -4 then
                        local d = dy + math.abs(pp.X - bp.X) * 2
                        if d < bd and d < 600 then bd = d; bal = P.price end
                    end
                end
            end
            break
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
tl.Text="🎁 Case Opener v3"; tl.TextColor3=Color3.new(1,1,1); tl.TextSize=13; tl.Parent=tb

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
    autoBtn.Text  = autoOn and "🎲 Auto Limited: ON" or "Auto Limited: OFF (ใช้กล่องที่เลือก)"
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
    local blocked, failN, tryIdx, estimate = {}, {}, {}, {}
    local cards, bal, lastScan = {}, nil, 0
    local prevOk, errCount = false, 0

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

        -- 2) สร้างรายการกล่องที่เปิดได้ตอนนี้ (มี stock, เงินพอ, ไม่ถูกพัก)
        local pool, st = {}, {total = 0, empty = 0, blocked = 0, poor = 0}
        local now = os.clock()
        local function consider(e)
            st.total += 1
            local b = blocked[e.norm]
            if b then
                if now >= b.untilT or (e.stock and b.stockAt and e.stock > b.stockAt) then
                    blocked[e.norm] = nil; failN[e.norm] = 0
                else
                    st.blocked += 1; return
                end
            end
            if e.stock and e.stock <= 0 then st.empty += 1; return end
            local a = amt
            if e.stock then a = math.min(a, e.stock) end
            if bal and e.price and e.price > 0 then a = math.min(a, math.floor(bal / e.price)) end
            if a < 1 then st.poor += 1; return end
            e.a = a
            pool[#pool + 1] = e
        end
        if autoOn then
            -- เฉพาะ 12 กล่องใน LIMITED และต้องอ่าน stock ได้ (ไม่รู้ stock = ไม่ยิง กัน Robux เด้ง)
            for nm in pairs(limitedSet) do
                local c = cards[nm]
                if c and c.stock ~= nil then consider(c) end
            end
        else
            for n in pairs(selectedCases) do
                local nm = norm(n)
                local c = cards[nm]
                consider({norm = nm, disp = n, key = n, stock = c and c.stock,
                          price = c and c.price, inst = c and c.inst})
            end
        end

        local balTxt = bal and string.format("$%.0f", bal) or "?"

        -- ไม่มีกล่องให้เปิด -> รอ (รีสต็อกมาแล้วเริ่มเองอัตโนมัติ)
        if #pool == 0 then
            prevOk = false
            if autoOn and st.total == 0 then
                stLbl.Text = "ไม่เจอการ์ดกล่อง Limited ใน UI\nเปิดหน้า Cases ค้างไว้ แล้วกด Scan ดูจำนวน"
            else
                stLbl.Text = string.format(
                    "รอกล่อง/รีสต็อก...\nUI %d | หมด %d | พัก %d | เงินไม่พอ %d\n💰%s | ส่ง %d ✓%d ได้ %d",
                    st.total, st.empty, st.blocked, st.poor, balTxt, sent, okn, total)
            end
            task.wait(1)
            return
        end

        -- 3) สุ่ม 1 กล่องแล้วยิง
        local e = pool[math.random(#pool)]
        local a = e.a
        local cl = candsFor(e)
        local key = cl[((tryIdx[e.norm] or 0) % #cl) + 1]
        local wasQuick = prevOk and quickOn

        local ok, res = pcall(function() return OpenRemote:InvokeServer(key, a, flag) end)
        sent += 1
        if hideOn then hideAnim() end
        local good = ok and res ~= nil and res ~= false
        prevOk = false

        if good then
            local got = a
            if type(res) == "table" and #res > 0 then got = #res end
            okType, lastGot = typeof(res), got
            okn += 1; total += got; failRun = 0; prevOk = true; note = ""
            if learned[e.norm] ~= key then learned[e.norm] = key; save() end
            tryIdx[e.norm] = 0; failN[e.norm] = 0
            if a > 3 then bigOk += 1 end
            if e.stock then
                local nv = math.max(0, e.stock - got)
                estimate[e.norm] = {v = nv, t = os.clock()}
                e.stock = nv
                local c = cards[e.norm]
                if c then c.stock = nv end
            end
            if bal and e.price then bal = math.max(0, bal - e.price * got) end
        else
            if a > 3 then
                bigFail += 1
                if bigOk == 0 and bigFail >= 6 then
                    amt = 3; note = "\nเซิร์ฟไม่รับ >3 → ใช้ 3 แทน"
                end
            end
            if wasQuick then
                -- ล้มเหลวทันทีหลังยิงรัว = น่าจะเป็น cooldown ของเซิร์ฟ ไม่นับว่ากล่องมีปัญหา
                note = "\nQuick ชน cooldown → รอ delay"
            else
                failRun += 1
                failN[e.norm] = (failN[e.norm] or 0) + 1
                if not learned[e.norm] then tryIdx[e.norm] = (tryIdx[e.norm] or 0) + 1 end
                local limit = learned[e.norm] and 2 or (#cl + 1)
                if failN[e.norm] >= limit then
                    blocked[e.norm] = {untilT = os.clock() + BLOCK_SECS, stockAt = e.stock}
                    note = "\nพัก "..e.disp.." "..BLOCK_SECS.."s (ล้มเหลวซ้ำ)"
                else
                    note = "\nล้มเหลว: "..(ok and "false/nil" or tostring(res))
                end
                lastScan = 0   -- อ่าน stock ใหม่ทันที
            end
        end

        -- 4) สถานะ
        local per = total / math.max(os.clock() - t0, 1) * 60
        local rate = math.floor(okn / math.max(sent, 1) * 100)
        stLbl.Text = string.format(
            "ส่ง %d | ✓%d (%d%%) | ได้ %d\n%.0f/min | UI%d พร้อม%d หมด%d พัก%d\n💰%s | ok:%s ได้×%d\n%s ขอ×%d%s",
            sent, okn, rate, total, per, st.total, #pool, st.empty, st.blocked,
            balTxt, okType, lastGot, e.disp, a, note)

        if failRun >= MAX_FAIL then
            stLbl.Text = stLbl.Text.."\n⛔ ล้มเหลวติดกัน "..MAX_FAIL.." ครั้ง — หยุดกัน Robux เด้ง (เช็คชื่อกล่อง/เงิน)"
            running = false
            return
        end

        task.wait(prevOk and quickOn and 0.05 or dly)
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
