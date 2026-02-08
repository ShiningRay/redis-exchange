# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe RedisExchange::Client, 'Fee accumulation across markets with different quote precision', type: :integration do
  include RedisExchangeSpecSetup

  it 'accumulates USDT fees in USDT balance_scale across markets' do
    redis.flushdb

    exchange.seed_asset(asset: 'BTC', balance_scale: 100_000_000, status: 'ACTIVE')
    exchange.seed_asset(asset: 'TRX', balance_scale: 1_000_000, status: 'ACTIVE')
    exchange.seed_asset(asset: 'USDT', balance_scale: 1_000_000, status: 'ACTIVE')

    exchange.seed_market(
      symbol: 'BTCUSDT',
      base_asset: 'BTC',
      quote_asset: 'USDT',
      price_scale: 100, # 10**2
      quantity_scale: 100_000_000, # 10**8
      maker_fee_bps: 100, # 0.0100
      taker_fee_bps: 25, # 0.0025
      min_qty: 1,
      min_notional: 1,
      status: 'OPEN'
    )

    exchange.seed_market(
      symbol: 'TRXUSDT',
      base_asset: 'TRX',
      quote_asset: 'USDT',
      price_scale: 10_000,
      quantity_scale: 1_000_000,
      maker_fee_bps: 100,
      taker_fee_bps: 25,
      min_qty: 1,
      min_notional: 1,
      status: 'OPEN'
    )

    exchange.set_balance(user_id: 'maker_btc', asset: 'BTC', available: 10_000_000)
    exchange.set_balance(user_id: 'maker_trx', asset: 'TRX', available: 10_000_000)
    exchange.set_balance(user_id: 'taker_usdt', asset: 'USDT', available: 5_000_000_000)

    exchange.place_limit_order(
      symbol: 'BTCUSDT',
      side: 'SELL',
      order_id: 'btc-sell-1',
      user_id: 'maker_btc',
      price: 3_000_000, # 30000.00
      quantity: 10_000_000 # 0.1
    )

    exchange.place_limit_order(
      symbol: 'BTCUSDT',
      side: 'BUY',
      order_id: 'btc-buy-1',
      user_id: 'taker_usdt',
      price: 3_000_000, # 30000.00
      quantity: 10_000_000 # 0.1
    )

    # funds 30000.0*0.1 = 3000.0
    # taker fee 0.1*0.0025 = 0.00025 BTC
    # maker fee 3000.0*0.01 = 30.00 USDT

    exchange.place_limit_order(
      symbol: 'TRXUSDT',
      side: 'SELL',
      order_id: 'trx-sell-1',
      user_id: 'maker_trx',
      price: 1234,  # 0.1234
      quantity: 10_000_000 # 10
    )

    exchange.place_limit_order(
      symbol: 'TRXUSDT',
      side: 'BUY',
      order_id: 'trx-buy-1',
      user_id: 'taker_usdt',
      price: 1234,  # 0.1234
      quantity: 10_000_000 # 10
    )

    # funds = 0.1234 * 10 = 1.234 USDT
    # taker fee 10*0.0025 = 0.025 TRX
    # maker fee 1.234*0.01 = 0.01234 USDT

    expected_btc_usdt_fee = 30.00 * 10**6
    expected_trx_usdt_fee = 0.01234 * 10**6
    expected_total_usdt_fee = expected_btc_usdt_fee + expected_trx_usdt_fee
    expected_btc_taker_fee = 0.00025 * 10**8
    expected_trx_taker_fee = 0.025 * 10**6

    total_fees = exchange.fees_total(asset: 'USDT')
    expect(total_fees).to eq(expected_total_usdt_fee)

    btc_fees = exchange.fees_total(asset: 'BTC')
    expect(btc_fees).to eq(expected_btc_taker_fee)

    trx_fees = exchange.fees_total(asset: 'TRX')
    expect(trx_fees).to eq(expected_trx_taker_fee)

    expect(exchange.fees_total(asset: 'USDT', auto_scale: true)).to eq(expected_total_usdt_fee.to_d / 1_000_000)

    btc_trades = redis.xrange('trades:BTCUSDT', '-', '+')
    expect(btc_trades.size).to eq(1)
    btc_trade_fields = btc_trades.first[1]
    btc_trade_fields = btc_trade_fields.is_a?(Hash) ? btc_trade_fields : Hash[*btc_trade_fields]
    expect(btc_trade_fields['taker_fee_asset']).to eq('BTC')
    expect(btc_trade_fields['taker_fee']).to eq(expected_btc_taker_fee.to_i.to_s)
    expect(btc_trade_fields['maker_fee_asset']).to eq('USDT')
    expect(btc_trade_fields['maker_fee']).to eq(expected_btc_usdt_fee.to_i.to_s)

    trx_trades = redis.xrange('trades:TRXUSDT', '-', '+')
    expect(trx_trades.size).to eq(1)
    trx_trade_fields = trx_trades.first[1]
    trx_trade_fields = trx_trade_fields.is_a?(Hash) ? trx_trade_fields : Hash[*trx_trade_fields]
    expect(trx_trade_fields['taker_fee_asset']).to eq('TRX')
    expect(trx_trade_fields['taker_fee']).to eq(expected_trx_taker_fee.to_i.to_s)
    expect(trx_trade_fields['maker_fee_asset']).to eq('USDT')
    expect(trx_trade_fields['maker_fee']).to eq(expected_trx_usdt_fee.to_i.to_s)

    taker_balances = redis.hgetall('balance:taker_usdt')
    expect(taker_balances.fetch('BTC:available', '0').to_i).to eq(10_000_000 - expected_btc_taker_fee)
    expect(taker_balances.fetch('TRX:available', '0').to_i).to eq(10_000_000 - expected_trx_taker_fee)
  end
end
