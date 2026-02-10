# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RedisExchange::Client do
  describe 'Small remaining quantity market order match' do
    # 使用用户提供的真实场景配置
    before do
      redis.flushdb
      # NST 配置: balance_scale: 100000000
      exchange.seed_asset(asset: 'NST', balance_scale: 100_000_000, status: 'ACTIVE')
      # USDT 配置: balance_scale: 1000000  
      exchange.seed_asset(asset: 'USDT', balance_scale: 1_000_000, status: 'ACTIVE')
      
      # NST/USDT 市场配置: price_scale: 1000, quantity_scale: 10000
      exchange.seed_market(
        symbol: 'NST/USDT',
        base_asset: 'NST',
        quote_asset: 'USDT',
        price_scale: 1000,
        quantity_scale: 10000,
        maker_fee_bps: 10,
        taker_fee_bps: 50,
        min_qty: 1,
        min_notional: 1,
        status: 'OPEN'
      )
    end

    it 'handles market sell against partially filled buy order with tiny remaining' do
      # 复现用户的场景：
      # 1. 创建一个 BUY 限价单，模拟已经部分成交后的状态
      # 2. 尝试市价卖出，匹配这个买单的剩余部分
      
      # 设置 maker（买单用户）的余额
      # 需要足够的 USDT 来支付买单
      # notional = (245 * 9,990,000) / 10,000 = 244,755
      # reserve_quote_balance = 244,755 * 1,000 (quote_factor) = 244,755,000
      exchange.set_balance(user_id: '7438', asset: 'USDT', available: 300_000_000, reserved: 0)
      
      # 创建原始限价买单
      # price=245, quantity=9990000 (scaled by quantity_scale=10000)
      # 实际价格 = 245/1000 = 0.245 USDT
      # 实际数量 = 9990000/10000 = 999 NST
      exchange.place_limit_order(
        symbol: 'NST/USDT',
        side: 'BUY',
        order_id: '4e9e268e-4228-4af0-a370-88789d2921b9',
        user_id: '7438',
        price: 245,        # 0.245 USDT (scaled by 1000)
        quantity: 9_990_000  # 999 NST (scaled by 10000)
      )
      
      # 验证订单创建成功
      order = exchange.order('4e9e268e-4228-4af0-a370-88789d2921b9')
      expect(order[:status]).to eq('OPEN')
      expect(order[:remaining]).to eq(9_990_000)
      
      # 模拟部分成交：直接修改订单状态为 PARTIALLY_FILLED，remaining=1
      # 这对应于用户提供的场景
      redis.hmset('order:4e9e268e-4228-4af0-a370-88789d2921b9',
        'remaining', 1,
        'status', 'PARTIALLY_FILLED',
        'executed_quote', 244754,
        'reserved_quote', 1000,
        'trade_count', 2
      )
      
      # 验证修改后的状态
      order = exchange.order('4e9e268e-4228-4af0-a370-88789d2921b9')
      expect(order[:remaining]).to eq(1)
      expect(order[:status]).to eq('PARTIALLY_FILLED')
      
      # 设置 taker（卖单用户）的余额
      exchange.set_balance(user_id: 'seller', asset: 'NST', available: 100_000_000, reserved: 0)
      
      # 尝试市价卖出 1 单位（匹配剩余的买单）
      # 这里应该能成功，不应该报错
      result = exchange.place_market_order(
        symbol: 'NST/USDT',
        side: 'SELL',
        order_id: 'market-sell-1',
        user_id: 'seller',
        quantity: 1,  # 最小的剩余数量
        price_cap: 0  # 无价格限制
      )
      
      # 验证结果
      expect(result[:error]).to be_nil, "Expected no error but got: #{result[:error]}"
      expect(result[:status]).to eq('FILLED')
      expect(result[:executed_quantity]).to eq(1)
    end

    it 'handles edge case where trade_quote rounds to zero' do
      # 测试 trade_quote 计算为 0 的边界情况
      # trade_quote = floor(trade_price * trade_qty / quantity_scale)
      # = floor(245 * 1 / 10000) = 0
      
      exchange.set_balance(user_id: 'buyer', asset: 'USDT', available: 10_000_000, reserved: 0)
      exchange.set_balance(user_id: 'seller', asset: 'NST', available: 100_000_000, reserved: 0)
      
      # 创建一个买单
      exchange.place_limit_order(
        symbol: 'NST/USDT',
        side: 'BUY',
        order_id: 'tiny-buy-1',
        user_id: 'buyer',
        price: 245,
        quantity: 1  # 非常小的数量
      )
      
      # 市价卖出匹配
      result = exchange.place_market_order(
        symbol: 'NST/USDT',
        side: 'SELL',
        order_id: 'tiny-sell-1',
        user_id: 'seller',
        quantity: 1,
        price_cap: 0
      )
      
      # 应该成功处理，不应该报错
      expect(result[:error]).to be_nil, "Expected no error but got: #{result[:error]}"
    end
  end
end
