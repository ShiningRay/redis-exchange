# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RedisExchange::Client, "Order Book Limit" do
  let(:redis) { RSpec.configuration.redis_factory.call }
  let(:exchange) { RedisExchange::Client.new(redis: redis) }
  let(:symbol) { 'BTCUSDT' }

  before do
    redis.flushdb
    exchange.seed_asset(asset: 'BTC', balance_scale: 100_000_000, status: 'ACTIVE')
    exchange.seed_asset(asset: 'USDT', balance_scale: 100, status: 'ACTIVE')
    exchange.seed_market(symbol: symbol, base_asset: 'BTC', quote_asset: 'USDT', status: 'OPEN')
    
    # Fund users
    exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 10_000_000_000)
    exchange.set_balance(user_id: 'maker', asset: 'USDT', available: 1_000_000_000)

    # Place Bids (Buy)
    # Price 100, 90, 80
    exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'b1', user_id: 'maker', price: 100, quantity: 1)
    exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'b2', user_id: 'maker', price: 90, quantity: 1)
    exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'b3', user_id: 'maker', price: 80, quantity: 1)

    # Place Asks (Sell)
    # Price 110, 120, 130
    exchange.place_limit_order(symbol: symbol, side: 'SELL', order_id: 's1', user_id: 'maker', price: 110, quantity: 1)
    exchange.place_limit_order(symbol: symbol, side: 'SELL', order_id: 's2', user_id: 'maker', price: 120, quantity: 1)
    exchange.place_limit_order(symbol: symbol, side: 'SELL', order_id: 's3', user_id: 'maker', price: 130, quantity: 1)
  end

  it "returns top N bids and asks correctly" do
    # Verify full book first
    full_book = exchange.order_book(symbol)
    expect(full_book[:bids].map { |x| x[:price] }).to eq([100, 90, 80])
    expect(full_book[:asks].map { |x| x[:price] }).to eq([110, 120, 130])

    # Verify limit 1
    limit_book = exchange.order_book(symbol, limit: 1)
    expect(limit_book[:bids].map { |x| x[:price] }).to eq([100]) # Best Bid
    expect(limit_book[:asks].map { |x| x[:price] }).to eq([110]) # Best Ask
    
    # Verify limit 2
    limit_book_2 = exchange.order_book(symbol, limit: 2)
    expect(limit_book_2[:bids].map { |x| x[:price] }).to eq([100, 90])
    expect(limit_book_2[:asks].map { |x| x[:price] }).to eq([110, 120])
  end

  describe '#price_level_count' do
    it 'returns correct count for price levels' do
      count = exchange.price_level_count(symbol: symbol)
      expect(count[:total]).to eq(6)
      expect(count[:bids]).to eq(3)
      expect(count[:asks]).to eq(3)
    end

    it 'returns 0 for empty book' do
      exchange.clear_books(symbol)
      count = exchange.price_level_count(symbol: symbol)
      expect(count[:total]).to eq(0)
      expect(count[:bids]).to eq(0)
      expect(count[:asks]).to eq(0)
    end

    it 'updates when orders are matched' do
      # Add a taker order that matches with existing orders
      exchange.set_balance(user_id: 'taker', asset: 'BTC', available: 1_000_000_000)
      exchange.set_balance(user_id: 'taker', asset: 'USDT', available: 10_000_000_000)

      exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'taker_buy', user_id: 'taker', price: 120, quantity: 1)

      # Should match with s2 (price 120)
      count = exchange.price_level_count(symbol: symbol)
      expect(count[:total]).to be < 6
    end

    it 'updates when orders are cancelled' do
      count_before = exchange.price_level_count(symbol: symbol)
      expect(count_before[:total]).to eq(6)

      exchange.cancel_order(order_id: 'b1')
      count_after = exchange.price_level_count(symbol: symbol)
      expect(count_after[:total]).to eq(5)
      expect(count_after[:bids]).to eq(2)

      exchange.cancel_order(order_id: 's1')
      count_final = exchange.price_level_count(symbol: symbol)
      expect(count_final[:total]).to eq(4)
      expect(count_final[:asks]).to eq(2)
    end

    it 'counts multiple orders at same price level as one price level' do
      # Add another order at existing price level
      exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'b4', user_id: 'maker', price: 100, quantity: 2)
      exchange.place_limit_order(symbol: symbol, side: 'SELL', order_id: 's4', user_id: 'maker', price: 110, quantity: 2)

      count = exchange.price_level_count(symbol: symbol)
      # Still 3 bid levels (100, 90, 80) and 3 ask levels (110, 120, 130)
      expect(count[:bids]).to eq(3)
      expect(count[:asks]).to eq(3)
      expect(count[:total]).to eq(6)
    end
  end
end
