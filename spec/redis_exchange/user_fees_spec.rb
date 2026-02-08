# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RedisExchange::Client do

  describe "#set_user_fees" do
    it 'sets user-specific maker and taker fee rates' do
      result = exchange.set_user_fees(
        user_id: 'vip_user',
        maker_fee_bps: 2,
        taker_fee_bps: 5
      )

      expect(result[:ok]).to eq(true)

      fees = redis.hgetall('user_fees:vip_user')
      expect(fees['maker_fee_bps'].to_i).to eq(2)
      expect(fees['taker_fee_bps'].to_i).to eq(5)
    end

    it 'raises ArgumentError for invalid user_id' do
      expect {
        exchange.set_user_fees(
          user_id: '',
          maker_fee_bps: 5,
          taker_fee_bps: 10
        )
      }.to raise_error(ArgumentError, 'user_id is required')
    end

    it 'raises ArgumentError for invalid maker_fee_bps' do
      expect {
        exchange.set_user_fees(
          user_id: 'vip_user',
          maker_fee_bps: -1,
          taker_fee_bps: 10
        )
      }.to raise_error(ArgumentError, 'maker_fee_bps must be between 0 and 10000')

      expect {
        exchange.set_user_fees(
          user_id: 'vip_user',
          maker_fee_bps: 10001,
          taker_fee_bps: 10
        )
      }.to raise_error(ArgumentError, 'maker_fee_bps must be between 0 and 10000')
    end

    it 'raises ArgumentError for invalid taker_fee_bps' do
      expect {
        exchange.set_user_fees(
          user_id: 'vip_user',
          maker_fee_bps: 5,
          taker_fee_bps: -1
        )
      }.to raise_error(ArgumentError, 'taker_fee_bps must be between 0 and 10000')

      expect {
        exchange.set_user_fees(
          user_id: 'vip_user',
          maker_fee_bps: 5,
          taker_fee_bps: 10001
        )
      }.to raise_error(ArgumentError, 'taker_fee_bps must be between 0 and 10000')
    end

    it 'allows zero fee rates' do
      result = exchange.set_user_fees(
        user_id: 'zero_fee_user',
        maker_fee_bps: 0,
        taker_fee_bps: 0
      )

      expect(result[:ok]).to eq(true)

      fees = redis.hgetall('user_fees:zero_fee_user')
      expect(fees['maker_fee_bps'].to_i).to eq(0)
      expect(fees['taker_fee_bps'].to_i).to eq(0)
    end
  end

  describe "#get_user_fees" do
    it 'retrieves user-specific fee rates when set' do
      exchange.set_user_fees(
        user_id: 'vip_user',
        maker_fee_bps: 3,
        taker_fee_bps: 7
      )

      fees = exchange.get_user_fees(user_id: 'vip_user')

      expect(fees[:maker_fee_bps]).to eq(3)
      expect(fees[:taker_fee_bps]).to eq(7)
    end

    it 'returns empty hash when user fees are not set' do
      fees = exchange.get_user_fees(user_id: 'non_existent_user')
      expect(fees).to eq({})
    end

    it 'raises ArgumentError for invalid user_id' do
      expect {
        exchange.get_user_fees(user_id: '')
      }.to raise_error(ArgumentError, 'user_id is required')
    end
  end

  describe "#delete_user_fees" do
    before do
      exchange.set_user_fees(
        user_id: 'vip_user',
        maker_fee_bps: 5,
        taker_fee_bps: 10
      )
    end

    it 'deletes user-specific fee rates' do
      result = exchange.delete_user_fees(user_id: 'vip_user')
      expect(result[:ok]).to eq(true)

      expect(redis.exists?('user_fees:vip_user')).to be_falsey
    end

    it 'returns error when user fees do not exist' do
      result = exchange.delete_user_fees(user_id: 'non_existent_user')
      expect(result[:error]).to eq('USER_FEES_NOT_FOUND')
    end

    it 'raises ArgumentError for invalid user_id' do
      expect {
        exchange.delete_user_fees(user_id: '')
      }.to raise_error(ArgumentError, 'user_id is required')
    end
  end

  describe "user fees in order placement" do
    context "taker with custom fee rates" do
      before do
        exchange.set_user_fees(
          user_id: 'vip_taker',
          maker_fee_bps: 2,
          taker_fee_bps: 4
        )

        exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 200_000_000)
        exchange.place_limit_order(
          symbol: symbol,
          side: 'SELL',
          order_id: 'maker-order-1',
          user_id: 'maker',
          price: 3_000_000,
          quantity: 200_000_000
        )
      end

      it 'applies user-specific taker fee on market buy order' do
        exchange.set_balance(user_id: 'vip_taker', asset: 'USDT', available: 10_000_000)

        result = exchange.place_market_order(
          symbol: symbol,
          side: 'BUY',
          order_id: 'taker-order-1',
          user_id: 'vip_taker',
          quantity: 100_000_000
        )

        expect(result[:status]).to eq('FILLED')
        expect(result[:executed_quantity]).to eq(100_000_000)

        # trade_quote = 3_000_000
        # trade_qty = 100_000_000
        # taker_fee with user rate (4bps) on Base Asset (BTC) = floor(100_000_000 * 4 / 10000) = 40_000
        expect(result[:taker_fee_paid]).to eq(40_000)

        # maker fee uses market default (5bps) on Quote Asset (USDT) = floor(3_000_000 * 5 / 10000) = 1_500
        expect(result[:maker_fee_charged]).to eq(1_500)

        # Check taker balance: 
        # - USDT (Quote): Spent exactly trade_quote (3_000_000). No fee deduction from Quote.
        # - BTC (Base): Received trade_qty (100_000_000) - taker_fee (40_000) = 99_960_000
        balances = redis.hgetall('balance:vip_taker')
        expect(balances['USDT:available'].to_i).to eq(10_000_000 - 3_000_000)
        expect(balances['BTC:available'].to_i).to eq(100_000_000 - 40_000)
      end
    end

    context "maker with custom fee rates" do
      before do
        exchange.set_user_fees(
          user_id: 'vip_maker',
          maker_fee_bps: 1,
          taker_fee_bps: 5
        )

        exchange.set_balance(user_id: 'vip_maker', asset: 'BTC', available: 200_000_000)
        exchange.place_limit_order(
          symbol: symbol,
          side: 'SELL',
          order_id: 'vip-maker-order',
          user_id: 'vip_maker',
          price: 3_000_000,
          quantity: 200_000_000
        )
      end

      it 'applies user-specific maker fee when maker order is matched' do
        exchange.set_balance(user_id: 'taker', asset: 'USDT', available: 10_000_000)

        result = exchange.place_market_order(
          symbol: symbol,
          side: 'BUY',
          order_id: 'taker-order-1',
          user_id: 'taker',
          quantity: 100_000_000
        )

        expect(result[:status]).to eq('FILLED')

        # taker (BUY) pays fee in Base Asset (BTC)
        # taker fee uses market default (10bps) = floor(100_000_000 * 10 / 10000) = 100_000
        expect(result[:taker_fee_paid]).to eq(100_000)

        # maker (SELL) pays fee in Quote Asset (USDT)
        # maker fee with user rate (1bps) = floor(3_000_000 * 1 / 10000) = 300
        expect(result[:maker_fee_charged]).to eq(300)

        # Check VIP maker balance: credited trade_quote - user_maker_fee
        balances = redis.hgetall('balance:vip_maker')
        # Maker sold 100_000_000 BTC, so reserved should drop by that amount.
        # Initial available 200_000_000. Sell order locks 200_000_000. 
        # Matched 100_000_000. Remaining reserved 100_000_000.
        expect(balances['BTC:reserved'].to_i).to eq(100_000_000)
        
        # Maker received 3_000_000 USDT minus 300 fee
        expect(balances['USDT:available'].to_i).to eq(3_000_000 - 300)
      end
    end

    context "user without custom fees uses market defaults" do
      before do
        exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 200_000_000)
        exchange.place_limit_order(
          symbol: symbol,
          side: 'SELL',
          order_id: 'maker-order-1',
          user_id: 'maker',
          price: 3_000_000,
          quantity: 200_000_000
        )
      end

      it 'applies market default fees when no user fees are set' do
        exchange.set_balance(user_id: 'regular_taker', asset: 'USDT', available: 10_000_000)

        result = exchange.place_market_order(
          symbol: symbol,
          side: 'BUY',
          order_id: 'taker-order-1',
          user_id: 'regular_taker',
          quantity: 100_000_000
        )

        expect(result[:status]).to eq('FILLED')

        # taker_fee market default (10bps) on Base Asset (BTC) = floor(100_000_000 * 10 / 10000) = 100_000
        expect(result[:taker_fee_paid]).to eq(100_000)

        # maker_fee market default (5bps) on Quote Asset (USDT) = floor(3_000_000 * 5 / 10000) = 1_500
        expect(result[:maker_fee_charged]).to eq(1_500)
      end
    end

    context "zero fee user" do
      before do
        exchange.set_user_fees(
          user_id: 'zero_fee_user',
          maker_fee_bps: 0,
          taker_fee_bps: 0
        )

        exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 200_000_000)
        exchange.place_limit_order(
          symbol: symbol,
          side: 'SELL',
          order_id: 'maker-order-1',
          user_id: 'maker',
          price: 3_000_000,
          quantity: 200_000_000
        )
      end

      it 'charges no fees for user with zero fee rates' do
        exchange.set_balance(user_id: 'zero_fee_user', asset: 'USDT', available: 10_000_000)

        result = exchange.place_market_order(
          symbol: symbol,
          side: 'BUY',
          order_id: 'taker-order-1',
          user_id: 'zero_fee_user',
          quantity: 100_000_000
        )

        expect(result[:status]).to eq('FILLED')
        expect(result[:taker_fee_paid]).to eq(0)
        expect(result[:maker_fee_charged]).to eq(1_500)

        # Check taker balance: debited only trade_quote, no fee
        balances = redis.hgetall('balance:zero_fee_user')
        # Taker spent exactly trade_quote (3_000_000). 
        expect(balances['USDT:available'].to_i).to eq(10_000_000 - 3_000_000)
        # Taker received full trade_qty (100_000_000) as fee is 0
        expect(balances['BTC:available'].to_i).to eq(100_000_000)
      end
    end
  end

  describe "updating user fees" do
    it 'allows updating existing user fee rates' do
      exchange.set_user_fees(
        user_id: 'vip_user',
        maker_fee_bps: 5,
        taker_fee_bps: 10
      )

      exchange.set_user_fees(
        user_id: 'vip_user',
        maker_fee_bps: 2,
        taker_fee_bps: 4
      )

      fees = exchange.get_user_fees(user_id: 'vip_user')
      expect(fees[:maker_fee_bps]).to eq(2)
      expect(fees[:taker_fee_bps]).to eq(4)
    end
  end
end
