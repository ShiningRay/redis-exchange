# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Market Precision Update', :precision_update do
  let(:redis) { RSpec.configuration.redis_factory.call }
  let(:exchange) { RedisExchange::Client.new(redis: redis) }
  let(:symbol) { 'BTCUSDT' }
  let(:base_asset) { 'BTC' }
  let(:quote_asset) { 'USDT' }
  let(:u1) { 'user1' }
  let(:u2) { 'user2' }

  before do
    redis.flushdb
    # Assets: BTC (8 decimals), USDT (6 decimals)
    exchange.seed_asset(asset: base_asset, balance_scale: 100_000_000, status: 'ACTIVE')
    exchange.seed_asset(asset: quote_asset, balance_scale: 1_000_000, status: 'ACTIVE')

    # Market: Price 2 decimals (100), Qty 2 decimals (100)
    exchange.seed_market(
      symbol: symbol,
      base_asset: base_asset,
      quote_asset: quote_asset,
      price_scale: 100,
      quantity_scale: 100,
      status: 'OPEN'
    )

    # User 1: Has 10 BTC
    exchange.set_balance(user_id: u1, asset: base_asset, available: 10 * 100_000_000)
    
    # User 2: Has 20,000 USDT
    exchange.set_balance(user_id: u2, asset: quote_asset, available: 20_000 * 1_000_000)
  end

  it 'updates order amounts and refunds dust when precision is reduced' do
    # 1. Place Orders
    
    # User 1 SELL 1.23 BTC @ 100.12 USDT
    res1 = exchange.place_limit_order(
      symbol: symbol, side: 'SELL', order_id: 'o1', user_id: u1,
      price: 10012, quantity: 123
    )
    expect(res1[:error]).to be_nil

    # User 2 BUY 1.23 BTC @ 90.12 USDT (No Match)
    # Locked USDT: floor(9012 * 123 / 100) * (1e6/1e2) 
    # = floor(11084.76) * 10000 = 11084 * 10000 = 110,840,000 (110.84 USDT)
    res2 = exchange.place_limit_order(
      symbol: symbol, side: 'BUY', order_id: 'o2', user_id: u2,
      price: 9012, quantity: 123
    )
    expect(res2[:error]).to be_nil

    # Verify initial state
    o1 = exchange.order('o1')
    expect(o1[:price]).to eq(10012)
    expect(o1[:quantity]).to eq(123)
    
    u1_bal = exchange.balances(u1)
    expect(u1_bal[:"BTC:reserved"]).to eq(123_000_000)

    u2_bal = exchange.balances(u2)
    expect(u2_bal[:"USDT:reserved"]).to eq(110_840_000)

    # 2. Update Precision
    # Change both scales to 10 (1 decimal)
    
    # Expectation:
    # o1 (SELL):
    #   Old Price: 100.12 (10012). New Price: 100.1 (1001).
    #   Old Qty: 1.23 (123). New Qty: 1.2 (12).
    #   Refund BTC: (1.23 - 1.2) = 0.03 BTC = 3,000,000 satoshis.
    #   New Reserved BTC: 1.2 * 1e8 = 120,000,000.
    
    # o2 (BUY):
    #   Old Price: 90.12 (9012). New Price: 90.1 (901).
    #   Old Qty: 1.23 (123). New Qty: 1.2 (12).
    #   New Locked USDT: floor(901 * 12 / 10) * (1e6/10)
    #   = floor(1081.2) * 100000 = 1081 * 100000 = 108,100,000 (108.1 USDT)
    #   Old Locked: 110,840,000.
    #   Refund USDT: 110,840,000 - 108,100,000 = 2,740,000 (2.74 USDT).
    
    # Execute Update with small batch size to force multiple rounds
    res = exchange.maintenance.update_market_precision(
      symbol: symbol,
      new_price_scale: 10,
      new_quantity_scale: 10,
      batch_size: 1
    )
    expect(res[:error]).to be_nil
    expect(res[:updated_orders]).to eq(2)

    # 3. Verify Final State
    
    # Verify o1
    o1 = exchange.order('o1')
    expect(o1[:price]).to eq(1001)
    expect(o1[:quantity]).to eq(12)
    expect(o1[:remaining]).to eq(12)
    
    u1_bal = exchange.balances(u1)
    expect(u1_bal[:"BTC:reserved"]).to eq(120_000_000)
    expect(u1_bal[:"BTC:available"]).to eq(880_000_000)

    # Verify o2
    o2 = exchange.order('o2')
    expect(o2[:price]).to eq(901)
    expect(o2[:quantity]).to eq(12)
    expect(o2[:remaining]).to eq(12)

    u2_bal = exchange.balances(u2)
    expect(u2_bal[:"USDT:reserved"]).to eq(108_100_000)
    # Original Available: 20000 - 110.84 = 19889.16 = 19,889,160,000
    # Refunded: 2,740,000
    # New Available: 19,889,160,000 + 2,740,000 = 19,891,900,000
    expect(u2_bal[:"USDT:available"]).to eq(19_891_900_000)
    
    # Verify Order Book
    book = exchange.order_book(symbol)
    expect(book[:bids].first[:price]).to eq(901)
    expect(book[:bids].first[:volume]).to eq(12)
    expect(book[:asks].first[:price]).to eq(1001)
    expect(book[:asks].first[:volume]).to eq(12)
  end
end
