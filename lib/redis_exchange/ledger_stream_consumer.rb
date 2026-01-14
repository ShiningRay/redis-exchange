# frozen_string_literal: true

require_relative 'stream_consumer'

module RedisExchange
  # LedgerStreamConsumer
  # --------------------
  # Encapsulates Redis Streams consumer-group operations for `account_ledger`.
  class LedgerStreamConsumer < StreamConsumer
    def initialize(redis:, group:, consumer:, stream_key: 'account_ledger')
      super(redis: redis, group: group, consumer: consumer, stream_key: stream_key)
    end
  end
end
