# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RedisExchange::Client do

  # 资产刻度预检错误场景覆盖：未配置资产与刻度不匹配
  context 'asset scale validation errors' do
    context 'when assets are not configured' do
      before do
        redis.flushdb
        exchange.seed_market(
          symbol: symbol,
          base_asset: 'BTC',
          quote_asset: 'USDT',
          price_scale: 100,
          quantity_scale: 100_000_000,
          maker_fee_bps: 0,
          taker_fee_bps: 0,
          min_qty: 1,
          min_notional: 1
        )
      end

      it 'rejects limit order with ASSET_NOT_CONFIGURED' do
        res = exchange.place_limit_order(
          symbol: symbol, side: 'SELL', order_id: 'notcfg-lim', user_id: 'u1',
          price: 3_000_000, quantity: 100_000_000
        )
        expect(res[:error]).to eq('ASSET_NOT_CONFIGURED')
        expect(res[:asset]).to eq('BTC')
      end

      it 'rejects market order with ASSET_NOT_CONFIGURED' do
        res = exchange.place_market_order(
          symbol: symbol, side: 'BUY', order_id: 'notcfg-mkt', user_id: 'u2',
          quantity: 100_000_000, price_cap: 3_000_000
        )
        expect(res[:error]).to eq('ASSET_NOT_CONFIGURED')
        expect(res[:asset]).to eq('BTC')
      end
    end

    context 'when base asset scale mismatches quantity_scale' do
      before do
        redis.flushdb
        # Base asset has a balance_scale that is NOT a multiple of quantity_scale
        exchange.seed_asset(asset: 'BTC', balance_scale: 100_000_001, status: 'ACTIVE')
        # Quote asset is correctly configured for price_scale
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
          min_notional: 1
        )
      end

      it 'rejects limit order with ASSET_SCALE_MISMATCH for base asset' do
        res = exchange.place_limit_order(
          symbol: symbol, side: 'SELL', order_id: 'mismatch-base', user_id: 'u3',
          price: 3_000_000, quantity: 100_000_000
        )
        expect(res[:error]).to eq('ASSET_SCALE_MISMATCH')
        expect(res[:asset]).to eq('BTC')
        expect(res[:balance_scale]).to eq(100_000_001)
        expect(res[:market_scale]).to eq(100_000_000)
      end
    end

    context 'when quote asset scale mismatches price_scale' do
      before do
        redis.flushdb
        # Base asset is correctly configured for quantity_scale
        exchange.seed_asset(asset: 'BTC', balance_scale: 100_000_000, status: 'ACTIVE')
        # Quote asset has a balance_scale that is NOT a multiple of price_scale
        exchange.seed_asset(asset: 'USDT', balance_scale: 101, status: 'ACTIVE')
        exchange.seed_market(
          symbol: symbol,
          base_asset: 'BTC',
          quote_asset: 'USDT',
          price_scale: 100,
          quantity_scale: 100_000_000,
          maker_fee_bps: 0,
          taker_fee_bps: 0,
          min_qty: 1,
          min_notional: 1
        )
      end

      it 'rejects market order with ASSET_SCALE_MISMATCH for quote asset' do
        res = exchange.place_market_order(
          symbol: symbol, side: 'BUY', order_id: 'mismatch-quote', user_id: 'u4',
          quantity: 100_000_000, price_cap: 3_000_000
        )
        expect(res[:error]).to eq('ASSET_SCALE_MISMATCH')
        expect(res[:asset]).to eq('USDT')
        expect(res[:balance_scale]).to eq(101)
        expect(res[:market_scale]).to eq(100)
      end
    end
  end

  end