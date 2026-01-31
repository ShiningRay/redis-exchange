# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RedisExchange::Client do
  include RedisExchangeSpecSetup

  let(:symbol) { 'BTCUSDT' }
  let(:price_scale) { 100 } # 0.01
  let(:quantity_scale) { 1000 } # 0.001
  let(:balance_scale) { 1000000 } # 0.000001

  before do
    redis.flushdb
    exchange.seed_asset(asset: 'BTC', balance_scale: balance_scale)
    exchange.seed_asset(asset: 'USDT', balance_scale: balance_scale)
    exchange.seed_market(
      symbol: symbol,
      base_asset: 'BTC',
      quote_asset: 'USDT',
      price_scale: price_scale,
      quantity_scale: quantity_scale
    )
  end

  describe '#active_orders with auto_scale' do
    it 'returns unscaled values when auto_scale is true' do
      # Place an order: Price 100.50, Quantity 1.234
      # Scaled Price: 100.50 * 100 = 10050
      # Scaled Quantity: 1.234 * 1000 = 1234
      
      exchange.set_balance(user_id: 'user1', asset: 'BTC', available: 10 * balance_scale)
      
      exchange.place_limit_order(
        symbol: symbol,
        side: 'SELL',
        order_id: 'order-1',
        user_id: 'user1',
        price: 10050,
        quantity: 1234
      )

      # Default behavior (auto_scale: false)
      orders = exchange.active_orders(user_id: 'user1', symbol: symbol)
      expect(orders.first[:price]).to eq(10050)
      expect(orders.first[:quantity]).to eq(1234)
      expect(orders.first[:remaining]).to eq(1234)

      # New behavior (auto_scale: true)
      # Since we haven't implemented it yet, this expectation should fail or argument error
      orders_scaled = exchange.active_orders(user_id: 'user1', symbol: symbol, auto_scale: true)
      
      # We expect floats
      expect(orders_scaled.first[:price]).to eq(100.5)
      expect(orders_scaled.first[:quantity]).to eq(1.234)
      expect(orders_scaled.first[:remaining]).to eq(1.234)
    end
  end
end
