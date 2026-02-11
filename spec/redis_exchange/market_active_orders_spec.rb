# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Market Active Orders' do
  let(:redis) { RSpec.configuration.redis_factory.call }
  let(:exchange) { RedisExchange::Client.new(redis: redis) }
  let(:symbol) { 'BTCUSDT' }

  before do
    redis.flushdb
    exchange.seed_asset(asset: 'BTC', balance_scale: 1, status: 'ACTIVE')
    exchange.seed_asset(asset: 'USDT', balance_scale: 1, status: 'ACTIVE')
    exchange.seed_market(
      symbol: symbol,
      base_asset: 'BTC',
      quote_asset: 'USDT',
      price_scale: 1,
      quantity_scale: 1,
      min_qty: 1,
      min_notional: 1,
      status: 'OPEN'
    )
    
    # Fund users
    exchange.set_balance(user_id: 'u1', asset: 'USDT', available: 1_000_000)
    exchange.set_balance(user_id: 'u2', asset: 'BTC', available: 10_000)
  end

  it 'returns all active orders from the book' do
    # Place a BUY order
    res1 = exchange.place_limit_order(
      symbol: symbol,
      side: 'BUY',
      order_id: 'buy-1',
      user_id: 'u1',
      price: 100,
      quantity: 10
    )
    expect(res1[:error]).to be_nil
    
    # Place a SELL order
    res2 = exchange.place_limit_order(
      symbol: symbol,
      side: 'SELL',
      order_id: 'sell-1',
      user_id: 'u2',
      price: 110,
      quantity: 5
    )
    expect(res2[:error]).to be_nil
    
    orders = exchange.market_active_orders(symbol: symbol)
    expect(orders.size).to eq(2)
    
    buy_order = orders.find { |o| o[:side] == 'BUY' }
    expect(buy_order[:order_id]).to eq('buy-1')
    expect(buy_order[:price]).to eq(100)
    
    sell_order = orders.find { |o| o[:side] == 'SELL' }
    expect(sell_order[:order_id]).to eq('sell-1')
    expect(sell_order[:price]).to eq(110)
  end
  
  it 'does not return filled orders' do
    # Place matching orders
    exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'buy-1', user_id: 'u1', price: 100, quantity: 10)
    exchange.place_limit_order(symbol: symbol, side: 'SELL', order_id: 'sell-1', user_id: 'u2', price: 100, quantity: 10)
    
    orders = exchange.market_active_orders(symbol: symbol)
    expect(orders).to be_empty
  end

  describe '#market_order_count' do
    it 'returns correct count for an empty book' do
      count = exchange.market_order_count(symbol: symbol)
      expect(count[:total]).to eq(0)
      expect(count[:buy]).to eq(0)
      expect(count[:sell]).to eq(0)
    end

    it 'returns correct count with buy and sell orders' do
      exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'buy-1', user_id: 'u1', price: 100, quantity: 10)
      exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'buy-2', user_id: 'u1', price: 99, quantity: 10)
      exchange.place_limit_order(symbol: symbol, side: 'SELL', order_id: 'sell-1', user_id: 'u2', price: 110, quantity: 5)

      count = exchange.market_order_count(symbol: symbol)
      expect(count[:total]).to eq(3)
      expect(count[:buy]).to eq(2)
      expect(count[:sell]).to eq(1)
    end

    it 'updates count when orders are matched' do
      exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'buy-1', user_id: 'u1', price: 100, quantity: 10)
      exchange.place_limit_order(symbol: symbol, side: 'SELL', order_id: 'sell-1', user_id: 'u2', price: 100, quantity: 5)

      count = exchange.market_order_count(symbol: symbol)
      expect(count[:total]).to eq(1)
      expect(count[:buy]).to eq(1)
      expect(count[:sell]).to eq(0)
    end

    it 'updates count when orders are cancelled' do
      exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'buy-1', user_id: 'u1', price: 100, quantity: 10)
      exchange.place_limit_order(symbol: symbol, side: 'SELL', order_id: 'sell-1', user_id: 'u2', price: 110, quantity: 5)

      count = exchange.market_order_count(symbol: symbol)
      expect(count[:total]).to eq(2)

      exchange.cancel_order(order_id: 'buy-1')
      count = exchange.market_order_count(symbol: symbol)
      expect(count[:total]).to eq(1)
      expect(count[:buy]).to eq(0)
      expect(count[:sell]).to eq(1)

      exchange.cancel_order(order_id: 'sell-1')
      count = exchange.market_order_count(symbol: symbol)
      expect(count[:total]).to eq(0)
    end

    it 'counts multiple orders at same price level' do
      exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'buy-1', user_id: 'u1', price: 100, quantity: 10)
      exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'buy-2', user_id: 'u1', price: 100, quantity: 10)
      exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'buy-3', user_id: 'u1', price: 100, quantity: 10)

      count = exchange.market_order_count(symbol: symbol)
      expect(count[:total]).to eq(3)
      expect(count[:buy]).to eq(3)
    end
  end
end
