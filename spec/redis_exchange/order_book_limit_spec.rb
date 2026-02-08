require 'spec_helper'

RSpec.describe RedisExchange::Client, "Order Book Limit" do
  let(:redis) { RSpec.configuration.redis_factory.call }
  let(:exchange) { RedisExchange::Client.new(redis: redis) }
  let(:symbol) { 'BTCUSDT' }

  before do
    redis.flushdb
    exchange.seed_asset(asset: 'BTC', balance_scale: 100_000_000, status: 'ACTIVE')
    exchange.seed_asset(asset: 'USDT', balance_scale: 100, status: 'ACTIVE')
    exchange.seed_market(symbol: symbol, base_asset: 'BTC', quote_asset: 'USDT', status: 'OPEN')
    
    # Fund users
    exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 10_000_000_000)
    exchange.set_balance(user_id: 'maker', asset: 'USDT', available: 1_000_000_000)

    # Place Bids (Buy)
    # Price 100, 90, 80
    exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'b1', user_id: 'maker', price: 100, quantity: 1)
    exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'b2', user_id: 'maker', price: 90, quantity: 1)
    exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'b3', user_id: 'maker', price: 80, quantity: 1)

    # Place Asks (Sell)
    # Price 110, 120, 130
    exchange.place_limit_order(symbol: symbol, side: 'SELL', order_id: 's1', user_id: 'maker', price: 110, quantity: 1)
    exchange.place_limit_order(symbol: symbol, side: 'SELL', order_id: 's2', user_id: 'maker', price: 120, quantity: 1)
    exchange.place_limit_order(symbol: symbol, side: 'SELL', order_id: 's3', user_id: 'maker', price: 130, quantity: 1)
  end

  it "returns top N bids and asks correctly" do
    # Verify full book first
    full_book = exchange.order_book(symbol)
    expect(full_book[:bids].map { |x| x[:price] }).to eq([100, 90, 80])
    expect(full_book[:asks].map { |x| x[:price] }).to eq([110, 120, 130])

    # Verify limit 1
    limit_book = exchange.order_book(symbol, limit: 1)
    expect(limit_book[:bids].map { |x| x[:price] }).to eq([100]) # Best Bid
    expect(limit_book[:asks].map { |x| x[:price] }).to eq([110]) # Best Ask
    
    # Verify limit 2
    limit_book_2 = exchange.order_book(symbol, limit: 2)
    expect(limit_book_2[:bids].map { |x| x[:price] }).to eq([100, 90])
    expect(limit_book_2[:asks].map { |x| x[:price] }).to eq([110, 120])
  end
end
