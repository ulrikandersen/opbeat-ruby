require 'thread'
require 'opbeat/subscriber'
require 'opbeat/http_client'
require 'opbeat/worker'
require 'opbeat/transaction'
require 'opbeat/trace'
require 'opbeat/error_message'
require 'opbeat/data_builders'

module Opbeat
  # @api private
  class Client
    include Logging

    KEY = :__opbeat_transaction_key
    LOCK = Mutex.new

    class TransactionInfo
      def current
        Thread.current[KEY]
      end
      def current= transaction
        Thread.current[KEY] = transaction
      end
    end

    # life cycle

    def self.inst
      @instance
    end

    def self.start! config = nil
      return @instance if @instance

      LOCK.synchronize do
        return @instance if @instance
        @instance = new(config).start!
      end
    end

    def self.stop!
      LOCK.synchronize do
        return unless @instance

        @instance.stop!
        @instance = nil
      end
    end

    def initialize config
      @config = config

      @http_client = HttpClient.new config
      @queue = Queue.new

      @data_builders = Struct.new(:transactions, :error_message).new(
        DataBuilders::Transactions.new(config),
        DataBuilders::Error.new(config)
      )

      unless config.disable_performance
        @transaction_info = TransactionInfo.new
        @subscriber = Subscriber.new config, self
      end

      @pending_transactions = []
      @last_sent_transactions = Time.now.utc
    end

    attr_reader :config, :queue, :pending_transactions

    def start!
      info "Starting client"

      @subscriber.register! if @subscriber

      self
    end

    def stop!
      flush_transactions
      kill_worker
      unregister! if @subscriber
    end

    at_exit do
      stop!
    end

    # metrics

    def current_transaction
      @transaction_info.current
    end

    def current_transaction= transaction
      @transaction_info.current = transaction
    end

    def transaction endpoint, kind = nil, result = nil, &block
      if config.disable_performance
        return yield if block_given?
        return nil
      end

      if transaction = current_transaction
        yield transaction if block_given?
        return transaction
      end

      transaction = Transaction.new self, endpoint, kind, result

      self.current_transaction = transaction
      return transaction unless block_given?

      begin
        yield transaction

      ensure
        self.current_transaction = nil
        transaction.done
      end

      transaction
    end

    def trace *args, &block
      if config.disable_performance
        return yield if block_given?
        return nil
      end

      unless transaction = current_transaction
        return yield if block_given?
        return
      end

      transaction.trace(*args, &block)
    end

    def submit_transaction transaction
      ensure_worker_running

      if config.debug_traces
        unless transaction.endpoint == 'Rack'
          debug { Util::Inspector.new.transaction transaction, include_parents: true }
        end
      end

      @pending_transactions << transaction

      if should_send_transactions?
        flush_transactions
      end
    end

    def flush_transactions
      return if @pending_transactions.empty?

      data = @data_builders.transactions.build(@pending_transactions)
      enqueue Worker::PostRequest.new('/transactions/', data)

      @last_sent_transactions = Time.now.utc
      @pending_transactions = []

      true
    end

    # errors

    def set_context context
      @context = context
    end

    def with_context context, &block
      current = @context

      set_context((current || {}).merge(context))

      yield if block_given?
    ensure
      set_context(current)
    end

    def report exception, opts = {}
      return if config.disable_errors
      return unless exception

      ensure_worker_running

      unless exception.backtrace
        exception.set_backtrace caller
      end

      error_message = ErrorMessage.from_exception(config, exception, opts)
      error_message.add_extra(@context) if @context
      data = @data_builders.error_message.build error_message
      enqueue Worker::PostRequest.new('/errors/', data)
    end

    def report_message message, opts = {}
      return if config.disable_errors

      ensure_worker_running

      error_message = ErrorMessage.new(config, message, opts)
      error_message.add_extra(@context) if @context
      data = @data_builders.error_message.build error_message
      enqueue Worker::PostRequest.new('/errors/', data)
    end

    def capture &block
      unless block_given?
        return Kernel.at_exit do
          if $!
            debug $!.inspect
            report $!
          end
        end
      end

      begin
        yield
      rescue Error => e
        raise # Don't capture Opbeat errors
      rescue Exception => e
        report e
        raise
      end
    end

    # releases

    def release rel, opts = {}
      rev = rel[:rev]
      if opts[:inline]
        debug "Sending release #{rev}"
        @http_client.post '/releases/', rel
      else
        debug "Enqueuing release #{rev}"
        enqueue Worker::PostRequest.new('/releases/', rel)
      end
    end

    private

    def enqueue request
      @queue << request
    end

    def start_worker
      return if worker_running?

      if config.disable_worker
        return
      end

      info "Starting worker in thread"

      @worker_thread = Thread.new do
        begin
          Worker.new(config, @queue, @http_client).run
        rescue => e
          fatal "Failed booting worker:\n#{e.inspect}"
          debug e.backtrace.join("\n")
          raise
        end
      end
    end

    def kill_worker
      return unless worker_running?
      @queue << Worker::StopMessage.new
      unless @worker_thread.join(config.worker_quit_timeout)
        error "Failed to wait for worker, not all messages sent"
      end
      @worker_thread = nil
    end

    def ensure_worker_running
      return if worker_running?

      LOCK.synchronize do
        return if worker_running?
        start_worker
      end
    end

    def worker_running?
      @worker_thread && @worker_thread.alive?
    end

    def unregister!
      @subscriber.unregister!
    end

    def should_send_transactions?
      return true if config.transaction_post_interval.nil?

      Time.now.utc - @last_sent_transactions > config.transaction_post_interval
    end

  end
end
