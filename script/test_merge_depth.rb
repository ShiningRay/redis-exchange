#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'redis'
require_relative '../lib/redis_exchange'

# 测试合并深度功能的脚本
# Usage:
#   ruby script/test_merge_depth.rb [--redis-url redis://127.0.0.1:6379/0] [--symbol BTCUSDT]

options = {
  redis_url: ENV['REDIS_URL'] || 'redis://127.0.0.1:6379/0',
  symbol: 'BTCUSDT',
  color: true
}

# 简单的参数解析
ARGV.each_with_index do |arg, i|
  case arg
  when '--redis-url'
    options[:redis_url] = ARGV[i + 1]
  when '--symbol'
    options[:symbol] = ARGV[i + 1]
  when '--no-color'
    options[:color] = false
  end
end

# 彩色输出辅助方法
COLORS = {
  reset: "\e[0m",
  bold: "\e[1m",
  red: "\e[31m",
  green: "\e[32m",
  yellow: "\e[33m",
  blue: "\e[34m",
  magenta: "\e[35m",
  cyan: "\e[36m"
}.freeze

def c(str, *styles)
  return str unless ($color_enabled rescue false)
  codes = styles.flatten.map { |s| COLORS[s] }.compact.join
  "#{codes}#{str}#{COLORS[:reset]}"
end

$color_enabled = options[:color] && $stdout.isatty

# 连接 Redis 和交易所
redis = Redis.new(url: options[:redis_url])
exchange = RedisExchange::Client.new(redis: redis)

symbol = options[:symbol]

# 默认市场配置
PRICE_SCALE = 100
QUANTITY_SCALE = 100_000_000

# 格式化辅助函数
def format_price(v)
  (v.to_f / 100).to_s
end

def format_quantity(v)
  (v.to_f / 100_000_000).to_s
end

puts "#{c('[TEST]', :cyan)} 开始测试合并深度功能..."
puts "#{c('[INFO]', :blue)} 市场符号: #{symbol}"

# 清理并准备测试环境
puts "#{c('[SETUP]', :yellow)} 清理测试环境..."
exchange.clear_books(symbol)

# 种子市场
puts "#{c('[SETUP]', :yellow)} 配置市场参数..."
exchange.seed_market(
  symbol: symbol,
  base_asset: 'BTC',
  quote_asset: 'USDT',
  price_scale: PRICE_SCALE,
  quantity_scale: QUANTITY_SCALE,
  maker_fee_bps: 5,
  taker_fee_bps: 10,
  min_qty: 1,
  min_notional: 1,
  status: 'OPEN'
)

# 创建测试订单簿数据
puts "#{c('[SETUP]', :yellow)} 创建测试订单簿数据..."

# 买单：从 29000 到 29900，间隔 100
buy_orders = []
(0..9).each do |i|
  price = (29000 + i * 100) * PRICE_SCALE
  quantity = (0.1 + i * 0.05) * QUANTITY_SCALE
  buy_orders << { price: price, quantity: quantity }
end

# 卖单：从 30100 到 31000，间隔 100
sell_orders = []
(0..9).each do |i|
  price = (30100 + i * 100) * PRICE_SCALE
  quantity = (0.1 + i * 0.05) * QUANTITY_SCALE
  sell_orders << { price: price, quantity: quantity }
end

# 使用直接 Redis 命令创建订单簿数据（绕过撮合引擎）
buy_orders.each_with_index do |order, i|
  order_id = "test-buy-#{i}"
  user_id = "test-user"

  # 添加到订单簿
  redis.zadd("book:#{symbol}:BUY", order[:price], order[:price].to_s)
  redis.hset("volume:#{symbol}:BUY", order[:price].to_s, order[:quantity].to_s)

  # 创建订单队列
  queue_key = "queue:#{symbol}:BUY:#{order[:price]}"
  redis.lpush(queue_key, order_id)

  # 创建订单记录
  order_key = "order:#{order_id}"
  redis.hset(order_key, {
    'order_id' => order_id,
    'user_id' => user_id,
    'symbol' => symbol,
    'side' => 'BUY',
    'type' => 'LIMIT',
    'status' => 'OPEN',
    'price' => order[:price].to_s,
    'quantity' => order[:quantity].to_s,
    'remaining' => order[:quantity].to_s,
    'created_at' => (Time.now.to_f * 1000).to_i,
    'sequence' => (i + 1).to_s
  })
end

