# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Market Maintenance Mode', :market_maintenance do
  let(:redis) { RSpec.configuration.redis_factory.call }
  let(:exchange) { RedisExchange::Client.new(redis: redis) }
  let(:symbol) { 'BTCUSDT' }
  let(:other_symbol) { 'ETHUSDT' }

  before do
    redis.flushdb
    exchange.seed_asset(asset: 'BTC', balance_scale: 1, status: 'ACTIVE')
    exchange.seed_asset(asset: 'USDT', balance_scale: 1, status: 'ACTIVE')
    exchange.seed_asset(asset: 'ETH', balance_scale: 1, status: 'ACTIVE')
    
    exchange.seed_market(symbol: symbol, base_asset: 'BTC', quote_asset: 'USDT', status: 'OPEN')
    exchange.seed_market(symbol: other_symbol, base_asset: 'ETH', quote_asset: 'USDT', status: 'OPEN')
    
    exchange.set_balance(user_id: 'u1', asset: 'USDT', available: 10000)
    exchange.set_balance(user_id: 'u1', asset: 'BTC', available: 10)
  end

  after do
    exchange.maintenance.disable_market(symbol)
  end

  it 'allows operations when market maintenance is disabled' do
    res = exchange.place_limit_order(
      symbol: symbol, side: 'BUY', order_id: 'o1', user_id: 'u1', price: 100, quantity: 1
    )
    expect(res[:error]).to be_nil
    
    res = exchange.cancel_order('o1')
    expect(res[:status]).to eq('CANCELLED')
  end

  context 'when market maintenance is enabled' do
    before do
      exchange.maintenance.enable_market(symbol)
    end

    it 'rejects place limit order' do
      res = exchange.place_limit_order(
        symbol: symbol, side: 'BUY', order_id: 'o2', user_id: 'u1', price: 100, quantity: 1
      )
      expect(res[:error]).to eq('MARKET_MAINTENANCE')
    end

    it 'rejects place market order' do
      res = exchange.place_market_order(
        symbol: symbol, side: 'BUY', order_id: 'o3', user_id: 'u1', quantity: 1, price_cap: 100
      )
      expect(res[:error]).to eq('MARKET_MAINTENANCE')
    end

    it 'rejects cancel order' do
      # Pre-create order (need to temporarily disable maintenance to place it, or inject directly)
      exchange.maintenance.disable_market(symbol)
      exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'o4', user_id: 'u1', price: 100, quantity: 1)
      exchange.maintenance.enable_market(symbol)

      res = exchange.cancel_order('o4')
      expect(res[:error]).to eq('MARKET_MAINTENANCE')
    end

    it 'does not affect other markets' do
      res = exchange.place_limit_order(
        symbol: other_symbol, side: 'BUY', order_id: 'o5', user_id: 'u1', price: 100, quantity: 1
      )
      expect(res[:error]).to be_nil
    end
    
    it 'cancel_all_orders handles market maintenance gracefully' do
      # Place order in BTCUSDT (will be maintained)
      exchange.maintenance.disable_market(symbol)
      exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'btc-o1', user_id: 'u1', price: 100, quantity: 1)
      
      # Place order in ETHUSDT (normal)
      exchange.place_limit_order(symbol: other_symbol, side: 'BUY', order_id: 'eth-o1', user_id: 'u1', price: 100, quantity: 1)
      
      exchange.maintenance.enable_market(symbol)
      
      # Cancel all orders
      results = exchange.cancel_all_orders('u1')
      
      # Expect ETH order to be cancelled
      eth_res = results.find { |r| r[:order_id] == 'eth-o1' }
      expect(eth_res[:status]).to eq('CANCELLED')
      
      # Expect BTC order to fail or report error
      btc_res = results.find { |r| r[:order_id] == 'btc-o1' }
      # Depending on implementation, it might be in results with error, or just skipped/failed
      # If we want it to report error:
      if btc_res
        expect(btc_res[:error]).to eq('MARKET_MAINTENANCE')
      end
      
      # Verify BTC order still exists
      order = exchange.order('btc-o1')
      expect(order[:status]).to eq('OPEN')
    end
  end
end
