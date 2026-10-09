-- Reine Logik der Git-Extension, ohne Host-Aufrufe, damit providers_test.lua sie allein prüfen kann.
-- Jede List-Funktion liefert Einträge { provider, slug, url }, die sich zu einem Cache aneinanderhängen lassen.

local M = {}

-- Repo-Name aus einem slug ("owner/name") oder einer git-URL, ohne .git.
function M.repoName(s)
  local name = tostring(s):match("([^/]+)/?%s*$") or tostring(s)
  return (name:gsub("%.git$", ""))
end

-- GitHub /user/repos oder /orgs/<org>/repos (dekodiert) -> { provider="github", slug, url }.
function M.githubRepos(list)
  local out = {}
  for _, r in ipairs(list or {}) do
    if type(r) == "table" and r.full_name and r.clone_url then
      out[#out + 1] = { provider = "github", slug = r.full_name, url = r.clone_url }
    end
  end
  return out
end

-- Bitbucket /2.0/repositories/<workspace> (dekodiert, Feld values) -> { provider="bitbucket", slug, url }.
-- https-Klon-URL aus links.clone, dem Array mit name = "https" | "ssh".
function M.bitbucketRepos(body)
  local out = {}
  for _, r in ipairs(body and body.values or {}) do
    local href
    for _, c in ipairs(r.links and r.links.clone or {}) do
      if c.name == "https" then href = c.href end
    end
    if r.full_name and href then out[#out + 1] = { provider = "bitbucket", slug = r.full_name, url = href } end
  end
  return out
end

-- Mehrzeilige URL-Liste -> { provider="vault", slug, url }. Leerzeilen und #-Kommentare raus.
function M.parseUrls(text)
  local out = {}
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    local url = line:match("^%s*(.-)%s*$")
    if url ~= "" and not url:match("^#") then
      out[#out + 1] = { provider = "vault", slug = M.repoName(url), url = url }
    end
  end
  return out
end

function M.makeId(provider, slug) return provider .. ":" .. slug end

function M.splitId(id)
  return tostring(id):match("^([^:]+):(.+)$")
end

-- Cache ({provider,slug,url}) -> Einträge für kadrell.palette.set.
function M.items(cache)
  local out = {}
  for _, r in ipairs(cache or {}) do
    out[#out + 1] = { id = M.makeId(r.provider, r.slug), title = r.slug,
                      detail = r.provider .. " · clone", group = r.provider }
  end
  return out
end

-- Zielordner: <cloneRoot>/<repo-name>, mit ~ am Anfang auf home expandiert.
function M.cloneTarget(cloneRoot, home, slug)
  local root = tostring(cloneRoot):gsub("^~", tostring(home))
  return root .. "/" .. M.repoName(slug)
end

-- Klon-URL zu einer palette-id aus dem Cache.
function M.cloneUrlFor(id, cache)
  for _, r in ipairs(cache or {}) do
    if M.makeId(r.provider, r.slug) == id then return r.url end
  end
end

return M
