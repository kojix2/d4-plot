require "./conversion"

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
    progress : ConversionProgress = ConversionProgress.new("Ready"),
    output : String? = nil, error : String? = nil, field : String? = nil,
    elapsed : Time::Span = Time::Span.zero

  # One conversion, independent of view reads. No worker callback touches UIng.
  class ConversionWorker
    @mutex = Thread::Mutex.new
    @control = ConversionControl.new
    @snapshot = ConversionSnapshot.new
    @worker : Fiber::ExecutionContext::Isolated?
    @started : Time::Instant?

    def start(request : ConversionRequest)
      raise "A D4 creation is already running." if snapshot.state.active?
      wait
      @control = ConversionControl.new
      @started = Time.instant
      @mutex.synchronize { @snapshot = ConversionSnapshot.new(ConversionState::Running) }
      @worker = Fiber::ExecutionContext::Isolated.new("d4-plot-converter") do
        begin
          output = D4Converter.new.run(request, @control, ->(event : ConversionProgress) {
            @mutex.synchronize { @snapshot = @snapshot.copy_with(progress: event) }
            nil
          })
          finish(ConversionState::Succeeded, output: output)
        rescue ConversionCancelled
          finish(ConversionState::Cancelled)
        rescue ex : ConversionError
          finish(ConversionState::Failed, error: ex.message, field: ex.field)
        rescue ex
          finish(ConversionState::Failed, error: ex.message || ex.class.name)
        end
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
      return unless @control.cancel
      @mutex.synchronize do
        @snapshot = @snapshot.copy_with(state: ConversionState::Cancelling) if @snapshot.state.running?
      end
    end

    def wait
      @worker.try(&.wait)
    end

    def reset
      raise "A D4 creation is still running." if snapshot.state.active?
      wait
      @mutex.synchronize { @snapshot = ConversionSnapshot.new }
    end

    private def finish(state, output : String? = nil, error : String? = nil, field : String? = nil)
      @mutex.synchronize do
        @snapshot = @snapshot.copy_with(state: state, output: output, error: error, field: field,
          elapsed: @started.try { |start| Time.instant - start } || Time::Span.zero)
      end
    end
  end
end
