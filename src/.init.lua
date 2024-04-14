
local hostname = table.unpack(arg)

-- Restrict system calls
unix.pledge("stdio inet exec", "rpath")
-- Restrict file system access (starts with no access)
unix.unveil(0, 0) -- commit

--------------------------------------------------------------------------------

MAX_USERS = 10
USER_REMOVE_SEC = 22
MAX_STATUS_WAIT_SEC = 10

--------------------------------------------------------------------------------

-- Locking prevents race conditions.
-- The counter keeps track of "relevant" data modifications; it should only
-- change when the JSON output of /status changes.

LOCK_BYTES = 8 -- 64bit integer
COUNTER_BYTES = 8
DATA_BYTES = MAX_USERS * 200 -- arbitrary amount

-- Initialize shared memory (zeros); number of bits, must be multiple of 8
-- All read and write operations are atomic.
mem = unix.mapshared((LOCK_BYTES + COUNTER_BYTES + DATA_BYTES) * 8)

-- Int offsets (each 8 bytes)
LOCK = 0
COUNTER = 1
-- String offsets (bytes)
DATA = LOCK_BYTES + COUNTER_BYTES

-- From Futexes Are Tricky Version 1.1 § Mutex, Take 3;
-- Ulrich Drepper, Red Hat Incorporated, June 27, 2004.
function Lock()
  local ok, old = mem:cmpxchg(LOCK, 0, 1)
  if not ok then
    if old == 1 then
      old = mem:xchg(LOCK, 2)
    end
    while old > 0 do
      mem:wait(LOCK, 2)
      old = mem:xchg(LOCK, 2)
    end
  end
end
function Unlock()
  old = mem:fetch_add(LOCK, -1)
  if old == 2 then
    mem:store(LOCK, 0)
    mem:wake(LOCK, 1)
  end
end

function ReadData()
  return DecodeJson(mem:read(DATA))
end