sell_orders.each_with_index do |order, i|
  order_id = "test-sell-#{i}"
  user_id = "test-user"

  # 添加到订单簿
  redis.zadd("book:#{symbol}:SELL", order[:price], order[:price].to_s)
  redis.hset("volume:#{symbol}:SELL", order[:price].to_s, order[:quantity].to_s)

  # 创建订单队列
  queue_key = "queue:#{symbol}:SELL:#{order[:price]}"
  redis.lpush(queue_key, order_id)

  # 创建订单记录
  order_key = "order:#{order_id}"
  redis.hset(order_key, {
    'order_id' => order_id,
    'user_id' => user_id,
    'symbol' => symbol,
    'side' => 'SELL',
    'type' => 'LIMIT',
    'status' => 'OPEN',
    'price' => order[:price].to_s,
    'quantity' => order[:quantity].to_s,
    'remaining' => order[:quantity].to_s,
    'created_at' => (Time.now.to_f * 1000).to_i,
    'sequence' => (i + 100).to_s
  })
end

puts "#{c('[SETUP]', :green)} ✅ 测试环境准备完成"
puts

# 显示原始订单簿
puts "#{c('[ORIGINAL]', :cyan)} 原始订单簿深度："
original_book = exchange.order_book(symbol)
puts "买单 (BIDS):"
original_book[:bids].first(5).each_with_index do |bid, i|
  puts "  #{i+1}. 价格: #{format_price(bid[:price])}, 数量: #{format_quantity(bid[:volume])}"
end
puts
puts "卖单 (ASKS):"
original_book[:asks].first(5).each_with_index do |ask, i|
  puts "  #{i+1}. 价格: #{format_price(ask[:price])}, 数量: #{format_quantity(ask[:volume])}"
end
puts

# 测试不同的合并深度设置
test_bucket_sizes = [500, 1000, 2000]

test_bucket_sizes.each do |bucket_size|
  puts "#{c('[MERGED]', :magenta)} 合并深度测试 (bucket_size = #{format_price(bucket_size)}):"

  merged_book = exchange.merge_depth_both_sides(symbol, bucket_size, bucket_size)

  puts "合并后的买单 (BIDS):"
  merged_book[:bids].first(5).each_with_index do |bid, i|
    puts "  #{i+1}. 价格: #{format_price(bid[:price])}, 数量: #{format_quantity(bid[:volume])}, 合并层级: #{bid[:original_levels]}"
  end
  puts

  puts "合并后的卖单 (ASKS):"
  merged_book[:asks].first(5).each_with_index do |ask, i|
    puts "  #{i+1}. 价格: #{format_price(ask[:price])}, 数量: #{format_quantity(ask[:volume])}, 合并层级: #{ask[:original_levels]}"
  end
  puts
end

# 测试单边合并深度
puts "#{c('[SINGLE SIDE]', :blue)} 单边合并深度测试："

buy_merged = exchange.merge_depth(symbol, 'BUY', 500)
puts "买单合并结果 (bucket_size = 5.00):"
buy_merged.first(3).each_with_index do |bid, i|
  puts "  #{i+1}. 价格: #{format_price(bid[:price])}, 数量: #{format_quantity(bid[:volume])}, 合并层级: #{bid[:original_levels]}"
end
puts

sell_merged = exchange.merge_depth(symbol, 'SELL', 1500)
puts "卖单合并结果 (bucket_size = 15.00):"
sell_merged.first(3).each_with_index do |ask, i|
  puts "  #{i+1}. 价格: #{format_price(ask[:price])}, 数量: #{format_quantity(ask[:volume])}, 合并层级: #{ask[:original_levels]}"
end
puts

# 测试边界条件
puts "#{c('[EDGE CASES]', :yellow)} 边界条件测试："

# 测试空的订单簿
empty_symbol = 'EMPTYTEST'
redis.del("book:#{empty_symbol}:BUY", "book:#{empty_symbol}:SELL")
empty_result = exchange.merge_depth(empty_symbol, 'BUY', 1000)
puts "空订单簿测试: #{empty_result.empty? ? '✅ 通过' : '❌ 失败'}"

# 测试无效参数
begin
  exchange.merge_depth(symbol, 'INVALID', 1000)
  puts "无效参数测试: ❌ 失败 - 应该抛出异常"
rescue ArgumentError => e
  puts "无效参数测试: ✅ 通过 - #{e.message}"
end

begin
  exchange.merge_depth(symbol, 'BUY', 0)
  puts "零bucket_size测试: ❌ 失败 - 应该抛出异常"
rescue ArgumentError => e
  puts "零bucket_size测试: ✅ 通过 - #{e.message}"
end

puts
puts "#{c('[COMPLETE]', :green)} 🎉 合并深度功能测试完成！"

# 清理测试数据
puts "#{c('[CLEANUP]', :yellow)} 清理测试数据..."
exchange.clear_books(symbol)
puts "#{c('[CLEANUP]', :green)} ✅ 清理完成"