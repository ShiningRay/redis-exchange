# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RedisExchange::Client do

  context 'market status pre-check' do
    context 'when market status is updated' do
      before do
        redis.flushdb
        exchange.seed_asset(asset: 'BTC', balance_scale: 100_000_000, status: 'ACTIVE')
        exchange.seed_asset(asset: 'USDT', balance_scale: 100, status: 'ACTIVE')
        exchange.seed_market(
          symbol: symbol,
          base_asset: 'BTC',
          quote_asset: 'USDT',
          price_scale: 100,
          quantity_scale: 100_000_000,
          maker_fee_bps: 0,
          taker_fee_bps: 0,
          min_qty: 1,
          min_notional: 1,
          status: 'OPEN'
        )
      end

      it 'updates status and affects order placement' do
        updated = exchange.set_market_status(symbol: symbol, status: 'HALTED')
        expect(updated[:status]).to eq('HALTED')

        res = exchange.place_limit_order(
          symbol: symbol, side: 'SELL', order_id: 'halted-limit-2', user_id: 'mx',
          price: 3_000_000, quantity: 100_000_000
        )
        expect(res[:error]).to eq('MARKET_HALTED')
      end
    end

    context 'when market is HALTED' do
      before do
        redis.flushdb
        exchange.seed_asset(asset: 'BTC', balance_scale: 100_000_000, status: 'ACTIVE')
        exchange.seed_asset(asset: 'USDT', balance_scale: 100, status: 'ACTIVE')
        exchange.seed_market(
          symbol: symbol,
          base_asset: 'BTC',
          quote_asset: 'USDT',
          price_scale: 100,
          quantity_scale: 100_000_000,
          maker_fee_bps: 0,
          taker_fee_bps: 0,
          min_qty: 1,
          min_notional: 1,
          status: 'HALTED'
        )
      end

      it 'rejects limit order with MARKET_HALTED' do
        res = exchange.place_limit_order(
          symbol: symbol, side: 'SELL', order_id: 'halted-limit', user_id: 'mx',
          price: 3_000_000, quantity: 100_000_000
        )
        expect(res[:error]).to eq('MARKET_HALTED')
      end

      it 'rejects market order with MARKET_HALTED' do
        res = exchange.place_market_order(
          symbol: symbol, side: 'BUY', order_id: 'halted-market', user_id: 'mx',
          quantity: 100_000_000, price_cap: 3_000_000
        )
        expect(res[:error]).to eq('MARKET_HALTED')
      end
    end

    context 'when market is CLOSED' do
      before do
        redis.flushdb
        exchange.seed_asset(asset: 'BTC', balance_scale: 100_000_000, status: 'ACTIVE')
        exchange.seed_asset(asset: 'USDT', balance_scale: 100, status: 'ACTIVE')
        exchange.seed_market(
          symbol: symbol,
          base_asset: 'BTC',
          quote_asset: 'USDT',
          price_scale: 100,
          quantity_scale: 100_000_000,
          maker_fee_bps: 0,
          taker_fee_bps: 0,
          min_qty: 1,
          min_notional: 1,
          status: 'CLOSED'
        )
      end

      it 'rejects limit order with MARKET_CLOSED' do
        res = exchange.place_limit_order(
          symbol: symbol, side: 'SELL', order_id: 'closed-limit', user_id: 'cx',
          price: 3_000_000, quantity: 100_000_000
        )
        expect(res[:error]).to eq('MARKET_CLOSED')
      end

      it 'rejects market order with MARKET_CLOSED' do
        res = exchange.place_market_order(
          symbol: symbol, side: 'BUY', order_id: 'closed-market', user_id: 'cx',
          quantity: 100_000_000, price_cap: 3_000_000
        )
        expect(res[:error]).to eq('MARKET_CLOSED')
      end
    end
  end

  end
