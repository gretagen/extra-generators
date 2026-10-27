-- pip plugin config — shipped by the pip-generator package.
--
-- Auto-loaded by declaration's config.lua on every sync, giving the
-- ["pip"] section its default value and type schema. You normally never
-- need to touch this file: it just lets nacelle parse the section.
-- Enable the generator itself in /etc/nacelle/enabled_modules.lua.

defaults["pip"] = {}
schema["pip"] = "table"
