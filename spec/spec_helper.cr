require "spec"
require "../src/d4_plot/i18n"
require "../src/d4_plot/log"

# Logging specs opt into the relevant sources with Log.capture/MemoryBackend.
Log.setup(:none)

# Keep non-localization specifications independent from the developer's shell
# locale. The i18n spec explicitly exercises the Japanese catalogue.
D4Plot::Translations.setup("en")
