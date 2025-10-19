# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RedisExchange::Client do

  describe "#cancel_order" do
    context "given an existing order" do
      it 'cancels a resting order and releases reserved balances' do
        exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 100_000_000)

        exchange.place_limit_order(
          symbol: symbol,
          side: 'SELL',
          order_id: 'cancel-1',
          user_id: 'maker',
          price: 3_000_000,
          quantity: 100_000_000
        )

        outcome = exchange.cancel_order('cancel-1')

        expect(outcome[:status]).to eq('CANCELLED')
        queue = redis.lrange('queue:BTCUSDT:SELL:3000000', 0, -1)
        expect(queue).to be_empty

        volume = redis.hgetall('volume:BTCUSDT:SELL')
        expect(volume.fetch('3000000', '0').to_i).to eq(0)

        balances = exchange.balances('maker')
        expect(balances[:'BTC:available']).to eq(100_000_000)
        expect(balances[:'BTC:reserved']).to eq(0)

        # 取消后的终态订单哈希应被删除
        expect(exchange.order('cancel-1')).to eq({})
        # 验证 orders 流的取消事件为最新一条
        latest = redis.xrevrange("orders:#{symbol}", '+', '-', count: 1)
        expect(latest).not_to be_empty
        _, fields = latest.first
        fields_hash = fields.is_a?(Hash) ? fields : Hash[*fields]
        expect(fields_hash['order_id']).to eq('cancel-1')
        expect(fields_hash['status']).to eq('CANCELLED')
      end
    end
    context "given a non-existent order id" do
      it 'returns NOT_FOUND when cancelling a non-existent order' do
        outcome = exchange.cancel_order('no-such-order')

        expect(outcome[:status]).to eq('NOT_FOUND')
        expect(outcome[:order_id]).to eq('no-such-order')

        # 不应有 orders 流事件产生
        recent = redis.xrevrange("orders:#{symbol}", '+', '-', count: 1)
        expect(recent).to be_empty

        # 查询该订单应为空
        expect(exchange.order('no-such-order')).to eq({})
      end
    end
  end 

  end