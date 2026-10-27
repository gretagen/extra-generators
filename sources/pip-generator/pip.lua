local gen = {}
gen.name = "pip"

-- Declare system-level pip packages from definition.lua:
--
--   ["pip"] = {
--     "requests",
--     "requests==2.31.0",
--   },
--
-- Entries follow a tight pip requirement grammar — name or name==version —
-- so whatever `pip install` would accept as a pinned requirement can be
-- declared: a bare name installs whatever current version satisfies it, an
-- "==" pin locks the exact version. Ranges (>=, ~=, ...) are deliberately
-- not accepted: a declaration should mean one concrete thing a sync can
-- verify without re-implementing PEP 440 comparison rules.
--
-- Backed by pip inside a dedicated SHARED venv (/usr/var/pip/declared)
-- instead of the system site-packages that zeta's own python-* packages own
-- — mixing declarative pip entries into /usr/lib/python3.14/site-packages
-- would blur who owns which file, and a removal could never be safely
-- attributed. The venv is created on the first sync that needs it (plan
-- never mutates; the add's apply runs `python3 -m venv`). /etc/profile.d/
-- pip-haliade.sh (shipped by this package) puts the venv's bin directory on
-- every login shell, so root's sync makes the tools visible to all users.
-- This is the generator shipped by the pip-generator construct; it only
-- runs when "pip" is enabled in /etc/nacelle/enabled_modules.lua (see
-- `pip-generator --help`). The ["pip"] section's default + schema come from
-- the package's plugin config at /etc/nacelle/plugin-configs/pip.lua,
-- auto-loaded by config.lua.
--
-- Additions diff against `pip list --format=json` inside the venv, whose
-- rows are {"name": ..., "version": ...} objects. Names are compared
-- PEP 503 style (lowercased, runs of "."/"_" folded to "-"), so a declared
-- "pillow" is satisfied by an installed "Pillow". A declared spec counts as
-- installed when the name is present and, with an "==" pin, when the
-- version string is equal — a drifted pin is re-applied: `pip install
-- name==version` swaps the installed version in place.
--
-- Removals only ever touch specs THIS generator previously declared,
-- recorded in /var/db/declared-pip at apply time (mirroring guix) — a
-- package someone installed by hand into the venv is never yanked from
-- their declaration, and the record is only written when the install
-- actually ran, so a failed install is retried next sync. The removal
-- target is the bare name (pip uninstalls by name, not by requirement), and
-- the uninstall is skipped entirely when the package is already gone from
-- the venv — dropped from the record, not re-removed — as well as when a
-- desired spec still names it (an "==" upgrade is an in-place install, and
-- uninstalling there would rip out the version the add just pinned).

local DECLARED = "/var/db/declared-pip"

-- The shared venv declared packages install into. Root's system
-- site-packages belongs to zeta; THIS venv is exposed by
-- /etc/profile.d/pip-haliade.sh (this package).
local VENV = "/usr/var/pip/declared"
local PIP = VENV .. "/bin/pip"

-- Parse a package requirement, the grammar this generator accepts:
-- name or name==version. Refs are interpolated into shell commands, so only
-- word-ish characters are accepted (requests, requests==2.31.0,
-- ruamel.yaml.clib==0.2.8) — no spaces, quotes, $, backticks, ;|&<>/ and no
-- comparison operators other than "==", safe to embed unquoted. Returns
-- name, version (nil when unpinned), or nil when the spec is malformed.
local function parse_spec(spec)
  if type(spec) ~= "string" or spec == "" then return nil end
  local name, rest = spec:match("^([%w][%w%.%_%-]*)(.*)$")
  if not name then return nil end
  if rest == "" then return name end
  local v = rest:match("^==([%w][%w%.%+%_%~-]*)$")
  if not v then return nil end
  return name, v
end

-- PEP 503 name normalization: case-insensitive, runs of "."/"_" are "-".
local function norm(name)
  return (name:lower():gsub("[%.%_]+", "-"))
end

local function read_declared(sync)
  local set = {}
  local content = sync.read_file(DECLARED) or ""
  for line in (content .. "\n"):gmatch("([^\n]+)") do
    local spec = line:match("^%s*(.-)%s*$")
    if spec and spec ~= "" then set[spec] = true end
  end
  return set
end

-- Record a spec as ours / drop it again. Runs at apply time only.
local function declare(sync, spec)
  sync.shell("mkdir -p /var/db")
  return sync.shell("grep -qxF '" .. spec .. "' " .. DECLARED
    .. " 2>/dev/null || echo '" .. spec .. "' >> " .. DECLARED)
end

local function undeclare(sync, spec)
  return sync.shell("grep -vxF '" .. spec .. "' " .. DECLARED .. " > " .. DECLARED
    .. ".tmp 2>/dev/null; mv -f " .. DECLARED .. ".tmp " .. DECLARED)
end

function gen.plan(cfg, sync)
  local changes = {}
  local desired_list = cfg["pip"] or {}

  if #desired_list == 0 and next(read_declared(sync)) == nil then
    return {}
  end

  -- pip is installed as its own package; without it there is no backend to
  -- plan against, so stop here with one clear warning rather than failing
  -- every change at apply time.
  if sync.shell_output("command -v python3") == "" then
    if #desired_list > 0 then
      io.stderr:write("[warn] pip: python3 is not installed — install it via zeta -Provide python\n")
    end
    return {}
  end

  if sync.shell_output("command -v pip") == "" then
    if #desired_list > 0 then
      io.stderr:write("[warn] pip: pip is not installed — install it via zeta -Provide pip\n")
    end
    return {}
  end

  -- Validate and de-duplicate the desired specs, keeping declaration order.
  -- Two specs for the SAME package with different version pins would fight
  -- over one venv entry every sync, so the first wins and the rest are
  -- reported; a bare name alongside a pin is the same conflict in slow
  -- motion and is left to the same first-wins rule.
  local desired, desired_set, seen = {}, {}, {}
  local desired_names = {}
  local pinned = {}
  for _, spec in ipairs(desired_list) do
    local name, version = parse_spec(spec)
    if not name then
      io.stderr:write("[warn] pip: skipping invalid package specification '"
        .. tostring(spec) .. "' (expected e.g. \"requests\", \"requests==2.31.0\")\n")
    elseif not seen[spec] then
      if version and pinned[norm(name)] and pinned[norm(name)] ~= version then
        io.stderr:write("[warn] pip: '" .. spec .. "' conflicts with version pin '"
          .. name .. "==" .. pinned[norm(name)] .. "' — keeping the first\n")
      else
        seen[spec] = true
        if version then pinned[norm(name)] = version end
        desired[#desired + 1] = spec
        desired_set[spec] = true
        desired_names[norm(name)] = true
      end
    end
  end

  if #desired == 0 and next(read_declared(sync)) == nil then
    return {}
  end

  -- Installed distributions of the declared venv, from the one listing call
  -- (`pip list --format=json` prints [{"name": ..., "version": ...}, ...]).
  -- The venv may not exist yet — plan stays read-only, so a missing venv
  -- simply lists as empty and every desired spec plans as an addition.
  local installed = {}
  if sync.shell_output("test -x " .. PIP .. " && echo up") ~= "" then
    local listing = sync.shell_output(PIP .. " list --format=json") or ""
    for obj in listing:gmatch("{[^}]*}") do
      local n = obj:match('"name":%s*"([^"]*)"')
      local v = obj:match('"version":%s*"([^"]*)"')
      if n then installed[norm(n)] = v end
    end
  end

  -- Does the venv hold this spec? With check_version, "==" must match too
  -- (additions); without it, any version counts (removals — the record
  -- still matters after a plain install/upgrade bumped the version).
  local function matches(spec, check_version)
    local name, version = parse_spec(spec)
    local have = installed[norm(name)]
    if have == nil then return false end
    if not check_version then return true end
    return version == nil or have == version
  end

  -- Install what is declared but not present. The venv itself is created
  -- here too — planning never mutates the system.
  for _, spec in ipairs(desired) do
    if not matches(spec, true) then
      table.insert(changes, sync.change("+", "pip", spec, nil,
        function(_, s)
          if not s.shell("test -x " .. PIP .. " || python3 -m venv " .. VENV) then
            io.stderr:write("[warn] pip: could not create the declared venv at "
              .. VENV .. "\n")
            return false
          end
          local ok = s.shell(PIP .. " install " .. spec)
          if not ok then
            io.stderr:write("[warn] '" .. spec .. "' pip install failed "
              .. "(unknown package, bad version pin, or network error)\n")
            return false
          end
          return declare(s, spec)
        end))
    end
  end

  -- Remove what we previously declared and is no longer desired (never touch
  -- entries this generator does not own). The target is the bare name — pip
  -- uninstalls by name — and the uninstall is skipped when the package is
  -- already gone from the venv (un-recorded, not re-removed) or when a
  -- desired spec still names it (a pin change is an in-place upgrade, so
  -- uninstalling would rip out the version the addition just pinned).
  local undeclared = {}
  for spec in pairs(read_declared(sync)) do
    if not desired_set[spec] then undeclared[#undeclared + 1] = spec end
  end
  table.sort(undeclared)

  for _, spec in ipairs(undeclared) do
    local name = parse_spec(spec)
    local key = norm(name)
    local present = installed[key] ~= nil
    local superseded = desired_names[key] == true
    table.insert(changes, sync.change("-", "pip", spec, nil,
      function(_, s)
        if present and not superseded then
          local ok = s.shell(PIP .. " uninstall -y " .. name)
          if not ok then
            io.stderr:write("[warn] '" .. spec .. "' — pip uninstall failed\n")
            return false
          end
        end
        return undeclare(s, spec)
      end))
  end

  return changes
end

return gen
