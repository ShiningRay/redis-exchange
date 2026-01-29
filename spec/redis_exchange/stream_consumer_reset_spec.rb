# frozen_string_literal: true

require 'spec_helper'
require 'redis_exchange/stream_consumer'

RSpec.describe RedisExchange::StreamConsumer do
  # Override 'exchange' because spec/support/redis_exchange_setup.rb expects described_class
  # to be RedisExchange::Client, but here it is StreamConsumer.
  # We need a Client instance for the shared 'before' block to run successfully.
  let(:exchange) { RedisExchange::Client.new(redis: redis) }

  let(:redis) { RSpec.configuration.redis_factory.call }
  let(:stream_key) { 'test:stream:reset' }
  let(:group) { 'test-group' }
  let(:consumer_name) { 'test-consumer' }
  let(:consumer) do
    described_class.new(
      redis: redis,
      stream_key: stream_key,
      group: group,
      consumer: consumer_name
    )
  end

  before do
    redis.del(stream_key)
    consumer.ensure_group(start_id: '0')
  end

  describe '#reset_offset' do
    it 'resets the consumer group offset to allow re-reading messages' do
      # 1. Add messages
      id1 = redis.xadd(stream_key, { data: 'msg1' })
      id2 = redis.xadd(stream_key, { data: 'msg2' })

      # 2. Read messages (consuming them)
      entries = consumer.read(count: 2, id: '>')
      expect(entries.size).to eq(2)
      expect(entries.map(&:id)).to contain_exactly(id1, id2)

      # 3. Read again -> should be empty (all consumed)
      entries_empty = consumer.read(count: 2, id: '>')
      expect(entries_empty).to be_empty

      # 4. Reset offset to 0
      consumer.reset_offset(id: '0')

      # 5. Read again -> should get messages again
      entries_retry = consumer.read(count: 2, id: '>')
      expect(entries_retry.size).to eq(2)
      expect(entries_retry.map(&:id)).to contain_exactly(id1, id2)
    end

    it 'can reset to a specific message ID' do
      id1 = redis.xadd(stream_key, { data: 'msg1' })
      id2 = redis.xadd(stream_key, { data: 'msg2' })

      # Read all
      consumer.read(count: 2, id: '>')

      # Reset to after id1 (so we should only get id2)
      consumer.reset_offset(id: id1)

      entries = consumer.read(count: 2, id: '>')
      expect(entries.size).to eq(1)
      expect(entries.first.id).to eq(id2)
    end
  end
end
