require "option_parser"
require "./i18n"
require "./igv_integration"
require "./igv_web_server"

module D4Plot
  # Command-line adapter shared by the desktop executable's `serve` subcommand
  # and the GUI-free `d4-plot-server` executable. Keep this file free of app,
  # UIng, and UI-runtime requires so the latter can be built on headless hosts.
  module ServeCLI
    Log = D4Plot::Log.for("cli")

    class UsageError < ArgumentError
    end

    enum ReferenceMode
      Auto
      Preset
      File
      ContigsOnly
    end

    class Configuration
      getter files : Array(String)
      getter port : Int32
      getter region : String?
      getter locale : String?
      getter reference_mode : ReferenceMode
      getter genome : String?
      getter reference_path : String?
      getter reference_index : String?
      getter? open_browser : Bool
      getter? help : Bool

      def initialize(@files : Array(String), @port : Int32, @region : String?, @locale : String?,
                     @reference_mode : ReferenceMode, @genome : String?, @reference_path : String?,
                     @reference_index : String?, @open_browser : Bool, @help : Bool)
      end

      # Resolve options that depend on the loaded D4 tracks only after they
      # have been inspected. In particular, contigs-only needs their merged
      # chromosome dictionary and must not manufacture a temporary file.
      def reference_for(sources : Array(TrackSource)) : ReferenceSpec?
        case @reference_mode
        when .auto?
          nil
        when .preset?
          ReferenceSpec.preset(@genome || raise UsageError.new("--genome is required"))
        when .file?
          path = @reference_path || raise UsageError.new("--reference is required")
          if path.downcase.ends_with?(".json")
            ReferenceSpec.igv_json(path)
          else
            ReferenceSpec.fasta(path, @reference_index)
          end
        when .contigs_only?
          ReferenceSpec.contigs_only(TrackSource.reference_chromosomes(sources))
        end
      end
    end

    def self.run(arguments : Array(String) = ARGV) : Int32
      Logging.setup
      configuration = parse(arguments)
      if configuration.help?
        puts usage
        return 0
      end

      Translations.setup(configuration.locale)
      sources = configuration.files.flat_map { |path| TrackSource.load(path) }
      Log.info &.emit("files.loaded", files: configuration.files.size, tracks: sources.size)
      initial_region = configuration.region.try do |text|
        if sources.empty?
          region = Region.parse(text)
          raise UsageError.new("--region needs chr:start-end without a D4 file") unless region && region.valid?
          region
        else
          Region.resolve(text, TrackSource.reference_chromosomes(sources))
        end
      end
      server = IGVWebServer.new(sources, initial_region, configuration.port, configuration.reference_for(sources))

      begin
        browser_url = server.browser_url(initial_region)
        puts browser_url
        STDOUT.flush
        if configuration.open_browser?
          begin
            BrowserLauncher.open(browser_url)
          rescue ex
            Logging.report_warning(Log, "browser.open_failed", ex)
            # The token URL was already printed. A missing xdg-open or a
            # headless host must not turn --open into a request to stop the
            # server before the user can paste that URL into another browser.
            Logging.write_stderr("d4-plot serve: could not open browser: #{ex.message || ex.class.name}; server remains running")
          end
        end
        server.listen
        0
      ensure
        server.close
        server.wait
      end
    rescue ex : UsageError | OptionParser::InvalidOption | OptionParser::MissingOption
      Log.warn &.emit("cli.invalid_arguments", error_class: ex.class.name)
      Logging.write_stderr("d4-plot serve: #{ex.message || ex.class.name}\n#{usage}")
      2
    rescue ex
      Logging.report_exception(Log, "cli.failed", ex)
      Logging.write_stderr("d4-plot serve: #{ex.message || ex.class.name}")
      1
    ensure
      Logging.close
    end

    # Public so callers and specs can validate their command line before
    # opening a D4 file or binding a listening socket.
    # Each option conflict has a separate diagnostic for CLI users.
    # ameba:disable Metrics/CyclomaticComplexity
    def self.parse(arguments : Array(String)) : Configuration
      args = arguments.dup
      genome : String? = nil
      reference_path : String? = nil
      reference_index : String? = nil
      region : String? = nil
      locale : String? = nil
      port = 0
      contigs_only = false
      open_browser = false
      show_help = false

      OptionParser.parse(args) do |parser|
        parser.banner = usage
        parser.on("-g ID", "--genome ID", "IGV preset genome (for example hg38)") { |value| genome = require_value!(value, "--genome") }
        parser.on("-R PATH", "--reference PATH", "Reference FASTA or IGV genome JSON") { |value| reference_path = require_value!(value, "--reference") }
        parser.on("-I PATH", "--reference-index PATH", "FAI index for --reference FASTA") { |value| reference_index = require_value!(value, "--reference-index") }
        parser.on("--contigs-only", "Use only D4 contig names and lengths") { contigs_only = true }
        parser.on("-p PORT", "--port PORT", "Loopback port (0 selects an available port)") { |value| port = parse_port(value) }
        parser.on("-r REGION", "--region REGION", "Initial region (1-based, inclusive)") { |value| region = require_value!(value, "--region") }
        parser.on("-l LOCALE", "--locale LOCALE", "Interface language") { |value| locale = require_value!(value, "--locale") }
        parser.on("-o", "--open", "Open the browser after the server starts") { open_browser = true }
        parser.on("-h", "--help", "Show usage") { show_help = true }
      end

      return Configuration.new([] of String, port, region, locale, ReferenceMode::Auto, genome, reference_path,
        reference_index, open_browser, true) if show_help

      if args.empty? && !genome && !reference_path
        raise UsageError.new("provide a .d4 file, --genome, or --reference")
      end
      if genome && reference_path
        raise UsageError.new("--genome and --reference cannot be used together")
      end
      if contigs_only && (genome || reference_path)
        raise UsageError.new("--contigs-only cannot be combined with --genome or --reference")
      end
      if reference_index && !reference_path
        raise UsageError.new("--reference-index requires --reference")
      end
      if reference_index && reference_path.try(&.downcase.ends_with?(".json"))
        raise UsageError.new("--reference-index cannot be used with an IGV genome JSON reference")
      end

      mode = if genome
               ReferenceMode::Preset
             elsif reference_path
               ReferenceMode::File
             elsif contigs_only
               ReferenceMode::ContigsOnly
             else
               ReferenceMode::Auto
             end
      Configuration.new(args, port, region, locale, mode, genome, reference_path, reference_index, open_browser, false)
    end

    def self.usage : String
      "Usage: d4-plot serve [options] [file.d4 ...] (without D4, specify --genome or --reference)"
    end

    private def self.require_value!(value : String, option : String) : String
      raise UsageError.new("#{option} cannot be empty") if value.strip.empty?
      value
    end

    private def self.parse_port(value : String) : Int32
      port = value.to_i64?
      unless port && (0..65_535).includes?(port)
        raise UsageError.new("--port must be an integer from 0 through 65535")
      end
      port.to_i
    end
  end
end
