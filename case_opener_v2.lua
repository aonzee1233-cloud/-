-- Case Opener v2  (Roblox / Luau executor)
-- แก้: จำกัดกล่อง 3 / Quick ล้มเหลวเกือบหมด / Scan หาไม่เจอ / ต้องพิมพ์ชื่อกล่องใหม่ทุกครั้ง
local RS          = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local lp          = game:GetService("Players").LocalPlayer
local OpenRemote  = RS.GameEvents.Cases.Open
local DisplayOpen = RS.GameEvents.Cases.DisplayOpen

local MAX_AMT   = 10               -- เพดานกล่องต่อครั้ง (ถ้าเซิร์ฟรับแค่ 3 สคริปต์จะถอยเป็น 3 เอง)
local SAVE_FILE = "CaseOpener.json"

local running, token, dead = false, 0, false
local sent, okn, total, t0 = 0, 0, 0, 0
local flag, skipOn, hideOn, quickOn = false, false, false, false
local hidden, selectedCases, cBtns = {}, {}, {}
local save = function() end

-- ===== โหลดค่าที่เซฟไว้ =====
local canFile = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
local cfg = {cases = {}, sel = {}, amt = "3", thr = "2", skip = false, hide = false, quick = false, flag = false}
if canFile and isfile(SAVE_FILE) then
    local ok, d = pcall(function() return HttpService:JSONDecode(readfile(SAVE_FILE)) end)
    if ok and type(d) == "table" then
        for k, v in pairs(d) do cfg[k] = v end
    end
end
flag, skipOn, hideOn, quickOn = cfg.flag == true, cfg.skip == true, cfg.hide == true, cfg.quick == true

local gui = Instance.new("ScreenGui")
gui.ResetOnSpawn = false
gui.Parent = (gethui and gethui()) or lp:WaitForChild("PlayerGui")

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

local W = 192
local frame = Instance.new("Frame")
frame.Size = UDim2.new(0,W,0,372)
frame.Position = UDim2.new(0,4,0.08,0)
frame.BackgroundColor3 = Color3.fromRGB(18,18,18)
frame.BackgroundTransparency = 0.1
frame.BorderSizePixel = 0
frame.Parent = gui

local tb = Instance.new("Frame")
tb.Size=UDim2.new(1,0,0,22); tb.BackgroundColor3=Color3.fromRGB(0,80,180); tb.BorderSizePixel=0; tb.Parent=frame
local tl = Instance.new("TextLabel")
tl.Size=UDim2.new(1,0,1,0); tl.BackgroundTransparency=1
tl.Text="🎁 Case Opener v2"; tl.TextColor3=Color3.new(1,1,1); tl.TextSize=13; tl.Parent=tb

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

local scanBtn=Btn("🔍 Scan หากล่องในเกม",24,Color3.fromRGB(0,80,160))

local scroll=Instance.new("ScrollingFrame")
scroll.Size=UDim2.new(1,-8,0,100); scroll.Position=UDim2.new(0,4,0,52)
scroll.BackgroundColor3=Color3.fromRGB(26,26,26); scroll.BorderSizePixel=0
scroll.ScrollBarThickness=4; scroll.CanvasSize=UDim2.new(0,0,0,0); scroll.Parent=frame
local ull=Instance.new("UIListLayout")
ull.Padding=UDim.new(0,2); ull.SortOrder=Enum.SortOrder.LayoutOrder; ull.Parent=scroll
ull:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    scroll.CanvasSize=UDim2.new(0,0,0,ull.AbsoluteContentSize.Y+4)
end)

local SEL=Color3.fromRGB(0,110,55); local DEF=Color3.fromRGB(44,44,44)
local function addCase(name,autoSel)
    if dead then return end
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

-- Scan: ไล่หาในทั้ง ReplicatedStorage (โฟลเดอร์/โมดูลที่ชื่อมีคำว่า case)
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
        local n=0; for k in pairs(found) do addCase(k); n+=1 end
        scanBtn.Text=n>0 and ("✓ "..n.." กล่อง — แตะเพื่อเลือก") or "ไม่เจอ — เปิดกล่องเอง 1 ครั้ง"
        save()
    end)
end)

local manBox=Fld("ชื่อกล่อง...","",154,0,0.73)
local addBtn=Btn("Add",154,Color3.fromRGB(0,100,50),0.73,0.27)
addBtn.MouseButton1Click:Connect(function()
    local n=manBox.Text:match("^%s*(.-)%s*$")
    if n~="" then addCase(n,true); manBox.Text=""; save() end
end)

local amtBox=Fld("amt(1-"..MAX_AMT..")",tostring(cfg.amt),182,0,0.5)
local thrBox=Fld("threads",tostring(cfg.thr),182,0.5,0.5)

local ON_C=Color3.fromRGB(0,100,180); local OFF_C=Color3.fromRGB(50,50,50)
local skipBtn =Btn("Skip: OFF", 210,nil,0,0.5)
local hideBtn =Btn("Hide: OFF", 210,nil,0.5,0.5)
local quickBtn=Btn("Quick: OFF",238,nil,0,0.5)
local flagBtn =Btn("Flag: false",238,nil,0.5,0.5)
local goBtn   =Btn("▶ Start",266,Color3.fromRGB(0,130,55))
goBtn.Size=UDim2.new(1,-8,0,28)

