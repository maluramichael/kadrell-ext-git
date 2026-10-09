-- kadrell-git: entfernte Repositories (GitHub, Bitbucket, eigene git-URLs) im Neue-Session-Dialog (⌘N).
-- Auswahl klont ins cloneRoot und öffnet dort eine Session. Docs: https://kadrell.malura.de/extensions
-- Host-Aufrufe (http, exec, run, secret, storage) laufen nur in Handlern.

local P = dofile((debug.getinfo(1, "S").source:match("^@(.*/)")) .. "providers.lua")

-- Sprache aus der Kadrell-Einstellung (de/en), Englisch als Rückfall.
local lang = (kadrell.locale or "en"):sub(1, 2)
local T = {
  en = { connectGithub = "Connect GitHub", refresh = "Refresh repos", connected = "connected",
         disconnected = "not connected", enterCode = "enter code ", cached = " repos cached, open Cmd-N to clone",
         cloning = "Cloning ", cloneFailed = "clone failed",
         needClientId = "Set the GitHub OAuth app client ID in the settings first." },
  de = { connectGithub = "Mit GitHub verbinden", refresh = "Repos aktualisieren", connected = "verbunden",
         disconnected = "nicht verbunden", enterCode = "Code eingeben ", cached = " Repos im Cache, Cmd+N zum Klonen",
         cloning = "Klone ", cloneFailed = "Klonen fehlgeschlagen",
         needClientId = "Erst die GitHub-OAuth-App-Client-ID in den Einstellungen setzen." },
}
local function tr(k) return (T[lang] or T.en)[k] or k end

local HOME = os.getenv("HOME") or ""
local cache = {}            -- { provider, slug, url }, Quelle für palette und Klon-URL
local ghState = "disconnected"  -- "connected" | "disconnected"
local ghCode = nil          -- user_code während des Device Flow
local lastError = nil

