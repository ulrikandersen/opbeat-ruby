require 'opbeat/util'

module Opbeat
  class Transaction

    DEFAULT_KIND = 'code.custom'.freeze
    DEFAULT_ROOT_SIGNATURE = 'transaction'.freeze

    def initialize client, endpoint, kind = DEFAULT_KIND, result = nil
      @client = client
      @endpoint = endpoint
      @kind = kind
      @result = result

      @timestamp = Util.nearest_minute.to_i
      @start = Time.now.to_f

      @root = Trace.new(self, endpoint, DEFAULT_ROOT_SIGNATURE, nil).start(@start)
      @traces = [@root]
      @notifications = []
    end

    attr_accessor :endpoint, :kind, :result, :duration
    attr_reader :timestamp, :start, :traces, :notifications

    def endpoint= val
      @endpoint = @root.signature = val
    end

    def release
      @client.current_transaction = nil
    end

    def done result = nil
      @result = result

      @root.done
      @duration = @root.duration

      self
    end

    def done?
      @root.done?
    end

    def submit result = nil
      done result

      release

      @client.submit_transaction self
    end

    def trace signature, kind = nil, parents = nil, extra = {}, &block
      trace = Trace.new self, signature, kind, [@root.signature], extra
      traces << trace
      trace.start

      return trace unless block_given?

      begin
        result = yield trace
      ensure
        trace.done
      end

      result
    end

  end
end
