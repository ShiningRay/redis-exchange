# frozen_string_literal: true

require 'spec_helper'
require 'redis_exchange/ledger_stream_consumer'

RSpec.describe RedisExchange::LedgerStreamConsumer do
  let(:redis) { RSpec.configuration.redis_factory.call }
  let(:exchange) { RedisExchange::Client.new(redis: redis) }

  before do
    redis.flushdb
    # Seed a market for consistency; not strictly needed for ledger operations
    exchange.seed_market(
      symbol: 'BTCUSDT',
      base_asset: 'BTC',
      quote_asset: 'USDT',
      price_scale: 100,
      quantity_scale: 100_000_000,
      maker_fee_bps: 0,
      taker_fee_bps: 0,
      min_qty: 1,
      min_notional: 1
    )
  end

  it 'reads ledger entries from stream and acknowledges them' do
    # Produce some ledger events via deposit and withdraw
    exchange.deposit(user_id: 'u1', asset: 'USDT', amount: 1_000, timestamp_ms: 1000)
    exchange.withdraw(user_id: 'u1', asset: 'USDT', amount: 200, timestamp_ms: 2000)

    consumer = exchange.ledger_consumer(group: 'ledger-consumers', consumer: 'worker-1')
    entries = consumer.read(count: 10, block_ms: 200)
    expect(entries).not_to be_empty

    # basic shape
    entry = entries.first
    expect(entry.stream).to eq('account_ledger')
    expect(entry.id).to be_a(String)
    expect(entry.fields).to be_a(Hash)
    expect(entry.fields['user_id']).to eq('u1')
    expect(entry.fields['asset']).to eq('USDT')
    expect(%w[available reserved]).to include(entry.fields['bucket'])

    acked = consumer.ack(entry.id)
    expect(acked).to be >= 1
  end

  it 'supports breaking the loop via each returning :halt' do
    # Produce one event
    exchange.deposit(user_id: 'u2', asset: 'USDT', amount: 500, timestamp_ms: 3000)

    consumer = exchange.ledger_consumer(group: 'ledger-consumers', consumer: 'worker-2')
    seen = []
    consumer.each(count: 10, block_ms: 200, auto_ack: true) do |e|
      seen << e.id
      :halt
    end
    expect(seen).not_to be_empty
  end

  it 'exposes pending summary and allows claiming idle entries' do
    # Produce an entry but do not ack to create pending
    exchange.deposit(user_id: 'u3', asset: 'USDT', amount: 100, timestamp_ms: 4000)
    consumer = exchange.ledger_consumer(group: 'ledger-consumers', consumer: 'worker-3')

    # Read without auto ack
    entries = consumer.read(count: 10, block_ms: 200)
    expect(entries).not_to be_empty

    summary = consumer.pending_summary
    expect(summary).to be_a(Array).or be_a(Hash)

    # Claim idle (set tiny idle to allow immediate claim)
    claimed = consumer.claim_idle(min_idle_ms: 1, count: 10)
    expect(claimed).to be_a(Array)
  end

  after do
    redis.close if redis.respond_to?(:close)
  end
end