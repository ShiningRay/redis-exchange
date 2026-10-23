# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RedisExchange::Client, "Depth Stream" do
  # RedisExchangeSpecSetup is automatically included by spec_helper config (assumed based on other specs)
  # But explicit let definitions are safer if I'm not sure about the shared context.
  # Based on snapshot_order_book_spec.rb, it uses explicit let.
  
  let(:redis) { RSpec.configuration.redis_factory.call }
  let(:exchange) { RedisExchange::Client.new(redis: redis) }
  let(:symbol) { 'BTCUSDT' }

  before do
    redis.flushdb
    exchange.seed_asset(asset: 'BTC', balance_scale: 100_000_000, status: 'ACTIVE')
    exchange.seed_asset(asset: 'USDT', balance_scale: 100_000_000, status: 'ACTIVE')
    exchange.seed_market(
      symbol: symbol, 
      base_asset: 'BTC', 
      quote_asset: 'USDT', 
      status: 'OPEN',
      price_scale: 100,
      quantity_scale: 1000
    )
  end

  it "publishes depth updates with sequence number" do
    # 1. Place a resting limit order -> triggers depth update
    exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 1_000_000_000)
    
    res = exchange.place_limit_order(
      symbol: symbol,
      side: 'SELL',
      order_id: 'maker-1',
      user_id: 'maker',
      price: 3_000_000, # 30000.00
      quantity: 1_000 # 1.000
    )
    expect(res[:error]).to be_nil

    # Check depth stream
    entries = redis.xrange("depth:#{symbol}", '-', '+')
    expect(entries.size).to eq(1)
    
    _, fields = entries.first
    event = fields.is_a?(Hash) ? fields : Hash[*fields]
    
    expect(event['e']).to eq('u')
    expect(event['s']).to eq('SELL')
    expect(event['p']).to eq('3000000')
    expect(event['v']).to eq('1000')
    expect(event).to have_key('seq')
    first_seq = event['seq'].to_i
    expect(first_seq).to be > 0

    # 2. Place a taker order that matches partially -> triggers depth update
    exchange.set_balance(user_id: 'taker', asset: 'USDT', available: 2_000_000_000_000)
    
    res2 = exchange.place_limit_order(
      symbol: symbol,
      side: 'BUY',
      order_id: 'taker-1',
      user_id: 'taker',
      price: 3_000_000,
      quantity: 500 # 0.500
    )
    expect(res2[:error]).to be_nil

    entries = redis.xrange("depth:#{symbol}", '-', '+')
    expect(entries.size).to eq(2)
    
    _, fields = entries.last
    event = fields.is_a?(Hash) ? fields : Hash[*fields]
    
    expect(event['v']).to eq('500') # Remaining 0.5
    expect(event).to have_key('seq')
    second_seq = event['seq'].to_i
    expect(second_seq).to be > first_seq
  end
end
