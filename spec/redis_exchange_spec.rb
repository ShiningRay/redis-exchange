# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe RedisExchange::Client do
  let(:redis) { RSpec.configuration.redis_factory.call }
  let(:exchange) { described_class.new(redis: redis) }
  let(:symbol) { 'BTCUSDT' }

  before do
    redis.flushdb
    exchange.seed_market(
      symbol: symbol,
      base_asset: 'BTC',
      quote_asset: 'USDT',
      price_scale: 100,
      quantity_scale: 100_000_000,
      maker_fee_bps: 5,
      taker_fee_bps: 10,
      min_qty: 100_000,
      min_notional: 1_000
    )
  end

  it 'rests a limit order when no opposite liquidity exists' do
    exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 100_000_000)

    result = exchange.place_limit_order(
      symbol: symbol,
      side: 'SELL',
      order_id: 'order-1',
      user_id: 'maker',
      price: 3_000_000,
      quantity: 100_000_000
    )

    expect(result['status']).to eq('OPEN')
    expect(result['remaining_quantity']).to eq(100_000_000)
    queue = redis.lrange('queue:BTCUSDT:SELL:3000000', 0, -1)
    expect(queue).to eq(['order-1'])

    ticker = exchange.ticker(symbol)
    expect(ticker[:best_ask_price]).to eq(3_000_000)
    expect(ticker[:best_ask_volume]).to eq(100_000_000)
    expect(ticker[:best_bid_price]).to eq(0)
    expect(ticker[:best_bid_volume]).to eq(0)
    expect(ticker[:last_price]).to eq(0)
  end

  it 'rejects a duplicate limit order with the same order_id' do
    exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 100_000_000)

    first = exchange.place_limit_order(
      symbol: symbol,
      side: 'SELL',
      order_id: 'dupe-1',
      user_id: 'maker',
      price: 3_000_000,
      quantity: 100_000_000
    )

    expect(first['status']).to eq('OPEN')

    duplicate = exchange.place_limit_order(
      symbol: symbol,
      side: 'SELL',
      order_id: 'dupe-1',
      user_id: 'maker',
      price: 3_000_000,
      quantity: 100_000_000
    )

    expect(duplicate['error']).to eq('DUPLICATE_ORDER_ID')
    queue = redis.lrange('queue:BTCUSDT:SELL:3000000', 0, -1)
    expect(queue).to eq(%w[dupe-1])
  end

  it 'matches a market order against resting liquidity' do
    exchange.set_balance(user_id: 'bob', asset: 'BTC', available: 200_000_000)
    exchange.place_limit_order(
      symbol: symbol,
      side: 'SELL',
      order_id: 'maker-1',
      user_id: 'bob',
      price: 3_000_000,
      quantity: 100_000_000
    )

    exchange.set_balance(user_id: 'alice', asset: 'USDT', available: 5_000_000)

    result = exchange.place_market_order(
      symbol: symbol,
      side: 'BUY',
      order_id: 'taker-1',
      user_id: 'alice',
      quantity: 50_000_000,
      price_cap: 3_100_000
    )

    expect(result['status']).to eq('FILLED')
    expect(result['executed_quantity']).to eq(50_000_000)
    alice_balances = redis.hgetall('balance:alice')
    expect(alice_balances['BTC:available'].to_i).to eq(50_000_000)
    expect(alice_balances['USDT:available'].to_i).to be < 5_000_000

    ticker = exchange.ticker(symbol)
    expect(ticker[:last_price]).to eq(3_000_000)
    expect(ticker[:best_ask_price]).to eq(3_000_000)
    expect(ticker[:best_ask_volume]).to eq(50_000_000)
    expect(ticker[:best_bid_price]).to eq(0)
    expect(ticker[:best_bid_volume]).to eq(0)
  end

  after do
    redis.close if redis.respond_to?(:close)
  end
end
