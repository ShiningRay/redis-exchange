# frozen_string_literal: true

require_relative 'stream_consumer'

module RedisExchange
  # OrderStreamConsumer
  # -------------------
  # Encapsulates Redis Streams consumer-group operations for `orders:{symbol}`.
  class OrderStreamConsumer < StreamConsumer
    attr_reader :symbol

    def initialize(redis:, symbol:, group:, consumer:)
      @symbol = symbol
      super(redis: redis, group: group, consumer: consumer, stream_key: "orders:#{symbol}")
    end
  end
end
