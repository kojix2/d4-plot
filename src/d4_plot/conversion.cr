require "d4"
require "file_utils"
require "mopdepth"

module D4Plot
  enum CoverageMode
    Standard
    Fast
    Fragment
  end

  class ConversionError < Exception
    getter field : String

    def initialize(@field, message)
      super(message)
    end
  end

  class ConversionCancelled < Exception; end

  record ConversionRequest,
    input : String, output : String, reference : String = "",
    mode : CoverageMode = CoverageMode::Standard, mapq : Int32 = 0,
    threads : Int32 = 0, exclude_flags : UInt16 = 1796_u16,
    include_flags : UInt16 = 0_u16, read_groups : Array(String) = [] of String,
    min_fragment : Int32 = -1, max_fragment : Int32 = -1 do
    def options : Mopdepth::Options
      mopdepth_mode = case mode
                      in .standard? then Mopdepth::Mode::Standard
                      in .fast?     then Mopdepth::Mode::Fast
                      in .fragment? then Mopdepth::Mode::Fragment
                      end
      Mopdepth::Options.new(mode: mopdepth_mode, minimum_mapping_quality: mapq,
        minimum_fragment_length: min_fragment < 0 ? nil : min_fragment,
        maximum_fragment_length: max_fragment < 0 ? nil : max_fragment,
        exclude_flags: exclude_flags, include_flags: include_flags, read_groups: read_groups)
    end

    def validate!
      raise ConversionError.new("Input", "Choose a local BAM or CRAM file.") unless File.file?(input)
      raise ConversionError.new("Output", "Choose a filename ending in .d4.") unless output.downcase.ends_with?(".d4")
      raise ConversionError.new("Output", "Choose an existing output folder.") unless Dir.exists?(File.dirname(output))
      if File.exists?(output) || File.symlink?(output)
        raise ConversionError.new("Output", "This output already exists. Choose a new filename.")
      end
      raise ConversionError.new("Minimum MAPQ", "Enter a value between 0 and 255.") unless (0..255).includes?(mapq)
      raise ConversionError.new("Threads", "Enter a value between 0 and 64.") unless (0..64).includes?(threads)
      if min_fragment < -1 || max_fragment < -1 || (min_fragment >= 0 && max_fragment >= 0 && min_fragment > max_fragment)
        raise ConversionError.new("Fragment length", "Enter non-negative limits, with minimum no larger than maximum.")
      end
      unless reference.empty?
        raise ConversionError.new("Reference", "Choose a local reference FASTA file.") unless File.file?(reference)
        raise ConversionError.new("Reference", "The reference FASTA needs a matching .fai index.") unless File.file?("#{reference}.fai")
      end
    end
  end

  # The publication lock makes Cancel vs successful completion unambiguous.
  # Only our own staging directory is ever removed; the destination is no-clobber.
  class ConversionControl
    @cancelled = Atomic(Bool).new(false)
    @mutex = Thread::Mutex.new
    @published = false
    @mopdepth_control : Mopdepth::Control? = nil
    @d4_control : D4::WriteControl? = nil

    def attach(mopdepth_control : Mopdepth::Control, d4_control : D4::WriteControl) : Nil
      @mutex.synchronize do
        @mopdepth_control = mopdepth_control
        @d4_control = d4_control
        if @cancelled.get
          mopdepth_control.cancel
          d4_control.cancel
        end
      end
    end

    def cancel : Bool
      @mutex.synchronize do
        return false if @published
        @cancelled.set(true)
        @mopdepth_control.try(&.cancel)
        @d4_control.try(&.cancel)
        true
      end
    end

    def detach : Nil
      @mutex.synchronize do
        @mopdepth_control = nil
        @d4_control = nil
      end
    end

    def check!
      raise ConversionCancelled.new if @cancelled.get
    end

    def publish(staged : String, destination : String)
      @mutex.synchronize do
        check!
        # An atomic, non-replacing publication on the same filesystem.
        File.link(staged, destination)
        @published = true
      end
    end
  end

  record ConversionProgress, stage : String, chromosome : String = "",
    current : Int32 = 0, total : Int32 = 0, records : Int64 = 0_i64

  class D4Converter
    CHECK_INTERVAL = 65_536

    def run(request : ConversionRequest, control : ConversionControl = ConversionControl.new,
            progress : Proc(ConversionProgress, Nil) = ->(event : ConversionProgress) { }) : String
      reader = nil.as(Mopdepth::Reader?)
      writer = nil.as(D4::Writer?)
      staging = nil.as(String?)
      current = ConversionProgress.new("Checking input")
      progress.call(current)
      control.check!
      request.validate!
      mopdepth_control = Mopdepth::Control.new do |event|
        stage = case event.stage
                in .preparing?  then "Preparing coverage"
                in .reading?    then "Reading alignments"
                in .finalizing? then "Preparing D4 output"
                end
        current = current.copy_with(stage: stage, records: event.records_examined)
        progress.call(current)
      end
      d4_control = D4::WriteControl.new do |event|
        stage = case event.stage
                in .finalizing?                           then "Finalizing D4"
                in .writing_primary?, .writing_secondary? then "Writing D4"
                in .building_indexes?                     then "Building D4 index"
                in .publishing?                           then "Finishing D4"
                end
        current = current.copy_with(stage: stage, chromosome: event.chromosome || "")
        progress.call(current)
      end
      control.attach(mopdepth_control, d4_control)
      begin
        reader = Mopdepth::Reader.open(request.input, reference: request.reference, threads: request.threads)
      rescue ex : Mopdepth::IndexError
        raise ConversionError.new("Input", "A matching BAI/CSI (BAM) or CRAI (CRAM) index is required. #{ex.message}")
      rescue ex : Mopdepth::InputError
        raise ConversionError.new("Input", "Could not open alignment: #{ex.message}")
      end
      if reader.file_format == "cram" && request.reference.empty?
        raise ConversionError.new("Reference", "Choose the reference FASTA used for this CRAM, with its .fai index.")
      end
      names = reader.targets.map(&.name)
      control.check!
      candidate = File.tempname(".d4-plot-", dir: File.dirname(File.expand_path(request.output)))
      Dir.mkdir(candidate)
      # Only record ownership after exclusive directory creation succeeds.
      staging = candidate
      staged = File.join(staging, "result.d4")
      writer = D4::Writer.new(staged,
        D4::WriteOptions.new(overwrite: true, indexes: [D4::IndexKind::SecondaryFrames]), d4_control)
      writer.set_chromosomes(reader.targets.map { |target| {target.name, target.length.to_u32} })
      coverage = [] of Int32
      reader.targets.each_with_index do |target, index|
        control.check!
        current = ConversionProgress.new("Preparing coverage", target.name, index + 1, names.size, reader.records_examined)
        progress.call(current)
        result = reader.coverage_into(target.region, coverage, options: request.options, control: mopdepth_control)
        current = current.copy_with(stage: "Writing coverage", records: reader.records_examined)
        progress.call(current)
        write_coverage(writer, result.values, target.name, control)
      end
      reader.close
      reader = nil
      control.check!
      current = current.copy_with(stage: "Finalizing D4")
      progress.call(current)
      writer.close
      control.check!
      progress.call(current.copy_with(stage: "Verifying D4"))
      D4.open(staged) do |file|
        raise "The generated D4 has no secondary-frame index." unless file.default_track.has_index?(D4::IndexKind::SecondaryFrames)
        raise "The generated D4 has unexpected reference sequences." unless file.chromosomes.map(&.name) == names
      end
      control.publish(staged, File.expand_path(request.output))
      File.expand_path(request.output)
    rescue ex : Mopdepth::CancelledError | D4::CancelledError
      raise ConversionCancelled.new
    ensure
      begin
        writer.try(&.abort) unless writer.try(&.closed?)
      ensure
        begin
          reader.try(&.close)
        ensure
          begin
            FileUtils.rm_rf(staging) if staging && Dir.exists?(staging)
          ensure
            control.detach
          end
        end
      end
    end

    private def write_coverage(writer, coverage, name, control)
      previous = 0_i32
      start = 0
      coverage.each_with_index do |depth, i|
        control.check! if i % CHECK_INTERVAL == 0
        if depth != previous
          writer.write_interval(name, start, i, previous) if start < i
          start = i
          previous = depth
        end
      end
      writer.write_interval(name, start, coverage.size, previous) if start < coverage.size
    end
  end
end
