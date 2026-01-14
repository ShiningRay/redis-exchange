# frozen_string_literal: true

require 'spec_helper'
require 'redis_exchange/maintenance'

RSpec.describe RedisExchange::Maintenance do
  # Override exchange to be the Client, so shared setup works (seeding markets etc)
  let(:exchange) { RedisExchange::Client.new(redis: redis) }
  let(:maintenance) { exchange.maintenance }
  
  # Shared setup is auto-included by RSpec config based on file path, 
  # but we need to ensure it uses the correct 'exchange' object which we just overrode.

  let(:symbol) { 'BTCUSDT' }
  let(:user_id) { 'user-1' }
  let(:order_id) { 'order-1' }

  before do
    exchange.seed_market(
      symbol: symbol,
      base_asset: 'BTC',
      quote_asset: 'USDT',
      price_scale: 1,
      quantity_scale: 1,
      status: 'MAINTENANCE' # Ensure we test in maintenance mode (though force cancel should bypass it)
    )
    exchange.seed_asset(asset: 'BTC', balance_scale: 1, status: 'ACTIVE')
    exchange.seed_asset(asset: 'USDT', balance_scale: 1, status: 'ACTIVE')
  end

  # Helper to manually inject an order since normal placement might be blocked by MAINTENANCE
  def inject_order(oid, side, price, qty, reserved)
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
      'created_at', Time.now.to_i * 1000,
      'reserved_base', side == 'SELL' ? reserved : 0,
      'reserved_quote', side == 'BUY' ? reserved : 0
    )
    redis.rpush("queue:#{symbol}:#{side}:#{price}", oid)
    redis.hincrby("volume:#{symbol}:#{side}", price, qty)
    redis.zadd("book:#{symbol}:#{side}", price, price)
    redis.zadd("user_orders:#{user_id}:#{symbol}", Time.now.to_i, oid)
  end

  describe '#force_cancel_order' do
    context 'with mode: :delete_only' do
      it 'removes order but leaves balances untouched' do
        # Setup balance
        exchange.set_balance(user_id: user_id, asset: 'USDT', available: 1000, reserved: 1000)
        
        # Inject order (BUY 1 BTC @ 1000 USDT)
        inject_order(order_id, 'BUY', 1000, 1, 1000)

        # Action
        res = exchange.maintenance.force_cancel_order(order_id: order_id, mode: :delete_only)

        # Verify
        expect(res[:status]).to eq('OK')
        expect(redis.exists?("order:#{order_id}")).to be false
        expect(redis.exists?("queue:#{symbol}:BUY:1000")).to be false
        expect(redis.exists?("user_orders:#{user_id}:#{symbol}")).to be false

        # Balance check: reserved should STILL be 1000 (leaked)
        balances = exchange.balances(user_id)
        expect(balances[:'USDT:reserved']).to eq(1000)
        expect(balances[:'USDT:available']).to eq(1000)
      end
    end

    context 'with mode: :best_effort_unlock' do
      it 'removes order and unlocks balance normally' do
        exchange.set_balance(user_id: user_id, asset: 'USDT', available: 0, reserved: 1000)
        inject_order(order_id, 'BUY', 1000, 1, 1000)

        res = exchange.maintenance.force_cancel_order(order_id: order_id, mode: :best_effort_unlock)

        expect(res[:status]).to eq('OK')
        expect(redis.exists?("order:#{order_id}")).to be false

        # Balance check: reserved 0, available 1000
        balances = exchange.balances(user_id)
        expect(balances[:'USDT:reserved']).to eq(0)
        expect(balances[:'USDT:available']).to eq(1000)
      end

      it 'removes order and partially unlocks if reserved balance is insufficient' do
        # User only has 500 reserved (corruption scenario), order thinks it reserved 1000
        exchange.set_balance(user_id: user_id, asset: 'USDT', available: 0, reserved: 500)
        inject_order(order_id, 'BUY', 1000, 1, 1000)

        res = exchange.maintenance.force_cancel_order(order_id: order_id, mode: :best_effort_unlock)

        expect(res[:status]).to eq('OK')
        expect(redis.exists?("order:#{order_id}")).to be false

        # Balance check: reserved should be drained to 0 (500 - 500), available increased by 500
        balances = exchange.balances(user_id)
        expect(balances[:'USDT:reserved']).to eq(0)
        expect(balances[:'USDT:available']).to eq(500)
      end

      it 'handles SELL orders similarly' do
        exchange.set_balance(user_id: user_id, asset: 'BTC', available: 0, reserved: 50)
        inject_order(order_id, 'SELL', 1000, 100, 100) # Wants to unlock 100 BTC

        res = exchange.maintenance.force_cancel_order(order_id: order_id, mode: :best_effort_unlock)

        balances = exchange.balances(user_id)
        expect(balances[:'BTC:reserved']).to eq(0) # 50 - 50
        expect(balances[:'BTC:available']).to eq(50)
      end
    end
  end
end
