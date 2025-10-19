# frozen_string_literal: true

require 'spec_helper'
require 'redis_exchange/trade_stream_consumer'
RSpec.describe RedisExchange::TradeStreamConsumer do
  let(:redis) { RSpec.configuration.redis_factory.call }
  let(:exchange) { RedisExchange::Client.new(redis: redis) }
  let(:symbol) { 'BTCUSDT' }

  before do
    redis.flushdb
    exchange.seed_asset(asset: 'BTC', balance_scale: 100_000_000, status: 'ACTIVE')
    exchange.seed_asset(asset: 'USDT', balance_scale: 100, status: 'ACTIVE')
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

  it 'reads trades from stream and acknowledges them' do
    # Seed one trade by matching
    exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 100_000_000)
    exchange.place_limit_order(
      symbol: symbol,
      side: 'SELL',
      order_id: 'maker-1',
      user_id: 'maker',
      price: 3_000_000,
      quantity: 50_000_000
    )

    exchange.set_balance(user_id: 'taker', asset: 'USDT', available: 1_000_000_000)
    exchange.place_market_order(
      symbol: symbol,
      side: 'BUY',
      order_id: 'taker-1',
      user_id: 'taker',
      quantity: 50_000_000,
      price_cap: 3_100_000
    )

    consumer = exchange.trade_consumer(symbol: symbol, group: 'trades-consumers', consumer: 'worker-1')
    entries = consumer.read(count: 10, block_ms: 100)
    expect(entries).not_to be_empty
    entry = entries.first

    # basic shape
    expect(entry.stream).to eq("trades:#{symbol}")
    expect(entry.id).to be_a(String)
    expect(entry.fields).to be_a(Hash)
    expect(entry.fields['symbol']).to eq(symbol)
    expect(entry.fields['price']).to eq('3000000')

    # ack should succeed
    acked = consumer.ack(entry.id)
    expect(acked).to be >= 1
  end

  it 'supports breaking the loop via each returning :halt' do
    # Seed one trade
    exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 100_000_000)
    exchange.place_limit_order(
      symbol: symbol,
      side: 'SELL',
      order_id: 'maker-2',
      user_id: 'maker',
      price: 3_000_000,
      quantity: 50_000_000
    )

    exchange.set_balance(user_id: 'taker', asset: 'USDT', available: 1_000_000_000)
    exchange.place_market_order(
      symbol: symbol,
      side: 'BUY',
      order_id: 'taker-2',
      user_id: 'taker',
      quantity: 10_000_000,
      price_cap: 3_100_000
    )

    consumer = exchange.trade_consumer(symbol: symbol, group: 'trades-consumers', consumer: 'worker-2')
    seen = []
    consumer.each(count: 10, block_ms: 100, auto_ack: true) do |e|
      seen << e.id
      :halt
    end
    expect(seen).not_to be_empty
  end

  after do
    redis.close if redis.respond_to?(:close)
  end
end