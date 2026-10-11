require "option_parser"
require "./d4_plot/app"

region : String? = nil
OptionParser.parse do |parser|
  parser.banner = "Usage: d4-plot [--region chromosome:start-end] [file.d4 ...]"
  parser.on("-r REGION", "--region REGION", "Initial region (1-based, inclusive)") { |value| region = value }
  parser.on("-h", "--help", "Show usage") { puts parser; exit }
end
# Retain the original single-file positional region syntax.
if ARGV.size == 2 && !File.exists?(ARGV[1]) && !ARGV[1].ends_with?(".d4")
  region ||= ARGV.pop
end
UIng.init
menu_items = D4Plot::App.create_menu_bar
D4Plot::App.new(menu_items).run(ARGV, region)
