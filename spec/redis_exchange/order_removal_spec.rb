# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RedisExchange::Client do

  it 'removes orders from index when filled or cancelled; retains partials' do
    # Bob 创建一笔会被完全吃掉的挂单
    exchange.set_balance(user_id: 'bob', asset: 'BTC', available: 300_000_000)
    exchange.place_limit_order(
      symbol: symbol,
      side: 'SELL',
      order_id: 'bob-full',
      user_id: 'bob',
      price: 3_000_000,
      quantity: 100_000_000
    )

    # Alice 以市价买入完全成交 bob-full
    exchange.set_balance(user_id: 'alice', asset: 'USDT', available: 10_000_000)
    result_full = exchange.place_market_order(
      symbol: symbol,
      side: 'BUY',
      order_id: 'taker-full',
      user_id: 'alice',
      quantity: 100_000_000,
      price_cap: 3_100_000
    )
    expect(result_full[:status]).to eq('FILLED')

    # 完全成交后索引应移除 bob-full
    expect(exchange.active_orders(user_id: 'bob', symbol: symbol)).to eq([])
    expect(redis.zcard("user_orders:bob:#{symbol}")).to eq(0)

    # Bob 再创建一笔并部分成交，索引应保留该订单
    limit_result = exchange.place_limit_order(
      symbol: symbol,
      side: 'SELL',
      order_id: 'bob-partial',
      user_id: 'bob',
      price: 3_000_000,
      quantity: 100_000_000
    )

    # 部分成交 40_000_000
    result_partial = exchange.place_market_order(
      symbol: symbol,
      side: 'BUY',
      order_id: 'taker-partial',
      user_id: 'alice',
      quantity: 40_000_000,
      price_cap: 3_100_000
    )
    expect(result_partial[:status]).to eq('FILLED')

    bob_active = exchange.active_orders(user_id: 'bob', symbol: symbol)
    expect(bob_active.map { |o| o[:order_id] }).to include('bob-partial')
    snapshot = exchange.order('bob-partial')
    expect(snapshot[:status]).to eq('PARTIALLY_FILLED')
    expect(snapshot[:remaining]).to eq(60_000_000)
    expect(redis.zcard("user_orders:bob:#{symbol}")).to eq(1)

    # 取消该部分成交订单后索引应移除
    cancel_outcome = exchange.cancel_order('bob-partial')
    expect(cancel_outcome[:status]).to eq('CANCELLED')
    expect(exchange.active_orders(user_id: 'bob', symbol: symbol)).to eq([])
    expect(redis.zcard("user_orders:bob:#{symbol}")).to eq(0)

    # 终态订单哈希应被删除
    expect(exchange.order('bob-partial')).to eq({})

    # 验证 orders 流的取消事件
    orders_entries = redis.xrevrange("orders:#{symbol}", '+', '-', count: 1)
    expect(orders_entries).not_to be_empty
    _, order_fields = orders_entries.first
    order_fields_hash = order_fields.is_a?(Hash) ? order_fields : Hash[*order_fields]
    expect(order_fields_hash['order_id']).to eq('bob-partial')
    expect(order_fields_hash['status']).to eq('CANCELLED')
    expect(order_fields_hash['symbol']).to eq(symbol)
    expect(order_fields_hash['remaining']).to eq('0')
  end

end