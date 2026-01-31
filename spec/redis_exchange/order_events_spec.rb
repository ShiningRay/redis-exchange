# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RedisExchange::Client do

  it 'publishes taker and maker order events and deletes terminal hashes' do
    # Maker 两笔：一笔会被完全成交，一笔部分成交
    exchange.set_balance(user_id: 'maker-x', asset: 'BTC', available: 200_000_000)
    exchange.place_limit_order(symbol: symbol, side: 'SELL', order_id: 'm-full', user_id: 'maker-x', price: 3_000_000, quantity: 100_000_000)
    exchange.place_limit_order(symbol: symbol, side: 'SELL', order_id: 'm-partial', user_id: 'maker-x', price: 3_000_000, quantity: 100_000_000)

    # Taker 吃掉 150_000_000：完全吃掉第一笔，第二笔部分保留
    exchange.set_balance(user_id: 'taker-x', asset: 'USDT', available: 1_000_000_000)
    res = exchange.place_market_order(symbol: symbol, side: 'BUY', order_id: 'taker-x-1', user_id: 'taker-x', quantity: 150_000_000, price_cap: 3_100_000)
    expect(%w[FILLED PARTIALLY_FILLED OPEN]).to include(res[:status])

    # Maker 完全成交的哈希应删除
    expect(exchange.order('m-full')).to eq({})
    # Maker 部分成交的哈希仍存在
    snap_partial = exchange.order('m-partial')
    expect(snap_partial[:status]).to eq('PARTIALLY_FILLED')
    expect(snap_partial[:remaining]).to be > 0

    # Taker 终态（FILLED 或 NO_LIQUIDITY）应删除其哈希；否则保留
    taker_snap = exchange.order('taker-x-1')
    if res[:status] == 'FILLED' || res[:status] == 'NO_LIQUIDITY'
      expect(taker_snap).to eq({})
    else
      expect(taker_snap[:status]).to eq(res[:status])
    end

    # 校验 orders 流最近的若干事件包含 maker/taker 记录
    recent_orders = redis.xrevrange("orders:#{symbol}", '+', '-', count: 5)
    ids = recent_orders.map { |(_, f)| (f.is_a?(Hash) ? f : Hash[*f])['order_id'] }
    expect(ids).to include('m-full')
    expect(ids).to include('m-partial')
    expect(ids).to include('taker-x-1')

    # Check executed_quote for taker order
    taker_event = recent_orders.find { |(_, f)| (f.is_a?(Hash) ? f : Hash[*f])['order_id'] == 'taker-x-1' }
    fields = taker_event[1].is_a?(Hash) ? taker_event[1] : Hash[*taker_event[1]]
    
    # Taker quantity 150_000_000 (1.5 BTC) matched at 3,000,000 (30,000.00 USDT)
    # Executed Quote = 3,000,000 * 150,000,000 / 100,000,000 = 4,500,000
    expect(fields).to have_key('executed_quote')
    expect(fields['executed_quote']).to eq('4500000')
  end

  end