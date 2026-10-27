#!/bin/sh
# pip-generator — enable declarative pip packages in Haliade system.
#
# The helper ships the "pip" generator (usr/lib/nacelle/generators/pip.lua)
# and its plugin config (etc/nacelle/plugin-configs/pip.lua, which gives the
# section its default + schema so config.lua parses it without anyone editing
# definition itself), plus etc/profile.d/pip-haliade.sh so the shared venv
# the packages land in is on every login shell's PATH. This script walks you
# through the two remaining manual steps and the sanity checks around them.

set -u

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
pip-generator — declare pip packages in Haliade system

Setup (two steps):

  1. pip must be installed — check with:
         pip-generator --verifypip
     (install it with: zeta -Provide pip)

  2. Enable the generator: edit /etc/nacelle/enabled_modules.lua and add
     "pip" to the list inside the file:

         local enabled_generators = {
           ...
           "pip",
         }

     The plugin config needed to parse the ["pip"] section ships with
     this package (/etc/nacelle/plugin-configs/pip.lua) and is loaded
     automatically on every sync — no declaration files need editing.

Then declare packages in /etc/nacelle/definition.lua:

         ["pip"] = {
           "requests",
           "requests==2.31.0",
         },

Entries use a tight pip requirement grammar: name or name==version.
A bare name installs the current version, "==" pins the exact version.
Ranges (>=, ~=, ...) are not accepted — a declaration should mean one
concrete thing a sync can verify.

Declared packages install into the shared venv (/usr/var/pip/declared),
never zeta's system site-packages. /etc/profile.d/pip-haliade.sh — shipped
with this package — puts that venv's bin directory on every login shell, so
what root's sync installs is runnable by all users. Only entries this
generator declared are ever removed from it; packages you installed by hand
are left alone.

and run:  nacelle spin system

Commands:
  --help         show this message
  --verifypip    report whether pip is ready for declarations
                 (exit 0 = installed, 1 = not)
EOF
}

verifypip() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is NOT installed (the declared venv needs it)."
    echo "install it with: zeta -Provide python"
    return 1
  fi

  if ! command -v pip >/dev/null 2>&1; then
    echo "pip is NOT installed."
    echo "install it with: zeta -Provide pip"
    return 1
  fi

  echo "pip is installed: $(pip --version 2>/dev/null | head -n1)"

  if [ -x /usr/var/pip/declared/bin/pip ]; then
    echo "venv: /usr/var/pip/declared present"
  else
    echo "note: shared venv not created yet (the first sync creates it)"
  fi
  echo "note: PATH exposure ships as /etc/profile.d/pip-haliade.sh with this package"
  return 0
}

case "${1:-}" in
  --help|-h)
    usage
    ;;
  --verifypip)
    verifypip
    ;;
  "")
    usage >&2
    exit 1
    ;;
  *)
    echo "unknown option: $1" >&2
    echo "run 'pip-generator --help' for usage." >&2
    exit 1
    ;;
esac
