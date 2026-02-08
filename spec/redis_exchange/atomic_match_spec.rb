# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Atomic Order Matching', :atomic_match do
  let(:redis) { RSpec.configuration.redis_factory.call }
  let(:exchange) { RedisExchange::Client.new(redis: redis) }
  let(:symbol) { 'BTCUSDT' }

  before do
    redis.flushdb
    # Setup standard assets and market
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
  end

  describe 'Partial fill on insufficient funds (Graceful Stop)' do
    # This scenario tests the "Graceful Stop" mechanism when a Taker order
    # matches against multiple Maker orders but runs out of funds partway through.
    #
    # Goal: Verify that the engine:
    # 1. Successfully executes trades that are fully covered by funds.
    # 2. Stops execution immediately before attempting a trade that cannot be afforded.
    # 3. Does NOT rollback valid trades (partial fill is better than nothing).
    # 4. Does NOT leave the system in an inconsistent state (no phantom trades or negative balances).

    let(:alice_id) { 'alice' }
    let(:bob_id) { 'bob' }
    let(:charlie_id) { 'charlie' }

    it 'halts matching gracefully when taker funds run out, preserving executed trades' do
      # SETUP:
      # 1. Alice sells 5 BTC @ 100 USDT (Cost 500)
      #    - This order should be fully matched.
      exchange.set_balance(user_id: alice_id, asset: 'BTC', available: 10)
      exchange.place_limit_order(
        symbol: symbol,
        side: 'SELL',
        order_id: 'alice-sell-1',
        user_id: alice_id,
        price: 100,
        quantity: 5,
        timestamp_ms: Time.now.to_i * 1000
      )

      # 2. Charlie sells 5 BTC @ 100 USDT (Cost 500)
      #    - This order sits behind Alice's.
      #    - It should NOT be matched because Taker runs out of funds.
      exchange.set_balance(user_id: charlie_id, asset: 'BTC', available: 10)
      exchange.place_limit_order(
        symbol: symbol,
        side: 'SELL',
        order_id: 'charlie-sell-1',
        user_id: charlie_id,
        price: 100,
        quantity: 5,
        timestamp_ms: (Time.now.to_i * 1000) + 100
      )

      # 3. Bob wants to buy 10 BTC (Cost 1000 USDT) but only has 700 USDT
      #    - Matching Alice (5 BTC * 100 = 500 USDT) should succeed. Bob has 200 USDT left.
      #    - Matching Charlie (needs 500 USDT) should fail the pre-flight check.
      exchange.set_balance(user_id: bob_id, asset: 'USDT', available: 700)

      # EXECUTION:
      response = exchange.place_market_order(
        symbol: symbol,
        side: 'BUY',
        order_id: 'bob-buy-market-1',
        user_id: bob_id,
        quantity: 10,
        timestamp_ms: (Time.now.to_i * 1000) + 200
      )

      # VERIFICATION:
      
      # 1. Response Integrity
      #    - No error means the script handled the "insufficient funds" condition internally via break.
      expect(response[:error]).to be_nil
      
      # 2. Status should be PARTIALLY_FILLED
      #    - executed: 5 (from Alice)
      #    - remaining: 5 (cancelled/unfilled because funds ran out)
      expect(response[:status]).to eq('PARTIALLY_FILLED')
      expect(response[:executed_quantity]).to eq(5)
      expect(response[:remaining_quantity]).to eq(5)

      # 2.1 Check Trade Stream
      trades = redis.xrange("trades:#{symbol}", '-', '+')
      expect(trades.size).to eq(1)
      
      _, fields = trades.first
      trade = fields.is_a?(Hash) ? fields : Hash[*fields]
      expect(trade).to have_key('sequence')
      expect(trade['sequence'].to_i).to be > 0
      expect(trade['price'].to_f).to eq(100.0)
      expect(trade['quantity'].to_f).to eq(5.0)
      
      # 3. Verify Balances (The Acid Test)
      
      # Alice (The Filled Maker):
      # - Sold 5 BTC, received 500 USDT.
      # - Logic: 10 BTC start - 5 sold = 5 remaining.
      alice_usdt = redis.hget("balance:#{alice_id}", 'USDT:available').to_i
      alice_btc = redis.hget("balance:#{alice_id}", 'BTC:available').to_i 
      # Received 500 USDT, but paid maker fee (if any, default 0 here)
      # Assuming default 0 fee from setup:
      expect(alice_usdt).to eq(500)
      expect(alice_btc).to eq(5)
      
      # Bob (The Partial Taker):
      # - Bought 5 BTC, spent 500 USDT. 
      # - Initial 700 - 500 = 200 USDT left.
      # - Must NOT have spent any extra for the failed Charlie match.
      bob_btc = redis.hget("balance:#{bob_id}", 'BTC:available').to_i
      bob_usdt = redis.hget("balance:#{bob_id}", 'USDT:available').to_i
      # Bought 5 BTC, but paid taker fee (if any, default 0 here)
      # Assuming default 0 fee from setup:
      expect(bob_btc).to eq(5)
      expect(bob_usdt).to eq(200)

      # Charlie (The Unaffected Maker):
      # - Should be completely untouched because matching stopped before writing to his account.
      # - His order placed 5 BTC into 'reserved'.
      charlie_reserved_btc = redis.hget("balance:#{charlie_id}", 'BTC:reserved').to_i
      
      # Key assertion: If the loop didn't break cleanly, Charlie's reserved balance might have been decremented
      # or his order status changed.
      expect(charlie_reserved_btc).to eq(5) 
      
      # Charlie order status should still be OPEN
      charlie_order_status = redis.hget("order:charlie-sell-1", 'status')
      expect(charlie_order_status).to eq('OPEN')
    end
  end

  describe 'Atomic Failure on Overflow' do
    # This scenario tests the "Atomic Failure" mechanism when a calculation overflows Lua's precision limits.
    # Redis Lua uses double-precision floats (53-bit mantissa). Integers > 9e15 (2^53) lose precision.
    #
    # Goal: Verify that the engine:
    # 1. Detects potential overflow BEFORE changing any state.
    # 2. Rejects the ENTIRE operation if overflow is detected.
    # 3. Ensures the Maker (victim) is protected from having their assets stuck in a bad state.

    let(:overflow_user) { 'overflow_user' }
    let(:victim_maker) { 'victim_maker' }

    it 'prevents any state change when precision overflow is detected due to balance scaling' do
      # SETUP: Force Overflow Condition
      # We configure assets such that converting from Market Units -> Balance Units triggers overflow.
      # 
      # - USDT Scale: 100 (Balance = Market Value * 100)
      # - Market Price: 1e14
      # - Trade Qty: 1
      # - Trade Notional: 1e14
      # - Required Balance Delta: 1e14 * 100 = 1e16
      # 
      # 1e16 > 9e15 (Redis Lua Max Integer Precision), so `would_overflow_mul` should return true.

      exchange.seed_asset(asset: 'USDT', balance_scale: 100, status: 'ACTIVE')
      exchange.seed_asset(asset: 'BTC', balance_scale: 1, status: 'ACTIVE')
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

      # 1. Place a Maker order with a very high price (100 Trillion USDT/BTC)
      #    This is valid on its own because 1e14 < 9e15.
      high_price = 100_000_000_000_000 
      exchange.set_balance(user_id: victim_maker, asset: 'BTC', available: 10)
      
      res = exchange.place_limit_order(
        symbol: symbol,
        side: 'SELL',
        order_id: 'high-price-sell',
        user_id: victim_maker,
        price: high_price,
        quantity: 1
      )
      expect(res[:error]).to be_nil
      
      # Snapshot Maker State
      expect(redis.hget('order:high-price-sell', 'status')).to eq('OPEN')
      initial_maker_reserved = redis.hget("balance:#{victim_maker}", 'BTC:reserved').to_i
      expect(initial_maker_reserved).to eq(1)

      # 2. Taker attempts to match this order.
      #    The engine calculates the required USDT debit: 1e14 * 100 (scale) = 1e16.
      #    This should trigger the overflow guard.
      
      exchange.set_balance(user_id: overflow_user, asset: 'USDT', available: 20_000_000_000_000_000) # Plenty of funds
      
      response = exchange.place_market_order(
        symbol: symbol,
        side: 'BUY',
        order_id: 'taker-overflow',
        user_id: overflow_user,
        quantity: 1
      )
      
      # EXPECTATION: Error returned
      expect(response[:error]).to eq('PRECISION_OVERFLOW')
      
      # VERIFY ATOMICITY:
      # Crucial: The Maker order must NOT have been partially processed or closed.
      maker_order = redis.hgetall('order:high-price-sell')
      expect(maker_order['status']).to eq('OPEN')
      expect(maker_order['remaining'].to_i).to eq(1)
      
      # Maker balance should be unchanged
      maker_reserved = redis.hget("balance:#{victim_maker}", 'BTC:reserved').to_i
      expect(maker_reserved).to eq(initial_maker_reserved)
      
      # Taker balance should be unchanged
      taker_avail = redis.hget("balance:#{overflow_user}", 'USDT:available').to_i
      expect(taker_avail).to eq(20_000_000_000_000_000)
      
      # No trades recorded in the stream
      trades_len = redis.xlen("trades:#{symbol}")
      expect(trades_len).to eq(0)
    end
  end
end
