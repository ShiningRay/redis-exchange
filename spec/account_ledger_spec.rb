# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Account Ledger and Balance Changes' do
  let(:redis) { RSpec.configuration.redis_factory.call }
  let(:exchange) { RedisExchange::Client.new(redis: redis) }

  before do
    redis.flushdb
  end

  def last_ledger_entry
    entries = redis.xrevrange('account_ledger', '+', '-', count: 1)
    return nil if entries.nil? || entries.empty?
    raw_fields = entries.first[1]
    raw_fields.is_a?(Hash) ? raw_fields : (raw_fields.first.is_a?(Array) ? raw_fields.to_h : Hash[*raw_fields])
  end

  it '存款：更新available并写入账户流水' do
    result = exchange.add_funds(user_id: 'u1', asset: 'USDT', amount: 100_000)
    expect(result[:ok]).to eq(true)
    balances = redis.hgetall('balance:u1')
    expect(balances['USDT:available'].to_i).to eq(100_000)
    expect(balances['USDT:reserved'].to_i).to eq(0)

    entry = last_ledger_entry
    expect(entry).not_to be_nil
    expect(entry['user_id']).to eq('u1')
    expect(entry['asset']).to eq('USDT')
    expect(entry['action']).to eq('ADD')
    expect(entry['amount']).to eq('100000')
    expect(entry['reason']).to eq('DEPOSIT')
    expect(entry['sequence']).to eq('1')
    expect(entry['biz_id']).to eq(result[:biz_id])
    expect(redis.get('ledger_seq:u1:USDT')).to eq('1')
  end

  it '取款：余额充足时更新available并写入账户流水' do
    exchange.add_funds(user_id: 'u1', asset: 'USDT', amount: 100_000)
    result = exchange.sub_funds(user_id: 'u1', asset: 'USDT', amount: 40_000)
    expect(result[:ok]).to eq(true)

    balances = redis.hgetall('balance:u1')
    expect(balances['USDT:available'].to_i).to eq(60_000)
    expect(balances['USDT:reserved'].to_i).to eq(0)

    entry = last_ledger_entry
    expect(entry).not_to be_nil
    expect(entry['user_id']).to eq('u1')
    expect(entry['asset']).to eq('USDT')
    expect(entry['action']).to eq('SUB')
    expect(entry['amount']).to eq('40000')
    expect(entry['reason']).to eq('WITHDRAWAL')
    expect(entry['sequence']).to eq('2')
    expect(entry['biz_id']).to eq(result[:biz_id])
    expect(redis.get('ledger_seq:u1:USDT')).to eq('2')
  end

  it '取款：余额不足时返回错误且不写入账户流水' do
    result = exchange.sub_funds(user_id: 'u1', asset: 'USDT', amount: 50_000)
    expect(result[:error]).to eq('INSUFFICIENT_FUNDS')

    balances = redis.hgetall('balance:u1')
    expect(balances['USDT:available'].to_i).to eq(0)
    expect(balances['USDT:reserved'].to_i).to eq(0)

    entries = redis.xrevrange('account_ledger', '+', '-', count: 1)
    expect(entries).to be_empty
    expect(redis.get('ledger_seq:u1:USDT')).to be_nil
  end

  it 'reserved变更：写入reserved并投递账户流水' do
    result = exchange.operate_balance(user_id: 'u1', asset: 'BTC', action: RedisExchange::ACTION_ADD_LOCKED, amount: 10_000_000, reason: 'ORDER_RESERVE')
    expect(result[:ok]).to eq(true)
    balances = redis.hgetall('balance:u1')
    expect(balances['BTC:available'].to_i).to eq(0)
    expect(balances['BTC:reserved'].to_i).to eq(10_000_000)

    entry = last_ledger_entry
    expect(entry).not_to be_nil
    expect(entry['user_id']).to eq('u1')
    expect(entry['asset']).to eq('BTC')
    expect(entry['action']).to eq('ADD_LOCKED')
    expect(entry['amount']).to eq('10000000')
    expect(entry['reason']).to eq('ORDER_RESERVE')
    expect(entry['sequence']).to eq('1')
    expect(entry['biz_id']).to eq(result[:biz_id])
    expect(redis.get('ledger_seq:u1:BTC')).to eq('1')
  end

  it 'add_funds 支持 biz_id 幂等，重复提交不产生重复流水或余额变化' do
    # 首次调用，使用相同的 biz_id
    biz_id = 'req-123'
    r1 = exchange.add_funds(user_id: 'u1', asset: 'USDT', amount: 50_000, reason: 'MANUAL_ADJUST', biz_id: biz_id)
    expect(r1[:ok]).to eq(true)
    expect(r1[:amount]).to eq(50_000)

    # 重复调用同一请求，应返回缓存结果且不重复写入流水
    r2 = exchange.add_funds(user_id: 'u1', asset: 'USDT', amount: 50_000, reason: 'MANUAL_ADJUST', biz_id: biz_id)
    expect(r2[:ok]).to eq(true)
    expect(r2[:amount]).to eq(50_000)
    expect(r2[:sequence]).to eq(r1[:sequence])
    expect(r2[:ts]).to eq(r1[:ts])

    balances = redis.hgetall('balance:u1')
    expect(balances['USDT:available'].to_i).to eq(50_000)

    # 账户流水只应有一条记录
    entries = redis.xrevrange('account_ledger', '+', '-', count: 10)
    expect(entries.size).to eq(1)
    entry_fields = (entries.first&.last.is_a?(Hash) ? entries.first.last : (entries.first.last.first.is_a?(Array) ? entries.first.last.to_h : Hash[*entries.first.last]))
    expect(entry_fields['user_id']).to eq('u1')
    expect(entry_fields['asset']).to eq('USDT')
    expect(entry_fields['action']).to eq('ADD')
    expect(entry_fields['amount']).to eq('50000')
    expect(entry_fields['reason']).to eq('MANUAL_ADJUST')
    expect(entry_fields['biz_id']).to eq(biz_id)
  end

  it 'records a LOCK entry when an order is placed' do
    exchange.seed_asset(asset: 'BTC', balance_scale: 100_000_000)
    exchange.seed_asset(asset: 'USDT', balance_scale: 100)
    exchange.seed_market(symbol: 'BTC_USDT', base_asset: 'BTC', quote_asset: 'USDT', price_scale: 100, quantity_scale: 100_000_000, maker_fee_bps: 5, taker_fee_bps: 5)
    exchange.add_funds(user_id: 'u1', asset: 'USDT', amount: 1_000_000_000)

      # 1. Place a limit buy order
      result = exchange.place_limit_order(
        symbol: 'BTC_USDT',
        side: 'BUY',
        order_id: 'order-1',
        user_id: 'u1',
        price: 3_000_000,
        quantity: 10_000_000
      )
      expect(result[:error]).to be_nil, "Expected no error but got #{result[:error]} details: #{result[:details]}"
       expect(result[:status]).to eq('OPEN').or eq('FILLED')

      # 2. Verify account ledger
      entries = redis.xrevrange('account_ledger', '+', '-', count: 1)
      expect(entries).not_to be_empty
      _, fields = entries.first
      fields = fields.is_a?(Hash) ? fields : Hash[*fields]

      expect(fields['user_id']).to eq('u1')
      expect(fields['asset']).to eq('USDT')
      expect(fields['action']).to eq('LOCK')
      expect(fields['amount']).to eq('300150') # (3000000 * 10000000 / 10^8) * 1.0005
      expect(fields['reason']).to eq('TAKER_RESERVE')
      expect(fields['biz_id']).to match(/^order_submit:\d+:order-1$/)
    end

  it 'ledger_seq：按用户资产独立递增' do
    exchange.add_funds(user_id: 'u1', asset: 'USDT', amount: 100_000)
    exchange.add_funds(user_id: 'u1', asset: 'USDT', amount: 50_000)
    exchange.add_funds(user_id: 'u1', asset: 'BTC', amount: 1_000_000)

    expect(redis.get('ledger_seq:u1:USDT')).to eq('2')
    expect(redis.get('ledger_seq:u1:BTC')).to eq('1')

    # 最新一条应为 BTC 的存款记录
    entry = last_ledger_entry
    expect(entry['asset']).to eq('BTC')
    expect(entry['reason']).to eq('DEPOSIT')
    expect(entry['amount']).to eq('1000000')
  end

  context '自动缩放支持 (auto_scale)' do
    before do
      exchange.seed_asset(asset: 'BTC', balance_scale: 100_000_000)
      exchange.seed_asset(asset: 'USDT', balance_scale: 100)
    end

    it 'add_funds: 自动将小数金额转换为整数单位' do
      exchange.add_funds(user_id: 'u2', asset: 'BTC', amount: 1.5, auto_scale: true)
      expect(exchange.balances('u2')[:"BTC:available"]).to eq(150_000_000)

      exchange.add_funds(user_id: 'u2', asset: 'USDT', amount: 2500.5, auto_scale: true)
      expect(exchange.balances('u2')[:"USDT:available"]).to eq(250_050)
    end

    it 'sub_funds: 自动将小数金额转换为整数单位' do
      exchange.add_funds(user_id: 'u2', asset: 'BTC', amount: 150_000_000)
      exchange.sub_funds(user_id: 'u2', asset: 'BTC', amount: 0.5, auto_scale: true)
      expect(exchange.balances('u2')[:"BTC:available"]).to eq(100_000_000)
    end

    it 'operate_balance: 自动将小数金额转换为整数单位' do
      exchange.operate_balance(user_id: 'u2', asset: 'BTC', action: RedisExchange::ACTION_ADD, amount: 1.23, auto_scale: true)
      expect(exchange.balances('u2')[:"BTC:available"]).to eq(123_000_000)
    end

    it 'balances: 自动将整数单位余额转换为小数' do
      exchange.add_funds(user_id: 'u3', asset: 'BTC', amount: 150_000_000)
      exchange.add_funds(user_id: 'u3', asset: 'USDT', amount: 250_050)

      b = exchange.balances('u3', auto_scale: true)
      expect(b[:"BTC:available"]).to eq(1.5)
      expect(b[:"USDT:available"]).to eq(2500.5)
    end

    it 'balance: 查询单个币种余额并支持自动缩放' do
      exchange.add_funds(user_id: 'u4', asset: 'BTC', amount: 250_000_000)
      
      # Test without auto_scale (default)
      b_raw = exchange.balance(user_id: 'u4', asset: 'BTC')
      expect(b_raw[:available]).to eq(250_000_000)
      expect(b_raw[:reserved]).to eq(0)

      # Test with auto_scale
      b_scaled = exchange.balance(user_id: 'u4', asset: 'BTC', auto_scale: true)
      expect(b_scaled[:available]).to eq(2.5)
      expect(b_scaled[:reserved]).to eq(0.0)
    end
  end
end