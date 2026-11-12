-- PBZTensionHUD - data layer
-- Reads the game's hidden TensionMeter subsystem and publishes a small state
-- file that the overlay exe renders. Read-only: never modifies game state.

local MOD_NAME = "PBZTensionHUD"
local MOD_VERSION = "1.0.0"
local STATE_PATH = nil
local LOG_PATH = nil
local REFRESH_MS = 120
local EVENT_TTL = 6.0
local EVENT_MERGE = 0.6
local DIM_JUMP_MIN = 3.0

local N = 0
local function log(s)
    N = N + 1
    local ok, f = pcall(io.open, LOG_PATH, "a")
    if ok and f then
        pcall(function() f:write(string.format("[%03d %s] %s\n", N, os.date("%H:%M:%S"), tostring(s))) f:close() end)
    end
end

local function valid(o)
    if o == nil then return false end
    local ok, r = pcall(function() return o:IsValid() end)
    return ok and r
end

local function nm(o)
    if o == nil then return "nil" end
    local ok, s = pcall(function() return o:GetFullName() end)
    if ok and s then return tostring(s) end
    return "<invalid>"
end

local function shortName(o)
    local s = nm(o)
    local t = s:match("([^%.%s:/]+)$") or s
    return t
end

-- ------------------------------------------------------------------ paths
local function initPaths()
    local tmp = os.getenv("TEMP") or os.getenv("TMP") or "."
    local dir = tmp .. "\\PBZTensionHUD"
    os.execute('if not exist "' .. dir .. '" mkdir "' .. dir .. '"')
    STATE_PATH = dir .. "\\state.txt"
    LOG_PATH = dir .. "\\mod.log"
end

local function exeCandidates()
    local base = "platform\\steam\\ue4ss\\Mods\\" .. MOD_NAME .. "\\bin\\PBZTensionHUD.exe"
    return {
        "..\\..\\..\\" .. base,
        "..\\..\\" .. base,
        "..\\" .. base,
        base,
    }
end

local function findOverlay()
    for _, rel in ipairs(exeCandidates()) do
        local f = io.open(rel, "rb")
        if f then f:close() return rel end
    end
    return nil
end

local overlayStarted = false
local function startOverlay()
    if overlayStarted then return end
    local rel = findOverlay()
    if not rel then log("overlay exe not found; skip auto-launch") return end
    local abs = rel
    pcall(function()
        local h = io.popen("cd")
        if h then abs = h:read("*l") .. "\\" .. rel h:close() end
    end)
    local cmd = string.format('start "" "%s" "%s"', abs, STATE_PATH)
    log("launch: " .. cmd)
    pcall(function() os.execute(cmd) end)
    overlayStarted = true
end

-- ------------------------------------------------------------- refs/cache
local refs = {}

local function getRefs()
    if refs.ready then return refs end
    local ok = pcall(function()
        refs.lib = StaticFindObject("/Script/TensionMeter.Default__TensionLibrary")
        refs.attrUtils = StaticFindObject("/Script/SGameAttributes.Default__AttributeUtils")
        refs.attrSet = StaticFindObject("/Script/CharacterBasics.BasicAttributeSet")
        refs.bpLib = StaticFindObject("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary")
    end)
    if not ok then return refs end
    pcall(function()
        if valid(refs.bpLib) and valid(refs.attrSet) then
            refs.health = refs.bpLib:MakeAttribute("Health", refs.attrSet)
            refs.healthMax = refs.bpLib:MakeAttribute("Health_Max", refs.attrSet)
        end
    end)
    refs.ready = true
    return refs
end

local function getPC()
    local pc = nil
    pcall(function()
        local UEHelpers = require("UEHelpers")
        pc = UEHelpers.GetPlayerController()
    end)
    return valid(pc) and pc or nil
end

local function getPawn(pc)
    local pawn = nil
    pcall(function() pawn = pc.Pawn end)
    return valid(pawn) and pawn or nil
end

-- HP path 0 (most reliable): read the character's own AttributeSetBase object directly.
-- FGameplayAttributeData exposes BaseValue/CurrentValue as plain properties, no struct arguments.
local function hpFromAttributeSetObject(set)
    if not valid(set) then return nil end

    local function numOf(structObj, fields)
        for _, f in ipairs(fields) do
            local v = nil
            pcall(function() v = structObj[f] end)
            if type(v) == "number" then return v end
        end
        return nil
    end

    local h, hm = nil, nil
    pcall(function() h = set.Health end)
    pcall(function() hm = set.Health_Max end)
    if h == nil or hm == nil then return nil end

    local cur = numOf(h, { "CurrentValue", "Current", "Value", "BaseValue" })
    local max = numOf(hm, { "CurrentValue", "Current", "Value", "BaseValue" })
    if cur ~= nil and max ~= nil and max > 0 then
        return cur, max
    end
    return nil
end

local function hpFromAttributeSet(actor)
    local set = nil
    pcall(function() set = actor.AttributeSetBase end)
    return hpFromAttributeSetObject(set)
end

-- boss characters keep extra attribute sets in an array; the main one may not hold the HP pool
local function hpFromAuxSets(actor)
    local arr = nil
    pcall(function() arr = actor.AuxiliaryAttributeSets end)
    if not valid(arr) then return nil end
    local n = -1
    pcall(function() n = arr:GetArrayNum() end)
    for i = 1, math.min(n, 6) do
        local set = nil
        pcall(function() set = arr[i] end)
        local c, m = hpFromAttributeSetObject(set)
        if c ~= nil and m ~= nil then return c, m end
    end
    return nil
end

-- some boss groups share one health pool instead of using the actor's attribute set
local poolCache, poolCacheAt = nil, -10
local function pools()
    if poolCache == nil or (os.clock() - poolCacheAt) > 2 then
        pcall(function() poolCache = FindAllOf("PBZSharedHealthPool") end)
        poolCacheAt = os.clock()
    end
    return poolCache
end

local function hpFromSharedPool(actor)
    local cls = nil
    pcall(function() cls = actor:GetClass() end)
    if not valid(cls) then return nil end
    local addr = nil
    pcall(function() addr = tostring(cls:GetAddress()) end)
    if addr == nil then return nil end
    local list = pools()
    if list == nil then return nil end
    for i = 1, #list do
        local pool = list[i]
        if valid(pool) then
            local init = false
            pcall(function() init = pool:IsPoolInitialized() end)
            if init then
                local anchor = nil
                pcall(function() anchor = pool.AnchorClass end)
                local aaddr = nil
                if valid(anchor) then pcall(function() aaddr = tostring(anchor:GetAddress()) end) end
                if aaddr ~= nil and aaddr == addr then
                    local cur, max = nil, nil
                    pcall(function() cur = pool:GetPoolHealth() end)
                    pcall(function() max = pool:GetPoolMaxHealth() end)
                    if type(cur) == "number" and type(max) == "number" and max > 0 then
                        return cur, max
                    end
                end
            end
        end
    end
    return nil
