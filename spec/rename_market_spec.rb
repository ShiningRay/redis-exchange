# frozen_string_literal: true

require 'spec_helper'
require 'open3'

RSpec.describe 'script/rename_market.rb' do
  let(:redis) { SpecRedis.factory.call }
  let(:client) { RedisExchange::Client.new(redis: redis) }
  let(:script_path) { File.expand_path('../script/rename_market.rb', __dir__) }

  before { redis.flushdb }
  after  { redis.flushdb }

  def run_script(args)
    env = { 'REDIS_URL' => redis.connection[:url] || ENV['SPEC_REDIS_URL'] || ENV['REDIS_URL'] || 'redis://127.0.0.1:6379/15' }
    Open3.capture3(env, 'ruby', script_path, *args)
  end

  def seed_btcusdt
    client.seed_asset(asset: 'BTC', balance_scale: 100_000_000)
    client.seed_asset(asset: 'USDT', balance_scale: 100)
    client.seed_market(symbol: 'BTCUSDT', base_asset: 'BTC', quote_asset: 'USDT', price_scale: 100, quantity_scale: 100_000_000)
  end

  context 'with dry run' do
    before do
      seed_btcusdt
      client.set_balance(user_id: 'alice', asset: 'BTC', available: 1_000_000, reserved: 0)
      client.place_limit_order(symbol: 'BTCUSDT', side: 'SELL', order_id: 's1', user_id: 'alice', price: 30_000_00, quantity: 100_000)
    end

    it 'does not mutate Redis data' do
      stdout, stderr, status = run_script(['--old-symbol', 'BTCUSDT', '--new-symbol', 'XBTUSDT'])
      expect(status).to be_success
      expect(stdout).to include('DRY RUN')

      expect(client.market_config('BTCUSDT')).not_to be_empty
      expect(client.market_config('XBTUSDT')).to be_empty
      expect(client.order('s1')[:symbol]).to eq('BTCUSDT')
      expect(redis.exists?('book:XBTUSDT:SELL')).to be false
      expect(redis.exists?('book:BTCUSDT:SELL')).to be true
    end
  end

  context 'with execute' do
    before do
      seed_btcusdt
      client.set_balance(user_id: 'alice', asset: 'BTC', available: 1_000_000, reserved: 0)
      client.set_balance(user_id: 'bob', asset: 'USDT', available: 1_000_000_000, reserved: 0)
      client.place_limit_order(symbol: 'BTCUSDT', side: 'SELL', order_id: 's1', user_id: 'alice', price: 30_000_00, quantity: 100_000)
      client.place_limit_order(symbol: 'BTCUSDT', side: 'BUY', order_id: 'b1', user_id: 'bob', price: 29_000_00, quantity: 50_000)
      redis.hset('ticker:BTCUSDT', 'last_price', '3000000')
    end

    it 'renames the market and migrates order book' do
      stdout, stderr, status = run_script(['--old-symbol', 'BTCUSDT', '--new-symbol', 'XBTUSDT', '--execute'])
      expect(status).to be_success, "script failed: #{stdout}\n#{stderr}"

      # Old market gone, new market exists
      expect(client.market_config('BTCUSDT')).to be_empty
      expect(client.market_config('XBTUSDT')).to include(base_asset: 'BTC', quote_asset: 'USDT')

      # Order book migrated
      expect(redis.exists?('book:BTCUSDT:SELL')).to be false
      expect(redis.exists?('book:XBTUSDT:SELL')).to be true
      expect(redis.zrange('book:XBTUSDT:SELL', 0, -1)).to eq(['3000000'])
      expect(redis.exists?('book:XBTUSDT:BUY')).to be true
      expect(redis.zrange('book:XBTUSDT:BUY', 0, -1)).to eq(['2900000'])

      # Queues migrated
      expect(redis.lrange('queue:XBTUSDT:SELL:3000000', 0, -1)).to eq(['s1'])
      expect(redis.lrange('queue:XBTUSDT:BUY:2900000', 0, -1)).to eq(['b1'])

      # Volume migrated
      expect(redis.hget('volume:XBTUSDT:SELL', '3000000').to_i).to eq(100_000)
      expect(redis.hget('volume:XBTUSDT:BUY', '2900000').to_i).to eq(50_000)

      # Order hashes updated
      expect(client.order('s1')[:symbol]).to eq('XBTUSDT')
      expect(client.order('b1')[:symbol]).to eq('XBTUSDT')

      # User order indexes migrated
      expect(redis.zrange('user_orders:alice:XBTUSDT', 0, -1)).to include('s1')
      expect(redis.zrange('user_orders:bob:XBTUSDT', 0, -1)).to include('b1')
      expect(redis.exists?('user_orders:alice:BTCUSDT')).to be false

      # Ticker migrated
      expect(redis.hget('ticker:XBTUSDT', 'last_price').to_i).to eq(3_000_000)

      # Order/Trade streams only exist after matching events. Since this test only
      # places limit orders, no streams were created yet; both old and new absent.
      expect(redis.exists?('trades:BTCUSDT')).to be false
      expect(redis.exists?('trades:XBTUSDT')).to be false
    end
  end

  context 'with --reset-streams' do
    before do
      seed_btcusdt
      client.set_balance(user_id: 'alice', asset: 'BTC', available: 1_000_000, reserved: 0)
      client.place_limit_order(symbol: 'BTCUSDT', side: 'SELL', order_id: 's1', user_id: 'alice', price: 30_000_00, quantity: 100_000)
      redis.xadd('trades:BTCUSDT', { price: '1' }, maxlen: 1000, approximate: true)
      redis.xadd('orders:BTCUSDT', { status: 'OPEN' }, maxlen: 1000, approximate: true)
    end

    it 'preserves old streams and does not create new ones' do
      stdout, stderr, status = run_script(['--old-symbol', 'BTCUSDT', '--new-symbol', 'XBTUSDT', '--execute', '--reset-streams'])
      expect(status).to be_success, "script failed: #{stdout}\n#{stderr}"

      expect(redis.exists?('trades:BTCUSDT')).to be true
      expect(redis.exists?('orders:BTCUSDT')).to be true
      expect(redis.exists?('trades:XBTUSDT')).to be false
      expect(redis.exists?('orders:XBTUSDT')).to be false
    end
  end

  context 'when streams exist and are renamed' do
    before do
      seed_btcusdt
      redis.xadd('trades:BTCUSDT', { price: '1' }, maxlen: 1000, approximate: true)
      redis.xadd('orders:BTCUSDT', { status: 'OPEN' }, maxlen: 1000, approximate: true)
    end

    it 'renames the streams preserving history' do
      stdout, stderr, status = run_script(['--old-symbol', 'BTCUSDT', '--new-symbol', 'XBTUSDT', '--execute'])
      expect(status).to be_success, "script failed: #{stdout}\n#{stderr}"

      expect(redis.exists?('trades:BTCUSDT')).to be false
      expect(redis.exists?('trades:XBTUSDT')).to be true
      expect(redis.exists?('orders:BTCUSDT')).to be false
      expect(redis.exists?('orders:XBTUSDT')).to be true
    end
  end
end
