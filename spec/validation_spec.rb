# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Parameter Validation' do
  let(:exchange) { RedisExchange::Client.new }
  let(:user_id) { 'test_user' }
  let(:asset) { 'BTC' }

  describe '#add_funds' do
    it 'raises ArgumentError if user_id is missing' do
      expect { exchange.add_funds(user_id: nil, asset: asset, amount: 100) }.to raise_error(ArgumentError, /user_id is required/)
      expect { exchange.add_funds(user_id: '', asset: asset, amount: 100) }.to raise_error(ArgumentError, /user_id is required/)
    end

    it 'raises ArgumentError if asset is missing' do
      expect { exchange.add_funds(user_id: user_id, asset: nil, amount: 100) }.to raise_error(ArgumentError, /asset is required/)
      expect { exchange.add_funds(user_id: user_id, asset: '', amount: 100) }.to raise_error(ArgumentError, /asset is required/)
    end

    it 'raises ArgumentError if amount is not positive' do
      expect { exchange.add_funds(user_id: user_id, asset: asset, amount: 0) }.to raise_error(ArgumentError, /amount must be positive/)
      expect { exchange.add_funds(user_id: user_id, asset: asset, amount: -1) }.to raise_error(ArgumentError, /amount must be positive/)
    end
  end

  describe '#sub_funds' do
    it 'raises ArgumentError if amount is not positive' do
      expect { exchange.sub_funds(user_id: user_id, asset: asset, amount: 0) }.to raise_error(ArgumentError, /amount must be positive/)
      expect { exchange.sub_funds(user_id: user_id, asset: asset, amount: -1) }.to raise_error(ArgumentError, /amount must be positive/)
    end
  end

  describe '#operate_balance' do
    it 'raises ArgumentError if user_id is missing' do
      expect {
        exchange.operate_balance(user_id: nil, asset: asset, action: 'ADD', amount: 100)
      }.to raise_error(ArgumentError, /user_id is required/)
    end
  end
end
