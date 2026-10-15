require "deque"
require "wait_group"

module D4Plot
  # Work runs serially in a dedicated execution context; completions run only in poll.
  # Jobs must capture snapshots, never read controls or mutate UI state.
  class BackgroundIO
    record Job, work : Proc(Nil), done : Proc(Exception?, Nil)
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
        @worker_error = ex
      ensure
        @finished.done
      end
    end

    def submit(work : Proc(Nil), &done : Exception? -> Nil) : Nil
      @mutex.synchronize do
        raise "Background I/O is closed" if @closed
        @jobs << Job.new(work, done)
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
        error = nil
        begin
          job.work.call
        rescue ex
          error = ex
        end
        @mutex.synchronize do
          @results << Result.new(job, error) unless @closed
        end
      end
    end
  end
end
