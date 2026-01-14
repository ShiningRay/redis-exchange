# frozen_string_literal: true

require 'spec_helper'
require 'redis_exchange/maintenance'

RSpec.describe RedisExchange::Maintenance do
  let(:exchange) { RedisExchange::Client.new(redis: redis) }
  let(:maintenance) { exchange.maintenance }
  let(:symbol) { 'BTCUSDT' }
  let(:user_id) { 'audit-user-1' }

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
      status: 'OPEN'
    )
  end

  # Helper to manually inject an order without updating balance (creating inconsistency)
  def inject_order(oid, side, price, qty, reserved_base, reserved_quote)
    redis.hmset(
      "order:#{oid}",
      'order_id', oid,
      'symbol', symbol,
      'side', side,
      'type', 'LIMIT',
      'status', 'OPEN',
      'user_id', user_id,
      'price', price,
      'quantity', qty,
      'remaining', qty,
      'reserved_base', reserved_base,
      'reserved_quote', reserved_quote,
      'created_at', Time.now.to_i * 1000
    )
    redis.zadd("user_orders:#{user_id}:#{symbol}", Time.now.to_i, oid)
  end

  describe '#audit_user_balances' do
    context 'when balance is consistent' do
      it 'reports no issues' do
        # Setup consistent state
        exchange.set_balance(user_id: user_id, asset: 'USDT', available: 1000, reserved: 100)
        inject_order('o1', 'BUY', 100, 1, 0, 100)

        report = maintenance.audit_user_balances(user_id: user_id)
        expect(report).to be_empty
      end
    end

    context 'when reserved balance is insufficient (Deficit)' do
      it 'locks available funds to fix deficit' do
        # User has 1000 available, but 0 reserved. Order needs 100 reserved.
        exchange.set_balance(user_id: user_id, asset: 'USDT', available: 1000, reserved: 0)
        inject_order('o1', 'BUY', 100, 1, 0, 100)

        report = maintenance.audit_user_balances(user_id: user_id, fix: true)
        
        expect(report.size).to eq(1)
        res = report.first
        expect(res[:deficits]).to be_empty
        expect(res[:fixes]).to include({ asset: 'USDT', action: 'LOCK', amount: 100 })

        # Check balance
        b = exchange.balances(user_id)
        expect(b[:'USDT:reserved']).to eq(100)
        expect(b[:'USDT:available']).to eq(900)
      end

      it 'reports deficit if available funds are insufficient' do
        # User has only 50 available, needs 100 reserved.
        exchange.set_balance(user_id: user_id, asset: 'USDT', available: 50, reserved: 0)
        inject_order('o1', 'BUY', 100, 1, 0, 100)

        report = maintenance.audit_user_balances(user_id: user_id, fix: true)
        
        res = report.first
        # Should lock the 50 available
        expect(res[:fixes]).to include({ asset: 'USDT', action: 'LOCK', amount: 50 })
        # Should report remaining 50 deficit
        expect(res[:deficits]).to include({ asset: 'USDT', amount: 50 })

        b = exchange.balances(user_id)
        expect(b[:'USDT:reserved']).to eq(50)
        expect(b[:'USDT:available']).to eq(0)
      end
    end

    context 'when reserved balance is excessive (Surplus)' do
      it 'releases excess reserved to available' do
        # User has 200 reserved, but order only needs 100.
        exchange.set_balance(user_id: user_id, asset: 'USDT', available: 0, reserved: 200)
        inject_order('o1', 'BUY', 100, 1, 0, 100)

        report = maintenance.audit_user_balances(user_id: user_id, fix: true)
        
        res = report.first
        expect(res[:deficits]).to be_empty
        expect(res[:fixes]).to include({ asset: 'USDT', action: 'RELEASE', amount: 100 })

        b = exchange.balances(user_id)
        expect(b[:'USDT:reserved']).to eq(100)
        expect(b[:'USDT:available']).to eq(100)
      end
    end

    context 'with multiple assets and orders' do
      it 'audits all correctly' do
        exchange.set_balance(user_id: user_id, asset: 'USDT', available: 1000, reserved: 0)
        exchange.set_balance(user_id: user_id, asset: 'BTC', available: 10, reserved: 5) # Surplus: 5 reserved, need 2

        inject_order('buy-1', 'BUY', 100, 1, 0, 100) # Needs 100 USDT reserved
        inject_order('sell-1', 'SELL', 200, 2, 2, 0) # Needs 2 BTC reserved

        report = maintenance.audit_user_balances(user_id: user_id, fix: true)
        res = report.first
        
        usdt_fix = res[:fixes].find { |f| f[:asset] == 'USDT' }
        btc_fix = res[:fixes].find { |f| f[:asset] == 'BTC' }

        expect(usdt_fix).to eq({ asset: 'USDT', action: 'LOCK', amount: 100 })
        expect(btc_fix).to eq({ asset: 'BTC', action: 'RELEASE', amount: 3 }) # 5 - 2 = 3 surplus

        b = exchange.balances(user_id)
        expect(b[:'USDT:reserved']).to eq(100)
        expect(b[:'BTC:reserved']).to eq(2)
      end
    end
  end
end
