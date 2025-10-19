# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RedisExchange::Client do

  describe "#order" do
    it 'retrieves typed order snapshot by id' do
      exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 100_000_000)
      exchange.place_limit_order(
        symbol: symbol,
        side: 'SELL',
        order_id: 'query-1',
        user_id: 'maker',
        price: 3_000_000,
        quantity: 100_000_000
      )

      snapshot = exchange.order('query-1')
      expect(snapshot[:order_id]).to eq('query-1')
      expect(snapshot[:symbol]).to eq(symbol)
      expect(snapshot[:side]).to eq('SELL')
      expect(snapshot[:type]).to eq('LIMIT')
      expect(snapshot[:status]).to eq('OPEN')
      expect(snapshot[:price]).to eq(3_000_000)
      expect(snapshot[:quantity]).to eq(100_000_000)
      expect(snapshot[:remaining]).to eq(100_000_000)
      expect(snapshot[:sequence]).to be_a(Integer)
      expect(snapshot[:created_at]).to be_a(Integer)

      expect(exchange.order('nonexistent')).to eq({})
    end

    it 'returns empty hash for non-existent order id' do
      expect(exchange.order('missing-123')).to eq({})
    end
  end 

end