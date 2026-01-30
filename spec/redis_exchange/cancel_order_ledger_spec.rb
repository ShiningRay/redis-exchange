# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RedisExchange::Client do
  let(:redis) { RSpec.configuration.redis_factory.call }
  let(:exchange) { RedisExchange::Client.new(redis: redis) }
  let(:symbol) { 'BTCUSDT' }

  before do
    redis.flushdb
    exchange.seed_asset(asset: 'BTC', balance_scale: 100_000_000, status: 'ACTIVE')
    exchange.seed_asset(asset: 'USDT', balance_scale: 100, status: 'ACTIVE')
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

  describe "cancel_order ledger entry" do
    it 'includes new_available and new_reserved fields in UNLOCK ledger entry' do
      # 1. Setup initial balance: 2 BTC available
      exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 200_000_000)

      # 2. Place SELL order for 1 BTC
      # This locks 1 BTC.
      # Expected State: Available: 100_000_000, Reserved: 100_000_000
      exchange.place_limit_order(
        symbol: symbol,
        side: 'SELL',
        order_id: 'cancel-test-1',
        user_id: 'maker',
        price: 3_000_000,
        quantity: 100_000_000
      )

      # Verify intermediate state
      balances_mid = exchange.balances('maker')
      expect(balances_mid[:'BTC:available']).to eq(100_000_000)
      expect(balances_mid[:'BTC:reserved']).to eq(100_000_000)

      # 3. Cancel order
      # This should UNLOCK 1 BTC.
      # Expected State: Available: 200_000_000, Reserved: 0
      outcome = exchange.cancel_order('cancel-test-1')
      expect(outcome[:status]).to eq('CANCELLED')

      # 4. Check Ledger
      entries = redis.xrevrange('account_ledger', '+', '-', count: 1)
      expect(entries).not_to be_empty
      _, fields = entries.first
      fields = fields.is_a?(Hash) ? fields : Hash[*fields]

      expect(fields['action']).to eq('UNLOCK')
      expect(fields['asset']).to eq('BTC')
      expect(fields['amount']).to eq('100000000')
      
      # Verify new fields
      expect(fields['new_available']).to eq('200000000')
      expect(fields['new_reserved']).to eq('0')
    end
  end
end