end

local function hpRaw(actor)
    local r = getRefs()
    if not valid(actor) then return -1, -1, "no-actor" end

    -- path 0: AttributeSetBase direct read (verified working for both player and bosses)
    local c0, m0 = hpFromAttributeSet(actor)
    if c0 ~= nil and m0 ~= nil then
        return c0, m0, "attrset"
    end

    -- path 0.5: auxiliary attribute sets (bosses)
    local c05, m05 = hpFromAuxSets(actor)
    if c05 ~= nil and m05 ~= nil then
        return c05, m05, "auxset"
    end

    -- path 0.9: shared health pool (only some encounters use one)
    local cp, mp = hpFromSharedPool(actor)
    if cp ~= nil and mp ~= nil then
        return cp, mp, "boss-pool"
    end

    -- path A: attribute utils (used by PhantomBossRematch)
    local aCur, aMax = -1, -1
    if valid(r.attrUtils) and valid(r.bpLib) and valid(r.attrSet) then
        pcall(function()
            aCur = r.attrUtils:GetCharacterAttributeValue(actor, r.bpLib:MakeAttribute("Health", r.attrSet))
        end)
        pcall(function()
            aMax = r.attrUtils:GetCharacterAttributeValue(actor, r.bpLib:MakeAttribute("Health_Max", r.attrSet))
        end)
    end
    if type(aCur) == "number" and type(aMax) == "number" and aMax > 0 and aCur > 0 then
        return aCur, aMax, "attrutils"
    end

    -- path B: ASC + GetAttributeSet(Class) — both take only Actor/Class, no struct arguments
    if not valid(r.ascLib) then
        pcall(function()
            r.ascLib = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
        end)
    end
    if not r.setClass then
        pcall(function() r.setClass = StaticFindObject("/Script/CharacterBasics.BasicAttributeSet") end)
    end
    if valid(r.ascLib) and valid(r.setClass) then
        local asc = nil
        pcall(function() asc = r.ascLib:GetAbilitySystemComponent(actor) end)
        if valid(asc) then
            local set2 = nil
            pcall(function() set2 = asc:GetAttributeSet(r.setClass) end)
            if valid(set2) then
                local c, m = hpFromAttributeSetObject(set2)
                if c ~= nil and m ~= nil then return c, m, "asc-set" end
            end
        end
    end

    -- path C: the TensionMeter plugin's own telemetry component exposes GetHpRatio()
    if not r.telemetry then
        pcall(function()
            r.telemetry = FindAllOf("CombatTelemetryComponent")
        end)
    end
    if r.telemetry then
        local addr = nil
        pcall(function() addr = actor:GetAddress() end)
        for _, comp in pairs(r.telemetry) do
            if valid(comp) then
                local owner, oaddr = nil, nil
                pcall(function() owner = comp:GetOwner() end)
                if valid(owner) then pcall(function() oaddr = owner:GetAddress() end) end
                if addr ~= nil and oaddr ~= nil and addr == oaddr then
                    local ratio = nil
                    pcall(function() ratio = comp:GetHpRatio() end)
                    if type(ratio) == "number" and ratio >= 0 then
                        return ratio * 100, 100, "telemetry"
                    end
                end
            end
        end
    end

    -- path D: the Health tension-dimension caches the player's HP ratio
    local dimsArr = nil
    pcall(function() dimsArr = getProfileDims() end)
    if valid(dimsArr) then
        local hd = nil
        pcall(function() hd = dimsArr[5] end)
        if valid(hd) then
            local ratio = nil
            pcall(function() ratio = hd.CachedHpRatio end)
            if type(ratio) == "number" and ratio >= 0 and ratio <= 1.5 then
                return ratio * 100, 100, "health-dim"
            end
        end
    end

    return aCur, aMax, "fail"
end

local function hpPercent(actor)
    local cur, max = hpRaw(actor)
    if type(cur) ~= "number" or type(max) ~= "number" or max <= 0 then return -1 end
    -- one decimal: boss HP pools are six digits, integers would hide small damage
    return math.floor(cur / max * 1000 + 0.5) / 10
end

