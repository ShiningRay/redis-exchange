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
    _, fields = entries.first
    fields.is_a?(Hash) ? fields : Hash[*fields]
  end

  it '存款：更新available并写入账户流水' do
    result = exchange.deposit(user_id: 'u1', asset: 'USDT', amount: 100_000)
    expect(result[:ok]).to eq(true)
    balances = redis.hgetall('balance:u1')
    expect(balances['USDT:available'].to_i).to eq(100_000)
    expect(balances['USDT:reserved'].to_i).to eq(0)

    entry = last_ledger_entry
    expect(entry).not_to be_nil
    expect(entry['user_id']).to eq('u1')
    expect(entry['asset']).to eq('USDT')
    expect(entry['bucket']).to eq('available')
    expect(entry['delta']).to eq('100000')
    expect(entry['reason']).to eq('DEPOSIT')
    expect(entry['sequence']).to eq('1')
    expect(redis.get('ledger_seq:u1:USDT')).to eq('1')
  end

  it '取款：余额充足时更新available并写入账户流水' do
    exchange.deposit(user_id: 'u1', asset: 'USDT', amount: 100_000)
    result = exchange.withdraw(user_id: 'u1', asset: 'USDT', amount: 40_000)
    expect(result[:ok]).to eq(true)

    balances = redis.hgetall('balance:u1')
    expect(balances['USDT:available'].to_i).to eq(60_000)
    expect(balances['USDT:reserved'].to_i).to eq(0)

    entry = last_ledger_entry
    expect(entry).not_to be_nil
    expect(entry['user_id']).to eq('u1')
    expect(entry['asset']).to eq('USDT')
    expect(entry['bucket']).to eq('available')
    expect(entry['delta']).to eq('-40000')
    expect(entry['reason']).to eq('WITHDRAWAL')
    expect(entry['sequence']).to eq('2')
    expect(redis.get('ledger_seq:u1:USDT')).to eq('2')
  end

  it '取款：余额不足时返回错误且不写入账户流水' do
    result = exchange.withdraw(user_id: 'u1', asset: 'USDT', amount: 50_000)
    expect(result[:error]).to eq('INSUFFICIENT_FUNDS')

    balances = redis.hgetall('balance:u1')
    expect(balances['USDT:available'].to_i).to eq(0)
    expect(balances['USDT:reserved'].to_i).to eq(0)

    entries = redis.xrevrange('account_ledger', '+', '-', count: 1)
    expect(entries).to be_empty
    expect(redis.get('ledger_seq:u1:USDT')).to be_nil
  end

  it 'reserved变更：写入reserved并投递账户流水' do
    result = exchange.change_balance(user_id: 'u1', asset: 'BTC', bucket: 'reserved', delta: 10_000_000, reason: 'ORDER_RESERVE')
    expect(result[:ok]).to eq(true)
    balances = redis.hgetall('balance:u1')
    expect(balances['BTC:available'].to_i).to eq(0)
    expect(balances['BTC:reserved'].to_i).to eq(10_000_000)

    entry = last_ledger_entry
    expect(entry).not_to be_nil
    expect(entry['user_id']).to eq('u1')
    expect(entry['asset']).to eq('BTC')
    expect(entry['bucket']).to eq('reserved')
    expect(entry['delta']).to eq('10000000')
    expect(entry['reason']).to eq('ORDER_RESERVE')
    expect(entry['sequence']).to eq('1')
    expect(redis.get('ledger_seq:u1:BTC')).to eq('1')
  end

  it 'ledger_seq：按用户资产独立递增' do
    exchange.deposit(user_id: 'u1', asset: 'USDT', amount: 100_000)
    exchange.deposit(user_id: 'u1', asset: 'USDT', amount: 50_000)
    exchange.deposit(user_id: 'u1', asset: 'BTC', amount: 1_000_000)

    expect(redis.get('ledger_seq:u1:USDT')).to eq('2')
    expect(redis.get('ledger_seq:u1:BTC')).to eq('1')

    # 最新一条应为 BTC 的存款记录
    entry = last_ledger_entry
    expect(entry['asset']).to eq('BTC')
    expect(entry['reason']).to eq('DEPOSIT')
    expect(entry['delta']).to eq('1000000')
  end
end