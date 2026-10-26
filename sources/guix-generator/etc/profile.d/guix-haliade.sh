# Haliade system: expose the guix profile that declared packages install into
# (/usr/var/guix/profiles/declared) on PATH for every login shell, so entries
# in definition.lua's ["guix"] (applied as root) are runnable by all users.
# Prepended here, then overridden by a user's own ~/.guix-profile when their
# profile prepends it later — the shared profile is the fallback, not a hijack.
case ":${PATH:-}:" in
  *:/usr/var/guix/profiles/declared/bin:*) ;;
  *) PATH="/usr/var/guix/profiles/declared/bin${PATH:+:$PATH}" ;;
esac
export PATH