local stLbl=Instance.new("TextLabel")
stLbl.Size=UDim2.new(1,-8,0,72); stLbl.Position=UDim2.new(0,4,0,296)
stLbl.BackgroundTransparency=1; stLbl.TextColor3=Color3.fromRGB(200,200,200)
stLbl.TextSize=10; stLbl.TextWrapped=true
stLbl.TextXAlignment=Enum.TextXAlignment.Left; stLbl.TextYAlignment=Enum.TextYAlignment.Top
stLbl.Text="หยุดอยู่"; stLbl.Parent=frame

local function paint()
    skipBtn.Text  = skipOn  and "Skip: ON"  or "Skip: OFF";  skipBtn.BackgroundColor3  = skipOn  and ON_C or OFF_C
    hideBtn.Text  = hideOn  and "Hide: ON"  or "Hide: OFF";  hideBtn.BackgroundColor3  = hideOn  and ON_C or OFF_C
    quickBtn.Text = quickOn and "Quick: ON" or "Quick: OFF"; quickBtn.BackgroundColor3 = quickOn and ON_C or OFF_C
    flagBtn.Text  = "Flag: "..tostring(flag);                flagBtn.BackgroundColor3  = flag    and ON_C or OFF_C
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
    local data = {cases=names, sel=sel, amt=amtBox.Text, thr=thrBox.Text,
                  skip=skipOn, hide=hideOn, quick=quickOn, flag=flag}
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

-- จับชื่อกล่องอัตโนมัติ: เปิดกล่องเองในเกม 1 ครั้ง ชื่อจะเด้งเข้าลิสต์และถูกเลือกให้
pcall(function()
    if not (hookmetamethod and getnamecallmethod) then return end
    local old
    old = hookmetamethod(game, "__namecall", (newcclosure or function(f) return f end)(function(self, ...)
        if not dead and not running and self == OpenRemote
            and getnamecallmethod() == "InvokeServer"
            and not (checkcaller and checkcaller()) then
            local n, a = ...
            if type(n) == "string" then
                task.defer(function()
                    addCase(n, true); save()
                    stLbl.Text = "จำกล่องแล้ว: "..n.." (เกมเปิดทีละ ×"..tostring(a)..")"
                end)
            end
        end
        return old(self, ...)
    end))
end)

goBtn.MouseButton1Click:Connect(function()
    if running then
        running=false; goBtn.Text="▶ Start"
        goBtn.BackgroundColor3=Color3.fromRGB(0,130,55); return
    end
    local cases={}; for n in pairs(selectedCases) do cases[#cases+1]=n end
    if #cases==0 then stLbl.Text="⚠ แตะชื่อกล่องเพื่อเลือกก่อน"; return end
    save()
    running=true; token+=1; local my=token
    goBtn.Text="■ Stop"; goBtn.BackgroundColor3=Color3.fromRGB(160,40,40)
    sent,okn,total,t0=0,0,0,os.clock()

    local nT  = math.clamp(math.floor(tonumber(thrBox.Text) or 1), 1, 10)
    local amt = math.clamp(math.floor(tonumber(amtBox.Text) or 3), 1, MAX_AMT)

    -- gap = ระยะห่างระหว่างคำขอ "รวมทุก thread" ปรับเองตามที่เซิร์ฟรับได้
    -- สำเร็จ -> เร็วขึ้น / ถูกปฏิเสธ -> ช้าลง (Quick แค่ลดค่าต่ำสุดลง)
    local minGap = quickOn and 0.12 or 0.4
    local gap    = 0.5
    local failRun, bigOk, bigFail = 0, 0, 0
    local lastType, note = "-", ""
    local alive = nT

    for i=1,nT do
        task.spawn(function()
            task.wait(gap*(i-1))
            while running and token==my do
                local name=cases[math.random(#cases)]
                local a=amt
                local ok,res=pcall(function()
                    return OpenRemote:InvokeServer(name,a,flag)
                end)

                if not ok and a>3 then
                    amt=3; note="\nเซิร์ฟไม่รับ >3 → ใช้ 3 แทน"
                elseif not ok then
                    stLbl.Text="err: "..tostring(res)
                    break
                else
                    sent+=1
                    lastType=typeof(res)
                    if hideOn then hideAnim() end
                    if res ~= nil and res ~= false then
                        okn+=1; total+=a; failRun=0
                        if a>3 then bigOk+=1 end
                        gap=math.max(gap*0.9, minGap)
                    else
                        failRun+=1
                        if a>3 then
                            bigFail+=1
                            if bigOk==0 and bigFail>=6 then
                                amt=3; note="\nเซิร์ฟไม่รับ >3 → ใช้ 3 แทน"
                            end
                        end
                        gap=math.min(gap*1.4+0.02, 3)
                    end
                end

                task.wait(gap*nT)

                if i==1 then
                    local per=total/math.max(os.clock()-t0,1)*60
                    local rate=math.floor(okn/math.max(sent,1)*100)
                    stLbl.Text=string.format(
                        "ส่ง %d | ✓%d (%d%%) | รวม %d\n%.0f/min | %dt | gap%.2f | res:%s\n%s×%d%s",
                        sent,okn,rate,total,per,nT,gap,lastType,name,a,note)
                end
                if failRun>=20 then
                    stLbl.Text=stLbl.Text.."\n⛔ โดนปฏิเสธรัว — ลด threads หรือปิด Quick"
                    running=false
                    break
                end
            end
            alive-=1
            if alive<=0 and token==my then
                running=false; goBtn.Text="▶ Start"
                goBtn.BackgroundColor3=Color3.fromRGB(0,130,55); restore()
            end
        end)
    end
end)
