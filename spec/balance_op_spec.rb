# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Balance Operations' do
  let(:exchange) { RedisExchange::Client.new }
  let(:user_id) { "user_#{SecureRandom.hex(4)}" }
  let(:asset) { 'BTC' }
  
  before do
    exchange.redis.flushdb
    # Ensure asset exists for scaling tests (8 decimals = 10^8)
    exchange.redis.hset('asset:BTC', 'balance_scale', '100000000')
  end

  def parse_fields(raw_fields)
    raw_fields.is_a?(Hash) ? raw_fields : (raw_fields.first.is_a?(Array) ? raw_fields.to_h : Hash[*raw_fields])
  end

  describe '#operate_balance' do
    it 'supports ADD action' do
      res = exchange.operate_balance(user_id: user_id, asset: asset, action: 'ADD', amount: 100)
      expect(res[:ok]).to be true
      expect(res[:available]).to eq(100)
      
      bal = exchange.redis.hget("balance:#{user_id}", "#{asset}:available").to_i
      expect(bal).to eq(100)
      
      entries = exchange.redis.xrange('account_ledger', '-', '+')
      expect(entries.size).to eq(1)
      fields = parse_fields(entries.first[1])
      
      expect(fields['action']).to eq('ADD')
      expect(fields['amount']).to eq('100')
    end
    
    it 'supports SUB action with balance check' do
      exchange.operate_balance(user_id: user_id, asset: asset, action: 'ADD', amount: 100)
      
      res = exchange.operate_balance(user_id: user_id, asset: asset, action: 'SUB', amount: 40)
      expect(res[:ok]).to be true
      expect(res[:available]).to eq(60)
      
      # Insufficient funds
      res = exchange.operate_balance(user_id: user_id, asset: asset, action: 'SUB', amount: 100)
      expect(res[:error]).to eq('INSUFFICIENT_FUNDS')
    end
    
    it 'supports LOCK action' do
      exchange.operate_balance(user_id: user_id, asset: asset, action: 'ADD', amount: 100)
      
      res = exchange.lock_funds(user_id: user_id, asset: asset, amount: 30)
      expect(res[:ok]).to be true
      expect(res[:available]).to eq(70)
      expect(res[:reserved]).to eq(30)
      
      entries = exchange.redis.xrange('account_ledger', '-', '+')
      # 1 for ADD, 1 for LOCK (transfers emit 1 entry with new schema?) 
      # My Lua script emits ONE entry with action='LOCK'
      expect(entries.size).to eq(2)
      last_fields = parse_fields(entries.last[1])
      expect(last_fields['action']).to eq('LOCK')
      expect(last_fields['amount']).to eq('30')
    end
    
    it 'supports UNLOCK action' do
      exchange.operate_balance(user_id: user_id, asset: asset, action: 'ADD', amount: 100)
      exchange.lock_funds(user_id: user_id, asset: asset, amount: 30)
      
      res = exchange.unlock_funds(user_id: user_id, asset: asset, amount: 10)
      expect(res[:ok]).to be true
      expect(res[:available]).to eq(80)
      expect(res[:reserved]).to eq(20)
      
      entries = exchange.redis.xrange('account_ledger', '-', '+')
      expect(entries.size).to eq(3)
      last_fields = parse_fields(entries.last[1])
      expect(last_fields['action']).to eq('UNLOCK')
      expect(last_fields['amount']).to eq('10')
    end
    
    it 'supports SUB_LOCKED action' do
      exchange.operate_balance(user_id: user_id, asset: asset, action: 'ADD', amount: 100)
      exchange.lock_funds(user_id: user_id, asset: asset, amount: 30)
      
      res = exchange.operate_balance(user_id: user_id, asset: asset, action: 'SUB_LOCKED', amount: 10)
      expect(res[:ok]).to be true
      expect(res[:reserved]).to eq(20)
      
      entries = exchange.redis.xrange('account_ledger', '-', '+')
      last_fields = parse_fields(entries.last[1])
      expect(last_fields['action']).to eq('SUB_LOCKED')
      expect(last_fields['amount']).to eq('10')
    end
    
    it 'supports auto_scale' do
      # 1.5 * 10^8 = 150000000
      res = exchange.operate_balance(user_id: user_id, asset: asset, action: 'ADD', amount: 1.5, auto_scale: true)
      expect(res[:amount]).to eq(150_000_000)
      expect(res[:available]).to eq(150_000_000)
    end
    
    it 'handles idempotency' do
      biz_id = "biz_#{SecureRandom.hex}"
      res1 = exchange.operate_balance(user_id: user_id, asset: asset, action: 'ADD', amount: 100, biz_id: biz_id)
      res2 = exchange.operate_balance(user_id: user_id, asset: asset, action: 'ADD', amount: 100, biz_id: biz_id)
      
      expect(res1[:sequence]).to eq(res2[:sequence])
      expect(exchange.redis.hget("balance:#{user_id}", "#{asset}:available").to_i).to eq(100)
    end
  end
end
