# frozen_string_literal: true

require 'spec_helper'

# Covers the order-path optimisations: duplicate-id detection now relies solely on
# the Lua matcher, and market/asset/user-fee config is cached per client with
# invalidation on every mutator.
RSpec.describe 'Order path config cache' do
  let(:redis) { SpecRedis.factory.call }
  let(:exchange) { RedisExchange::Client.new(redis: redis) }
  let(:symbol) { 'CACHEUSDT' }

  before do
    redis.flushdb
    exchange.seed_market(
      symbol: symbol, base_asset: 'CB', quote_asset: 'USDT',
      price_scale: 100, quantity_scale: 100_000_000,
      maker_fee_bps: 5, taker_fee_bps: 10, min_qty: 1, min_notional: 1
    )
    exchange.seed_asset(asset: 'CB', balance_scale: 100_000_000)
    exchange.seed_asset(asset: 'USDT', balance_scale: 100_000_000)
    exchange.set_balance(user_id: 'u1', asset: 'CB', available: 10**12)
    exchange.set_balance(user_id: 'u1', asset: 'USDT', available: 5 * 10**15)
  end

  def place(order_id, price: 2_500, quantity: 100_000)
    exchange.place_limit_order(
      symbol: symbol, side: 'BUY', order_id: order_id,
      user_id: 'u1', price: price, quantity: quantity
    )
  end

  it 'rejects duplicate order ids without a client-side pre-check' do
    expect(place('dup-1')).not_to include(:error)
    expect(place('dup-1')[:error]).to eq('DUPLICATE_ORDER_ID')
  end

  def commands_per_order(ttl, prefix)
    exchange.config_cache_ttl = ttl
    place("#{prefix}-warmup")
    before = redis.info('stats')['total_commands_processed'].to_i
    5.times { |i| place("#{prefix}-#{i}") }
    (redis.info('stats')['total_commands_processed'].to_i - before) / 5.0
  end

  it 'serves repeated orders from cache instead of re-reading configuration' do
    uncached = commands_per_order(0, 'uncached')
    cached = commands_per_order(5.0, 'cached')

    # Market, both assets and the user fee table cost ~4 commands per order
    # without the cache; the Lua script's own calls are unaffected.
    expect(uncached - cached).to be >= 3
  end

  it 'invalidates the market cache when the status changes' do
    expect(place('st-1')).not_to include(:error)

    exchange.set_market_status(symbol: symbol, status: 'HALTED')

    expect(place('st-2')[:error]).to eq('MARKET_HALTED')
  end

  it 'invalidates the asset cache when a balance scale changes' do
    expect(place('scale-1')).not_to include(:error)

    exchange.seed_asset(asset: 'CB', balance_scale: 3)

    expect(place('scale-2')[:error]).to eq('ASSET_SCALE_MISMATCH')
  end

  it 'invalidates the user fee cache when fees change' do
    place('fee-1')
    exchange.set_user_fees(user_id: 'u1', maker_fee_bps: 5, taker_fee_bps: 25)
    before = redis.info('stats')['total_commands_processed'].to_i
    place('fee-2')
    # A refill costs the market HGETALL plus one pipelined round trip.
    expect(redis.info('stats')['total_commands_processed'].to_i - before).to be > 35
  end

  it 'honours a zero TTL by re-reading configuration every order' do
    uncached = commands_per_order(0, 'ttl0')
    cached = commands_per_order(5.0, 'ttl5')

    expect(uncached).to be > cached
  end

  it 'exposes clear_config_cache!' do
    place('clear-0')
    expect(exchange.clear_config_cache!).to be_nil
  end
end
