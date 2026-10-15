require "deque"
require "wait_group"
require "./log"

module D4Plot
  # Work runs serially in a dedicated execution context; completions run only in poll.
  # Jobs must capture snapshots, never read controls or mutate UI state.
  class BackgroundIO
    Log = D4Plot::Log.for("background_io")

    record Job, id : Int64, operation : String, work : Proc(Nil), done : Proc(Exception?, Nil)
    record Result, job : Job, error : Exception?

    @mutex = Thread::Mutex.new
    @wake = Thread::ConditionVariable.new
    @jobs = Deque(Job).new
    @results = Deque(Result).new
    @closed = false
    @context : Fiber::ExecutionContext::Concurrent
    @finished = WaitGroup.new(1)
    @worker_error : Exception?

    def initialize
      @context = Fiber::ExecutionContext::Concurrent.new("d4-plot-io")
      @context.spawn do
        run
      rescue ex
        Logging.report_exception(Log, "io.worker_failed", ex)
        @worker_error = ex
      ensure
        @finished.done
      end
    end

    def submit(work : Proc(Nil), *, operation : String, &done : Exception? -> Nil) : Nil
      @mutex.synchronize do
        raise "Background I/O is closed" if @closed
        @jobs << Job.new(Logging.next_correlation_id, operation, work, done)
        @wake.signal
      end
    end

    def poll : Nil
      # One completion per tick bounds callback work and permits shutdown
      # from inside a completion without invoking any later callbacks.
      result = @mutex.synchronize { @results.shift? unless @closed }
      result.try { |value| value.job.done.call(value.error) }
    end

    # Drain accepted writes even when the user closes the window immediately.
    def close : Nil
      @mutex.synchronize do
        @closed = true
        @results.clear
        @wake.signal
      end
    end

    # Only after native UI teardown (or in non-UI tests).
    def wait : Nil
      @finished.wait
      if error = @worker_error
        raise error
      end
    end

    private def next_job : Job?
      @mutex.synchronize do
        while @jobs.empty? && !@closed
          @wake.wait(@mutex)
        end
        @jobs.shift?
      end
    end

    private def run : Nil
      while job = next_job
        started = Time.instant
        Log.debug &.emit("io.started", job_id: job.id, operation: job.operation)
        error = nil
        begin
          job.work.call
        rescue ex
          Logging.report_exception(Log, "io.failed", ex, job_id: job.id, operation: job.operation)
          error = ex
        end
        Log.info &.emit("io.finished", job_id: job.id, operation: job.operation, failed: !error.nil?, elapsed_ms: Logging.elapsed_ms(started))
        @mutex.synchronize do
          @results << Result.new(job, error) unless @closed
        end
      end
    end
  end
end
