# frozen_string_literal: true

require 'spec_helper'

# 终态 taker 单只删除订单哈希、不移除 user_orders 索引，会留下永久幽灵条目：
# 订单已不存在但索引仍在，active_orders 会不断返回不存在的订单。
# 做市机器人按 active_orders 对账时，这些幽灵条目会让它每轮都判为"不一致"并撤重挂。
RSpec.describe RedisExchange::Client do
  it 'taker 完全成交后从 user_orders 索引移除' do
    exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 100_000_000)
    exchange.set_balance(user_id: 'taker', asset: 'USDT', available: 10_000_000_000)

    exchange.place_limit_order(
      symbol: symbol, side: 'SELL', order_id: 'm1', user_id: 'maker',
      price: 3_000_000, quantity: 100_000_000
    )

    result = exchange.place_limit_order(
      symbol: symbol, side: 'BUY', order_id: 't1', user_id: 'taker',
      price: 3_000_000, quantity: 100_000_000
    )
    expect(result[:status]).to eq('FILLED')

    # 订单哈希已删除，索引里也不能再有它
    expect(redis.exists('order:t1')).to eq(0)
    expect(redis.zscore("user_orders:taker:#{symbol}", 't1')).to be_nil
    expect(exchange.active_orders(user_id: 'taker', symbol: symbol)).to be_empty
  end

  it 'taker 部分成交后仍保留在索引里' do
    exchange.set_balance(user_id: 'maker2', asset: 'BTC', available: 100_000_000)
    exchange.set_balance(user_id: 'taker2', asset: 'USDT', available: 10_000_000_000)

    exchange.place_limit_order(
      symbol: symbol, side: 'SELL', order_id: 'm2', user_id: 'maker2',
      price: 3_000_000, quantity: 40_000_000
    )

    result = exchange.place_limit_order(
      symbol: symbol, side: 'BUY', order_id: 't2', user_id: 'taker2',
      price: 3_000_000, quantity: 100_000_000
    )
    expect(result[:status]).to eq('PARTIALLY_FILLED')

    expect(redis.zscore("user_orders:taker2:#{symbol}", 't2')).not_to be_nil
    expect(exchange.active_orders(user_id: 'taker2', symbol: symbol).map { |o| o[:order_id] }).to include('t2')
  end
end
