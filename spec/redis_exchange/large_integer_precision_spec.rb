# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe RedisExchange::Client, 'Large Integer Precision Handling', type: :integration do
  include RedisExchangeSpecSetup

  let(:symbol) { 'BTCUSDT' }
  # Use scales of 1 to make math simple and directly control the integer values sent to Lua
  let(:price_scale) { 1 }
  let(:quantity_scale) { 1 }
  let(:balance_scale) { 1 }
  
  # 5e15 is below PRECISION_BOUND (9e15) but large enough to trigger scientific notation
  # in standard Lua tostring() which causes Redis HINCRBY errors
  let(:large_amount) { 5_000_000_000_000_000 } 

  before do
    redis.flushdb
    
    # Setup assets with scale 1
    exchange.seed_asset(asset: 'BTC', balance_scale: balance_scale, status: 'ACTIVE')
    exchange.seed_asset(asset: 'USDT', balance_scale: balance_scale, status: 'ACTIVE')
    
    # Setup market
    exchange.seed_market(
      symbol: symbol,
      base_asset: 'BTC',
      quote_asset: 'USDT',
      price_scale: price_scale,
      quantity_scale: quantity_scale,
      maker_fee_bps: 0,
      taker_fee_bps: 0,
      min_qty: 1,
      min_notional: 1,
      status: 'OPEN'
    )
    
    # Seed balances with enough funds (10e15)
    # Using raw redis commands to ensure we get the exact large integer in
    redis.hset('balance:user1', 'BTC:available', (large_amount * 2).to_s)
    redis.hset('balance:user2', 'USDT:available', (large_amount * 2).to_s)
  end

  it 'handles large integer values without Redis errors' do
    # User 1 places a large SELL order
    res1 = exchange.place_limit_order(
      symbol: symbol,
      side: 'SELL',
      order_id: 'sell-1',
      price: 1,
      quantity: large_amount,
      user_id: 'user1'
    )
    
    expect(res1[:error]).to be_nil
    expect(res1[:status]).to eq('OPEN')
    expect(res1[:remaining_quantity]).to eq(large_amount)

    # Verify order book volume is correct (checking HINCRBY in Lua)
    book_vol = redis.hget("volume:#{symbol}:SELL", "1")
    expect(book_vol).to eq(large_amount.to_s)

    # User 2 places a matching BUY order
    res2 = exchange.place_limit_order(
      symbol: symbol,
      side: 'BUY',
      order_id: 'buy-1',
      price: 1,
      quantity: large_amount,
      user_id: 'user2'
    )

    expect(res2[:error]).to be_nil
    expect(res2[:status]).to eq('FILLED')
    expect(res2[:executed_quantity]).to eq(large_amount)
    
    # Verify balances updated correctly (checking HINCRBY in Lua)
    # User 1 should have received 5e15 USDT
    user1_usdt = redis.hget('balance:user1', 'USDT:available')
    expect(user1_usdt).to eq(large_amount.to_s)
    
    # User 2 should have received 5e15 BTC
    user2_btc = redis.hget('balance:user2', 'BTC:available')
    expect(user2_btc).to eq(large_amount.to_s)
    
    # Verify trade stream (checking XADD with large ints)
    trades = redis.xrange("trades:#{symbol}", '-', '+')
    expect(trades.size).to eq(1)
    trade_data = trades.first[1]
    trade_fields = trade_data.is_a?(Hash) ? trade_data : Hash[*trade_data]
    expect(trade_fields['quantity']).to eq(large_amount.to_s)
    expect(trade_fields['quote']).to eq(large_amount.to_s)
  end

  it 'accumulates fees correctly with large numbers' do
    # Update fee settings
    redis.hset("market:#{symbol}", 'taker_fee_bps', '10') # 0.1%
    
    # Taker fee will be large_amount * 0.001 = 5e12
    # 5e12 is safe from scientific notation usually, but let's check total fees accumulation
    
    expected_fee = large_amount / 1000
    
    # User 1 (Maker SELL)
    exchange.place_limit_order(
      symbol: symbol,
      side: 'SELL',
      order_id: 'fee-sell-1',
      price: 1,
      quantity: large_amount,
      user_id: 'user1'
    )
    
    # User 2 (Taker BUY)
    exchange.place_limit_order(
      symbol: symbol,
      side: 'BUY',
      order_id: 'fee-buy-1',
      price: 1,
      quantity: large_amount,
      user_id: 'user2'
    )
    
    # Check fee accumulation in global stats
    total_fees = redis.hget('fees:USDT', 'total')
    expect(total_fees).to eq(expected_fee.to_s)
  end
end
