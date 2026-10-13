require "spec"
require "../src/d4_plot/i18n"

# Keep non-localization specifications independent from the developer's shell
# locale. The i18n spec explicitly exercises the Japanese catalogue.
D4Plot::Translations.setup("en")
