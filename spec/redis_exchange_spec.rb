# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe RedisExchange::Client do
  let(:redis) { RSpec.configuration.redis_factory.call }
  let(:exchange) { described_class.new(redis: redis) }
  let(:symbol) { 'BTCUSDT' }

  before do
    redis.flushdb
    exchange.seed_market(
      symbol: symbol,
      base_asset: 'BTC',
      quote_asset: 'USDT',
      price_scale: 100,  
      quantity_scale: 100_000_000,
      maker_fee_bps: 5,
      taker_fee_bps: 10,
      min_qty: 100_000,
      min_notional: 1_000
    )
  end

  describe "#place_limit_order" do
    context "user has sufficient balance" do
      it 'rests a limit order when no opposite liquidity exists' do
        exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 100_000_000)

        result = exchange.place_limit_order(
          symbol: symbol,
          side: 'SELL',
          order_id: 'order-1',
          user_id: 'maker',
          price: 3_000_000, # 30000.00000000 USDT
          quantity: 100_000_000 # 1.00000000 BTC
        )

        expect(result['status']).to eq('OPEN')
        expect(result['remaining_quantity']).to eq(100_000_000)
        queue = redis.lrange('queue:BTCUSDT:SELL:3000000', 0, -1)
        expect(queue).to eq(['order-1'])

        balances = redis.hgetall('balance:maker')
        expect(balances['BTC:available'].to_i).to eq(0)
        expect(balances['BTC:reserved'].to_i).to eq(100_000_000)

        ticker = exchange.ticker(symbol)
        expect(ticker[:best_ask_price]).to eq(3_000_000)
        expect(ticker[:best_ask_volume]).to eq(100_000_000)
        expect(ticker[:best_bid_price]).to eq(0)
        expect(ticker[:best_bid_volume]).to eq(0)
        expect(ticker[:last_price]).to eq(0)

        book = exchange.order_book(symbol)
        expect(book[:asks].map { |row| row[:price] }).to eq([3_000_000])
        expect(book[:asks].first[:volume]).to eq(100_000_000)
        expect(book[:bids]).to be_empty
      end

      it 'rests a limit buy order when no opposite liquidity exists' do
        # 买方先充入 USDT 余额，足以覆盖名义金额与预估手续费
        exchange.set_balance(user_id: 'buyer', asset: 'USDT', available: 5_000_000) # 50000.00000000 USDT

        result = exchange.place_limit_order(
          symbol: symbol,
          side: 'BUY',
          order_id: 'order-buy-1',
          user_id: 'buyer',
          price: 3_000_000, # 30000.00000000 USDT
          quantity: 100_000_000 # 1.00000000 BTC
        )

        expect(result['status']).to eq('OPEN')
        expect(result['remaining_quantity']).to eq(100_000_000)
        queue = redis.lrange('queue:BTCUSDT:BUY:3000000', 0, -1)
        expect(queue).to eq(['order-buy-1'])

        # 预留金额仅为名义金额：reserve_quote = floor(3_000_000 * 100_000_000 / 100_000_000) = 3_000_000
        balances = redis.hgetall('balance:buyer')
        expect(balances['USDT:available'].to_i).to eq(5_000_000 - 3_000_000)
        expect(balances['USDT:reserved'].to_i).to eq(3_000_000)
        expect(balances.fetch('BTC:available', '0').to_i).to eq(0)
        expect(balances.fetch('BTC:reserved', '0').to_i).to eq(0)

        ticker = exchange.ticker(symbol)
        expect(ticker[:best_bid_price]).to eq(3_000_000)
        expect(ticker[:best_bid_volume]).to eq(100_000_000)
        expect(ticker[:best_ask_price]).to eq(0)
        expect(ticker[:best_ask_volume]).to eq(0)
        expect(ticker[:last_price]).to eq(0)

        book = exchange.order_book(symbol)
        expect(book[:bids].map { |row| row[:price] }).to eq([3_000_000])
        expect(book[:bids].first[:volume]).to eq(100_000_000)
        expect(book[:asks]).to be_empty
      end
    end
    context "user has insufficient balance" do
      it 'rejects limit BUY when available quote is insufficient to reserve' do
        # USDT 余额不足以预留名义金额
        exchange.set_balance(user_id: 'poor_buyer', asset: 'USDT', available: 2_000_000) # 20000.00000000 USDT

        result = exchange.place_limit_order(
          symbol: symbol,
          side: 'BUY',
          order_id: 'insufficient-buy-1',
          user_id: 'poor_buyer',
          price: 3_000_000, # 30000.00000000 USDT
          quantity: 100_000_000 # 1.00000000 BTC
        )

        expect(result['error']).to eq('INSUFFICIENT_FUNDS')
        expect(result['asset']).to eq('USDT')

        # 不应产生队列或余额变化（除非预留成功）
        expect(redis.lrange('queue:BTCUSDT:BUY:3000000', 0, -1)).to be_empty
        balances = redis.hgetall('balance:poor_buyer')
        expect(balances['USDT:available'].to_i).to eq(2_000_000)
        expect(balances.fetch('USDT:reserved', '0').to_i).to eq(0)

        volume = redis.hgetall('volume:BTCUSDT:BUY')
        expect(volume.fetch('3000000', '0').to_i).to eq(0)
      end

      it 'rejects limit SELL when available base is insufficient to reserve' do
        # BTC 余额不足以预留挂单数量
        exchange.set_balance(user_id: 'poor_seller', asset: 'BTC', available: 50_000_000) # 0.50000000 BTC

        result = exchange.place_limit_order(
          symbol: symbol,
          side: 'SELL',
          order_id: 'insufficient-sell-1',
          user_id: 'poor_seller',
          price: 3_000_000,
          quantity: 100_000_000 # 1.00000000 BTC
        )

        expect(result['error']).to eq('INSUFFICIENT_FUNDS')
        expect(result['asset']).to eq('BTC')

        # 不应产生队列或余额变化
        expect(redis.lrange('queue:BTCUSDT:SELL:3000000', 0, -1)).to be_empty
        balances = redis.hgetall('balance:poor_seller')
        expect(balances['BTC:available'].to_i).to eq(50_000_000)
        expect(balances.fetch('BTC:reserved', '0').to_i).to eq(0)

        volume = redis.hgetall('volume:BTCUSDT:SELL')
        expect(volume.fetch('3000000', '0').to_i).to eq(0)
      end
    end

    context "order with dupliated id exists" do 
      it 'rejects a duplicate limit order with the same order_id' do
        exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 100_000_000)

        first = exchange.place_limit_order(
          symbol: symbol,
          side: 'SELL',
          order_id: 'dupe-1',
          user_id: 'maker',
          price: 3_000_000,
          quantity: 100_000_000
        )

        expect(first['status']).to eq('OPEN')

        duplicate = exchange.place_limit_order(
          symbol: symbol,
          side: 'SELL',
          order_id: 'dupe-1',
          user_id: 'maker',
          price: 3_000_000,
          quantity: 100_000_000
        )

        expect(duplicate['error']).to eq('DUPLICATE_ORDER_ID')
        queue = redis.lrange('queue:BTCUSDT:SELL:3000000', 0, -1)
        expect(queue).to eq(%w[dupe-1])

        balances = redis.hgetall('balance:maker')
        expect(balances['BTC:available'].to_i).to eq(0)
        expect(balances['BTC:reserved'].to_i).to eq(100_000_000)
      end
    end
  end

  describe "#cancel_order" do
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

      expect(outcome['status']).to eq('CANCELLED')
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

  describe "#order" do
    it 'retrieves typed order snapshot by id' do
      exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 100_000_000)
      exchange.place_limit_order(
        symbol: symbol,
        side: 'SELL',
        order_id: 'query-1',
        user_id: 'maker',
        price: 3_000_000,
        quantity: 100_000_000
      )

      snapshot = exchange.order('query-1')
      expect(snapshot[:order_id]).to eq('query-1')
      expect(snapshot[:symbol]).to eq(symbol)
      expect(snapshot[:side]).to eq('SELL')
      expect(snapshot[:type]).to eq('LIMIT')
      expect(snapshot[:status]).to eq('OPEN')
      expect(snapshot[:price]).to eq(3_000_000)
      expect(snapshot[:quantity]).to eq(100_000_000)
      expect(snapshot[:remaining]).to eq(100_000_000)
      expect(snapshot[:sequence]).to be_a(Integer)
      expect(snapshot[:created_at]).to be_a(Integer)

      expect(exchange.order('nonexistent')).to eq({})
    end
  end 

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

      expect(cancelled.map { |row| row['order_id'] }).to match_array(%w[bulk-1 bulk-2])

      expect(redis.lrange('queue:BTCUSDT:SELL:3000000', 0, -1)).to be_empty
      expect(redis.lrange('queue:BTCUSDT:SELL:3100000', 0, -1)).to be_empty
      expect(redis.lrange('queue:BTCUSDT:SELL:3200000', 0, -1)).to eq(['other-1'])

      volume = redis.hgetall('volume:BTCUSDT:SELL')
      expect(volume.fetch('3000000', '0').to_i).to eq(0)
      expect(volume.fetch('3100000', '0').to_i).to eq(0)
      expect(volume.fetch('3200000', '0').to_i).to eq(100_000_000)

      balances = exchange.balances('maker')
      expect(balances[:'BTC:available']).to eq(200_000_000)
      expect(balances[:'BTC:reserved']).to eq(0)

      %w[bulk-1 bulk-2].each do |order_id|
        # 取消后的终态订单哈希应被删除
        expect(exchange.order(order_id)).to eq({})
      end

      # 验证 orders 流包含两条取消事件
      recent = redis.xrevrange("orders:#{symbol}", '+', '-', count: 5)
      ids_status = recent.map { |(_, f)| (f.is_a?(Hash) ? f : Hash[*f]) }.map { |h| [h['order_id'], h['status']] }
      expect(ids_status).to include(['bulk-1', 'CANCELLED'])
      expect(ids_status).to include(['bulk-2', 'CANCELLED'])

      other_snapshot = redis.hgetall('order:other-1')
      expect(other_snapshot['status']).to eq('OPEN')
      expect(other_snapshot['remaining']).to eq('100000000')

      book = exchange.order_book(symbol)
      ask_entry = book[:asks].find { |row| row[:price] == 3_200_000 }
      expect(ask_entry).not_to be_nil
      expect(ask_entry[:volume]).to eq(100_000_000)
    end
  end

  it 'matches a market order against resting liquidity' do
    exchange.set_balance(user_id: 'bob', asset: 'BTC', available: 200_000_000) # 200.00000000 BTC
    exchange.place_limit_order(
      symbol: symbol,
      side: 'SELL', 
      order_id: 'maker-1',
      user_id: 'bob',
      price: 3_000_000, # 30000.00000000 USDT
      quantity: 100_000_000 # 1.00000000 BTC
    ) # SELL, lock BTC

    exchange.set_balance(user_id: 'alice', asset: 'USDT', available: 5_000_000) # 50000.00000000 USDT

    result = exchange.place_market_order(
      symbol: symbol,
      side: 'BUY',
      order_id: 'taker-1',
      user_id: 'alice',
      quantity: 50_000_000, # 0.500000000 BTC
      price_cap: 3_100_000 # 31000.00000000 USDT
    ) # BUY, Spent 15000 USDT 

    expect(result['status']).to eq('FILLED')
    expect(result['executed_quantity']).to eq(50_000_000) # 0.500000000 BTC

    alice_balances = redis.hgetall('balance:alice')
    expect(alice_balances['BTC:available'].to_i).to eq(50_000_000) # 0.500000000 BTC
    # USDT 可用余额精确校验：trade_quote=1_500_000, taker_fee=1_500 → debit=1_501_500 → 5_000_000-1_501_500=3_498_500
    expect(alice_balances['USDT:available'].to_i).to eq(3_498_500) # 34985.00 USDT
    expect(alice_balances['USDT:reserved'].to_i).to eq(0)

    bob_balances = redis.hgetall('balance:bob')
    # BTC 预留余额减少 50_000_000，剩余 50_000_000；可用余额保持 100_000_000
    expect(bob_balances['BTC:reserved'].to_i).to eq(50_000_000) # 50.00000000 BTC
    expect(bob_balances['BTC:available'].to_i).to eq(100_000_000)
    # USDT 可用余额精确校验：maker_fee=750 → credit=1_500_000-750=1_499_250
    expect(bob_balances['USDT:available'].to_i).to eq(1_499_250) 

    ticker = exchange.ticker(symbol)
    expect(ticker[:last_price]).to eq(3_000_000) # 30000.00000000 USDT
    expect(ticker[:best_ask_price]).to eq(3_000_000) # 30000.00000000 USDT
    expect(ticker[:best_ask_volume]).to eq(50_000_000) # 50.00000000 BTC
    expect(ticker[:best_bid_price]).to eq(0)
    expect(ticker[:best_bid_volume]).to eq(0)

    book = exchange.order_book(symbol)
    expect(book[:asks].first[:price]).to eq(3_000_000)
    expect(book[:asks].first[:volume]).to eq(50_000_000)
    expect(book[:bids]).to be_empty

    # Verify trades returned in response
    trades = result['trades']
    expect(trades).to be_an(Array)
    expect(trades.size).to eq(1)
    trade = trades.first
    expect(trade['taker_order_id']).to eq('taker-1')
    expect(trade['maker_order_id']).to eq('maker-1')
    expect(trade['buy_order_id']).to eq('taker-1')
    expect(trade['sell_order_id']).to eq('maker-1')
    expect(trade['taker_side']).to eq('BUY')
    expect(trade['price']).to eq(3_000_000)
    expect(trade['quantity']).to eq(50_000_000)
    expect(trade['timestamp']).to be_a(Integer)

    # Verify trade stream entry in Redis (values stored as strings)
    stream_entries = redis.xrevrange('trades:BTCUSDT', '+', '-', count: 1)
    expect(stream_entries).not_to be_empty
    entry_id, fields = stream_entries.first
    fields_hash = fields.is_a?(Hash) ? fields : Hash[*fields]
    expect(fields_hash['taker_order_id']).to eq('taker-1')
    expect(fields_hash['maker_order_id']).to eq('maker-1')
    expect(fields_hash['buy_order_id']).to eq('taker-1')
    expect(fields_hash['sell_order_id']).to eq('maker-1')
    expect(fields_hash['taker_side']).to eq('BUY')
    expect(fields_hash['price']).to eq('3000000')
    expect(fields_hash['quantity']).to eq('50000000')
    expect(fields_hash['symbol']).to eq('BTCUSDT')
  end

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
      expect(result['status']).to eq('OPEN')
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
    expect(result_full['status']).to eq('FILLED')

    # 完全成交后索引应移除 bob-full
    expect(exchange.active_orders(user_id: 'bob', symbol: symbol)).to eq([])
    expect(redis.zcard("user_orders:bob:#{symbol}")).to eq(0)

    # Bob 再创建一笔并部分成交，索引应保留该订单
    exchange.place_limit_order(
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
    expect(result_partial['status']).to eq('FILLED')

    bob_active = exchange.active_orders(user_id: 'bob', symbol: symbol)
    expect(bob_active.map { |o| o[:order_id] }).to include('bob-partial')
    snapshot = exchange.order('bob-partial')
    expect(snapshot[:status]).to eq('PARTIALLY_FILLED')
    expect(snapshot[:remaining]).to eq(60_000_000)
    expect(redis.zcard("user_orders:bob:#{symbol}")).to eq(1)

    # 取消该部分成交订单后索引应移除
    cancel_outcome = exchange.cancel_order('bob-partial')
    expect(cancel_outcome['status']).to eq('CANCELLED')
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

  it 'publishes taker and maker order events and deletes terminal hashes' do
    # Maker 两笔：一笔会被完全成交，一笔部分成交
    exchange.set_balance(user_id: 'maker-x', asset: 'BTC', available: 200_000_000)
    exchange.place_limit_order(symbol: symbol, side: 'SELL', order_id: 'm-full', user_id: 'maker-x', price: 3_000_000, quantity: 100_000_000)
    exchange.place_limit_order(symbol: symbol, side: 'SELL', order_id: 'm-partial', user_id: 'maker-x', price: 3_000_000, quantity: 100_000_000)

    # Taker 吃掉 150_000_000：完全吃掉第一笔，第二笔部分保留
    exchange.set_balance(user_id: 'taker-x', asset: 'USDT', available: 1_000_000_000)
    res = exchange.place_market_order(symbol: symbol, side: 'BUY', order_id: 'taker-x-1', user_id: 'taker-x', quantity: 150_000_000, price_cap: 3_100_000)
    expect(%w[FILLED PARTIALLY_FILLED OPEN]).to include(res['status'])

    # Maker 完全成交的哈希应删除
    expect(exchange.order('m-full')).to eq({})
    # Maker 部分成交的哈希仍存在
    snap_partial = exchange.order('m-partial')
    expect(snap_partial[:status]).to eq('PARTIALLY_FILLED')
    expect(snap_partial[:remaining]).to be > 0

    # Taker 终态（FILLED 或 NO_LIQUIDITY）应删除其哈希；否则保留
    taker_snap = exchange.order('taker-x-1')
    if res['status'] == 'FILLED' || res['status'] == 'NO_LIQUIDITY'
      expect(taker_snap).to eq({})
    else
      expect(taker_snap[:status]).to eq(res['status'])
    end

    # 校验 orders 流最近的若干事件包含 maker/taker 记录
    recent_orders = redis.xrevrange("orders:#{symbol}", '+', '-', count: 5)
    ids = recent_orders.map { |(_, f)| (f.is_a?(Hash) ? f : Hash[*f])['order_id'] }
    expect(ids).to include('m-full')
    expect(ids).to include('m-partial')
    expect(ids).to include('taker-x-1')
  end

  after do
    redis.close if redis.respond_to?(:close)
  end
end
