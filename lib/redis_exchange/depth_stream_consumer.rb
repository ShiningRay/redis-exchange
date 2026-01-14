# frozen_string_literal: true

require_relative 'stream_consumer'

module RedisExchange
  class DepthStreamConsumer < StreamConsumer
    # Typed wrapper for raw Redis fields
    DepthEvent = Struct.new(
      :id, :symbol, :event_type, :side, :price, :delta, :final_volume, :timestamp
    )

    def initialize(redis:, symbol:, group:, consumer:)
      super(redis: redis, group: group, consumer: consumer, stream_key: "depth:#{symbol}")
      @symbol = symbol
    end

    # Reads and normalizes depth events
    def read_events(count: 100, block_ms: 2000)
      entries = read(count: count, block_ms: block_ms)
      entries.map { |e| normalize_event(e) }
    end

    private

    def normalize_event(entry)
      f = entry.fields
      DepthEvent.new(
        entry.id,
        @symbol,
        f['e'],
        f['s'],
        f['p'].to_i,
        f['d'].to_i,
        f['v'].to_i,
        f['ts'].to_i
      )
    end
  end
end
