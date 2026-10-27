# Haliade system: expose the venv that declared packages install into
# (/usr/var/pip/declared) on PATH for every login shell, so entries in
# definition.lua's ["pip"] (applied as root) are runnable by all users.
# Prepended here, then overridden by a user's own venv activation when their
# profile prepends it later — the shared venv is the fallback, not a hijack.
case ":${PATH:-}:" in
  *:/usr/var/pip/declared/bin:*) ;;
  *) PATH="/usr/var/pip/declared/bin${PATH:+:$PATH}" ;;
esac
export PATH
