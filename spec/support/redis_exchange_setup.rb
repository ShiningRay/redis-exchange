# frozen_string_literal: true

# Shared setup for RedisExchange specs to DRY common initialization
module RedisExchangeSpecSetup
  def self.included(base)
    base.let(:redis) { RSpec.configuration.redis_factory.call }
    base.let(:exchange) { described_class.new(redis: redis) }
    base.let(:symbol) { 'BTCUSDT' }

    base.before do
      redis.flushdb
      exchange.seed_asset(asset: 'BTC', balance_scale: 100_000_000, status: 'ACTIVE')
      exchange.seed_asset(asset: 'USDT', balance_scale: 100, status: 'ACTIVE')
      exchange.seed_market(
        symbol: symbol,
        base_asset: 'BTC',
        quote_asset: 'USDT',
        price_scale: 100,
        quantity_scale: 100_000_000,
        maker_fee_bps: 5,
        taker_fee_bps: 10,
        min_qty: 100_000,
        min_notional: 1_000,
        status: 'OPEN'
      )
    end

    base.after do
      redis.close if redis.respond_to?(:close)
    end
  end
end

RSpec.configure do |config|
  # Auto-include the shared setup for specs under spec/redis_exchange
  config.include RedisExchangeSpecSetup, file_path: %r{spec/redis_exchange/}
end