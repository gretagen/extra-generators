local gen = {}
gen.name = "guix"

-- Declare system-level guix packages from definition.lua:
--
--   ["guix"] = {
--     "hello",
--     "emacs@29.4",
--     "gcc:debug",
--     "guile@3.0.9:debug",
--   },
--
-- Entries follow guix's own package-spec grammar — name[@version][:output] —
-- so whatever `guix package -i` accepts can be declared: a bare name installs
-- the package's default output, "@version" pins it, ":output" picks one
-- output (debug, lib, ...).
--
-- Backed by `guix package -i/-r` against a dedicated SHARED profile
-- (/usr/var/guix/profiles/declared) instead of root's default per-user
-- profile (/usr/var/guix/profiles/per-user/root/guix), which no other user's
-- PATH contains. The path is under /usr/var/guix because that is this build's
-- (zeta's guix 1.5.0, prefix /usr) guix localstatedir — the daemon socket and
-- store db live there too. /etc/profile.d/guix-haliade.sh (shipped by this
-- package) puts that profile's bin directory on every login shell, so root's
-- sync makes the tools visible to all users. This is the generator shipped by
-- the guix-generator construct; it only runs when "guix" is enabled in
-- /etc/nacelle/enabled_modules.lua (see `guix-generator --help`). The
-- ["guix"] section's default + schema come from the package's plugin config
-- at /etc/nacelle/plugin-configs/guix.lua, auto-loaded by config.lua.
--
-- Additions diff against `guix package --list-installed`, whose rows are
-- "name version output path". A declared spec counts as installed when a row
-- has its name, its "@version" when one is given, and its output — "out" when
-- no output is named, since that is what `guix install name` records. So a
-- hand-installed "hello:debug" never masquerades as the declared "hello", and
-- a pin that drifted (someone ran `guix package -u`) is re-applied: guix
-- replaces an entry with the same name and output in one transaction, which
-- is exactly what a version-mismatched `-i` does.
--
-- Removals only ever touch specs THIS generator previously declared, recorded
-- in /var/db/declared-guix at apply time (mirroring nixpkgs) — a package
-- someone installed themselves with `guix package -i` is never yanked from
-- their declaration, and the record is only written when the command actually
-- ran, so a failed install is retried next sync. The removal target drops any
-- "@version" (so a drifted upgrade is still removed) but keeps ":output" (so
-- "gcc:debug" never takes out gcc's default output), and is skipped entirely
-- when the package is already gone from the profile at plan time — dropped
-- from the record, not re-removed.

local DECLARED = "/var/db/declared-guix"

-- The shared profile declared packages install into. Root's default guix
-- profile would be per-user and on nobody else's PATH — THIS one is exposed
-- by /etc/profile.d/guix-haliade.sh (this package).
local PROFILE = "/usr/var/guix/profiles/declared"

-- guix talks to guix-daemon over this socket; with it missing, every -i/-r
-- would fail, so planning stops with a warning instead of failing each apply.
local DAEMON_SOCKET = "/usr/var/guix/daemon-socket/socket"

-- Parse a package specification, guix's own grammar: name[@version][:output].
-- Refs are interpolated into shell commands, so only word-ish characters plus
-- the punctuation guix specs legitimately use are accepted (hello,
-- emacs@29.4, gcc:debug, libstdc++@13.2.0:debug) — no spaces, quotes, $,
-- backticks, ;|&<>/ — safe to embed unquoted. Returns name, version, output
-- (version/output nil when absent), or nil when the spec is malformed.
local function parse_spec(spec)
  if type(spec) ~= "string" or spec == "" then return nil end
  local name, rest = spec:match("^([%w][%w%.%_%+%-]*)(.*)$")
  if not name then return nil end
  if rest == "" then return name end

  local v, o = rest:match("^@([%w%.%+%_%~%-]+):([%w][%w%.%_%+%-]*)$")
  if not v then
    v = rest:match("^@([%w%.%+%_%~%-]+)$")
  end
  if not v then
    o = rest:match("^:([%w][%w%.%_%+%-]*)$")
    if not o then return nil end
  end
  return name, v, o
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
  local desired_list = cfg["guix"] or {}

  if #desired_list == 0 and next(read_declared(sync)) == nil then
    return {}
  end

  -- guix is optional (see `guix-generator --verifyguix`): plan nothing
  -- and say why rather than failing the whole sync.
  if sync.shell_output("command -v guix") == "" then
    if #desired_list > 0 then
      io.stderr:write("[warn] guix: guix is not installed — install it via zeta -Provide guix\n")
    end
    return {}
  end

  -- Without the daemon socket no -i/-r can succeed, so stop here with one
  -- clear warning instead of failing every change at apply time.
  if sync.shell_output("test -S " .. DAEMON_SOCKET .. " && echo up") == "" then
    if #desired_list > 0 then
      io.stderr:write("[warn] guix: guix-daemon is not running (no " .. DAEMON_SOCKET
        .. ") — start it before syncing\n")
    end
    return {}
  end

  -- Validate and de-duplicate the desired specs, keeping declaration order.
  -- Two specs for the SAME package with different version pins would fight
  -- over one profile entry every sync, so the first wins and the rest are
  -- reported; differing outputs are fine and kept (they are separate entries).
  local desired, desired_set, seen = {}, {}, {}
  local pinned = {}
  for _, spec in ipairs(desired_list) do
    local name, version = parse_spec(spec)
    if not name then
      io.stderr:write("[warn] guix: skipping invalid package specification '"
        .. tostring(spec) .. "' (expected e.g. \"hello\", \"emacs@29.4\", \"gcc:debug\")\n")
    elseif not seen[spec] then
      if version and pinned[name] and pinned[name] ~= version then
        io.stderr:write("[warn] guix: '" .. spec .. "' conflicts with version pin '"
          .. name .. "@" .. pinned[name] .. "' — keeping the first\n")
      else
        seen[spec] = true
        if version then pinned[name] = version end
        desired[#desired + 1] = spec
        desired_set[spec] = true
      end
    end
  end

  if #desired == 0 and next(read_declared(sync)) == nil then
    return {}
  end

  -- Installed rows of the declared profile, from the one listing call
  -- (`guix package --list-installed` prints "name version output path",
  -- column-padded) — indexed by package name. `-A`/`--show` lookups are
  -- deliberately avoided: they load every package module and cost a minute.
  local installed = {}
  local listing = sync.shell_output("guix package -p " .. PROFILE .. " --list-installed")
  for line in (listing .. "\n"):gmatch("([^\n]+)") do
    local n, v, o = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+%S+$")
    if n then
      if not installed[n] then installed[n] = {} end
      table.insert(installed[n], { version = v, output = o })
    end
  end

  -- Does the profile hold this spec? With check_version, "@version" must match
  -- too (additions); without it, any version counts (removals — the record
  -- still matters after a plain `guix package -u` bumped the version).
  -- An unnamed output means "out": guix records `guix install name` that way,
  -- so a stray debug/lib output never stands in for the declared package.
  local function matches(spec, check_version)
    local name, version, output = parse_spec(spec)
    local want = output or "out"
    for _, row in ipairs(installed[name] or {}) do
      if row.output == want
        and (not check_version or version == nil or row.version == version) then
        return true
      end
    end
    return false
  end

  -- Install what is declared but not present.
  for _, spec in ipairs(desired) do
    if not matches(spec, true) then
      table.insert(changes, sync.change("+", "guix", spec, nil,
        function(_, s)
          local ok = s.shell("guix package -p " .. PROFILE .. " -i " .. spec)
          if not ok then
            io.stderr:write("[warn] '" .. spec .. "' guix package -i failed "
              .. "(unknown package, daemon error, or a collision in the profile)\n")
            return false
          end
          return declare(s, spec)
        end))
    end
  end

  -- Remove what we previously declared and is no longer desired (never touch
  -- entries this generator does not own). The target keeps ":output" but drops
  -- "@version", so it matches whatever version guix is currently holding; a
  -- spec already gone from the profile is un-recorded without running anything.
  local undeclared = {}
  for spec in pairs(read_declared(sync)) do
    if not desired_set[spec] then undeclared[#undeclared + 1] = spec end
  end
  table.sort(undeclared)

  for _, spec in ipairs(undeclared) do
    local name, _, output = parse_spec(spec)
    local target = output and (name .. ":" .. output) or name
    local still_there = matches(spec, false)
    table.insert(changes, sync.change("-", "guix", spec, nil,
        function(_, s)
        if still_there then
          local ok = s.shell("guix package -p " .. PROFILE .. " -r " .. target)
          if not ok then
            io.stderr:write("[warn] '" .. spec .. "' — guix package -r failed\n")
            return false
          end
        end
        return undeclare(s, spec)
      end))
  end

  return changes
end

return gen
