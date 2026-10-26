#!/bin/sh
# guix-generator — enable declarative guix packages in Haliade system.
#
# The helper ships the "guix" generator (usr/lib/nacelle/generators/guix.lua)
# and its plugin config (etc/nacelle/plugin-configs/guix.lua, which gives the
# section its default + schema so config.lua parses it without anyone editing
# definition itself), plus etc/profile.d/guix-haliade.sh so the shared profile
# the packages land in is on every login shell's PATH. This script walks you
# through the two remaining manual steps and the sanity checks around them.

set -u

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
guix-generator — declare guix packages in Haliade system

Setup (two steps):

  1. guix must be installed — check with:
         guix-generator --verifyguix
     (install it with: zeta -Provide guix)

  2. Enable the generator: edit /etc/nacelle/enabled_modules.lua and add
     "guix" to the list inside the file:

         local enabled_generators = {
           ...
           "guix",
         }

     The plugin config needed to parse the ["guix"] section ships with
     this package (/etc/nacelle/plugin-configs/guix.lua) and is loaded
     automatically on every sync — no declaration files need editing.

Then declare packages in /etc/nacelle/definition.lua:

         ["guix"] = {
           "hello",
           "emacs@29.4",
           "gcc:debug",
           "guile@3.0.9:debug",
         },

Entries use guix's own package-spec grammar: name[@version][:output].
A bare name installs the package's default output, "@version" pins the
version, ":output" selects one output (debug, lib, ...).

Declared packages install into the shared profile
(/usr/var/guix/profiles/declared), never root's private per-user profile.
/etc/profile.d/guix-haliade.sh — shipped with this package — puts that
profile's bin directory on every login shell, so what root's sync installs
is runnable by all users. Only entries this generator declared are ever
removed from it; packages you installed by hand are left alone.

and run:  nacelle spin system

Commands:
  --help         show this message
  --verifyguix   report whether guix is ready for declarations
                 (exit 0 = installed + daemon reachable, 1 = not)
EOF
}

verifyguix() {
  if ! command -v guix >/dev/null 2>&1; then
    echo "guix is NOT installed."
    echo "install it with: zeta -Provide guix"
    return 1
  fi

  echo "guix is installed: $(guix --version 2>/dev/null | head -n1)"

  if [ -d /gnu/store ]; then
    echo "store: /gnu/store present"
  else
    echo "warning: guix is installed but /gnu/store does not exist" >&2
  fi

  if [ -S /usr/var/guix/daemon-socket/socket ]; then
    echo "daemon: guix-daemon is reachable (/usr/var/guix/daemon-socket/socket)"
  else
    echo "warning: guix-daemon socket missing — installs will fail until it runs" >&2
    echo "          start it via your init (it is /usr/bin/guix-daemon)" >&2
    return 1
  fi

  if [ -d /usr/var/guix/profiles/declared ]; then
    echo "shared profile: /usr/var/guix/profiles/declared present"
  else
    echo "note: shared profile not created yet (the first sync creates it)"
  fi
  echo "note: PATH exposure ships as /etc/profile.d/guix-haliade.sh with this package"
  return 0
}

case "${1:-}" in
  --help|-h)
    usage
    ;;
  --verifyguix)
    verifyguix
    ;;
  "")
    usage >&2
    exit 1
    ;;
  *)
    echo "unknown option: $1" >&2
    echo "run 'guix-generator --help' for usage." >&2
    exit 1
    ;;
esac
