# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Numeric precision bounds', :precision_bounds do
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

  context 'limit orders' do
    it 'flags overflow when price*quantity exceeds approx 9e15' do
      # overflow should now be handled in both Ruby and Lua layers

      exchange.set_balance(user_id: 'maker_overflow', asset: 'BTC', available: 10_000_000_000_000_000)

    result = exchange.place_limit_order(
      symbol: symbol,
      side: 'SELL',
      order_id: 'overflow-limit-1',
      user_id: 'maker_overflow',
      price: 10_000_000_000,
      quantity: 1_000_000_000
    )

    expect(result[:error]).to eq('PRECISION_OVERFLOW')
    end

    it 'accepts near-threshold price*quantity without overflow' do
      exchange.set_balance(user_id: 'maker_near', asset: 'BTC', available: 9_000_000_000_000_000)

      result = exchange.place_limit_order(
        symbol: symbol,
        side: 'SELL',
        order_id: 'near-limit-1',
        user_id: 'maker_near',
        price: 4_500_000_000,
        quantity: 2_000_000
      )

      expect(result[:status]).to eq('OPEN')
      expect(result[:error]).to be_nil
    end
  end

  context 'market orders' do
    it 'flags overflow when matching would exceed precision bounds' do
      # overflow should now be handled in both Ruby and Lua layers

      exchange.set_balance(user_id: 'maker_ext', asset: 'BTC', available: 2_000_000_000)
      exchange.place_limit_order(
        symbol: symbol,
        side: 'SELL',
        order_id: 'maker-extreme',
        user_id: 'maker_ext',
        price: 10_000_000_000,
        quantity: 2_000_000_000
      )

      exchange.set_balance(user_id: 'taker_ext', asset: 'USDT', available: 10_000_000_000_000_000)

      outcome = exchange.place_market_order(
        symbol: symbol,
        side: 'BUY',
        order_id: 'taker-extreme',
        user_id: 'taker_ext',
        quantity: 1_500_000_000,
        price_cap: 10_000_000_000
      )

      expect(outcome[:error]).to eq('PRECISION_OVERFLOW')
    end

    it 'accepts near-threshold matching without overflow' do
      exchange.set_balance(user_id: 'maker_near2', asset: 'BTC', available: 2_000_000_000)
      exchange.place_limit_order(
        symbol: symbol,
        side: 'SELL',
        order_id: 'maker-near',
        user_id: 'maker_near2',
        price: 4_500_000_000,
        quantity: 2_000_000
      )

      exchange.set_balance(user_id: 'taker_near2', asset: 'USDT', available: 10_000_000_000_000_000)

      outcome = exchange.place_market_order(
        symbol: symbol,
        side: 'BUY',
        order_id: 'taker-near',
        user_id: 'taker_near2',
        quantity: 1_000_000,
        price_cap: 5_000_000_000
      )

      expect(outcome[:status]).to eq('FILLED').or eq('PARTIALLY_FILLED')
      expect(outcome[:error]).to be_nil
    end
  end

  after do
    redis.close if redis.respond_to?(:close)
  end
end