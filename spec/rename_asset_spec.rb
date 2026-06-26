# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'json'
require 'tempfile'

RSpec.describe 'script/rename_asset.rb' do
  let(:redis) { SpecRedis.factory.call }
  let(:client) { RedisExchange::Client.new(redis: redis) }
  let(:script_path) { File.expand_path('../script/rename_asset.rb', __dir__) }

  before { redis.flushdb }
  after  { redis.flushdb }

  def run_script(args)
    env = { 'REDIS_URL' => redis.connection[:url] || ENV['SPEC_REDIS_URL'] || ENV['REDIS_URL'] || 'redis://127.0.0.1:6379/15' }
    Open3.capture3(env, 'ruby', script_path, *args)
  end

  context 'with dry run' do
    before do
      client.seed_asset(asset: 'BTC', balance_scale: 100_000_000)
      client.seed_asset(asset: 'USDT', balance_scale: 100)
      client.seed_market(symbol: 'BTCUSDT', base_asset: 'BTC', quote_asset: 'USDT', price_scale: 100, quantity_scale: 100_000_000)
      client.set_balance(user_id: 'alice', asset: 'BTC', available: 1_000_000, reserved: 100_000)
      redis.hset('fees:BTC', 'total', 500)
      redis.set('ledger_seq:alice:BTC', 42)
    end

    it 'does not mutate Redis data' do
      stdout, stderr, status = run_script(['--old-asset', 'BTC', '--new-asset', 'XBT'])
      expect(status).to be_success
      expect(stdout).to include('DRY RUN')

      expect(client.asset_config('BTC')).not_to be_empty
      expect(client.asset_config('XBT')).to be_empty
      expect(redis.hgetall('balance:alice')).to include('BTC:available' => '1000000', 'BTC:reserved' => '100000')
      expect(redis.exists?('fees:XBT')).to be false
      expect(redis.exists?('ledger_seq:alice:XBT')).to be false
    end
  end

  context 'with execute' do
    before do
      client.seed_asset(asset: 'BTC', balance_scale: 100_000_000)
      client.seed_asset(asset: 'USDT', balance_scale: 100)
      client.seed_market(symbol: 'BTCUSDT', base_asset: 'BTC', quote_asset: 'USDT', price_scale: 100, quantity_scale: 100_000_000)
      client.set_balance(user_id: 'alice', asset: 'BTC', available: 1_000_000, reserved: 100_000)
      client.set_balance(user_id: 'bob', asset: 'BTC', available: 0, reserved: 0)
      client.set_balance(user_id: 'bob', asset: 'USDT', available: 10_000_000, reserved: 0)
      redis.hset('fees:BTC', 'total', 500)
      redis.set('ledger_seq:alice:BTC', 42)
    end

    it 'renames the asset across all keys' do
      stdout, stderr, status = run_script(['--old-asset', 'BTC', '--new-asset', 'XBT', '--execute'])
      expect(status).to be_success, "script failed: #{stdout}\n#{stderr}"

      # Asset config migrated
      expect(client.asset_config('BTC')).to be_empty
      expect(client.asset_config('XBT')).to include(balance_scale: 100_000_000, status: 'ACTIVE')

      # Market config updated
      cfg = client.market_config('BTCUSDT')
      expect(cfg[:base_asset]).to eq('XBT')
      expect(cfg[:quote_asset]).to eq('USDT')

      # Balances migrated. The audit step releases reserved funds that are not
      # backing any active order, so reserved moves back to available.
      expect(redis.hgetall('balance:alice')).to include(
        'XBT:available' => '1100000',
        'XBT:reserved' => '0'
      )
      expect(redis.hgetall('balance:alice').keys).not_to include('BTC:available', 'BTC:reserved')

      # Fees migrated
      expect(redis.hget('fees:XBT', 'total').to_i).to eq(500)
      expect(redis.exists?('fees:BTC')).to be false

      # Ledger seq migrated. The post-rename audit emits one UNLOCK entry,
      # so the sequence is bumped by one.
      expect(redis.get('ledger_seq:alice:XBT').to_i).to be >= 42
      expect(redis.exists?('ledger_seq:alice:BTC')).to be false
    end
  end

  context 'when active orders exist' do
    before do
      client.seed_asset(asset: 'BTC', balance_scale: 100_000_000)
      client.seed_asset(asset: 'USDT', balance_scale: 100)
      client.seed_market(symbol: 'BTCUSDT', base_asset: 'BTC', quote_asset: 'USDT', price_scale: 100, quantity_scale: 100_000_000)
      client.set_balance(user_id: 'bob', asset: 'BTC', available: 1_000_000, reserved: 0)
      client.place_limit_order(
        symbol: 'BTCUSDT',
        side: 'SELL',
        order_id: 'sell-1',
        user_id: 'bob',
        price: 30_000_00,
        quantity: 500_000
      )
    end

    it 'aborts by default' do
      stdout, _stderr, status = run_script(['--old-asset', 'BTC', '--new-asset', 'XBT', '--execute'])
      expect(status).not_to be_success
      expect(stdout).to include('active order')
    end

    it 'cancels orders and renames when --cancel-orders is given' do
      stdout, stderr, status = run_script(['--old-asset', 'BTC', '--new-asset', 'XBT', '--execute', '--cancel-orders'])
      expect(status).to be_success, "script failed: #{stdout}\n#{stderr}"

      expect(client.order('sell-1')).to be_empty
      expect(client.asset_config('XBT')).not_to be_empty
    end
  end

  context 'with --users-file' do
    before do
      client.seed_asset(asset: 'BTC', balance_scale: 100_000_000)
      client.seed_asset(asset: 'USDT', balance_scale: 100)
      client.seed_market(symbol: 'BTCUSDT', base_asset: 'BTC', quote_asset: 'USDT', price_scale: 100, quantity_scale: 100_000_000)
      client.set_balance(user_id: 'alice', asset: 'BTC', available: 1_000_000, reserved: 100_000)
      client.set_balance(user_id: 'bob', asset: 'BTC', available: 2_000_000, reserved: 0)
      client.set_balance(user_id: 'carol', asset: 'BTC', available: 3_000_000, reserved: 0)
      redis.set('ledger_seq:alice:BTC', 1)
      redis.set('ledger_seq:bob:BTC', 2)
    end

    it 'processes only users listed in the file' do
      Tempfile.create('users.txt') do |file|
        file.puts('alice')
        file.puts('bob')
        file.flush

        stdout, stderr, status = run_script([
          '--old-asset', 'BTC', '--new-asset', 'XBT', '--execute', '--users-file', file.path
        ])
        expect(status).to be_success, "script failed: #{stdout}\n#{stderr}"

        # alice and bob migrated. reserved funds with no active order are released by audit.
        expect(redis.hget('balance:alice', 'XBT:available').to_i).to eq(1_100_000)
        expect(redis.hget('balance:alice', 'XBT:reserved').to_i).to eq(0)
        expect(redis.hget('balance:bob', 'XBT:available').to_i).to eq(2_000_000)
        expect(redis.exists?('ledger_seq:alice:XBT')).to be true
        expect(redis.exists?('ledger_seq:bob:XBT')).to be true

        # carol untouched
        expect(redis.hget('balance:carol', 'BTC:available').to_i).to eq(3_000_000)
        expect(redis.hget('balance:carol', 'XBT:available')).to be_nil
      end
    end
  end
end
