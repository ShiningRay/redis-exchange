# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RedisExchange::Client do

  it 'maintains per-user active order index and supports pagination' do
    # Alice places multiple SELL limit orders; verify index and pagination
    exchange.set_balance(user_id: 'alice', asset: 'BTC', available: 600_000_000)

    %w[a1 a2 a3 a4 a5].each_with_index do |oid, idx|
      price = 3_000_000 + (idx * 10_000)
      result = exchange.place_limit_order(
        symbol: symbol,
        side: 'SELL',
        order_id: oid,
        user_id: 'alice',
        price: price,
        quantity: 100_000_000
      )
      expect(result[:status]).to eq('OPEN')
    end

    # ZSET 索引应包含 5 条记录
    zcount = redis.zcard("user_orders:alice:#{symbol}")
    expect(zcount).to eq(5)

    # 默认按序列倒序分页（最新在前）
    page1 = exchange.active_orders(user_id: 'alice', symbol: symbol, page: 1, per_page: 2, direction: :desc)
    expect(page1.map { |o| o[:order_id] }).to eq(%w[a5 a4])

    page2 = exchange.active_orders(user_id: 'alice', symbol: symbol, page: 2, per_page: 2, direction: :desc)
    expect(page2.map { |o| o[:order_id] }).to eq(%w[a3 a2])

    page3 = exchange.active_orders(user_id: 'alice', symbol: symbol, page: 3, per_page: 2, direction: :desc)
    expect(page3.map { |o| o[:order_id] }).to eq(%w[a1])

    # 升序方向（最早在前）
    asc_page1 = exchange.active_orders(user_id: 'alice', symbol: symbol, page: 1, per_page: 2, direction: :asc)
    expect(asc_page1.map { |o| o[:order_id] }).to eq(%w[a1 a2])
  end

end