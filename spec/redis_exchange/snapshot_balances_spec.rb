# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Snapshot Balances', :snapshot_balances do
  let(:redis) { RSpec.configuration.redis_factory.call }
  let(:exchange) { RedisExchange::Client.new(redis: redis) }

  before do
    redis.flushdb
    # Seed assets
    exchange.seed_asset(asset: 'BTC', balance_scale: 1, status: 'ACTIVE')
    exchange.seed_asset(asset: 'USDT', balance_scale: 1, status: 'ACTIVE')
  end

  describe '#snapshot_balances' do
    let(:alice) { 'alice' }
    let(:bob) { 'bob' }

    it 'atomically retrieves all user balances' do
      # 1. Setup Initial State
      # Alice: 10 BTC Available, 5 BTC Reserved
      exchange.set_balance(user_id: alice, asset: 'BTC', available: 10)
      redis.hset("balance:#{alice}", 'BTC:reserved', 5)
      
      # Bob: 1000 USDT Available
      exchange.set_balance(user_id: bob, asset: 'USDT', available: 1000)

      # 2. Execute Snapshot
      snapshot = exchange.maintenance.snapshot_balances

      # 3. Verify Structure and Content
      # Expected format: { 'user_id' => { 'ASSET' => { 'available' => X, 'reserved' => Y } } }
      
      expect(snapshot).to be_a(Hash)
      expect(snapshot.keys).to include(alice, bob)

      # Verify Alice
      alice_data = snapshot[alice]
      expect(alice_data['BTC']['available']).to eq(10)
      expect(alice_data['BTC']['reserved']).to eq(5)
      
      # Verify Bob
      bob_data = snapshot[bob]
      expect(bob_data['USDT']['available']).to eq(1000)
      expect(bob_data['USDT']['reserved']).to eq(0) # Default should be 0 if not set
    end

    it 'returns empty hash when no balances exist' do
      snapshot = exchange.maintenance.snapshot_balances
      expect(snapshot).to eq({})
    end

    it 'writes snapshot to file when output_path is provided' do
      # Setup data
      exchange.set_balance(user_id: alice, asset: 'BTC', available: 10)
      
      # Temp file
      temp_file = File.join(Dir.tmpdir, "snapshot_#{Time.now.to_i}.json")
      
      begin
        result_path = exchange.maintenance.snapshot_balances(output_path: temp_file)
        
        expect(result_path).to eq(temp_file)
        expect(File.exist?(temp_file)).to be true
        
        content = File.read(temp_file)
        json = JSON.parse(content)
        
        expect(json).to be_a(Hash)
        expect(json[alice]['BTC']['available']).to eq(10)
      ensure
        File.delete(temp_file) if File.exist?(temp_file)
      end
    end
  end
end
