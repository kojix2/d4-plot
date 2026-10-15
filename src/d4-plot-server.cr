require "./d4_plot/serve_cli"

# Deliberately separate from src/d4-plot.cr: this target never requires the
# native desktop app, UIng, or the GUI runtime.
exit D4Plot::ServeCLI.run(ARGV)
