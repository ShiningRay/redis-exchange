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

    it 'includes :UNT flag in biz_id when order was never executed' do
      exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 200_000_000)

      exchange.place_limit_order(
        symbol: symbol,
        side: 'SELL',
        order_id: 'untouched-cancel',
        user_id: 'maker',
        price: 3_000_000,
        quantity: 100_000_000
      )

      outcome = exchange.cancel_order('untouched-cancel')
      expect(outcome[:status]).to eq('CANCELLED')

      # Check Ledger
      entries = redis.xrevrange('account_ledger', '+', '-', count: 1)
      expect(entries).not_to be_empty
      _, fields = entries.first
      fields = fields.is_a?(Hash) ? fields : Hash[*fields]

      expect(fields['action']).to eq('UNLOCK')
      expect(fields['biz_id']).to end_with(':UNT')
    end

    it 'does not include :UNT flag in biz_id when order was partially filled' do
      exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 200_000_000)
      exchange.set_balance(user_id: 'taker', asset: 'USDT', available: 500_000_000)

      # Place a sell order
      exchange.place_limit_order(
        symbol: symbol,
        side: 'SELL',
        order_id: 'partial-fill',
        user_id: 'maker',
        price: 3_000_000,
        quantity: 100_000_000
      )

      # Place a buy order that partially fills it
      exchange.place_limit_order(
        symbol: symbol,
        side: 'BUY',
        order_id: 'taker-order',
        user_id: 'taker',
        price: 3_000_000,
        quantity: 50_000_000
      )

      # Verify partial fill
      order_before = exchange.order('partial-fill')
      expect(order_before[:status]).to eq('PARTIALLY_FILLED')
      expect(order_before[:remaining]).to eq(50_000_000)

      # Cancel the remaining order
      outcome = exchange.cancel_order('partial-fill')
      expect(outcome[:status]).to eq('CANCELLED')

      # Check Ledger for the unlock entry
      entries = redis.xrevrange('account_ledger', '+', '-', count: 5)
      unlock_entry = entries.find { |_, fields|
        fields = fields.is_a?(Hash) ? fields : Hash[*fields]
        fields['action'] == 'UNLOCK' && fields['biz_id']&.include?('order_cancel')
      }
      expect(unlock_entry).not_to be_nil

      _, fields = unlock_entry
      fields = fields.is_a?(Hash) ? fields : Hash[*fields]
      expect(fields['biz_id']).not_to end_with(':UNT')
    end

    it 'does not include :UNT flag in biz_id when order was fully filled' do
      exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 200_000_000)
      exchange.set_balance(user_id: 'taker', asset: 'USDT', available: 300_000_000)

      # Place a sell order
      exchange.place_limit_order(
        symbol: symbol,
        side: 'SELL',
        order_id: 'fully-filled',
        user_id: 'maker',
        price: 3_000_000,
        quantity: 100_000_000
      )

      # Place a buy order that fully fills it
      exchange.place_limit_order(
        symbol: symbol,
        side: 'BUY',
        order_id: 'taker-order-full',
        user_id: 'taker',
        price: 3_000_000,
        quantity: 100_000_000
      )

      # Order hash is deleted after being fully filled
      order_after = exchange.order('fully-filled')
      expect(order_after).to eq({})

      # Try to cancel a fully filled order (should succeed with NOT_FOUND status since hash is deleted)
      outcome = exchange.cancel_order('fully-filled')
      expect(outcome[:status]).to eq('NOT_FOUND')

      # No unlock should occur for fully filled orders
      entries = redis.xrevrange('account_ledger', '+', '-', count: 10)
      unlock_entries = entries.select { |_, fields|
        fields = fields.is_a?(Hash) ? fields : Hash[*fields]
        fields['action'] == 'UNLOCK' && fields['biz_id']&.include?('order_cancel:fully-filled')
      }
      expect(unlock_entries).to be_empty
    end
  end
end
