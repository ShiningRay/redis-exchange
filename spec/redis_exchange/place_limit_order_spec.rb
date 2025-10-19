# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RedisExchange::Client do

  describe "#place_limit_order" do
    context "user has sufficient balance" do
      context " when no opposite liquidity exists" do
        it 'rests a limit order' do
          exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 100_000_000)

          result = exchange.place_limit_order(
            symbol: symbol,
            side: 'SELL',
            order_id: 'order-1',
            user_id: 'maker',
            price: 3_000_000, # 30000.00000000 USDT
            quantity: 100_000_000 # 1.00000000 BTC
          )

          expect(result[:status]).to eq('OPEN')
          expect(result[:remaining_quantity]).to eq(100_000_000)
          queue = redis.lrange('queue:BTCUSDT:SELL:3000000', 0, -1)
          expect(queue).to eq(['order-1'])

          balances = redis.hgetall('balance:maker')
          expect(balances['BTC:available'].to_i).to eq(0)
          expect(balances['BTC:reserved'].to_i).to eq(100_000_000)

          ticker = exchange.ticker(symbol)
          expect(ticker[:best_ask_price]).to eq(3_000_000)
          expect(ticker[:best_ask_volume]).to eq(100_000_000)
          expect(ticker[:best_bid_price]).to eq(0)
          expect(ticker[:best_bid_volume]).to eq(0)
          expect(ticker[:last_price]).to eq(0)

          book = exchange.order_book(symbol)
          expect(book[:asks].map { |row| row[:price] }).to eq([3_000_000])
          expect(book[:asks].first[:volume]).to eq(100_000_000)
          expect(book[:bids]).to be_empty
        end

        it 'rests a limit buy order' do
          # 买方先充入 USDT 余额，足以覆盖名义金额与预估手续费
          exchange.set_balance(user_id: 'buyer', asset: 'USDT', available: 5_000_000) # 50000.00000000 USDT

          result = exchange.place_limit_order(
            symbol: symbol,
            side: 'BUY',
            order_id: 'order-buy-1',
            user_id: 'buyer',
            price: 3_000_000, # 30000.00000000 USDT
            quantity: 100_000_000 # 1.00000000 BTC
          )

          expect(result[:status]).to eq('OPEN')
          expect(result[:remaining_quantity]).to eq(100_000_000)
          queue = redis.lrange('queue:BTCUSDT:BUY:3000000', 0, -1)
          expect(queue).to eq(['order-buy-1'])

          # 预留金额仅为名义金额：reserve_quote = floor(3_000_000 * 100_000_000 / 100_000_000) = 3_000_000
          balances = redis.hgetall('balance:buyer')
          expect(balances['USDT:available'].to_i).to eq(5_000_000 - 3_000_000)
          expect(balances['USDT:reserved'].to_i).to eq(3_000_000)
          expect(balances.fetch('BTC:available', '0').to_i).to eq(0)
          expect(balances.fetch('BTC:reserved', '0').to_i).to eq(0)

          ticker = exchange.ticker(symbol)
          expect(ticker[:best_bid_price]).to eq(3_000_000)
          expect(ticker[:best_bid_volume]).to eq(100_000_000)
          expect(ticker[:best_ask_price]).to eq(0)
          expect(ticker[:best_ask_volume]).to eq(0)
          expect(ticker[:last_price]).to eq(0)

          book = exchange.order_book(symbol)
          expect(book[:bids].map { |row| row[:price] }).to eq([3_000_000])
          expect(book[:bids].first[:volume]).to eq(100_000_000)
          expect(book[:asks]).to be_empty
        end
      end
      context " when opposite liquidity exists" do
        before do
          # 先挂出卖方流动性
          exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 100_000_000)
          exchange.place_limit_order(
            symbol: symbol,
            side: 'SELL',
            order_id: 'maker-ask',
            user_id: 'maker',
            price: 3_000_000,
            quantity: 100_000_000
          )
        end
        it 'matches when limit BUY price crosses best ask and partially fills then rests remaining' do
          # 买方下限价单，价格高于最优卖价，数量为 1.5 BTC，触发部分成交（吃掉 1 BTC，剩余 0.5 BTC 挂单）
          exchange.set_balance(user_id: 'buyer', asset: 'USDT', available: 5_000_000)
          result = exchange.place_limit_order(
            symbol: symbol,
            side: 'BUY',
            order_id: 'buy-match-1',
            user_id: 'buyer',
            price: 3_100_000,  # 高于最优卖价，可成交
            quantity: 150_000_000 # 1.5 BTC
          )

          expect(result[:status]).to eq('PARTIALLY_FILLED')
          expect(result[:remaining_quantity]).to eq(50_000_000)

          # 成交 1.0 BTC，买方获得 1.0 BTC；剩余 0.5 BTC 以 3_100_000 挂单并预留名义金额
          balances = redis.hgetall('balance:buyer')
          # 交易报价：floor(3_000_000 * 100_000_000 / 100_000_000) = 3_000_000
          # 买方手续费 10bps：floor(3_000_000 * 10 / 10000) = 3_000
          # 挂单预留报价：floor(3_100_000 * 50_000_000 / 100_000_000) = 1_550_000
          expect(balances.fetch('BTC:available', '0').to_i).to eq(100_000_000)
          expect(balances['USDT:reserved'].to_i).to eq(1_550_000)
          expect(balances['USDT:available'].to_i).to eq(5_000_000 - 3_000_000 - 3_000 - 1_550_000)

          # 买方剩余以 3_100_000 价格挂单
          buy_queue = redis.lrange('queue:BTCUSDT:BUY:3100000', 0, -1)
          expect(buy_queue).to eq(['buy-match-1'])

          # 卖方订单被完全吃掉（maker-ask FILLED 并移除）
          sell_queue = redis.lrange('queue:BTCUSDT:SELL:3000000', 0, -1)
          expect(sell_queue).to eq([])
          # 卖方订单应已完全成交并删除
          expect(exchange.order('maker-ask')).to eq({})

          # Ticker 应更新最优买卖与最近成交价
          ticker = exchange.ticker(symbol)
          expect(ticker[:best_bid_price]).to eq(3_100_000)
          expect(ticker[:best_bid_volume]).to eq(50_000_000)
          expect(ticker[:best_ask_price]).to eq(0)
          expect(ticker[:best_ask_volume]).to eq(0)
          expect(ticker[:last_price]).to eq(3_000_000)
        end

        it 'does not match when limit BUY price is below best ask; rests OPEN' do
          # 买方下限价单，价格低于最优卖价，无法成交，直接挂单
          exchange.set_balance(user_id: 'buyer2', asset: 'USDT', available: 5_000_000)
          result = exchange.place_limit_order(
            symbol: symbol,
            side: 'BUY',
            order_id: 'buy-no-match-1',
            user_id: 'buyer2',
            price: 2_900_000,  # 低于最优卖价，不满足撮合条件
            quantity: 100_000_000 # 1.0 BTC
          )

          expect(result[:status]).to eq('OPEN')
          expect(result[:remaining_quantity]).to eq(100_000_000)

          balances = redis.hgetall('balance:buyer2')
          # 预留报价：floor(2_900_000 * 100_000_000 / 100_000_000) = 2_900_000
          expect(balances['USDT:available'].to_i).to eq(5_000_000 - 2_900_000)
          expect(balances['USDT:reserved'].to_i).to eq(2_900_000)
          expect(balances.fetch('BTC:available', '0').to_i).to eq(0)
          expect(balances.fetch('BTC:reserved', '0').to_i).to eq(0)

          # 买方以 2_900_000 价格挂单；卖方仍保持队列与总量
          buy_queue = redis.lrange('queue:BTCUSDT:BUY:2900000', 0, -1)
          expect(buy_queue).to eq(['buy-no-match-1'])
          sell_queue = redis.lrange('queue:BTCUSDT:SELL:3000000', 0, -1)
          expect(sell_queue).to eq(['maker-ask'])
          sell_volume = redis.hgetall('volume:BTCUSDT:SELL')
          expect(sell_volume.fetch('3000000', '0').to_i).to eq(100_000_000)

          ticker = exchange.ticker(symbol)
          expect(ticker[:best_bid_price]).to eq(2_900_000)
          expect(ticker[:best_bid_volume]).to eq(100_000_000)
          expect(ticker[:best_ask_price]).to eq(3_000_000)
          expect(ticker[:best_ask_volume]).to eq(100_000_000)
          expect(ticker[:last_price]).to eq(0)
        end
      end
    end

    context "user has insufficient balance" do
      it 'rejects limit BUY when available quote is insufficient to reserve' do
        # USDT 余额不足以预留名义金额
        exchange.set_balance(user_id: 'poor_buyer', asset: 'USDT', available: 2_000_000) # 20000.00000000 USDT

        result = exchange.place_limit_order(
          symbol: symbol,
          side: 'BUY',
          order_id: 'insufficient-buy-1',
          user_id: 'poor_buyer',
          price: 3_000_000, # 30000.00000000 USDT
          quantity: 100_000_000 # 1.00000000 BTC
        )

        expect(result[:error]).to eq('INSUFFICIENT_FUNDS')
        expect(result[:asset]).to eq('USDT')

        # 不应产生队列或余额变化（除非预留成功）
        expect(redis.lrange('queue:BTCUSDT:BUY:3000000', 0, -1)).to be_empty
        balances = redis.hgetall('balance:poor_buyer')
        expect(balances['USDT:available'].to_i).to eq(2_000_000)
        expect(balances.fetch('USDT:reserved', '0').to_i).to eq(0)

        volume = redis.hgetall('volume:BTCUSDT:BUY')
        expect(volume.fetch('3000000', '0').to_i).to eq(0)
      end

      it 'rejects limit SELL when available base is insufficient to reserve' do
        # BTC 余额不足以预留挂单数量
        exchange.set_balance(user_id: 'poor_seller', asset: 'BTC', available: 50_000_000) # 0.50000000 BTC

        result = exchange.place_limit_order(
          symbol: symbol,
          side: 'SELL',
          order_id: 'insufficient-sell-1',
          user_id: 'poor_seller',
          price: 3_000_000,
          quantity: 100_000_000 # 1.00000000 BTC
        )

        expect(result[:error]).to eq('INSUFFICIENT_FUNDS')
        expect(result[:asset]).to eq('BTC')

        # 不应产生队列或余额变化
        expect(redis.lrange('queue:BTCUSDT:SELL:3000000', 0, -1)).to be_empty
        balances = redis.hgetall('balance:poor_seller')
        expect(balances['BTC:available'].to_i).to eq(50_000_000)
        expect(balances.fetch('BTC:reserved', '0').to_i).to eq(0)

        volume = redis.hgetall('volume:BTCUSDT:SELL')
        expect(volume.fetch('3000000', '0').to_i).to eq(0)
      end
    end
  
    context "order with dupliated id exists" do 
      it 'rejects a duplicate limit order with the same order_id' do
        exchange.set_balance(user_id: 'maker', asset: 'BTC', available: 100_000_000)

        first = exchange.place_limit_order(
          symbol: symbol,
          side: 'SELL',
          order_id: 'dupe-1',
          user_id: 'maker',
          price: 3_000_000,
          quantity: 100_000_000
        )

        expect(first[:status]).to eq('OPEN')

        duplicate = exchange.place_limit_order(
          symbol: symbol,
          side: 'SELL',
          order_id: 'dupe-1',
          user_id: 'maker',
          price: 3_000_000,
          quantity: 100_000_000
        )

        expect(duplicate[:error]).to eq('DUPLICATE_ORDER_ID')
        queue = redis.lrange('queue:BTCUSDT:SELL:3000000', 0, -1)
        expect(queue).to eq(%w[dupe-1])

        balances = redis.hgetall('balance:maker')
        expect(balances['BTC:available'].to_i).to eq(0)
        expect(balances['BTC:reserved'].to_i).to eq(100_000_000)
      end
    end
  end

  after do
    redis.close if redis.respond_to?(:close)
  end
end