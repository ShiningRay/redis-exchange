# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Maintenance Mode', :maintenance do
  let(:redis) { RSpec.configuration.redis_factory.call }
  let(:exchange) { RedisExchange::Client.new(redis: redis) }

  before do
    redis.flushdb
    exchange.seed_asset(asset: 'BTC', balance_scale: 1, status: 'ACTIVE')
    exchange.seed_asset(asset: 'USDT', balance_scale: 1, status: 'ACTIVE')
    exchange.seed_market(symbol: 'BTCUSDT', base_asset: 'BTC', quote_asset: 'USDT', status: 'OPEN')
  end

  after do
    exchange.maintenance.disable
  end

  it 'rejects order placement when maintenance mode is active' do
    exchange.maintenance.enable

    result = exchange.place_limit_order(
      symbol: 'BTCUSDT',
      side: 'BUY',
      order_id: 'o1',
      user_id: 'u1',
      price: 100,
      quantity: 10
    )
    expect(result[:error]).to eq('SYSTEM_MAINTENANCE')
  end

  it 'rejects balance changes when maintenance mode is active' do
    exchange.maintenance.enable
    
    result = exchange.add_funds(user_id: 'u1', asset: 'BTC', amount: 100)
    expect(result[:error]).to eq('SYSTEM_MAINTENANCE')
  end

  it 'rejects order cancellation when maintenance mode is active' do
    # Create order first
    exchange.set_balance(user_id: 'u1', asset: 'USDT', available: 1000)
    exchange.place_limit_order(symbol: 'BTCUSDT', side: 'BUY', order_id: 'o1', user_id: 'u1', price: 100, quantity: 1)
    
    exchange.maintenance.enable
    
    result = exchange.cancel_order('o1')
    expect(result[:error]).to eq('SYSTEM_MAINTENANCE')
  end
  
  it 'rejects cancel all orders when maintenance mode is active' do
    exchange.maintenance.enable
    result = exchange.cancel_all_orders('u1')
    expect(result[:error]).to eq('SYSTEM_MAINTENANCE')
  end
end
