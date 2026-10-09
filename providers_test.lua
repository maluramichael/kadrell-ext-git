-- Selbsttest der reinen Logik: luajit providers_test.lua (aus diesem Ordner oder mit vollem Pfad).
local dir = arg[0]:match("^(.*/)") or "./"
local P = dofile(dir .. "providers.lua")

-- repoName
assert(P.repoName("acme/web") == "web")
assert(P.repoName("git@vault:/x/foo.git") == "foo")
assert(P.repoName("https://host/bar") == "bar")

-- GitHub: nur vollständige Einträge
local gh = P.githubRepos({ { full_name = "acme/web", clone_url = "https://github.com/acme/web.git" }, { full_name = "x" } })
assert(#gh == 1 and gh[1].provider == "github" and gh[1].slug == "acme/web")
assert(gh[1].url == "https://github.com/acme/web.git")

-- Bitbucket: https-Klon-URL aus links.clone, ssh ignoriert
local bb = P.bitbucketRepos({ values = { { full_name = "team/api", links = { clone = {
  { name = "ssh", href = "git@bitbucket.org:team/api.git" },
  { name = "https", href = "https://bitbucket.org/team/api.git" } } } } } })
assert(#bb == 1 and bb[1].url == "https://bitbucket.org/team/api.git")

-- Vault: Leerzeilen und Kommentare raus
local v = P.parseUrls("git@vault:/x/foo.git\n\n# comment\n  https://host/bar  ")
assert(#v == 2 and v[1].slug == "foo" and v[2].slug == "bar")
assert(v[1].provider == "vault")

-- Cache -> items und id-Roundtrip
local cache = {}
for _, e in ipairs(gh) do cache[#cache + 1] = e end
for _, e in ipairs(v) do cache[#cache + 1] = e end
local items = P.items(cache)
assert(items[1].id == "github:acme/web" and items[1].group == "github" and items[1].detail == "github · clone")
local p, s = P.splitId("github:acme/web")
assert(p == "github" and s == "acme/web")

-- Zielordner und Klon-URL
assert(P.cloneTarget("~/dev", "/Users/m", "acme/web") == "/Users/m/dev/web")
assert(P.cloneTarget("/abs/root", "/Users/m", "foo.git") == "/abs/root/foo")
assert(P.cloneUrlFor("vault:foo", cache) == "git@vault:/x/foo.git")
assert(P.cloneUrlFor("github:acme/web", cache) == "https://github.com/acme/web.git")
assert(P.cloneUrlFor("nope:nope", cache) == nil)

print("providers_test ok")
