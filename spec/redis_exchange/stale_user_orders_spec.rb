# frozen_string_literal: true

require 'spec_helper'
require 'redis_exchange/maintenance'

# 索引里可能存在订单哈希已不存在的条目（正常路径会 ZREM，但线上观察到少量残留）。
# 客户端按 active_orders 对账时会被这些幽灵条目干扰，需要一个幂等的清理入口。
RSpec.describe RedisExchange::Maintenance do
  # 共享 setup 会把 described_class 当作 exchange，这里显式覆盖成真正的客户端
  let(:exchange) { RedisExchange::Client.new(redis: redis) }
  let(:maintenance) { described_class.new(redis) }

  before do
    exchange.set_balance(user_id: 'alice', asset: 'BTC', available: 300_000_000)
    exchange.place_limit_order(
      symbol: symbol, side: 'SELL', order_id: 'live1', user_id: 'alice',
      price: 3_000_000, quantity: 100_000_000
    )
    exchange.place_limit_order(
      symbol: symbol, side: 'SELL', order_id: 'ghost1', user_id: 'alice',
      price: 3_100_000, quantity: 100_000_000
    )
    # 模拟残留：删掉订单哈希但保留索引条目
    redis.del('order:ghost1')
  end

  it '移除没有订单哈希的索引条目，保留正常的订单' do
    result = maintenance.purge_stale_user_orders

    expect(result[:removed]).to eq(1)
    ids = redis.zrange("user_orders:alice:#{symbol}", 0, -1)
    expect(ids).to eq(['live1'])
  end

  it '可以按交易对限定范围' do
    result = maintenance.purge_stale_user_orders(symbol: symbol)

    expect(result[:removed]).to eq(1)
    expect(redis.zcard("user_orders:alice:#{symbol}")).to eq(1)
  end

  it '没有残留时不修改任何数据' do
    redis.zrem("user_orders:alice:#{symbol}", 'ghost1')

    result = maintenance.purge_stale_user_orders

    expect(result[:removed]).to eq(0)
    expect(redis.zcard("user_orders:alice:#{symbol}")).to eq(1)
  end
end
