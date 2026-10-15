require "./conversion"
require "./log"

module D4Plot
  enum ConversionState
    Idle
    Running
    Cancelling
    Succeeded
    Cancelled
    Failed

    def active?
      running? || cancelling?
    end

    def editable?
      idle? || failed? || cancelled?
    end
  end

  record ConversionSnapshot, state : ConversionState = ConversionState::Idle,
    progress : ConversionProgress = ConversionProgress.new(D4Plot.t("conversion.ready_short")),
    output : String? = nil, error : String? = nil, field : String? = nil,
    elapsed : Time::Span = Time::Span.zero

  # One conversion, independent of view reads. No worker callback touches UIng.
  class ConversionWorker
    Log = D4Plot::Log.for("conversion")
    @mutex = Thread::Mutex.new
    @control = ConversionControl.new
    @snapshot = ConversionSnapshot.new
    @worker : Fiber::ExecutionContext::Isolated?
    @started : Time::Instant?
    @job_id = 0_i64

    def start(request : ConversionRequest)
      raise D4Plot.t("errors.creation_running") if snapshot.state.active?
      @control = ConversionControl.new
      @started = Time.instant
      @job_id = Logging.next_correlation_id
      Log.info &.emit("conversion.started", job_id: @job_id, mode: request.mode.to_s, threads: request.threads)
      Log.debug &.emit("conversion.input", job_id: @job_id, input: request.input, output: request.output,
        reference: request.reference, mapq: request.mapq, min_fragment: request.min_fragment,
        max_fragment: request.max_fragment, exclude_flags: request.exclude_flags.to_i, include_flags: request.include_flags.to_i)
      @mutex.synchronize { @snapshot = ConversionSnapshot.new(ConversionState::Running) }
      @worker = Fiber::ExecutionContext::Isolated.new("d4-plot-converter") do
        last_stage = ""
        output = D4Converter.new.run(request, @control, ->(event : ConversionProgress) {
          if event.stage != last_stage
            Log.debug &.emit("conversion.stage", job_id: @job_id, stage: event.stage, records: event.records)
            last_stage = event.stage
          end
          @mutex.synchronize { @snapshot = @snapshot.copy_with(progress: event) }
          nil
        })
        finish(ConversionState::Succeeded, output: output)
      rescue ConversionCancelled
        finish(ConversionState::Cancelled)
      rescue ex : ConversionError
        Logging.report_exception(Log, "conversion.failed", ex, job_id: @job_id)
        finish(ConversionState::Failed, error: ex.message, field: ex.field)
      rescue ex
        Logging.report_exception(Log, "conversion.failed", ex, job_id: @job_id)
        finish(ConversionState::Failed, error: ex.message || ex.class.name)
      end
    end

    def snapshot : ConversionSnapshot
      @mutex.synchronize do
        result = @snapshot
        if result.state.active? && (started = @started)
          result = result.copy_with(elapsed: Time.instant - started)
        end
        result
      end
    end

    def cancel
      return unless snapshot.state.active?
      return unless @control.cancel
      Log.info &.emit("conversion.cancel_requested", job_id: @job_id)
      @mutex.synchronize do
        @snapshot = @snapshot.copy_with(state: ConversionState::Cancelling) if @snapshot.state.running?
      end
    end

    def wait
      @worker.try(&.wait)
    end

    def reset
      raise D4Plot.t("errors.creation_still_running") if snapshot.state.active?
      @mutex.synchronize { @snapshot = ConversionSnapshot.new }
    end

    private def finish(state, output : String? = nil, error : String? = nil, field : String? = nil)
      Log.info &.emit("conversion.finished", job_id: @job_id, state: state.to_s.underscore,
        elapsed_ms: @started.try { |started| Logging.elapsed_ms(started) })
      # Publishing a terminal snapshot is this job's final access to shared
      # application state. The UI may reset/start immediately; joining the
      # Isolated context here would yield inside a native callback.
      @mutex.synchronize do
        @snapshot = @snapshot.copy_with(state: state, output: output, error: error, field: field,
          elapsed: @started.try { |start| Time.instant - start } || Time::Span.zero)
      end
    end
  end
end
