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

    balances = redis.hgetall('balance:maker')
    expect(balances['BTC:available'].to_i).to eq(0)
    expect(balances['BTC:reserved'].to_i).to eq(100_000_000)

    ticker = exchange.ticker(symbol)
    expect(ticker[:best_ask_price]).to eq(3_000_000)
    expect(ticker[:best_ask_volume]).to eq(100_000_000)
    expect(ticker[:best_bid_price]).to eq(0)
    expect(ticker[:best_bid_volume]).to eq(0)
    expect(ticker[:last_price]).to eq(0)

    book = exchange.order_book(symbol)
    expect(book[:asks].map { |row| row[:price] }).to eq([3_000_000])
    expect(book[:asks].first[:volume]).to eq(100_000_000)
    expect(book[:bids]).to be_empty
  end

  it 'cancels a resting order and releases reserved balances' do
    exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 100_000_000)

    exchange.place_limit_order(
      symbol: symbol,
      side: 'SELL',
      order_id: 'cancel-1',
      user_id: 'maker',
      price: 3_000_000,
      quantity: 100_000_000
    )

    outcome = exchange.cancel_order('cancel-1')

    expect(outcome['status']).to eq('CANCELLED')
    queue = redis.lrange('queue:BTCUSDT:SELL:3000000', 0, -1)
    expect(queue).to be_empty

    volume = redis.hgetall('volume:BTCUSDT:SELL')
    expect(volume.fetch('3000000', '0').to_i).to eq(0)

    balances = exchange.balances('maker')
    expect(balances[:'BTC:available']).to eq(100_000_000)
    expect(balances[:'BTC:reserved']).to eq(0)

    order_snapshot = redis.hgetall('order:cancel-1')
    expect(order_snapshot['status']).to eq('CANCELLED')
    expect(order_snapshot['remaining']).to eq('0')
  end

  it 'retrieves typed order snapshot by id' do
    exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 100_000_000)
    exchange.place_limit_order(
      symbol: symbol,
      side: 'SELL',
      order_id: 'query-1',
      user_id: 'maker',
      price: 3_000_000,
      quantity: 100_000_000
    )

    snapshot = exchange.order('query-1')
    expect(snapshot[:order_id]).to eq('query-1')
    expect(snapshot[:symbol]).to eq(symbol)
    expect(snapshot[:side]).to eq('SELL')
    expect(snapshot[:type]).to eq('LIMIT')
    expect(snapshot[:status]).to eq('OPEN')
    expect(snapshot[:price]).to eq(3_000_000)
    expect(snapshot[:quantity]).to eq(100_000_000)
    expect(snapshot[:remaining]).to eq(100_000_000)
    expect(snapshot[:sequence]).to be_a(Integer)
    expect(snapshot[:created_at]).to be_a(Integer)

    expect(exchange.order('nonexistent')).to eq({})
  end

  it 'cancels all orders for a user without touching other users' do
    exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 200_000_000)
    exchange.place_limit_order(
      symbol: symbol,
      side: 'SELL',
      order_id: 'bulk-1',
      user_id: 'maker',
      price: 3_000_000,
      quantity: 100_000_000
    )
    exchange.place_limit_order(
      symbol: symbol,
      side: 'SELL',
      order_id: 'bulk-2',
      user_id: 'maker',
      price: 3_100_000,
      quantity: 100_000_000
    )

    exchange.set_balance(user_id: 'other', asset: 'BTC', available: 100_000_000)
    exchange.place_limit_order(
      symbol: symbol,
      side: 'SELL',
      order_id: 'other-1',
      user_id: 'other',
      price: 3_200_000,
      quantity: 100_000_000
    )

    cancelled = exchange.cancel_all_orders('maker')

    expect(cancelled.map { |row| row['order_id'] }).to match_array(%w[bulk-1 bulk-2])

    expect(redis.lrange('queue:BTCUSDT:SELL:3000000', 0, -1)).to be_empty
    expect(redis.lrange('queue:BTCUSDT:SELL:3100000', 0, -1)).to be_empty
    expect(redis.lrange('queue:BTCUSDT:SELL:3200000', 0, -1)).to eq(['other-1'])

    volume = redis.hgetall('volume:BTCUSDT:SELL')
    expect(volume.fetch('3000000', '0').to_i).to eq(0)
    expect(volume.fetch('3100000', '0').to_i).to eq(0)
    expect(volume.fetch('3200000', '0').to_i).to eq(100_000_000)

    balances = exchange.balances('maker')
    expect(balances[:'BTC:available']).to eq(200_000_000)
    expect(balances[:'BTC:reserved']).to eq(0)

    %w[bulk-1 bulk-2].each do |order_id|
      snapshot = redis.hgetall("order:#{order_id}")
      expect(snapshot['status']).to eq('CANCELLED')
      expect(snapshot['remaining']).to eq('0')
    end

    other_snapshot = redis.hgetall('order:other-1')
    expect(other_snapshot['status']).to eq('OPEN')
    expect(other_snapshot['remaining']).to eq('100000000')

    book = exchange.order_book(symbol)
    ask_entry = book[:asks].find { |row| row[:price] == 3_200_000 }
    expect(ask_entry).not_to be_nil
    expect(ask_entry[:volume]).to eq(100_000_000)
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

    balances = redis.hgetall('balance:maker')
    expect(balances['BTC:available'].to_i).to eq(0)
    expect(balances['BTC:reserved'].to_i).to eq(100_000_000)
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

    bob_balances = redis.hgetall('balance:bob')
    expect(bob_balances['BTC:reserved'].to_i).to eq(50_000_000)
    expect(bob_balances['USDT:available'].to_i).to be > 0

    ticker = exchange.ticker(symbol)
    expect(ticker[:last_price]).to eq(3_000_000)
    expect(ticker[:best_ask_price]).to eq(3_000_000)
    expect(ticker[:best_ask_volume]).to eq(50_000_000)
    expect(ticker[:best_bid_price]).to eq(0)
    expect(ticker[:best_bid_volume]).to eq(0)

    book = exchange.order_book(symbol)
    expect(book[:asks].first[:price]).to eq(3_000_000)
    expect(book[:asks].first[:volume]).to eq(50_000_000)
    expect(book[:bids]).to be_empty

    # Verify trades returned in response
    trades = result['trades']
    expect(trades).to be_an(Array)
    expect(trades.size).to eq(1)
    trade = trades.first
    expect(trade['taker_order_id']).to eq('taker-1')
    expect(trade['maker_order_id']).to eq('maker-1')
    expect(trade['buy_order_id']).to eq('taker-1')
    expect(trade['sell_order_id']).to eq('maker-1')
    expect(trade['taker_side']).to eq('BUY')
    expect(trade['price']).to eq(3_000_000)
    expect(trade['quantity']).to eq(50_000_000)
    expect(trade['timestamp']).to be_a(Integer)

    # Verify trade stream entry in Redis (values stored as strings)
    stream_entries = redis.xrevrange('trades:BTCUSDT', '+', '-', count: 1)
    expect(stream_entries).not_to be_empty
    entry_id, fields = stream_entries.first
    fields_hash = fields.is_a?(Hash) ? fields : Hash[*fields]
    expect(fields_hash['taker_order_id']).to eq('taker-1')
    expect(fields_hash['maker_order_id']).to eq('maker-1')
    expect(fields_hash['buy_order_id']).to eq('taker-1')
    expect(fields_hash['sell_order_id']).to eq('maker-1')
    expect(fields_hash['taker_side']).to eq('BUY')
    expect(fields_hash['price']).to eq('3000000')
    expect(fields_hash['quantity']).to eq('50000000')
    expect(fields_hash['symbol']).to eq('BTCUSDT')
  end

  after do
    redis.close if redis.respond_to?(:close)
  end
end
