require "d4"
require "file_utils"
require "mopdepth"
require "./i18n"

module D4Plot
  alias CoverageMode = Mopdepth::Mode

  class ConversionError < Exception
    getter field : String

    def initialize(@field, message)
      super(message)
    end
  end

  class ConversionCancelled < Exception; end

  class ConversionRequest
    getter input : String
    getter output : String
    getter reference : String
    getter mode : CoverageMode
    getter mapq : Int32
    getter threads : Int32
    getter exclude_flags : UInt16
    getter include_flags : UInt16
    getter read_groups : Array(String)
    getter min_fragment : Int32
    getter max_fragment : Int32

    def initialize(
      @input : String,
      @output : String,
      @reference : String = "",
      @mode : CoverageMode = CoverageMode::Standard,
      @mapq : Int32 = 0,
      @threads : Int32 = 2,
      @exclude_flags : UInt16 = 1796_u16,
      @include_flags : UInt16 = 0_u16,
      @read_groups : Array(String) = [] of String,
      @min_fragment : Int32 = -1,
      @max_fragment : Int32 = -1
    )
    end

    def_equals_and_hash input, output, reference, mode, mapq, threads, exclude_flags, include_flags,
      read_groups, min_fragment, max_fragment

    def copy_with(*, input : String = @input, output : String = @output, reference : String = @reference,
                  mode : CoverageMode = @mode, mapq : Int32 = @mapq, threads : Int32 = @threads,
                  exclude_flags : UInt16 = @exclude_flags, include_flags : UInt16 = @include_flags,
                  read_groups : Array(String) = @read_groups, min_fragment : Int32 = @min_fragment,
                  max_fragment : Int32 = @max_fragment) : self
      self.class.new(input, output, reference, mode, mapq, threads, exclude_flags, include_flags,
        read_groups, min_fragment, max_fragment)
    end

    def options : Mopdepth::Options
      Mopdepth::Options.new(mode: mode, minimum_mapping_quality: mapq,
        minimum_fragment_length: min_fragment < 0 ? nil : min_fragment,
        maximum_fragment_length: max_fragment < 0 ? nil : max_fragment,
        exclude_flags: exclude_flags, include_flags: include_flags, read_groups: read_groups)
    end

    def validate!
      validate_input
      validate_output
      validate_options
      validate_reference
    end

    private def validate_input : Nil
      raise_error("fields.input", "errors.input_missing") unless File.file?(input)
    end

    private def validate_output : Nil
      raise_error("fields.output", "errors.output_extension") unless output.downcase.ends_with?(".d4")
      raise_error("fields.output", "errors.output_directory") unless Dir.exists?(File.dirname(output))
      raise_error("fields.output", "errors.output_exists") if File.exists?(output) || File.symlink?(output)
    end

    private def validate_options : Nil
      raise_error("fields.minimum_mapq", "errors.mapq_range") unless (0..255).includes?(mapq)
      raise_error("fields.threads", "errors.threads_range") unless (0..64).includes?(threads)
      if min_fragment < -1 || max_fragment < -1 || (min_fragment >= 0 && max_fragment >= 0 && min_fragment > max_fragment)
        raise_error("fields.fragment_length", "errors.fragment_range")
      end
    end

    private def validate_reference : Nil
      return if reference.empty?
      raise_error("fields.reference", "errors.reference_missing") unless File.file?(reference)
      raise_error("fields.reference", "errors.reference_index") unless File.file?("#{reference}.fai")
    end

    private def raise_error(field_key : String, error_key : String) : NoReturn
      raise ConversionError.new(D4Plot.t(field_key), D4Plot.t(error_key))
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

  class ConversionProgress
    getter stage : String
    getter chromosome : String
    getter current : Int32
    getter total : Int32
    getter records : Int64

    def initialize(
      @stage : String,
      @chromosome : String = "",
      @current : Int32 = 0,
      @total : Int32 = 0,
      @records : Int64 = 0_i64
    )
    end

    def_equals_and_hash stage, chromosome, current, total, records

    def copy_with(*, stage : String = @stage, chromosome : String = @chromosome,
                  current : Int32 = @current, total : Int32 = @total, records : Int64 = @records) : self
      self.class.new(stage, chromosome, current, total, records)
    end
  end

  class D4Converter
    CHECK_INTERVAL = 65_536

    def run(request : ConversionRequest, control : ConversionControl = ConversionControl.new,
            progress : Proc(ConversionProgress, Nil) = ->(_event : ConversionProgress) { }) : String
      current = ConversionProgress.new(D4Plot.t("conversion.checking_input"))
      emit = ->(event : ConversionProgress) do
        current = event
        progress.call(event)
      end
      emit.call(current)
      control.check!
      request.validate!
      mopdepth_control = Mopdepth::Control.new do |event|
        stage = coverage_stage(event.stage)
        emit.call(current.copy_with(stage: stage, records: event.records_examined))
      end
      d4_control = D4::WriteControl.new do |event|
        stage = write_stage(event.stage)
        # D4 counts bytes in the primary phase and references in other phases.
        # Only reference progress belongs in the UI's chromosome counter.
        emit.call(current.copy_with(stage: stage, chromosome: event.chromosome || "",
          current: event.chromosome ? event.current.to_i32 + 1 : 0,
          total: event.chromosome ? event.total.to_i32 : 0))
      end
      control.attach(mopdepth_control, d4_control)
      begin
        reader = open_reader(request)
        begin
          names = reader.targets.map(&.name)
          control.check!
          staging = File.tempname(".d4-plot-", dir: File.dirname(File.expand_path(request.output)))
          Dir.mkdir(staging)
          begin
            staged = File.join(staging, "result.d4")
            writer = D4.create(staged,
              chromosomes: reader.targets.map { |target| D4::Chromosome.new(target.name, target.length) },
              options: D4::WriteOptions.new(overwrite: true, indexes: [D4::IndexKind::SecondaryFrames, D4::IndexKind::Sum]),
              control: d4_control)
            begin
              convert_targets(reader, writer, request.options, mopdepth_control, control, emit)
              control.check!
              writer.close
              control.check!
              emit.call(current.copy_with(stage: D4Plot.t("conversion.verifying_d4")))
              verify(staged, names)
              control.publish(staged, File.expand_path(request.output))
              File.expand_path(request.output)
            ensure
              writer.abort unless writer.closed?
            end
          ensure
            FileUtils.rm_rf(staging) if Dir.exists?(staging)
          end
        ensure
          reader.close
        end
      rescue Mopdepth::CancelledError | D4::CancelledError
        raise ConversionCancelled.new
      ensure
        control.detach
      end
    rescue Mopdepth::CancelledError | D4::CancelledError
      raise ConversionCancelled.new
    end

    private def coverage_stage(stage : Mopdepth::Stage) : String
      case stage
      in .preparing?  then D4Plot.t("conversion.preparing_coverage")
      in .reading?    then D4Plot.t("conversion.reading_alignments")
      in .finalizing? then D4Plot.t("conversion.preparing_output")
      end
    end

    private def write_stage(stage : D4::WriteStage) : String
      case stage
      in .finalizing?                           then D4Plot.t("conversion.finalizing")
      in .writing_primary?, .writing_secondary? then D4Plot.t("conversion.writing")
      in .building_indexes?                     then D4Plot.t("conversion.building_index")
      in .publishing?                           then D4Plot.t("conversion.finishing")
      end
    end

    private def open_reader(request : ConversionRequest) : Mopdepth::Reader
      reader = Mopdepth::Reader.open(request.input, reference: request.reference, threads: request.threads)
      if reader.file_format == "cram" && request.reference.empty?
        reader.close
        raise ConversionError.new(D4Plot.t("fields.reference"), D4Plot.t("errors.cram_reference"))
      end
      reader
    rescue ex : Mopdepth::IndexError
      raise ConversionError.new(D4Plot.t("fields.input"), D4Plot.t("errors.alignment_index", error: ex.message))
    rescue ex : Mopdepth::InputError
      raise ConversionError.new(D4Plot.t("fields.input"), D4Plot.t("errors.alignment_open", error: ex.message))
    end

    private def convert_targets(reader, writer, options, mopdepth_control, control, progress) : Nil
      # Mopdepth fills the same buffer for every chromosome. Reserve enough
      # room once so growing it cannot temporarily duplicate a large array.
      coverage = Array(Int32).new(reader.targets.max_of(&.length) + 1)
      total = reader.targets.size
      reader.targets.each_with_index do |target, index|
        control.check!
        event = ConversionProgress.new(D4Plot.t("conversion.preparing_coverage"), target.name, index + 1, total, reader.records_examined)
        progress.call(event)
        result = reader.coverage_into(target.region, coverage, options: options, control: mopdepth_control)
        progress.call(event.copy_with(stage: D4Plot.t("conversion.writing_coverage"), records: reader.records_examined))
        write_coverage(writer, result.values, target.name, control)
      end
    end

    private def verify(path : String, names : Array(String)) : Nil
      D4.open(path) do |file|
        raise D4Plot.t("errors.no_secondary_index") unless file.default_track.has_index?(D4::IndexKind::SecondaryFrames)
        raise D4Plot.t("errors.unexpected_references") unless file.chromosomes.map(&.name) == names
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