local function render()
  local label = ghCode and (tr("enterCode") .. ghCode) or tr(ghState)
  local children = {
    { type = "section", title = "GitHub", children = {
      { type = "text", text = "GitHub: " .. label, color = ghState == "connected" and "ok" or "warn" },
      { type = "button", label = tr("connectGithub"), action = "gh:connect" },
    } },
    { type = "text", text = #cache .. tr("cached"), color = "muted" },
    { type = "button", label = tr("refresh"), action = "refresh" },
  }
  if lastError then table.insert(children, 1, { type = "text", text = lastError, color = "err" }) end
  kadrell.panel.set{ title = "Repos", children = children }
end

local function lines(text)
  local out = {}
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    local v = line:match("^%s*(.-)%s*$")
    if v ~= "" then out[#out + 1] = v end
  end
  return out
end

-- GitHub: Token aus dem Schlüsselbund, deine Repos oder die der konfigurierten Orgs. shortcut: nur die ersten 100 je
-- Endpunkt, keine Paginierung; aufdrehen, sobald jemand mehr als 100 Repos hat.
local function listGithub()
  local token = kadrell.secret.get("github:token")
  if not token then return {} end
  ghState = "connected"
  local urls = {}
  local orgs = lines(kadrell.config.githubOrgs)
  if #orgs == 0 then
    urls[1] = "https://api.github.com/user/repos?per_page=100&sort=updated"
  else
    for _, o in ipairs(orgs) do urls[#urls + 1] = "https://api.github.com/orgs/" .. o .. "/repos?per_page=100" end
  end
  local out = {}
  for _, u in ipairs(urls) do
    local resp = kadrell.http{ url = u, headers = { Authorization = "Bearer " .. token,
      Accept = "application/vnd.github+json", ["User-Agent"] = "kadrell-git" } }
    if resp.status == 200 then
      for _, e in ipairs(P.githubRepos(kadrell.json.decode(resp.body))) do out[#out + 1] = e end
    else
      lastError = "GitHub: HTTP " .. tostring(resp.status)
    end
  end
  return out
end

-- Bitbucket Cloud: Bearer mit einem Access-Token (Workspace/Repository Access Token). shortcut: App-Passwörter
-- brauchen Basic user:pw mit Nutzernamen, hier bewusst nur Bearer; umstellen, falls ein App-Passwort nötig wird.
local function listBitbucket()
  local ws = kadrell.config.bitbucketWorkspace
  local token = kadrell.config.bitbucketToken
  if not ws or ws == "" or not token or token == "" then return {} end
  local resp = kadrell.http{ url = "https://api.bitbucket.org/2.0/repositories/" .. ws .. "?pagelen=100&role=member",
    headers = { Authorization = "Bearer " .. token, Accept = "application/json" } }
  if resp.status ~= 200 then
    lastError = "Bitbucket: HTTP " .. tostring(resp.status)
    return {}
  end
  return P.bitbucketRepos(kadrell.json.decode(resp.body))
end

local function refresh()
  lastError = nil
  local out = {}
  for _, e in ipairs(listGithub()) do out[#out + 1] = e end
  for _, e in ipairs(listBitbucket()) do out[#out + 1] = e end
  for _, e in ipairs(P.parseUrls(kadrell.config.vaultRepos)) do out[#out + 1] = e end
  cache = out
  kadrell.storage.set("repos", cache)
  kadrell.palette.set(P.items(cache))
  render()
end

-- GitHub OAuth Device Flow. Endpunkte laut docs.github.com (apps/oauth-apps authorizing-oauth-apps, Device Flow).
local function pollToken(clientId, deviceCode, interval)
  kadrell.after(interval, function()
    local resp = kadrell.http{ method = "POST", url = "https://github.com/login/oauth/access_token",
      headers = { Accept = "application/json" },
      body = "client_id=" .. clientId .. "&device_code=" .. deviceCode
        .. "&grant_type=urn:ietf:params:oauth:grant-type:device_code" }
    local d = resp.body and kadrell.json.decode(resp.body) or {}
    if d.access_token then
      kadrell.secret.set("github:token", d.access_token)
      ghState, ghCode = "connected", nil
      refresh()
    elseif d.error == "authorization_pending" then
      pollToken(clientId, deviceCode, interval)
    elseif d.error == "slow_down" then
      pollToken(clientId, deviceCode, interval + 5)
    else
      lastError = "GitHub: " .. tostring(d.error or resp.status)
      ghState, ghCode = "disconnected", nil
      render()
    end
  end)
end

local function connectGithub()
  local clientId = kadrell.config.githubClientId
  if not clientId or clientId == "" then
    lastError = tr("needClientId")
    return render()
  end
  local resp = kadrell.http{ method = "POST", url = "https://github.com/login/device/code",
    headers = { Accept = "application/json" }, body = "client_id=" .. clientId .. "&scope=repo" }
  local d = resp.body and kadrell.json.decode(resp.body) or {}
  if not d.device_code then
    lastError = "GitHub device code: HTTP " .. tostring(resp.status)
    return render()
  end
  ghCode = tostring(d.user_code)
  kadrell.exec({ "open", d.verification_uri })
  render()
  pollToken(clientId, d.device_code, tonumber(d.interval) or 5)
end

local function openExisting(target)
  return kadrell.exec({ "test", "-d", target }).status == 0
end

-- Auswahl eines ⌘N-Eintrags: Zielordner bestimmen, bei Bedarf klonen (kadrell.run new -c braucht einen
-- existierenden Ordner), dann Session im Zielordner öffnen.
kadrell.on("palette.select", function(d)
  local _, slug = P.splitId(d.id)
  local target = P.cloneTarget(kadrell.config.cloneRoot or "~/development/projects", HOME, slug or d.id)
  if openExisting(target) then
    kadrell.run("new", "-c", target)
    return
  end
  local url = P.cloneUrlFor(d.id, cache)
  if not url then
    lastError = "No clone URL for " .. tostring(d.id)
    return render()
  end
  kadrell.status.set{ text = tr("cloning") .. (slug or ""), color = "accent" }
  local r = kadrell.exec({ "git", "clone", url, target })
  if r.status == 0 then
    kadrell.status.clear()
    kadrell.run("new", "-c", target)
  else
    lastError = tr("cloneFailed") .. ": " .. tostring((r.stderr or ""):gsub("%s+$", ""))
    kadrell.status.set{ text = tr("cloneFailed"), color = "err" }
    render()
  end
end)

kadrell.on("ui.action", function(d)
  if d.id == "refresh" then refresh()
  elseif d.id == "gh:connect" then connectGithub()
  else kadrell.warn("unknown action: " .. tostring(d.id)) end
end)

kadrell.on("app.ready", function()
  cache = kadrell.storage.get("repos") or {}
  if kadrell.secret.get("github:token") then ghState = "connected" end
  kadrell.palette.set(P.items(cache))
  render()
  refresh()
end)

-- Regelmäßig aktualisieren, damit neue Repos von selbst in ⌘N auftauchen.
kadrell.every(600, refresh)
