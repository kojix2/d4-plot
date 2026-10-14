module D4Plot
  module UIRuntime
    {% if flag?(:darwin) %}
      lib NativeThread
        fun main? = pthread_main_np : Int32
      end
    {% end %}

    def self.check_thread! : Nil
      {% if flag?(:darwin) %}
        raise "Native UI must run on the process main thread" if NativeThread.main? == 0
      {% end %}
    end

    def self.prepare : Nil
      check_thread!
      # The native loop occupies one scheduler. Leave another available for
      # Crystal's signal loop and ordinary background fibers.
      Fiber::ExecutionContext.default.resize(2)
    end

    # Startup only: wait without yielding the caller's OS thread. Never use
    # this in a UI callback; submit asynchronous work there instead.
    def self.load(&block : -> T) : T forall T
      mutex = Thread::Mutex.new
      wake = Thread::ConditionVariable.new
      done = false
      result = nil.as(T?)
      error = nil.as(Exception?)
      Fiber::ExecutionContext::Isolated.new("d4-plot-startup") do
        result = block.call
      rescue ex
        error = ex
      ensure
        mutex.synchronize do
          done = true
          wake.signal
        end
      end
      mutex.synchronize do
        until done
          wake.wait(mutex)
        end
      end
      if exception = error
        raise exception
      end
      {% if T == NoReturn %}
        raise "Startup operation returned unexpectedly"
      {% else %}
        result.as(T)
      {% end %}
    end
  end
end