-- Only use when locked!
function WriteData(obj, increaseCounter)
  local text = EncodeJson(obj)
  assert(#text < DATA_BYTES, "Too much data!")
  mem:write(DATA, text)
  if increaseCounter then
    mem:fetch_add(COUNTER, 1)
    mem:wake(COUNTER) -- wake all waiting processes
  end
end

function GetDataCounter()
  return mem:load(COUNTER)
end

function WaitForCounterChange(expected, timeoutSeconds)
  local seconds, nanos = unix.clock_gettime()
  mem:wait(COUNTER, expected, seconds + timeoutSeconds, nanos)
end

--------------------------------------------------------------------------------

local initialData = {
  result = nil,
  users = {},
}

-- Test data
if hostname == "localhost" then
  local currentTime = os.time()
  initialData.users = {
    aaaa = { id="aaaa", lastseen=currentTime+00, name="~~~Sir Foobar Baz~~~", card="6" },
    bbbb = { id="bbbb", lastseen=currentTime+10, name="Pen Guin", card=nil },
    cccc = { id="cccc", lastseen=currentTime+40, name="Max Mustermann", card=nil },
    dddd = { id="dddd", lastseen=currentTime+99, name="Maria", card="1" },
  }
end

-- Data: { result: string?, users: { string => { id: string, name: string, card: string?, lastseen: number } } }
WriteData(initialData, true)

-- Actions:
-- POST /register: user name
-- GET /status: users, selected cards, result
-- POST /choose: card
-- POST /reveal: reveals cards and shows result
-- POST /clear: clears selected cards and result

local function pairCount(tbl)
  local count = 0
  for _, _ in pairs(tbl) do
    count = count + 1
  end
  return count
end

local function FindUser(state, userid)
  return state.users[userid]
end

local function CreateUser(state, userid, username)
  if pairCount(state.users) == MAX_USERS then
    SetStatus(400)
    EncodeJson({error="Too many users"}, {useoutput=true})
    return false
  end
  state.users[userid] = {
    id = userid,
    name = username,
    card = nil,
    lastseen = os.time(),
  }
  return true
end

local function GetStatus(state)
  local status = {
    result = state.result,
    users = {[0]=false}, -- empty array [] for JSON encoder
  }
  local currentTime = os.time()
  for _, user in pairs(state.users) do
    if user.card == nil and (currentTime - user.lastseen) > USER_REMOVE_SEC then
      state.users[user.id] = nil
    else
      table.insert(status.users, {
        name = user.name,
        card = status.result and user.card
          or user.card and "",
      })
    end
  end
  return status
end

local function ChooseCard(state, userid, card)
  local user = FindUser(state, userid)
  if not user then
    SetStatus(403)
    return false
  end
  if state.result then
    Log(kLogWarn, "Warning: choose is not allowed when result is present.")
    return false
  end
  state.users[userid].card = card
  return true
end

local function RevealCards(state)
  local count = 0
  local sum = 0
  local questionCount = 0
  local hotBeverageCount = 0
  for _, user in pairs(state.users) do
    if user.card then
      if tostring(user.card):match("^%d+$") then
        count = count + 1
        sum = sum + tonumber(user.card)
      elseif user.card == "?" then
        questionCount = questionCount + 1
      elseif user.card == "☕" then
        hotBeverageCount = hotBeverageCount + 1
      end
    end
  end
  local result = nil
  if count > 0 then
    result = string.format("%g", -- remove trailing zeros
              string.format("%.2f", -- limit to 2 digits after .
                sum / count))
  elseif questionCount > 0 or hotBeverageCount > 0 then
    if questionCount > hotBeverageCount then
      result = "?"
    else
      result = "☕"
    end
  end
  state.result = result
  return true
end

local function ClearCards(state)
  for _, user in pairs(state.users) do
    user.card = nil
  end
  state.result = nil
  return true
end

--------------------------------------------------------------------------------

local function stringTrim(text)
  return text:match("^%s*(.-)%s*$")
end

local function toSet(list)
  local set = {}
  for _, e in ipairs(list) do
    set[e] = e
  end
  return set
end

-- `Lock`s and guarantees that `Unlock` is called after `fun` returns.
-- Writes back state, if `fun` returns a truthy value.
-- Increases the data counter if data is written and `increaseCounter` is true.
function WithWriteLock1(increaseCounter, fun, ...)
  Lock()
  local state = ReadData()
  local success, res = pcall(fun, state, ...)
  if success and res then
    success, res = pcall(WriteData, state, increaseCounter)
  end
  Unlock()
  if not success then
    error(res)
  end
end

function WithWriteLock(fun, ...)
  WithWriteLock1(true, fun, ...)
end

function WithReadLock(fun, ...)
  Lock()
  local state = ReadData()
  local success, res = pcall(fun, state, ...)
  Unlock()
  if not success then
    error(res)
  end
end

--------------------------------------------------------------------------------

-- Headers for all requests
ProgramBrand("Servus/23.2") -- "Server" Header
-- Cache nothing:
ProgramHeader("Cache-Control", "no-store, must-revalidate")
ProgramHeader("Expires", "0")

function TryToFindUser(state)
  local userid = GetCookie('userid')
  if userid then
    return FindUser(state, userid)
  end
end

function UpdateUserPresence(state)
  local user = TryToFindUser(state)
  if user then
    user.lastseen = os.time()
    return true
  end
end

function OutputStatusJson(state)
  local user = TryToFindUser(state)
  local status = GetStatus(state)
  if user then
    user.lastseen = os.time()
    status.username = user.name
  end
  status.counter = GetDataCounter()
  EncodeJson(status, {useoutput=true})
end

function SetUserIdCookie()
  local userid = GetCookie('userid')
  if not userid then
    userid = EncodeBase64(GetRandomBytes(20))
    SetCookie('userid', userid, {MaxAge=999888777, HttpOnly=true, SameSite="Strict"})
  end
end

function ServeApi(path)
  if path == "/status" then
    WithWriteLock1(false, UpdateUserPresence) -- never increases data counter
    local json = DecodeJson(GetBody())
    local lastCounter = json.lastCounter
    if not lastCounter or type(lastCounter) ~= "number" then
      EncodeJson({error="`lastCounter` missing or invalid"}, {useoutput=true})
      SetStatus(400)
    else
      WaitForCounterChange(lastCounter, MAX_STATUS_WAIT_SEC)
      WithReadLock(OutputStatusJson)
      SetUserIdCookie()
    end

  elseif path == "/register" then
    local userid = GetCookie("userid")
    if not userid then
      EncodeJson({error="Cookie missing"}, {useoutput=true})
      SetStatus(400)
    else
      local json = DecodeJson(GetBody())
      local username = stringTrim(json.username)
      if username == "" or username:len() > 20 then
        EncodeJson({error="Name missing or too long"}, {useoutput=true})
        SetStatus(400)
      else
        WithWriteLock(CreateUser, userid, username)
      end
    end

  elseif path == "/choose" then
    local json = DecodeJson(GetBody())
    local card = stringTrim(json.value)
    if not card or card == "" then
      EncodeJson({error="Card missing"}, {useoutput=true})
      SetStatus(400)
    else
      local userid = GetCookie('userid')
      WithWriteLock(ChooseCard, userid, card)
    end

  elseif path == "/reveal" then
    WithWriteLock(RevealCards)

  elseif path == "/clear" then
    WithWriteLock(ClearCards)

  else
    return false
  end
  return true
end

function RedirectHttp()
  local url = ParseUrl(GetUrl())
  if url.host ~= "localhost" and url.scheme ~= "https" then
    url.scheme = "https"
    SetStatus(301)
    SetHeader("Location", EncodeUrl(url))
    return true
  end
  return false
end

local skinPathMap = {
  original = {
    ["/"] = "original/index.html",
    ["/main.js"] = "original/main.js",
  },
  hyperapp = {
    ["/"] = "hyperapp/index.html",
    ["/main.mjs"] = "hyperapp/main.mjs",
    ["/hyperapp.js"] = "hyperapp/hyperapp-2.0.22.js",
  },
}

function ServeFrontend(path)
  if toSet({
    "/favicon.ico",
    "/main.css",
  })[path] then
    ServeAsset(path)
    return true
  end

  local param = GetParam("skin")
  if param then
    SetStatus("302")
    SetHeader("Location", "/planning-poker/")
    SetCookie("skin", param, {MaxAge=999888777, HttpOnly=true, SameSite="Strict"})
    return true
  end

  local skin = GetCookie("skin")
  if not skin or skin == "" then
    ServeAsset("frontend-switch.html")
    return true
  end

  local mapping = skinPathMap[skin]
  if not mapping then
    SetStatus("302")
    SetHeader("Location", "/planning-poker/")
    SetCookie("skin", "")
    return true
  end

  local destination = mapping[path]
  if destination then
    ServeAsset(destination)
    return true
  end

  return false
end

function OnHttpRequest()
  if RedirectHttp() then
    return
  end
  if hostname and GetHost() ~= hostname then
    SetStatus(401)
    return
  end

  local path = GetPath()
  if path == "/planning-poker" then
    SetStatus(301)
    SetHeader("Location", path .. "/")
    return
  end
  local match = path:match("^/planning%-poker(/.*)")
  if not match then
    SetStatus(401)
    return
  end
  path = match

  if ServeApi(path) then
  elseif ServeFrontend(path) then
  else
    SetStatus(404)
    Write("<h1>Not found</h1>")
  end
end