local hpDiagDone = false
local function hpDiag(pc, pawn)
    if hpDiagDone then return end
    hpDiagDone = true
    local r = getRefs()
    log("DIAG attrUtils=" .. nm(r.attrUtils))
    log("DIAG bpLib=" .. nm(r.bpLib))
    log("DIAG attrSet=" .. nm(r.attrSet))
    log("DIAG ascLib=" .. nm(r.ascLib))

    local list = { { "pawn", pawn } }
    local ps = nil
    pcall(function() ps = pc.PlayerState end)
    list[#list + 1] = { "playerstate", ps }
    list[#list + 1] = { "controller", pc }
    local char = nil
    pcall(function() char = pc.Character end)
    list[#list + 1] = { "pc.Character", char }

    for _, item in ipairs(list) do
        local tag, actor = item[1], item[2]
        if valid(actor) then
            local h, hm = nil, nil
            pcall(function()
                h = r.bpLib:MakeAttribute("Health", r.attrSet)
                hm = r.bpLib:MakeAttribute("Health_Max", r.attrSet)
            end)
            local v1, v2 = -1, -1
            pcall(function() v1 = r.attrUtils:GetCharacterAttributeValue(actor, h) end)
            pcall(function() v2 = r.attrUtils:GetCharacterAttributeValue(actor, hm) end)
            log(string.format("  %s/%s attrutils cur=%s max=%s", tag, shortName(actor), tostring(v1), tostring(v2)))

            local asc = nil
            pcall(function() asc = r.ascLib:GetAbilitySystemComponent(actor) end)
            if valid(asc) then
                local a1, a2 = -1, -1
                pcall(function() a1 = asc:GetNumericAttribute(h) end)
                pcall(function() a2 = asc:GetNumericAttribute(hm) end)
                log(string.format("  %s/%s asc cur=%s max=%s", tag, shortName(actor), tostring(a1), tostring(a2)))
            else
                log("  " .. tag .. "/" .. shortName(actor) .. " asc=nil")
            end
        else
            log("  " .. tag .. " invalid")
        end
    end
end

local function resolveBoss(actor)
    if not valid(actor) then return nil end
    local cur = actor
    for _ = 1, 8 do
        local n = shortName(cur)
        if n:find("AIController") or n:find("Controller") then
            local pawn = nil
            pcall(function() pawn = cur.Pawn end)
            if valid(pawn) then return pawn end
            pcall(function() pawn = cur.Character end)
            if valid(pawn) then return pawn end
        end
        local outer = nil
        pcall(function() outer = cur:GetOuter() end)
        if not valid(outer) then break end
        cur = outer
    end
    return actor
end

local bossActor = nil
local bossName = ""

-- Chinese boss names from the game's own localization
local BOSS_CN = {
    ["BP_Monster_AHua_GuiTouDao"] = "新娘阿花",
    ["BP_Monster_BiYuan"] = "天玄派：毕远掌门残躯",
    ["BP_Monster_CanQu_BiHai"] = "苦叶寺：碧海大师残躯",
    ["BP_Monster_ChangHong_P2"] = "长鸿：雷电枪骑",
    ["BP_Monster_ChangHong_Spear"] = "“雷枪”：长鸿",
    ["BP_Monster_ChiLian"] = "双蛇夫人：白赤练",
    ["BP_Monster_ChiLian_P2"] = "白赤练：献祭之蛇",
    ["BP_Monster_Danghui"] = "操偶师：荡秽",
    ["BP_Monster_DuYanBoss"] = "独眼弓客",
    ["BP_Monster_EMei_Sword_Top"] = "红衣女剑客",
    ["BP_Monster_FemaleVessel_YuDing"] = "十二号·偃月刀偶：“玉鼎”",
    ["BP_Monster_FemaleVessel_YuZan"] = "三号·乐师偶：“玉瓒”",
    ["BP_Monster_FengXueDaoKe"] = "风雪刀客",
    ["BP_Monster_GreatBladeMan"] = "横刀：毕峰",
    ["BP_Monster_GuiChai_Cyan_ShuangYue"] = "鬼差高手：断肠",
    ["BP_Monster_GuiChai_Red"] = "鬼差队长：火流星",
    ["BP_Monster_GuiChai_Red_P2"] = "火流星：磷火意识",
    ["BP_Monster_GuiChai_Yellow_MoDao"] = "鬼差高手：斩骑",
    ["BP_Monster_GuiChai_Yellow_ShuangGou"] = "鬼差高手：勾魂",
    ["BP_Monster_GuWanYue"] = "女妖骨婉约",
    ["BP_Monster_HookMan"] = "钩者：六绝钩镰",
    ["BP_Monster_HookMan_HorseCartCombat"] = "“组织”鬼差：钩者",
    ["BP_Monster_HookMan_P2"] = "钩者：六绝钩镰",
    ["BP_Monster_HuaQianXIao"] = "剑痴：花千笑",
    ["BP_Monster_HuaShan_Blue"] = "七星剑阵：大师兄",
    ["BP_Monster_HuaShan_JianOu"] = "大师兄的绝望剑意",
    ["BP_Monster_HuaShan_RedTroop_BigBro"] = "悲痛欲绝的阿瑾",
    ["BP_Monster_HuoDaoDuiZhang"] = "火刀：祝原",
    ["BP_Monster_JadeMaskMan"] = "玉面郎君",
    ["BP_Monster_JingYe"] = "亡命徒：荆野",
    ["BP_Monster_LeiDang"] = "“虎炮”：雷当",
    ["BP_Monster_LeiDang_P2"] = "雷当：独臂虎",
    ["BP_Monster_LengTu"] = "梦差：冷荼",
    ["BP_Monster_LionDancer"] = "被面具控制的舞狮尊主：烈焰",
    ["BP_Monster_LionDancer_P2"] = "舞狮尊主的最后一舞",
    ["BP_Monster_LuanShi"] = "拳痴：铁狂",
    ["BP_Monster_Maddoctor_Elite"] = "神医：谢秋冬",
    ["BP_Monster_MBoss"] = "昆仑叛教者：荒行子",
    ["BP_Monster_MBossVariants"] = "荒行子：撕裂锯轮",
    ["BP_Monster_MengHua"] = "救苦救难梦华娘娘",
    ["BP_Monster_MobMan_Elite"] = "癫狂暴徒：铁杀",
    ["BP_Monster_MobMan_Elite_Sword"] = "痴狂暴徒：残钢",
    ["BP_Monster_MoTian"] = "暗魔天堡之主：魔渊",
    ["BP_Monster_MoTian_LongZhu_01"] = "金面具黑衣人",
    ["BP_Monster_MoTian_LongZhu_02"] = "金面具黑衣人",
    ["BP_Monster_MoTian_LongZhu_03"] = "金面具黑衣人",
    ["BP_Monster_MoTian_LongZhu_04"] = "金面具黑衣人",
    ["BP_Monster_MuXiaoKui"] = "“组织”少主：沐小葵",
    ["BP_Monster_MuXiaoKui_P2"] = "沐小葵：铁玉女王",
    ["BP_Monster_PengMeng_Axe"] = "斧老大：彭猛",
    ["BP_Monster_PowerMan"] = "力者和锯者",
    ["BP_Monster_PowerMan_P2"] = "力者：石破天惊之态",
    ["BP_Monster_QiShu_Bing"] = "灭法之法：寒岁",
    ["BP_Monster_QiShu_Du"] = "灭法之法：蛊鹤",
    ["BP_Monster_QiShu_Huo"] = "灭法之法：炎茹",
    ["BP_Monster_QiShu_Lei"] = "灭法之法：雷婷",
    ["BP_Monster_Scavenger"] = "活人偶清道夫",
    ["BP_Monster_TieGui"] = "少主护卫：铁鬼",
    ["BP_Monster_WanJun_JinGua"] = "巨锤客：万钧",
    ["BP_Monster_WuLengShuang"] = "软剑：乌冷霜",
    ["BP_Monster_WuXuan"] = "堕落将军：武轩",
    ["BP_Monster_XiaoXue"] = "吞噬尸体的小雪",
    ["BP_Monster_YanQianSui"] = "琴女烟千岁",
    ["BP_Monster_YanYan_Club"] = "疯婆子奎艳艳",
    ["BP_Monster_YingMei_RedShadowBoneBlade"] = "赤影骨刃：囚锋",
    ["BP_Monster_YouLong_Harpoon"] = "发狂的水行帮主：游龙",
    ["BP_Monster_YouLong_SecondBrother"] = "水行帮主：游龙",
    ["BP_Monster_YuBi"] = "廿一号·剑偶：“玉璧”",
    ["BP_Monster_YuCong_Bing"] = "“玉琮”：寒冰",
    ["BP_Monster_YuCong_FirstTime"] = "三张脸的诡异魔偶",
    ["BP_Monster_YuCong_HunDun"] = "“玉琮”：混沌",
    ["BP_Monster_YuCong_P1"] = "卅四号·混沌魔偶：“玉琮”",
    ["BP_Monster_YuCong_WuLi"] = "“玉琮”：钢刃",
    ["BP_Monster_Yuu"] = "少主护卫：玉妖",
    ["BP_Monster_Zhuobi"] = "守门人拙壁",
    ["BP_Monster_ZuoShang"] = "“组织”冥主：左殇",
    ["BP_Monster_ZuoShang_Ending"] = "“组织”冥主：左殇",
    ["BP_Monster_ZuoShang_P2"] = "左殇：真龙之躯",
    ["BP_Monster_ZuoShang_Young_Tutorial"] = "少年左殇",
}
local bossNameFromHud
local cleanBossName

local function bossFromHudBar()
    local ch = nil
    pcall(function()
        for _, w in pairs(FindAllOf("WB_BossHPBar_C") or {}) do
            if valid(w) then
                local vis = true
                pcall(function() vis = w:IsVisible() end)
                if vis then
                    local c = nil
                    pcall(function() c = w.Character end)
                    if valid(c) then ch = c return end
                end
            end
        end
    end)
    return ch
end

-- the rematch mod can revive a boss without firing BeginBossEncounter again,
-- so the HP bar widget is the authoritative source for "which boss is on screen"
local function refreshBossFromBar()
    if valid(bossActor) then return end
    local b = bossFromHudBar()
    if valid(b) then
        bossActor = b
        local hudName = bossNameFromHud()
        bossName = (hudName and #hudName > 0) and hudName or cleanBossName(b)
        log("boss resolved from HP bar: " .. bossName)
    end
end

bossNameFromHud = function()
    local out = nil
    pcall(function()
        for _, w in pairs(FindAllOf("WB_BossHPBar_C") or {}) do
            if valid(w) then
                local vis = true
                pcall(function() vis = w:IsVisible() end)
                if vis then
                    local txt = nil
                    pcall(function() txt = w.BossName:GetSynchronizedText() end)
                    if txt == nil then pcall(function() txt = w.BossName:GetText() end) end
                    if txt ~= nil then
                        local s = nil
                        pcall(function() s = txt:ToString() end)
                        if type(s) == "string" and #s > 0 and s ~= "None" then
                            out = s
                            return
                        end
                    end
                end
            end
        end
    end)
    return out
end

cleanBossName = function(actor)
    local s = shortName(actor)
    s = s:gsub("_2147%d+$", "")
    local cls = s:gsub("_C$", "")
    if BOSS_CN[cls] then return BOSS_CN[cls] end
    local pretty = cls:gsub("^BP_Monster_", ""):gsub("_", " ")
    if pretty == "" or pretty:find("AIScript") then return "" end
    return pretty
end

local function subsystem()
    local r = getRefs()
    if valid(r.sub) then return r.sub end
    local ok, list = pcall(function() return FindAllOf("TensionWorldSubsystem") end)
    if ok and list then
        for _, s in pairs(list) do
            if valid(s) then r.sub = s return s end
        end
    end
    return nil
end

local tierNames = { "CALM", "STEADY", "NEUTRAL", "PRESSURED", "PANIC", "OVERWHELMED" }
local dimTags = {
    { tag = "Dim.Defense", cn = "防御", en = "DEF" },
    { tag = "Dim.Dodge", cn = "闪避", en = "DODGE" },
    { tag = "Dim.Offense", cn = "进攻", en = "OFF" },
    { tag = "Dim.Rhythm", cn = "节奏", en = "RHYTHM" },
    { tag = "Dim.Health", cn = "血量", en = "HP" },
    { tag = "Dim.Posture", cn = "架势", en = "POSTURE" },
}

local profileAsset = nil
local dimSourceLogged = false
local dimProbed = false
local evDumped = false

local function getProfileDims()
    if profileAsset == nil then
        local ok = pcall(function()
            profileAsset = StaticFindObject("/Game/TensionMeter/DA_TensionProfile_Default.DA_TensionProfile_Default") or false
        end)
        if not ok then profileAsset = false end
    end
    if not valid(profileAsset) then return nil end
    local arr = nil
    pcall(function() arr = profileAsset.Dimensions end)
    if not valid(arr) then return nil end
    return arr
end

local TAG_CN = {
    ["Defense.PerfectDeflect"] = "精防",
    ["Defense.PerfectDeflect.PowerAttack"] = "精防重击",
    ["Defense.NormalBlock"] = "普通防御",
    ["Defense.GuardBreak"] = "破防",
    ["Defense.HitWhileBlocking"] = "防中受击",
    ["Defense.NoResponseHit"] = "未防受击",
    ["Defense.Grabbed"] = "被抓",
    ["Defense.RedEyeHit"] = "红眼受击",
    ["Dodge.PerfectDodge"] = "完美闪避",
    ["Dodge.DodgeSuccess"] = "闪避成功",
    ["Dodge.GrazeDodge"] = "擦身闪避",
    ["Offense.HitLanded"] = "命中",
    ["Offense.WhiffedAttack"] = "攻击落空",
    ["Offense.GreedyHit"] = "贪刀",
    ["Offense.BreakCaused"] = "打出破防",
    ["Offense.HeavyHit"] = "重击",
    ["Offense.WeaponSwitchHit"] = "换武命中",
    ["Offense.BreakWindowHit"] = "破防窗口",
    ["Session.PlayerKilled"] = "阵亡",
    ["Session.BossKilled"] = "击杀",
    ["Hidden.Whiffed"] = "落空(隐)",
    ["Defense.GuardBreak.Normal"] = "破防",
    ["Defense.GuardBreak.Executed"] = "破防处决",
    ["Defense.RedEyeHit"] = "红眼受击",
    ["Dodge.PerfectDodge.Forced"] = "强制完美闪避",
    ["Dodge.PerfectDodge.Optional"] = "完美闪避(选)",
    ["Hidden.PreemptiveBlock"] = "预判防御",
    ["Offense.ExecutedBoss"] = "处决 Boss",
    ["Player.Mistake.AbilityNoResource"] = "技能无资源",
    ["Player.Mistake.HealNoConsumable"] = "无药可回",
}

-- known base weights, used when the engine struct does not expose them
local BASE_WEIGHT = {
    ["Defense.PerfectDeflect"] = -12,
    ["Defense.PerfectDeflect.PowerAttack"] = 5,
    ["Defense.NormalBlock"] = 2,
    ["Defense.GuardBreak"] = 40,
    ["Defense.HitWhileBlocking"] = 20,
    ["Defense.NoResponseHit"] = 30,
    ["Defense.Grabbed"] = 45,
    ["Dodge.PerfectDodge"] = -8,
    ["Dodge.DodgeSuccess"] = -5,
    ["Dodge.GrazeDodge"] = 5,
    ["Offense.HitLanded"] = -1,
    ["Offense.WhiffedAttack"] = 3,
    ["Offense.GreedyHit"] = 10,
    ["Offense.BreakCaused"] = -10,
    ["Offense.HeavyHit"] = -15,
    ["Offense.WeaponSwitchHit"] = -15,
    ["Offense.BreakWindowHit"] = -8,
    ["Session.PlayerKilled"] = 50,
    ["Session.BossKilled"] = -30,
    ["Hidden.Whiffed"] = -5,
}

local function unwrapNum(v)
    if type(v) == "number" then return v end
    local ok, g = pcall(function() return v:get() end)
    if ok and type(g) == "number" then return g end
    return nil
end

local function tagLabel(full)
    local s = tostring(full)
    local short = s:gsub("^Outcome%.", "")
    return TAG_CN[short] or short
end

-- only dimensions that actually carry data are shown (Health/Posture/Resource have none)
local DIM_FIELD = { "RawSum", "RawSum", "RawSum", "RawSum" }
local DIM_LABEL = { "防御", "闪避", "进攻", "节奏" }

-- 20 base weights, paginated in the panel (F9)
local WEIGHT_ROWS = {
    { "精防", -12 }, { "普通防御", 2 }, { "破防", 40 }, { "被抓", 45 },
    { "未防受击", 30 }, { "防中受击", 20 }, { "精防重击", 5 }, { "完美闪避", -8 },
    { "闪避成功", -5 }, { "擦身闪避", 5 }, { "命中", -1 }, { "攻击落空", 3 },
    { "贪刀", 10 }, { "打出破防", -10 }, { "重击", -15 }, { "换武命中", -15 },
    { "破防窗口", -8 }, { "阵亡", 50 }, { "击杀", -30 }, { "落空(隐)", -5 },
}
local PAGE_SIZE = 6
local WEIGHT_PAGES = math.ceil(#WEIGHT_ROWS / PAGE_SIZE)

local function readDimsFromProfile()
    local out = {}
    local arr = getProfileDims()
    if not arr then return out end
    local n = -1
    pcall(function() n = arr:GetArrayNum() end)
    for i = 0, math.min(n - 1, #DIM_LABEL - 1) do
        local field = DIM_FIELD[i + 1]
        local v = 0
        local avail = field ~= nil
        if field ~= nil then
            pcall(function()
                local d = arr[i + 1]
                if valid(d) then
                    local val = d[field]
                    if type(val) == "number" then v = val end
                end
            end)
        end
        out[#out + 1] = { tag = i, cn = DIM_LABEL[i + 1], value = v, avail = avail }
    end
    return out
end

local function getSession(sub)
    local sess = nil
    pcall(function()
        local sessions = sub.SessionsByBoss
        if sessions == nil then return end
        local ref = sessions:Find(bossActor)
        if ref == nil then return end
        sess = ref:get()
    end)
    return sess
end

local function readRecentEvents(sess, cap)
    local out = {}
    if sess == nil then return out end
    local bs = nil
    pcall(function() bs = sess.BossState end)
    if bs == nil then return out end
    local arr = nil
    pcall(function() arr = bs.RecentEvents end)
    if arr == nil then return out end
    local n = -1
    pcall(function() n = arr:GetArrayNum() end)
    if n <= 0 then return out end
    local start = math.max(1, n - cap + 1)
    for i = start, n do
        local e = nil
        pcall(function() e = arr[i] end)
        if e ~= nil then
            local tag, base, final = "", 0, 0
            pcall(function() tag = e.OutcomeTag.TagName:ToString() end)
            pcall(function() base = unwrapNum(e.BaseWeight) or 0 end)
            pcall(function() final = unwrapNum(e.FinalWeight) or 0 end)

            local key = tostring(tag):gsub("^Outcome%.", "")
            if base == 0 then base = BASE_WEIGHT[key] or 0 end
            if final == 0 then final = base end
            local t = 0
            pcall(function() t = unwrapNum(e.Time) or 0 end)
            if final ~= 0 or base ~= 0 then
                out[#out + 1] = { name = tagLabel(tag), value = final, base = base, key = key, t = t }
            end

            if not evDumped then
                evDumped = true
                pcall(function()
                    e:ForEachProperty(function(pp)
                        local pn = "?"
                        pcall(function() pn = pp:GetFName():ToString() end)
                        local v = "?"
                        pcall(function()
                            local val = e[pn]
                            if type(val) == "number" then
                                v = string.format("%.4f", val)
                            elseif val == nil then
                                v = "nil"
                            else
                                local oks, s = pcall(function() return val:ToString() end)
                                if oks and type(s) == "string" then v = s else v = tostring(val) end
                            end
                        end)
                        log("  ev field " .. pn .. " = " .. v)
                    end)
                end)
            end
        end
    end
    return out
end

-- which dimension each outcome belongs to (from DA_TensionProfile_Default subscriptions)
local TAG_DIM = {}
local function fillTagDim(dimIndex, keys)
    for _, k in ipairs(keys) do TAG_DIM[k] = dimIndex end
end
fillTagDim(1, { "Defense.PerfectDeflect", "Defense.NormalBlock", "Defense.GuardBreak",
    "Defense.HitWhileBlocking", "Defense.NoResponseHit", "Defense.Grabbed", "Hidden.Whiffed",
    "Offense.GreedyHit", "Offense.WhiffedAttack", "Defense.PerfectDeflect.PowerAttack" })
fillTagDim(2, { "Dodge.PerfectDodge", "Dodge.DodgeSuccess", "Dodge.GrazeDodge" })
fillTagDim(3, { "Offense.HitLanded", "Offense.BreakCaused" })

local function dimsFromEvents(list, window)
    local acc = { 0, 0, 0, 0, 0, 0, 0 }
    local n = 0
    for _, e in ipairs(list) do
        local idx = TAG_DIM[e.key or ""]
        if idx then
            acc[idx] = acc[idx] + (e.base or 0)
            n = n + 1
        end
    end
    -- normalise to a comparable magnitude (average weight per recent event)
    local div = math.max(1, math.min(window or 8, n))
    for i = 1, 7 do acc[i] = acc[i] / div end
    return acc
end

local function readDimsFromSession(sess)
    local out = {}
    local arr = nil
    if sess ~= nil then
        local prof = nil
        pcall(function() prof = sess.Profile end)
        if valid(prof) then pcall(function() arr = prof.Dimensions end) end
    end
    if not valid(arr) then arr = getProfileDims() end
    if not valid(arr) then return out end
    local n = -1
    pcall(function() n = arr:GetArrayNum() end)
    for i = 0, math.min(n - 1, #DIM_LABEL - 1) do
        local field = DIM_FIELD[i + 1]
        local v = 0
        local avail = field ~= nil
        if field ~= nil then
            pcall(function()
                local d = arr[i + 1]
                if valid(d) then
                    local val = d[field]
                    if type(val) == "number" then v = val end
                end
            end)
        end
        out[#out + 1] = { tag = i, cn = DIM_LABEL[i + 1], value = v, avail = avail }
    end
    return out
end

local function readDims(readout)
    local out = {}
    local arr = getProfileDims()
    local i = 0
    for _, d in ipairs(dimTags) do
        i = i + 1
        local v, src = 0, "none"

        -- 1) readout map, key wrapped as FGameplayTag
        pcall(function()
            local ref = readout.DimScores:Find({ TagName = FName(d.tag) })
            if ref ~= nil then
                local g = ref:get()
                if type(g) == "number" then v, src = g, "map-tag" end
            end
        end)

        -- 2) readout map, key as bare FName
        if src == "none" then
            pcall(function()
                local ref = readout.DimScores:Find(FName(d.tag))
                if ref ~= nil then
                    local g = ref:get()
                    if type(g) == "number" then v, src = g, "map-name" end
                end
            end)
        end

        -- 3) profile dimension object RawSum
        if src == "none" and arr then
            pcall(function()
                local dimObj = arr[i]
                if valid(dimObj) then
                    local rs = dimObj.RawSum
                    if type(rs) == "number" then v, src = rs, "rawsum" end
                end
            end)
        end

        out[#out + 1] = { tag = d.tag, cn = d.cn, value = v, src = src }
    end

    if not dimSourceLogged then
        dimSourceLogged = true
        local parts = {}
        for _, d in ipairs(out) do parts[#parts + 1] = d.tag .. "=" .. tostring(d.value) .. "(" .. d.src .. ")" end
        log("dims: " .. table.concat(parts, ", "))
    end

    return out
end

-- ------------------------------------------------------------ event ticker
local events = {}
local evSeq = 0
local fightId = 0
local awaitingNewFight = false
local lastTopEvent = nil
local multProbeDone = false
local researchOn = false
local shachiVal, shachiDps = -1, 0
local shachiPrev, shachiPrevT = nil, nil
local lastSeenTier = -1
local researchTick = 0
local difficultyTag = '?'
local tierCallbackCount = 0
local prevDims = {}

local function pushEvent(name, value)
    local now = os.clock()
    if #events > 0 then
        local e = events[1]
        if e.name == name and (now - e.t) <= EVENT_MERGE then
            e.count = e.count + 1
            e.value = value
            e.t = now
            evSeq = evSeq + 1
            return
        end
    end
    table.insert(events, 1, { name = name, value = value, count = 1, t = now })
    evSeq = evSeq + 1
    while #events > 8 do table.remove(events) end
end

local function ageEvents()
    local now = os.clock()
    for i = #events, 1, -1 do
        if now - events[i].t > EVENT_TTL then table.remove(events, i) end
    end
end

local function inferEvents(dims)
    for i, d in ipairs(dims) do
        local prev = prevDims[d.tag]
        if prev ~= nil then
            local delta = d.value - prev
            if math.abs(delta) >= DIM_JUMP_MIN then
                pushEvent(d.cn, delta)
            end
        end
        prevDims[d.tag] = d.value
    end
    ageEvents()
end

-- -------------------------------------------------------------- ui toggles
local ui = { visible = false, preset = "standard", page = 1, pages = WEIGHT_PAGES }

local function toggleVisible() ui.visible = not ui.visible end
local function cyclePreset()
    if ui.preset == "full" then
        ui.preset = "standard"
    else
        ui.preset = "full"
    end
end
local function nextPage()
    ui.page = ui.page + 1
    if ui.page > WEIGHT_PAGES then ui.page = 1 end
end

local restartOverlay
local function bindKeys()
    pcall(function()
        RegisterKeyBind(Key.F7, function() toggleVisible() end)
        RegisterKeyBind(Key.F8, function() cyclePreset() end)
        RegisterKeyBind(Key.F9, function() nextPage() end)
        RegisterKeyBind(Key.F10, function() restartOverlay() end)
    end)
end

-- ------------------------------------------------------------------ state
local lastRaw, lastTime = nil, nil
local deltaSmooth = 0
local peak = 0
local trough = 0
local rawHist = {}
local peakHold = 0
local lastActiveAt = nil
local cached = nil
local hudNameTried, hudNameDone = false, false
local pendingEndAt = nil
local endedLogged = false

local function fmt(v, dec)
    return string.format("%." .. (dec or 1) .. "f", v)
end

local function writeState(session, readout, dims, php, bhp)
    local lines = {}
    local function add(k, v) lines[#lines + 1] = k .. "=" .. tostring(v) end
    add("ts", os.time())
    add("visible", ui.visible and 1 or 0)
    add("preset", ui.preset)
    add("page", ui.page)
    add("pages", WEIGHT_PAGES)
    add("evseq", evSeq)
    add("fight", fightId)
    add("shachi", string.format("%.3f", shachiVal))
    add("shachidps", string.format("%.2f", shachiDps))

    local first = (ui.page - 1) * PAGE_SIZE + 1
    local wparts = {}
    for i = first, math.min(first + PAGE_SIZE - 1, #WEIGHT_ROWS) do
        local row = WEIGHT_ROWS[i]
        wparts[#wparts + 1] = row[1] .. "|" .. row[2]
    end
    add("w", table.concat(wparts, ";"))

    if not session then
        add("boss", "")
        add("tier", 2)
        add("raw", "0.0")
        add("delta", "0.0")
        add("peak", "0.0")
        add("php", php or -1)
        add("bhp", -1)
        add("dim", "")
        add("ev", "")
    else
        add("boss", bossName ~= "" and bossName or "Boss")
        add("tier", readout and readout.tier or 2)
        add("raw", fmt(readout and readout.raw or 0))
        add("delta", fmt(deltaSmooth))
        add("peak", fmt(peak))
        add("php", php or -1)
        add("bhp", bhp or -1)
        local ds = {}
        for _, d in ipairs(dims) do
            if d.avail == false then
                ds[#ds + 1] = d.cn .. "|"
            else
                ds[#ds + 1] = d.cn .. "|" .. fmt(d.value)
            end
        end
        add("dim", table.concat(ds, ";"))
        local es = {}
        for _, e in ipairs(events) do
            es[#es + 1] = e.name .. "|" .. fmt(e.value) .. "|" .. e.count .. "|" .. string.format("%.0f", e.base or 0)
        end
        add("ev", table.concat(es, ";"))
    end

    add("eof", 1)
    local ok, f = pcall(io.open, STATE_PATH, "w")
    if ok and f then
        pcall(function() f:write(table.concat(lines, "\n")) f:close() end)
    end
end

-- ------------------------------------------------------------------- tick
local tickCount = 0
local sessionDumped = false

local function dumpSessionOnce()
    if sessionDumped then return end
    local ok, list = pcall(function() return FindAllOf("TensionSession") end)
    if not ok or not list then return end
    local n = 0
    for _, s in pairs(list) do
        if valid(s) then
            n = n + 1
            sessionDumped = true
            log("session found: " .. nm(s))
            pcall(function()
                local c = s:GetClass()
                c:ForEachProperty(function(p)
                    local tn, pn = "?", "?"
                    pcall(function() tn = p:GetClass():GetFName():ToString() end)
                    pcall(function() pn = p:GetFName():ToString() end)
                    log("  session prop: " .. tn .. " " .. pn)
                end)
            end)
        end
    end
    if n > 0 then log("session instances: " .. n) end
end

local function tick()
    tickCount = tickCount + 1
    if tickCount == 1 then startOverlay() end

    local pc = getPC()
    if tickCount % 40 == 0 then
        local pawn = pc and getPawn(pc) or nil
        local cur, max, err = hpRaw(pawn)
        local bcur, bmax, berr = hpRaw(bossActor)
        local sub0 = subsystem()
        local act0 = false
        if valid(sub0) then pcall(function() act0 = sub0:HasActiveSession() end) end
        log(string.format("hb pc=%s pawn=%s hp=%s/%s[%s] active=%s boss=%s bhp=%s/%s[%s]",
            pc and nm(pc) or "nil", pawn and nm(pawn) or "nil",
            tostring(cur), tostring(max), tostring(err), tostring(act0), bossName,
            tostring(bcur), tostring(bmax), tostring(berr)))
    end

    if not pc then
        pcall(writeState, nil, nil, {}, -1, -1)
        return
    end

    local sub = subsystem()
    local active = false
    if valid(sub) then pcall(function() active = sub:HasActiveSession() end) end
    if active and awaitingNewFight then
        awaitingNewFight = false
        fightId = fightId + 1
        log("new fight after revive: id=" .. fightId)
    end

    local pawn = getPawn(pc)
    if pawn and not hpDiagDone then hpDiag(pc, pawn) end

    -- an EndBossEncounter from the previous attempt can arrive right after the new Begin;
    -- debounce it so a retry does not wipe the fresh boss
    if pendingEndAt and (os.clock() - pendingEndAt) > 1.5 then
        pendingEndAt = nil
        bossActor, bossName = nil, ""
        hudNameTried, hudNameDone = false, false
        log("encounter end confirmed")
    end

    -- sessions flap between active/inactive; hold the last good snapshot for a few seconds
    if active then
        lastActiveAt = os.clock()
    end
    local withinGrace = lastActiveAt ~= nil and (os.clock() - lastActiveAt) < 3.0

    if not active then
        if withinGrace and cached then
            pcall(writeState, true, cached.readout, cached.dims or {}, cached.php, cached.bhp)
            return
        end
        if bossActor ~= nil and not endedLogged then
            endedLogged = true
            log("session ended")
        end
        if bossActor ~= nil then awaitingNewFight = true end
        bossActor, bossName = nil, ""
        lastRaw, deltaSmooth, peak = nil, 0, 0
        prevDims = {}
        events = {}
        cached = nil
        shachiVal, shachiDps, shachiPrev = -1, 0, nil
        lastActiveAt = nil
        hudNameTried, hudNameDone = false, false
        pcall(writeState, nil, nil, {}, hpPercent(getPawn(pc)), -1)
        return
    end

    endedLogged = false
    refreshBossFromBar()

    dumpSessionOnce()

    -- the game's own boss HP bar carries the localized boss name; prefer it once it appears
    if not hudNameTried and bossName ~= "" and not bossName:find("[\228-\233]") then
        hudNameTried = true
    end
    if hudNameTried and not hudNameDone then
        local hudName = bossNameFromHud()
        if hudName and #hudName > 0 then
            bossName = hudName
            hudNameDone = true
            log("boss name from HUD: " .. hudName)
        end
    end

    local readout = nil
    pcall(function() readout = sub:GetReadout(bossActor) end)
    local readoutAny = nil
    pcall(function() readoutAny = sub:GetReadout(nil) end)

    if not dimProbed then
        dimProbed = true
        local function probe(tag, r)
            if r == nil then log("probe " .. tag .. ": nil") return end
            local raw, tier = "?", "?"
            pcall(function() raw = r.Raw end)
            pcall(function() tier = r.Tier end)
            log(string.format("probe %s: raw=%s tier=%s", tag, tostring(raw), tostring(tier)))
        end
        probe("boss", readout)
        probe("nil", readoutAny)

        -- FTensionSession lives inside TMap<SessionsByBoss> as a struct value
        pcall(function()
            local sessions = sub.SessionsByBoss
            if sessions == nil then log("sessions map nil") return end
            local ref = nil
            local ok = pcall(function() ref = sessions:Find(bossActor) end)
            if not ok or ref == nil then log("session: no ref") return end
            local sess = nil
            pcall(function() sess = ref:get() end)
            if sess == nil then log("session: nil") return end
            log("session struct: " .. nm(sess))

            local prof = nil
            pcall(function() prof = sess.Profile end)
            log("session profile: " .. nm(prof))

            local dimsArr = nil
            if valid(prof) then pcall(function() dimsArr = prof.Dimensions end) end
            if valid(dimsArr) then
                local n = -1
                pcall(function() n = dimsArr:GetArrayNum() end)
                log("profile dims count: " .. tostring(n))
                for i = 1, math.min(n, 8) do
                    local d = nil
                    pcall(function() d = dimsArr[i] end)
                    if valid(d) then
                        local props = {}
                        pcall(function()
                            d:GetClass():ForEachProperty(function(pp)
                                local pn = pp:GetFName():ToString()
                                local v = nil
                                pcall(function()
                                    local val = d[pn]
                                    if type(val) == "number" then v = string.format("%.3f", val) end
                                end)
                                if v ~= nil then props[#props + 1] = pn .. "=" .. v end
                            end)
                        end)
                        log(string.format("  dim[%d] %s: %s", i - 1, shortName(d), table.concat(props, ", ")))
                    end
                end
            end

            local bs = nil
            pcall(function() bs = sess.BossState end)
            if bs ~= nil then
                log("BossState: " .. nm(bs))
                pcall(function()
                    bs:ForEachProperty(function(pp)
                        local pn = "?"
                        pcall(function() pn = pp:GetFName():ToString() end)
                        local v = "?"
                        pcall(function()
                            local val = bs[pn]
                            if type(val) == "number" then
                                v = string.format("%.3f", val)
                            elseif val == nil then
                                v = "nil"
                            else
                                local oks, s = pcall(function() return val:ToString() end)
                                if oks and type(s) == "string" then v = s else v = tostring(val) end
                            end
                        end)
                        log(string.format("  bs field %s = %s", pn, v))
                    end)
                end)
            end
        end)
    end

    if readout == nil then
        readout = readoutAny
    end
    if readout == nil then
        if cached then
            pcall(writeState, true, cached.readout, cached.dims or {}, cached.php, cached.bhp)
        else
            pcall(writeState, nil, nil, {}, hpPercent(getPawn(pc)), -1)
        end
        return
    end

    local raw, tier = 0, 2
    pcall(function() raw = readout.Raw end)
    pcall(function() tier = readout.Tier end)
    if type(tier) ~= "number" then tier = 2 end
    tier = math.max(0, math.min(5, tier))

    local sess = getSession(sub)
    local dims = readDimsFromSession(sess)
    local rawEvents = readRecentEvents(sess, 8)

    -- monotonic counter: the overlay animates the ticker when this changes
    do
        local top = ""
        if rawEvents and #rawEvents > 0 then
            local e = rawEvents[#rawEvents]
            -- semantic identity: label + event timestamp (tostring(e.OutcomeTag) is an address, unusable)
            top = tostring(e.name) .. "|" .. string.format("%.4f", tonumber(e.t) or 0)
        end
        if top ~= lastTopEvent then
            lastTopEvent = top
            evSeq = evSeq + 1
        end
    end

    -- continuous research probe: CSV for the AI-vs-score correlation experiment
    if researchOn then
        researchTick = researchTick + 1
        if researchTick % 2 == 0 then
            local bs = nil
            pcall(function() bs = sess.BossState end)
            local lastAct, lastBossBreak, lastPlayerBreak, curTension = -1, -1, -1, -1
            if bs ~= nil then
                pcall(function() lastAct = bs.LastBossActionTime end)
                pcall(function() lastBossBreak = bs.LastBossBrokenTime end)
                pcall(function() lastPlayerBreak = bs.LastPlayerBrokenTime end)
                pcall(function() curTension = bs.CurrentTension end)
            end
            local shachi = nil
            pcall(function()
                if valid(pc) then
                    local tel = nil
                    pcall(function() tel = pc.CombatTelemetry end)
                    if valid(tel) then pcall(function() shachi = tel:GetShachiRatio() end) end
                end
            end)
            local tierNow = 0
            pcall(function() tierNow = readout.Tier end)
            log(string.format("CSV %.2f|%d|%.1f|%s|%s|%s|%s|%s",
                os.clock(), tierNow, raw or 0,
                tostring(shachi), tostring(lastAct), tostring(lastBossBreak),
                tostring(lastPlayerBreak), tostring(curTension)))
        end
    end
    -- fallback: derive per-dimension contribution from the recent event stream
    local anyDim = false
    for _, d in ipairs(dims) do
        if math.abs(d.value) > 0.01 then anyDim = true end
    end
    if not anyDim and #rawEvents > 0 then
        local acc = dimsFromEvents(rawEvents, 10)
        for i, d in ipairs(dims) do
            if acc[i] ~= nil then d.value = acc[i] end
        end
    end

    if tickCount % 20 == 0 then
        local parts = {}
        for _, d in ipairs(dims) do parts[#parts + 1] = d.cn .. "=" .. string.format("%.1f", d.value) end
        log("dimvals: " .. table.concat(parts, " ") .. " events=" .. #rawEvents)
    end
    events = {}
    for i = #rawEvents, 1, -1 do
        local e = rawEvents[i]
        local merged = false
        for _, ex in ipairs(events) do
            if ex.name == e.name then
                ex.count = ex.count + 1
                ex.value = e.value
                merged = true
                break
            end
        end
        if not merged then
            events[#events + 1] = { name = e.name, value = e.value, base = e.base or 0, count = 1 }
        end
        if #events >= 6 then break end
    end

    local now = os.clock()
    -- 1-second windowed delta: raw is very jumpy, instantaneous rate is useless
    rawHist[#rawHist + 1] = { t = now, raw = raw }
    while #rawHist > 0 and (now - rawHist[1].t) > 2.0 do table.remove(rawHist, 1) end
    if #rawHist >= 2 then
        local ref = rawHist[1]
        for i = #rawHist, 1, -1 do
            if (now - rawHist[i].t) >= 1.0 then ref = rawHist[i] break end
        end
        local dt = now - ref.t
        if dt > 0.05 then
            local d = (raw - ref.raw) / dt
            if d > 99 then d = 99 elseif d < -99 then d = -99 end
            deltaSmooth = deltaSmooth * 0.5 + d * 0.5
        end
    end
    if lastRaw == nil then
        peak = raw
        trough = raw
    end
    lastRaw, lastTime = raw, now

    if raw > peak then peak = raw end
    if raw < trough then trough = raw end

    local bhp = -1
    if valid(bossActor) then bhp = hpPercent(bossActor) end

    -- boss/player 杀气 gauge straight from the game's own combat telemetry
    pcall(function()
        local tel = nil
        if valid(pc) then pcall(function() tel = pc.CombatTelemetry end) end
        if valid(tel) then
            local r = nil
            pcall(function() r = tel:GetShachiRatio() end)
            if type(r) == "number" then
                local now = os.clock()
                if shachiPrev ~= nil and (now - shachiPrevT) > 0.15 then
                    shachiDps = shachiDps * 0.6 + ((r - shachiPrev) / (now - shachiPrevT)) * 0.4
                end
                shachiPrev, shachiPrevT = r, now
                shachiVal = r
            end
        else
            shachiVal = -1
        end
    end)
    local php = hpPercent(getPawn(pc))

    cached = {
        readout = { raw = raw, tier = tier },
        dims = dims,
        php = php,
        bhp = bhp,
    }

    pcall(writeState, true, { raw = raw, tier = tier }, dims, php, bhp)
end

-- ------------------------------------------------------------------ hooks
local function installHooks()
    pcall(function()
        RegisterHook("/Script/TensionMeter.TensionLibrary:BeginBossEncounter", function(_, b)
            local boss = b
            pcall(function() boss = b:get() end)
            if valid(boss) then
                local real = resolveBoss(boss)
                bossActor = real
                bossName = cleanBossName(real)
                pendingEndAt = nil
                log("encounter begin: raw=" .. shortName(boss) .. " resolved=" .. nm(real) .. " name=" .. bossName)
                events = {}
                prevDims = {}
                deltaSmooth = 0
                lastRaw = nil
                rawHist = {}
                peak = 0
                trough = 0
                dimProbed = false
                dimSourceLogged = false
                awaitingNewFight = false
                fightId = fightId + 1
                evSeq = evSeq + 1
                lastTopEvent = nil
                shachiPrev, shachiPrevT = nil, nil
                shachiDps = 0
                hudNameTried, hudNameDone = false, false
                cached = nil
                trough = 0
            end
        end)
    end)
    pcall(function()
        RegisterHook("/Script/TensionMeter.TensionLibrary:EndBossEncounter", function()
            pendingEndAt = os.clock()
        end)
    end)
end

-- ------------------------------------------------------------------- boot
initPaths()
log("PBZTensionHUD v" .. MOD_VERSION .. " loaded " .. os.date("%H:%M:%S"))
startOverlay()
installHooks()
bindKeys()

-- manual overlay restart only: no background polling, no console windows

restartOverlay = function()
    local rel = findOverlay()
    if not rel then log("manual relaunch: exe not found") return end
    local abs = rel
    pcall(function()
        local h = io.popen("cd")
        if h then abs = h:read("*l") .. "\\" .. rel h:close() end
    end)
    local cmd = string.format('start "" "%s" "%s"', abs, STATE_PATH)
    log("manual overlay relaunch: " .. cmd)
    pcall(function() os.execute(cmd) end)
end
LoopAsync(REFRESH_MS, function()
    local ok, err = pcall(tick)
    if not ok then log("tick error: " .. tostring(err)) end
    return false
end)

log("main loop started")