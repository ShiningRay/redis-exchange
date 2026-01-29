# frozen_string_literal: true

require 'json'

module RedisExchange
  # StreamConsumer
  # --------------
  # Base class for Redis Streams consumer-group operations.
  # Provides common logic for ensure_group, read, ack, pending, and claim.
  class StreamConsumer
    Entry = Struct.new(:stream, :id, :fields)

    attr_reader :redis, :stream_key, :group, :consumer

    def initialize(redis:, group:, consumer:, stream_key:)
      @redis = redis
      @group = group
      @consumer = consumer
      @stream_key = stream_key
    end

    # Ensure the consumer group exists; create starting at `start_id`.
    # Use '0' to consume existing backlog; use '$' to start from the end.
    def ensure_group(start_id: '0')
      begin
        @redis.xgroup(:create, stream_key, group, start_id, mkstream: true)
      rescue StandardError => e
        # Ignore group exists errors across redis-rb versions
        msg = e.message.to_s.downcase
        return if msg.include?('busygroup') || msg.include?('exists')
        raise
      end
      true
    end

    # Read a batch of entries as Entry objects.
    # Returns [] on timeout or when no entries are available.
    # @param id [String] '>' for new entries, '0' for pending entries
    def read(count: 100, block_ms: 2000, id: '>')
      # Use positional args form to support older redis-rb versions
      raw = @redis.xreadgroup(group, consumer, stream_key, id, count: count, block: block_ms)
      normalize_read_result(raw)
    end

    # Convenience loop: continuously read and yield entries to the given block.
    # Stops when the block returns :halt. If auto_ack is true, ack after block
    # executes successfully (no exception raised).
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

    # Get the consumer group lag (number of messages not yet delivered to the group).
    # Returns Integer (lag) or nil if lag cannot be determined.
    def lag
      groups = @redis.xinfo(:groups, stream_key)
      group_info = groups.find { |g| g['name'] == group }
      return nil unless group_info

      # Redis returns 'lag' field; if nil, it means calculation is pending or not applicable
      group_info['lag']
    end

    # Claim idle pending entries older than min_idle_ms for this consumer.
    # Returns claimed Entry objects.
    def claim_idle(min_idle_ms: 60_000, count: 10)
      # Find pending entries from any consumer that are idle
      summary = @redis.xpending(stream_key, group, '-', '+', count)
      ids = Array(summary).map { |row| row.is_a?(Array) ? row[0] : row['entry_id'] }.compact
      return [] if ids.empty?

      # Claim them - this moves them to our PEL and returns the message content
      raw = @redis.xclaim(stream_key, group, consumer, min_idle_ms, ids)
      
      # xclaim returns entries in a slightly different format than xreadgroup
      # Format: [[id, [k, v, ...]], ...]
      entries = []
      Array(raw).each do |pair|
        id, fields = pair
        entries << Entry.new(stream_key, id, fields_to_hash(fields))
      end
      entries
    end

    # Manually trim the stream to a maximum length.
    # @param maxlen [Integer] Maximum number of entries to keep
    # @param approximate [Boolean] Whether to use approximate trimming (~), which is more efficient
    # @return [Integer] Number of entries removed
    def trim(maxlen:, approximate: true)
      @redis.xtrim(stream_key, maxlen, approximate: approximate)
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
