require "deque"
require "log"
require "./backends"

module D4Plot::Logging
  # A bounded dispatcher for native UI callbacks. Dispatch never yields and
  # the isolated worker is the only thread that writes to a backend.
  class NonBlockingDispatcher
    include ::Log::Dispatcher

    @mutex = Thread::Mutex.new
    @close_mutex = Thread::Mutex.new
    @wake = Thread::ConditionVariable.new
    @queue = Deque(Tuple(::Log::Entry, ::Log::Backend)).new
    @closed = false
    @joined = false
    @dropped = 0
    @worker : Fiber::ExecutionContext::Isolated

    def initialize(@capacity : Int32 = 2048)
      raise ArgumentError.new("Log queue capacity must be positive") unless @capacity > 0
      @worker = Fiber::ExecutionContext::Isolated.new("d4-plot-log") { work }
    end

    def dispatch(entry : ::Log::Entry, backend : ::Log::Backend) : Nil
      @mutex.synchronize do
        return if @closed
        if @queue.size >= @capacity
          @dropped += 1
          return
        end
        @queue << {entry, backend}
        @wake.signal
      end
    end

    # Call only after all producers have stopped. The separate close mutex
    # makes repeated or concurrent backend close calls harmless.
    def close : Nil
      @close_mutex.synchronize do
        return if @joined
        @mutex.synchronize do
          @closed = true
          @wake.signal
        end
        @worker.wait
        @joined = true
      end
    end

    private def next_entry
      @mutex.synchronize do
        while @queue.empty? && !@closed
          @wake.wait(@mutex)
        end
        entry = @queue.shift?
        dropped = @dropped
        @dropped = 0
        {entry, dropped}
      end
    end

    private def work : Nil
      loop do
        item, dropped = next_entry
        break unless item
        entry, backend = item
        if dropped > 0
          backend.write(::Log::Entry.new("d4_plot.logging", :warn, "log.entries_dropped",
            ::Log::Metadata.build({count: dropped}), nil))
        end
        backend.write(entry)
      rescue ex
        # Logging must never make application work fail. Stop this output
        # after any backend/formatter failure and avoid recursive logging.
        StderrOutput.write("d4-plot: log output failed (#{ex.class.name})")
        @mutex.synchronize do
          @queue.clear
          @closed = true
        end
        break
      end
    end
  end
end
