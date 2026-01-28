require 'spec_helper'

RSpec.describe 'Reproduction' do
  let(:redis) { RSpec.configuration.redis_factory.call }
  let(:exchange) { RedisExchange::Client.new(redis: redis) }

  before do
    redis.flushdb
  end

  it 'returns UNKNOWN_MARKET without seed' do
    result = exchange.place_limit_order(
      symbol: 'BTC_USDT',
      side: 'BUY',
      order_id: 'order-1',
      user_id: 'u1',
      price: 3_000_000,
      quantity: 10_000_000
    )
    puts "Result: #{result.inspect}"
    expect(result[:error]).to eq('UNKNOWN_MARKET')
  end
end
