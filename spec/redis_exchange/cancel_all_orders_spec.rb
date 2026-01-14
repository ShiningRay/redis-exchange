# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RedisExchange::Client do

  describe "#cancel_all_orders" do
    it 'cancels all orders for a user without touching other users' do
      exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 200_000_000)
      exchange.place_limit_order(
        symbol: symbol,
        side: 'SELL',
        order_id: 'bulk-1',
        user_id: 'maker',
        price: 3_000_000,
        quantity: 100_000_000
      )
      exchange.place_limit_order(
        symbol: symbol,
        side: 'SELL',
        order_id: 'bulk-2',
        user_id: 'maker',
        price: 3_100_000,
        quantity: 100_000_000)

      exchange.set_balance(user_id: 'maker', asset: 'USDT', available: 10_000_000)
      exchange.place_limit_order(
        symbol: symbol,
        side: 'BUY',
        order_id: 'bulk-buy-1',
        user_id: 'maker',
        price: 2_900_000,
        quantity: 100_000_000
      )

      exchange.set_balance(user_id: 'other', asset: 'BTC', available: 100_000_000)
      exchange.place_limit_order(
        symbol: symbol,
        side: 'SELL',
        order_id: 'other-1',
        user_id: 'other',
        price: 3_200_000,
        quantity: 100_000_000
      )

      cancelled = exchange.cancel_all_orders('maker')

      expect(cancelled.map { |row| row[:order_id] }).to match_array(%w[bulk-1 bulk-2 bulk-buy-1])

      expect(redis.lrange('queue:BTCUSDT:SELL:3000000', 0, -1)).to be_empty
      expect(redis.lrange('queue:BTCUSDT:SELL:3100000', 0, -1)).to be_empty
      expect(redis.lrange('queue:BTCUSDT:BUY:2900000', 0, -1)).to be_empty
      expect(redis.lrange('queue:BTCUSDT:SELL:3200000', 0, -1)).to eq(['other-1'])

      volume = redis.hgetall('volume:BTCUSDT:SELL')
      expect(volume.fetch('3000000', '0').to_i).to eq(0)
      expect(volume.fetch('3100000', '0').to_i).to eq(0)
      expect(volume.fetch('3200000', '0').to_i).to eq(100_000_000)

      buy_volume = redis.hgetall('volume:BTCUSDT:BUY')
      expect(buy_volume.fetch('2900000', '0').to_i).to eq(0)

      balances = exchange.balances('maker')
      expect(balances[:'BTC:available']).to eq(200_000_000)
      expect(balances[:'BTC:reserved']).to eq(0)
      expect(balances[:'USDT:available']).to eq(10_000_000)
      expect(balances[:'USDT:reserved']).to eq(0)

      %w[bulk-1 bulk-2 bulk-buy-1].each do |order_id|
        # 取消后的终态订单哈希应被删除
        expect(exchange.order(order_id)).to eq({})
      end

      # 验证 orders 流包含两条取消事件
      recent = redis.xrevrange("orders:#{symbol}", '+', '-', count: 5)
      ids_status = recent.map { |(_, f)| (f.is_a?(Hash) ? f : Hash[*f]) }.map { |h| [h['order_id'], h['status']] }
      expect(ids_status).to include(['bulk-1', 'CANCELLED'])
      expect(ids_status).to include(['bulk-2', 'CANCELLED'])
      expect(ids_status).to include(['bulk-buy-1', 'CANCELLED'])

      other_snapshot = redis.hgetall('order:other-1')
      expect(other_snapshot[:status] || other_snapshot['status']).to eq('OPEN')
      expect(other_snapshot[:remaining] || other_snapshot['remaining']).to eq('100000000')

      book = exchange.order_book(symbol)
      ask_entry = book[:asks].find { |row| row[:price] == 3_200_000 }
      expect(ask_entry).not_to be_nil
      expect(ask_entry[:volume]).to eq(100_000_000)
    end
  end

  end
