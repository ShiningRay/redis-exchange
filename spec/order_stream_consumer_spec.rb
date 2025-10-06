# frozen_string_literal: true

require 'spec_helper'
require 'redis_exchange/order_stream_consumer'

RSpec.describe RedisExchange::OrderStreamConsumer do
  let(:redis) { RSpec.configuration.redis_factory.call }
  let(:exchange) { RedisExchange::Client.new(redis: redis) }
  let(:symbol) { 'BTCUSDT' }

  before do
    redis.flushdb
    exchange.seed_market(
      symbol: symbol,
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

  it 'reads order events from stream and acknowledges them' do
    # Seed one order then cancel to emit CANCELLED
    exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 100_000_000)
    exchange.place_limit_order(
      symbol: symbol,
      side: 'SELL',
      order_id: 'o-1',
      user_id: 'maker',
      price: 3_000_000,
      quantity: 50_000_000
    )

    exchange.cancel_order('o-1')

    consumer = exchange.order_consumer(symbol: symbol, group: 'orders-consumers', consumer: 'worker-1')
    entries = consumer.read(count: 10, block_ms: 200)
    expect(entries).not_to be_empty
    # We may read OPEN and CANCELLED depending on timing; assert at least one has order_id
    expect(entries.map { |e| e.fields['order_id'] }).to include('o-1')

    entry = entries.find { |e| e.fields['order_id'] == 'o-1' && e.fields['status'] == 'CANCELLED' } || entries.first

    expect(entry.stream).to eq("orders:#{symbol}")
    expect(entry.id).to be_a(String)
    expect(entry.fields).to be_a(Hash)
    expect(entry.fields['symbol']).to eq(symbol)
    expect(entry.fields['order_id']).to eq('o-1')

    acked = consumer.ack(entry.id)
    expect(acked).to be >= 1
  end

  it 'supports breaking the loop via each returning :halt' do
    # Seed an order and cancel to emit events
    exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 100_000_000)
    exchange.place_limit_order(
      symbol: symbol,
      side: 'SELL',
      order_id: 'o-2',
      user_id: 'maker',
      price: 3_000_000,
      quantity: 50_000_000
    )
    exchange.cancel_order('o-2')

    consumer = exchange.order_consumer(symbol: symbol, group: 'orders-consumers', consumer: 'worker-2')
    seen = []
    consumer.each(count: 10, block_ms: 200, auto_ack: true) do |e|
      seen << e.id
      :halt
    end
    expect(seen).not_to be_empty
  end

  after do
    redis.close if redis.respond_to?(:close)
  end
end