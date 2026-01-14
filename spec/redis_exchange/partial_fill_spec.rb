# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RedisExchange::Client do
  describe 'Partial fill with insufficient funds' do
    # Override setup to use simple scales for easier arithmetic
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
    end

    let(:alice_id) { 'alice' }
    let(:charlie_id) { 'charlie' }
    let(:bob_id) { 'bob' }

    it 'gracefully handles partial fill when funds run out during multi-match execution' do
      # 1. Alice sells 5 BTC @ 100 USDT
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

      # 2. Charlie sells 5 BTC @ 100 USDT
      # Ensure distinct ordering
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
      # - Matching Alice (5 BTC * 100 = 500 USDT) is successful. Bob has 200 USDT left.
      # - Matching Charlie (needs 500 USDT) fails.
      exchange.set_balance(user_id: bob_id, asset: 'USDT', available: 700)

      response = exchange.place_market_order(
        symbol: symbol,
        side: 'BUY',
        order_id: 'bob-buy-market-1',
        user_id: bob_id,
        quantity: 10,
        timestamp_ms: (Time.now.to_i * 1000) + 200
      )

      # VERIFY THE FIX
      # The API should NOT return an error, but stop matching gracefully
      expect(response[:error]).to be_nil

      # State has changed (Partial fill occurred)
      alice_usdt = redis.hget("balance:#{alice_id}", 'USDT:available').to_i
      bob_btc = redis.hget("balance:#{bob_id}", 'BTC:available').to_i
      bob_usdt = redis.hget("balance:#{bob_id}", 'USDT:available').to_i

      # Alice received 500 USDT
      expect(alice_usdt).to eq(500)
      
      # Bob received 5 BTC
      expect(bob_btc).to eq(5)
      
      # Bob spent 500 USDT, remaining 200
      expect(bob_usdt).to eq(200)

      # Charlie was not touched
      charlie_usdt = redis.hget("balance:#{charlie_id}", 'USDT:available')
      expect(charlie_usdt).to be_nil # Or 0 depending on implementation details, usually nil if not set
    end
  end
end
