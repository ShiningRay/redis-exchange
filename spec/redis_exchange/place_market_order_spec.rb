# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RedisExchange::Client do

  describe "#place_market_order" do
    context "given resting liquidity is sufficient" do
      before do
        exchange.set_balance(user_id: 'bob', asset: 'BTC', available: 200_000_000) # 2.00000000 BTC
        exchange.place_limit_order(
          symbol: symbol,
          side: 'SELL', 
          order_id: 'maker-1',
          user_id: 'bob',
          price: 3_000_000, # 30000.00000000 USDT
          quantity: 100_000_000 # 1.00000000 BTC
        ) # SELL, lock BTC
        
      end

      it 'matches a market order against resting liquidity' do
        exchange.set_balance(user_id: 'alice', asset: 'USDT', available: 5_000_000) # 50000.00000000 USDT

        result = exchange.place_market_order(
          symbol: symbol,
          side: 'BUY',
          order_id: 'taker-1',
          user_id: 'alice',
          quantity: 50_000_000, # 0.500000000 BTC
          price_cap: 3_100_000 # 31000.00000000 USDT
        ) # BUY, Spent 15000 USDT 

        expect(result[:status]).to eq('FILLED')
        expect(result[:executed_quantity]).to eq(50_000_000) # 0.500000000 BTC

        alice_balances = redis.hgetall('balance:alice')
        expect(alice_balances['BTC:available'].to_i).to eq(50_000_000) # 0.500000000 BTC
        # USDT 可用余额精确校验：trade_quote=1_500_000, taker_fee=1_500 → debit=1_501_500 → 5_000_000-1_501_500=3_498_500
        expect(alice_balances['USDT:available'].to_i).to eq(3_498_500) # 34985.00 USDT
        expect(alice_balances['USDT:reserved'].to_i).to eq(0)

        bob_balances = redis.hgetall('balance:bob')
        # BTC 预留余额减少 50_000_000，剩余 50_000_000；可用余额保持 100_000_000
        expect(bob_balances['BTC:reserved'].to_i).to eq(50_000_000) # 50.00000000 BTC
        expect(bob_balances['BTC:available'].to_i).to eq(100_000_000)
        # USDT 可用余额精确校验：maker_fee=750 → credit=1_500_000-750=1_499_250
        expect(bob_balances['USDT:available'].to_i).to eq(1_499_250) 

        ticker = exchange.ticker(symbol)
        expect(ticker[:last_price]).to eq(3_000_000) # 30000.00000000 USDT
        expect(ticker[:best_ask_price]).to eq(3_000_000) # 30000.00000000 USDT
        expect(ticker[:best_ask_volume]).to eq(50_000_000) # 50.00000000 BTC
        expect(ticker[:best_bid_price]).to eq(0)
        expect(ticker[:best_bid_volume]).to eq(0)

        book = exchange.order_book(symbol)
        expect(book[:asks].first[:price]).to eq(3_000_000)
        expect(book[:asks].first[:volume]).to eq(50_000_000)
        expect(book[:bids]).to be_empty

        # Verify trades returned in response
        trades = result[:trades]
        expect(trades).to be_an(Array)
        expect(trades.size).to eq(1)
        trade = trades.first
        expect(trade[:taker_order_id]).to eq('taker-1')
        expect(trade[:maker_order_id]).to eq('maker-1')
        expect(trade[:buy_order_id]).to eq('taker-1')
        expect(trade[:sell_order_id]).to eq('maker-1')
        expect(trade[:taker_side]).to eq('BUY')
        expect(trade[:price]).to eq(3_000_000)
        expect(trade[:quantity]).to eq(50_000_000)
        expect(trade[:timestamp]).to be_a(Integer)

        # Verify trade stream entry in Redis (values stored as strings)
        stream_entries = redis.xrevrange('trades:BTCUSDT', '+', '-', count: 1)
        expect(stream_entries).not_to be_empty
        entry_id, fields = stream_entries.first
        fields_hash = fields.is_a?(Hash) ? fields : Hash[*fields]
        expect(fields_hash['taker_order_id']).to eq('taker-1')
        expect(fields_hash['maker_order_id']).to eq('maker-1')
        expect(fields_hash['buy_order_id']).to eq('taker-1')
        expect(fields_hash['sell_order_id']).to eq('maker-1')
        expect(fields_hash['taker_side']).to eq('BUY')
        expect(fields_hash['price']).to eq('3000000')
        expect(fields_hash['quantity']).to eq('50000000')
        expect(fields_hash['symbol']).to eq('BTCUSDT')
      end

    end

    context "when matching against a resting BUY limit order" do
      it 'does not make maker quote reserved negative' do
        exchange.set_balance(user_id: 'maker-buyer', asset: 'USDT', available: 5_000_000)
        exchange.place_limit_order(
          symbol: symbol,
          side: 'BUY',
          order_id: 'maker-bid-1',
          user_id: 'maker-buyer',
          price: 3_000_000,
          quantity: 100_000_000
        )

        maker_before = redis.hgetall('balance:maker-buyer')
        expect(maker_before['USDT:reserved'].to_i).to eq(3_001_500)
        expect(maker_before['USDT:available'].to_i).to eq(5_000_000 - 3_001_500)

        exchange.set_balance(user_id: 'taker-seller', asset: 'BTC', available: 100_000_000)
        result = exchange.place_market_order(
          symbol: symbol,
          side: 'SELL',
          order_id: 'taker-sell-1',
          user_id: 'taker-seller',
          quantity: 100_000_000,
          price_cap: 2_900_000
        )

        expect(result[:status]).to eq('FILLED')

        maker_after = redis.hgetall('balance:maker-buyer')
        expect(maker_after['USDT:reserved'].to_i).to eq(0)
        expect(maker_after['BTC:available'].to_i).to eq(100_000_000)
        expect(maker_after['USDT:available'].to_i).to eq(5_000_000 - 3_001_500)

        expect(exchange.order('maker-bid-1')).to eq({})
      end
    end
    
    context "market order completely fills a resting limit order" do
      it 'matches a market order full with a limit order' do
        # Create fresh limit order for this test
        exchange.set_balance(user_id: 'bob', asset: 'BTC', available: 200_000_000) # 200.00000000 BTC
        exchange.place_limit_order(
          symbol: symbol,
          side: 'SELL', 
          order_id: 'market-full-maker-1',
          user_id: 'bob',
          price: 3_000_000, # 30000.00000000 USDT
          quantity: 100_000_000 # 1.00000000 BTC
        ) # SELL, lock BTC

        exchange.set_balance(user_id: 'alice', asset: 'USDT', available: 5_000_000) # 50000.00000000 USDT

        result = exchange.place_market_order(
          symbol: symbol,
          side: 'BUY',
          order_id: 'market-full-taker-1',
          user_id: 'alice',
          quantity: 100_000_000, # 1.00000000 BTC
          price_cap: 3_100_000 # 31000.00000000 USDT
        ) # BUY market order
        
        # 完全吃掉 1.00000000 BTC 挂单，市价单应为 FILLED
        expect(result[:status]).to eq('FILLED')
        expect(result[:executed_quantity]).to eq(100_000_000)
        expect(result[:remaining_quantity]).to eq(0)

        duplicate = exchange.place_market_order(
          symbol: symbol,
          side: 'BUY',
          order_id: 'market-full-taker-1',
          user_id: 'alice',
          quantity: 100_000_000,
          price_cap: 3_100_000
        )
        expect(duplicate[:error]).to eq('DUPLICATE_ORDER_ID')

        # 对手方卖单队列应被清空；订单哈希删除（终态）
        expect(redis.lrange('queue:BTCUSDT:SELL:3000000', 0, -1)).to eq([])
        expect(exchange.order('market-full-maker-1')).to eq({})
        expect(exchange.order('market-full-taker-1')).to eq({})

        # 买方余额：获得 1.00000000 BTC；USDT 可用扣除名义金额与吃单手续费
        # trade_quote = floor(3_000_000 * 100_000_000 / 100_000_000) = 3_000_000
        # taker_fee(10bps) = floor(3_000_000 * 10 / 10000) = 3_000
        # debit = 3_000_000 + 3_000 = 3_003_000
        alice_balances = redis.hgetall('balance:alice')
        expect(alice_balances['BTC:available'].to_i).to eq(100_000_000)
        expect(alice_balances['USDT:reserved'].to_i).to eq(0)
        expect(alice_balances['USDT:available'].to_i).to eq(5_000_000 - 3_003_000)

        # 卖方余额：释放全部 BTC 预留，USDT 入账（扣除 maker_fee）
        # maker_fee(5bps) = floor(3_000_000 * 5 / 10000) = 1_500
        # credit = 3_000_000 - 1_500 = 2_998_500
        bob_balances = redis.hgetall('balance:bob')
        expect(bob_balances['BTC:reserved'].to_i).to eq(0)
        expect(bob_balances['BTC:available'].to_i).to eq(100_000_000)
        expect(bob_balances['USDT:available'].to_i).to eq(2_998_500)

        # Ticker：更新最近成交价；订单簿清空
        ticker = exchange.ticker(symbol)
        expect(ticker[:last_price]).to eq(3_000_000)
        expect(ticker[:best_ask_price]).to eq(0)
        expect(ticker[:best_ask_volume]).to eq(0)
        expect(ticker[:best_bid_price]).to eq(0)
        expect(ticker[:best_bid_volume]).to eq(0)

        book = exchange.order_book(symbol)
        expect(book[:asks]).to be_empty
        expect(book[:bids]).to be_empty

        # 返回与流中的成交记录
        trades = result[:trades]
        expect(trades).to be_an(Array)
        expect(trades.size).to eq(1)
        trade = trades.first
        expect(trade[:taker_order_id]).to eq('market-full-taker-1')
        expect(trade[:maker_order_id]).to eq('market-full-maker-1')
        expect(trade[:buy_order_id]).to eq('market-full-taker-1')
        expect(trade[:sell_order_id]).to eq('market-full-maker-1')
        expect(trade[:taker_side]).to eq('BUY')
        expect(trade[:price]).to eq(3_000_000)
        expect(trade[:quantity]).to eq(100_000_000)

        stream_entries = redis.xrevrange("trades:#{symbol}", '+', '-', count: 1)
        expect(stream_entries).not_to be_empty
        _, fields = stream_entries.first
        fields_hash = fields.is_a?(Hash) ? fields : Hash[*fields]
        expect(fields_hash['taker_order_id']).to eq('market-full-taker-1')
        expect(fields_hash['maker_order_id']).to eq('market-full-maker-1')
        expect(fields_hash['buy_order_id']).to eq('market-full-taker-1')
        expect(fields_hash['sell_order_id']).to eq('market-full-maker-1')
        expect(fields_hash['taker_side']).to eq('BUY')
        expect(fields_hash['price']).to eq('3000000')
        expect(fields_hash['quantity']).to eq('100000000')
        expect(fields_hash['symbol']).to eq(symbol)
      end      
    end
    it '当市价单数量大于对手方可成交数量时，直接失败并报错流动性不足' do
      # 对手方仅有 0.50000000 BTC 的挂单
      exchange.set_balance(user_id: 'bob', asset: 'BTC', available: 200_000_000) # 200.00000000 BTC
      exchange.place_limit_order(
        symbol: symbol,
        side: 'SELL',
        order_id: 'maker-1',
        user_id: 'bob',
        price: 3_000_000, # 30000.00000000 USDT
        quantity: 50_000_000 # 0.50000000 BTC
      ) # SELL, lock BTC

      exchange.set_balance(user_id: 'alice', asset: 'USDT', available: 5_000_000) # 50000.00000000 USDT

      # 市价买入 1.00000000 BTC，但对手方仅有 0.50000000 BTC，期望直接失败
      result = exchange.place_market_order(
        symbol: symbol,
        side: 'BUY',
        order_id: 'taker-1',
        user_id: 'alice',
        quantity: 100_000_000, # 1.00000000 BTC
        price_cap: 3_100_000 # 31000.00000000 USDT
      )
      expect(result[:status]).to eq('NO_LIQUIDITY')
      expect(result[:executed_quantity]).to eq(0)

      # 余额不应发生变化（市价单失败不成交）
      alice_balances = redis.hgetall('balance:alice')
      expect(alice_balances['BTC:available'].to_i).to eq(0)
      expect(alice_balances['USDT:available'].to_i).to eq(5_000_000)
      expect(alice_balances['USDT:reserved'].to_i).to eq(0)

      bob_balances = redis.hgetall('balance:bob')
      expect(bob_balances['BTC:reserved'].to_i).to eq(50_000_000) # 挂单仍保持
      expect(bob_balances['BTC:available'].to_i).to eq(150_000_000)

      # 订单哈希：taker 为终态 NO_LIQUIDITY，应被删除；maker 保持 OPEN
      expect(exchange.order('taker-1')).to eq({})
      maker_snapshot = exchange.order('maker-1')
      expect(maker_snapshot[:status]).to eq('OPEN')
      expect(maker_snapshot[:remaining]).to eq(50_000_000)

      # 撮合流水与队列：无成交，无队列变化
      trades = redis.xrevrange("trades:#{symbol}", '+', '-', count: 5)
      expect(trades).to be_empty
      expect(redis.lrange('queue:BTCUSDT:SELL:3000000', 0, -1)).to eq(['maker-1'])
      expect(redis.hget('volume:BTCUSDT:SELL', '3000000').to_i).to eq(50_000_000)

      ticker = exchange.ticker(symbol)
      # 失败不应更新最近成交价与最佳买卖
      expect(ticker[:last_price]).to eq(0)
      expect(ticker[:best_ask_price]).to eq(3_000_000)
      expect(ticker[:best_ask_volume]).to eq(50_000_000)
      expect(ticker[:best_bid_price]).to eq(0)
      expect(ticker[:best_bid_volume]).to eq(0)

      book = exchange.order_book(symbol)
      expect(book[:asks].map { |row| row[:price] }).to eq([3_000_000])
      expect(book[:asks].first[:volume]).to eq(50_000_000)
      expect(book[:bids]).to be_empty

      # 返回的成交记录应为空
      trades = result[:trades]
      expect(trades).to be_empty

      # Redis 成交流应无新增记录
      stream_entries = redis.xrevrange('trades:BTCUSDT', '+', '-', count: 1)
      expect(stream_entries).to be_empty
    end
  # 价格选择相关的市价单测试
  context 'price selection for market orders' do
    it '市价买单在存在多个不同价格的卖单时，按最低的限价卖单价格成交（只吃掉一个）' do
      # 挂三档限价卖单（不同价格、相同数量）
      exchange.set_balance(user_id: 'seller-multi', asset: 'BTC', available: 300_000_000)
      exchange.place_limit_order(symbol: symbol, side: 'SELL', order_id: 'ask-low',  user_id: 'seller-multi', price: 2_900_000, quantity: 100_000_000)
      exchange.place_limit_order(symbol: symbol, side: 'SELL', order_id: 'ask-mid',  user_id: 'seller-multi', price: 3_000_000, quantity: 100_000_000)
      exchange.place_limit_order(symbol: symbol, side: 'SELL', order_id: 'ask-high', user_id: 'seller-multi', price: 3_100_000, quantity: 100_000_000)

      # 市价买单数量只吃掉一个卖单
      exchange.set_balance(user_id: 'taker-b', asset: 'USDT', available: 10_000_000)
      res = exchange.place_market_order(symbol: symbol, side: 'BUY', order_id: 'mkt-buy-1', user_id: 'taker-b', quantity: 100_000_000, price_cap: 0)

      expect(res[:status]).to eq('FILLED')
      expect(res[:executed_quantity]).to eq(100_000_000)
      expect(res[:trades]).to be_an(Array)
      expect(res[:trades].size).to eq(1)
      expect(res[:trades].first[:price]).to eq(2_900_000)

      # Redis 成交流最新一条记录的价格应为最低卖价
      stream_entries = redis.xrevrange("trades:#{symbol}", '+', '-', count: 1)
      expect(stream_entries).not_to be_empty
      _, fields = stream_entries.first
      fields_hash = fields.is_a?(Hash) ? fields : Hash[*fields]
      expect(fields_hash['price']).to eq('2900000')
    end

    it '市价卖单在存在多个不同价格的买单时，按最高的限价买单价格成交（只吃掉一个）' do
      # 挂三档限价买单（不同价格、相同数量）
      exchange.set_balance(user_id: 'buyer-1', asset: 'USDT', available: 5_000_000)
      exchange.set_balance(user_id: 'buyer-2', asset: 'USDT', available: 5_000_000)
      exchange.set_balance(user_id: 'buyer-3', asset: 'USDT', available: 5_000_000)
      exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'bid-low',  user_id: 'buyer-1', price: 2_900_000, quantity: 100_000_000)
      exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'bid-mid',  user_id: 'buyer-2', price: 3_000_000, quantity: 100_000_000)
      exchange.place_limit_order(symbol: symbol, side: 'BUY', order_id: 'bid-high', user_id: 'buyer-3', price: 3_100_000, quantity: 100_000_000)

      # 市价卖单数量只吃掉一个买单
      exchange.set_balance(user_id: 'taker-s', asset: 'BTC', available: 100_000_000)
      res = exchange.place_market_order(symbol: symbol, side: 'SELL', order_id: 'mkt-sell-1', user_id: 'taker-s', quantity: 100_000_000, price_cap: 0)

      expect(res[:status]).to eq('FILLED')
      expect(res[:executed_quantity]).to eq(100_000_000)
      expect(res[:trades]).to be_an(Array)
      expect(res[:trades].size).to eq(1)
      expect(res[:trades].first[:price]).to eq(3_100_000)

      # Redis 成交流最新一条记录的价格应为最高买价
      stream_entries = redis.xrevrange("trades:#{symbol}", '+', '-', count: 1)
      expect(stream_entries).not_to be_empty
      _, fields = stream_entries.first
      fields_hash = fields.is_a?(Hash) ? fields : Hash[*fields]
      expect(fields_hash['price']).to eq('3100000')
    end
  end

  end
end
