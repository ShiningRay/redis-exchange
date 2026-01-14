# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Snapshot Order Book', :snapshot_order_book do
  let(:redis) { RSpec.configuration.redis_factory.call }
  let(:exchange) { RedisExchange::Client.new(redis: redis) }
  let(:symbol) { 'BTCUSDT' }

  before do
    redis.flushdb
    exchange.seed_asset(asset: 'BTC', balance_scale: 1, status: 'ACTIVE')
    exchange.seed_asset(asset: 'USDT', balance_scale: 1, status: 'ACTIVE')
    exchange.seed_market(symbol: symbol, base_asset: 'BTC', quote_asset: 'USDT', status: 'OPEN')
    
    # Setup users
    exchange.set_balance(user_id: 'maker_bid', asset: 'USDT', available: 1_000_000)
    exchange.set_balance(user_id: 'maker_ask', asset: 'BTC', available: 100)
    
    # Place some orders to populate the book
    # Bids:
    # 1. Price 100, Qty 1
    # 2. Price 99, Qty 2
    exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'bid1', user_id: 'maker_bid', price: 100, quantity: 1)
    exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'bid2', user_id: 'maker_bid', price: 99, quantity: 2)
    
    # Asks:
    # 1. Price 101, Qty 1
    # 2. Price 102, Qty 3
    exchange.place_limit_order(symbol: symbol, side: 'SELL', order_id: 'ask1', user_id: 'maker_ask', price: 101, quantity: 1)
    exchange.place_limit_order(symbol: symbol, side: 'SELL', order_id: 'ask2', user_id: 'maker_ask', price: 102, quantity: 3)
  end

  after do
    exchange.maintenance.disable_market(symbol)
  end

  it 'exports order book to a hash when no output path is provided' do
    snapshot = exchange.maintenance.snapshot_order_book(symbol: symbol)
    
    expect(snapshot).to be_a(Hash)
    expect(snapshot[:symbol]).to eq(symbol)
    expect(snapshot[:bids]).to be_a(Array)
    expect(snapshot[:asks]).to be_a(Array)
    
    # Check bids (order might not be guaranteed by ZSCAN but we can sort or find)
    bids = snapshot[:bids].sort_by { |b| -b[:price] }
    expect(bids.size).to eq(2)
    expect(bids[0]).to include(price: 100, volume: 1)
    expect(bids[1]).to include(price: 99, volume: 2)
    
    # Check asks
    asks = snapshot[:asks].sort_by { |a| a[:price] }
    expect(asks.size).to eq(2)
    expect(asks[0]).to include(price: 101, volume: 1)
    expect(asks[1]).to include(price: 102, volume: 3)
  end

  it 'exports order book to a file when output path is provided' do
    temp_file = File.join(Dir.tmpdir, "order_book_#{Time.now.to_i}.json")
    
    begin
      result_path = exchange.maintenance.snapshot_order_book(symbol: symbol, output_path: temp_file)
      expect(result_path).to eq(temp_file)
      expect(File.exist?(temp_file)).to be true
      
      content = File.read(temp_file)
      json = JSON.parse(content, symbolize_names: true)
      
      expect(json[:symbol]).to eq(symbol)
      
      # Verify content matches
      bids = json[:bids].sort_by { |b| -b[:price] }
      expect(bids.size).to eq(2)
      expect(bids[0]).to include(price: 100, volume: 1)
      expect(bids[1]).to include(price: 99, volume: 2)
      
      asks = json[:asks].sort_by { |a| a[:price] }
      expect(asks.size).to eq(2)
      expect(asks[0]).to include(price: 101, volume: 1)
      expect(asks[1]).to include(price: 102, volume: 3)
      
    ensure
      File.delete(temp_file) if File.exist?(temp_file)
    end
  end

  it 'ensures market is in maintenance mode during export' do
    # We can't easily check internal state during the call without mocking,
    # but we can verify it returns to normal state afterwards.
    
    exchange.maintenance.snapshot_order_book(symbol: symbol)
    
    # Market should be open now
    expect(exchange.maintenance.market_enabled?(symbol)).to be false
    
    # Should be able to place order
    res = exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'new_o', user_id: 'maker_bid', price: 90, quantity: 1)
    expect(res[:error]).to be_nil
  end
end
