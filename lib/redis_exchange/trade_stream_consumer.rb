# frozen_string_literal: true

require 'json'

module RedisExchange
  # TradeStreamConsumer
  # -------------------
  # Encapsulates Redis Streams consumer-group operations for `trades:{symbol}`.
  # Provides helpers to create/ensure consumer group, read entries, and ack.
  #
  # Default semantics:
  # - Group is created at '0' (consume existing backlog) unless overridden.
  # - Reads with XREADGROUP and stream id '>' (deliver new or pending to this consumer).
  # - Normalizes Redis gem return types to a uniform array of entries.
  class TradeStreamConsumer
    Entry = Struct.new(:stream, :id, :fields)

    attr_reader :redis, :symbol, :stream_key, :group, :consumer

    def initialize(redis:, symbol:, group:, consumer:)
      @redis = redis
      @symbol = symbol
      @stream_key = "trades:#{symbol}"
      @group = group
      @consumer = consumer
    end

    # Ensure the consumer group exists; create starting at `start_id`.
    # Use '0' to consume existing backlog; use '$' to start from the end.
    def ensure_group(start_id: '0')
      begin
        @redis.xgroup(:create, stream_key, group, start_id, mkstream: true)
      rescue StandardError => e
        # Ignore group exists errors; different Redis drivers raise different messages
        msg = e.message.to_s.downcase
        return if msg.include?('busygroup') || msg.include?('exists')
        raise
      end
      true
    end

    # Read a batch of entries as Entry objects.
    # Returns [] on timeout or when no entries are available.
    def read(count: 100, block_ms: 2000)
      # Use positional args form to support older redis-rb versions
      raw = @redis.xreadgroup(group, consumer, stream_key, '>', count: count, block: block_ms)
      normalize_read_result(raw)
    end

    # Convenience loop: continuously read and yield entries to the given block.
    # Stops when the block returns :halt. If auto_ack is true, ack after block
    # executes successfully (no exception raised).
    #
    # Example:
    #   consumer.each(count: 100, block_ms: 2000, auto_ack: true) do |entry|
    #     persist(entry)
    #     # return :halt to stop the loop
    #   end
    def each(count: 100, block_ms: 2000, auto_ack: false)
      raise ArgumentError, 'block required' unless block_given?
      loop do
        entries = read(count: count, block_ms: block_ms)
        next if entries.empty?

        entries.each do |e|
          begin
            result = yield e
            ack(e.id) if auto_ack
            return if result == :halt
          rescue StandardError => err
            warn "[#{self.class.name}] error processing #{stream_key} #{e.id}: #{err.message}"
            # Do not ack on error; pending entries can be retried/claimed later
          end
        end
      end
    end

    # Acknowledge an entry id back to the consumer group.
    def ack(entry_id)
      @redis.xack(stream_key, group, entry_id)
    end

    # Inspect pending summary (XPENDING without range) for monitoring.
    def pending_summary
      @redis.xpending(stream_key, group)
    end

    # Claim idle pending entries older than min_idle_ms for this consumer.
    # Returns claimed entry ids.
    def claim_idle(min_idle_ms: 60_000, count: 10)
      summary = @redis.xpending(stream_key, group, '-', '+', count, consumer)
      ids = Array(summary).map { |row| row.is_a?(Array) ? row[0] : row['entry_id'] }.compact
      ids = ids.first(count)
      return [] if ids.empty?
      @redis.xclaim(stream_key, group, consumer, min_idle_ms, ids)
      ids
    end

    private

    # Normalize Redis gem return into [Entry].
    def normalize_read_result(raw)
      return [] if raw.nil? || (raw.respond_to?(:empty?) && raw.empty?)

      # Redis >= 5 typically returns a Hash: { stream_key => [[entry_id, [k1, v1, ...]], ...] }
      if raw.is_a?(Hash)
        entries = []
        list = raw[stream_key] || []
        list.each do |pair|
          id, fields = pair
          entries << Entry.new(stream_key, id, fields_to_hash(fields))
        end
        return entries
      end

      # Fallback for array forms
      # [[stream, [[id, [k, v, ...]], ...]]]
      if raw.is_a?(Array)
        entries = []
        raw.each do |stream_and_entries|
          stream, pairs = stream_and_entries
          Array(pairs).each do |pair|
            id, fields = pair
            entries << Entry.new(stream.to_s, id, fields_to_hash(fields))
          end
        end
        return entries
      end

      []
    end

    def fields_to_hash(fields)
      return fields if fields.is_a?(Hash)
      Hash[*Array(fields)]
    end
  end
end