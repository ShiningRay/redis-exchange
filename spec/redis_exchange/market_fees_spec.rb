# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe RedisExchange::Client, '#set_market_fees', type: :integration do
  include RedisExchangeSpecSetup

  it 'updates maker/taker fee bps for an existing market' do
    res = exchange.set_market_fees(symbol: symbol, maker_fee_bps: 12, taker_fee_bps: 34)
    expect(res).to eq({ ok: true, symbol: symbol, maker_fee_bps: 12, taker_fee_bps: 34 })

    raw = redis.hgetall("market:#{symbol}")
    expect(raw.fetch('maker_fee_bps')).to eq('12')
    expect(raw.fetch('taker_fee_bps')).to eq('34')
  end

  it 'returns UNKNOWN_MARKET for missing markets' do
    res = exchange.set_market_fees(symbol: 'NOPE', maker_fee_bps: 1, taker_fee_bps: 2)
    expect(res).to eq({ error: 'UNKNOWN_MARKET' })
  end

  it 'raises ArgumentError for invalid fee values' do
    expect { exchange.set_market_fees(symbol: symbol, maker_fee_bps: -1, taker_fee_bps: 0) }
      .to raise_error(ArgumentError)
    expect { exchange.set_market_fees(symbol: symbol, maker_fee_bps: 0, taker_fee_bps: 10_001) }
      .to raise_error(ArgumentError)
  end
end

