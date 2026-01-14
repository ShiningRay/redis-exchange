# frozen_string_literal: true

require_relative 'stream_consumer'

module RedisExchange
  # TradeStreamConsumer
  # -------------------
  # Encapsulates Redis Streams consumer-group operations for `trades:{symbol}`.
  class TradeStreamConsumer < StreamConsumer
    attr_reader :symbol

    def initialize(redis:, symbol:, group:, consumer:)
      @symbol = symbol
      super(redis: redis, group: group, consumer: consumer, stream_key: "trades:#{symbol}")
    end
  end
end
