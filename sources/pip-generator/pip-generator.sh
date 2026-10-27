#!/bin/sh
# pip-generator — enable declarative pip packages in Haliade system.
#
# The helper ships the "pip" generator (usr/lib/nacelle/generators/pip.lua)
# and its plugin config (etc/nacelle/plugin-configs/pip.lua, which gives the
# section its default + schema so config.lua parses it without anyone editing
# definition itself). This script walks you through the two remaining manual
# steps and the sanity checks around them.

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

     (or: nacelle enable-generator system pip)

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

Declared packages install into the SYSTEM environment
(/usr/lib/python3.14/site-packages): what root's sync installs is
importable by every python3 immediately, with no PATH or PYTHONPATH
plumbing. Installs pass --break-system-packages (the interpreter carries
a PEP 668 EXTERNALLY-MANAGED marker — this is a deliberate system
decision). Only entries this generator declared are ever removed, and pip
only uninstalls distributions it holds a RECORD for, so zeta's own
python-* packages can never be yanked. Don't declare a package zeta
already ships.

Note: pip-generator 1.0 installed into a private venv instead. That venv
(/usr/var/pip/declared) is no longer used; remove it with
    rm -rf /usr/var/pip/declared

and run:  nacelle spin system

Commands:
  --help         show this message
  --verifypip    report whether pip is ready for declarations
                 (exit 0 = installed, 1 = not)
EOF
}

verifypip() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is NOT installed."
    echo "install it with: zeta -Provide python"
    return 1
  fi

  if ! command -v pip >/dev/null 2>&1; then
    echo "pip is NOT installed."
    echo "install it with: zeta -Provide pip"
    return 1
  fi

  echo "pip is installed: $(pip --version 2>/dev/null | head -n1)"

  if [ -f /usr/lib/python3.14/EXTERNALLY-MANAGED ]; then
    echo "note: interpreter is PEP 668 marked; installs use --break-system-packages"
  fi

  if [ -d /usr/var/pip/declared ]; then
    echo "note: leftover 1.0 venv at /usr/var/pip/declared — remove it with:"
    echo "          rm -rf /usr/var/pip/declared"
  fi
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
