require "option_parser"
require "./d4_plot/serve_cli"

# The standalone d4-plot-server target is the GUI-free distribution option.
# Keep the familiar subcommand on the desktop executable as well, but dispatch
# it before the UI runtime is prepared or any native window is initialized.
if ARGV.first? == "serve"
  ARGV.shift
  exit D4Plot::ServeCLI.run(ARGV)
end

require "./d4_plot/i18n"
require "./d4_plot/preferences"
require "./d4_plot/app"

D4Plot::UIRuntime.prepare

region : String? = nil
locale : String? = nil
show_help = false
OptionParser.parse do |parser|
  parser.banner = "Usage: d4-plot [--locale #{D4Plot::Translations.locale_list}] [--region chromosome:start-end] [file.d4 ...]"
  parser.on("-l LOCALE", "--locale LOCALE", "Interface language") { |value| locale = value }
  parser.on("-r REGION", "--region REGION", "Initial region (1-based, inclusive)") { |value| region = value }
  parser.on("-h", "--help", "Show usage") { show_help = true }
end
# Retain the original single-file positional region syntax.
if ARGV.size == 2 && !File.exists?(ARGV[1]) && !ARGV[1].ends_with?(".d4")
  region ||= ARGV.pop
end
preferences = D4Plot::UIRuntime.load { D4Plot::Preferences.load }
D4Plot::Translations.setup(locale || preferences.locale)
if show_help
  puts D4Plot::Translations.usage
  puts D4Plot.t("cli.locale_option")
  puts D4Plot.t("cli.region_option")
  puts D4Plot.t("cli.help_option")
  exit
end
D4Plot::UIRuntime.check_thread!
UIng.init
menu_items = D4Plot::App.create_menu_bar
D4Plot::App.new(menu_items, preferences).run(ARGV, region)
