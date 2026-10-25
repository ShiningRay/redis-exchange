# frozen_string_literal: true

require 'spec_helper'
require 'redis_exchange/maintenance'

# 不变式：任何时刻，活跃订单索引（user_orders:<uid>:<symbol>）里的每个 id
# 都必须对应一个真实存在的订单哈希（order:<id>）。
#
# 线上观察到约 15% 的索引条目没有对应哈希（BTC 39 条里 9 条），这些幽灵条目
# 会让客户端按 active_orders 对账时不断拿到不存在的订单，进而反复撤单/重挂。
# 这里用随机操作序列覆盖 挂单 / 撤单 / 吃单 / 市价单 / 强制撤单 五条写入路径，
# 每步都校验该不变式；一旦某条路径留下幽灵条目，用例立刻失败并打印具体 id。
RSpec.describe RedisExchange::Client do
  let(:users) { %w[alice bob] }
  let(:symbol) { 'BTCUSDT' }

  def stale_index_entries
    entries = []
    redis.keys("user_orders:*:#{symbol}").each do |key|
      redis.zrange(key, 0, -1).each do |order_id|
        next if redis.exists("order:#{order_id}") == 1

        entries << { key: key, order_id: order_id, tombstone: redis.get("order_tombstone:#{order_id}") }
      end
    end
    entries
  end

  before do
    users.each do |u|
      exchange.set_balance(user_id: u, asset: 'BTC', available: 5_000_000_000)
      exchange.set_balance(user_id: u, asset: 'USDT', available: 5_000_000_000_000)
    end
  end

  it '随机挂单/撤单/吃单/市价单/强撤之后，索引里不应出现没有订单哈希的条目' do
    maintenance = RedisExchange::Maintenance.new(redis)
    rng = Random.new(20_261_025)
    live = []   # 仍在盘口上的订单 id
    seq = 0
    stats = Hash.new(0)

    240.times do |step|
      case rng.rand(6)
      when 0, 1 # 常规挂单（价格分散，避免立即成交）
        seq += 1
        user = users.sample(random: rng)
        side = rng.rand(2).zero? ? 'BUY' : 'SELL'
        oid = "#{user}-#{seq}"
        res = exchange.place_limit_order(
          symbol: symbol, side: side, order_id: oid, user_id: user,
          price: 3_000_000 + rng.rand(20_000), quantity: 100_000_000
        )
        stats["limit:#{res[:status] || res[:error]}"] += 1
        live << [user, oid] if %w[OPEN PARTIALLY_FILLED].include?(res[:status])
      when 2 # 撤单
        next if live.empty?

        _user, oid = live.delete_at(rng.rand(live.size))
        res = exchange.cancel_order(oid)
        stats["cancel:#{res[:status] || res[:error]}"] += 1
      when 3 # taker 打穿对手价，制造成交（含部分成交）
        seq += 1
        user = users.sample(random: rng)
        side = rng.rand(2).zero? ? 'BUY' : 'SELL'
        oid = "take-#{seq}"
        res = exchange.place_limit_order(
          symbol: symbol, side: side, order_id: oid, user_id: user,
          price: side == 'BUY' ? 3_200_000 : 2_800_000, quantity: 120_000_000
        )
        stats["take:#{res[:status] || res[:error]}"] += 1
        live << [user, oid] if %w[OPEN PARTIALLY_FILLED].include?(res[:status])
      when 4 # 市价单（部分成交后丢弃的路径）
        seq += 1
        user = users.sample(random: rng)
        side = rng.rand(2).zero? ? 'BUY' : 'SELL'
        oid = "mkt-#{seq}"
        res = exchange.place_market_order(
          symbol: symbol, side: side, order_id: oid, user_id: user,
          quantity: 80_000_000, price_cap: side == 'BUY' ? 3_300_000 : 2_700_000
        )
        stats["market:#{res[:status] || res[:error]}"] += 1
      when 5 # 强制撤单（运维/清理路径）
        next if live.empty?

        _user, oid = live.delete_at(rng.rand(live.size))
        res = maintenance.force_cancel_order(order_id: oid, mode: :best_effort_unlock)
        stats["force:#{res[:status] || res[:error]}"] += 1
      end

      stale = stale_index_entries
      next if stale.empty?

      raise "step #{step} 之后出现幽灵索引条目: #{stale.inspect}\n操作统计: #{stats.inspect}"
    end

    # 收尾：把剩下的订单全部撤掉后再校验一次
    live.each { |_u, oid| exchange.cancel_order(oid) }
    remaining = stale_index_entries
    expect(remaining).to be_empty, "撤单收尾后仍有幽灵索引条目: #{remaining.inspect}\n操作统计: #{stats.inspect}"

    # 确保随机序列真的覆盖到了每条路径（否则用例是空转的）
    expect(stats.keys.grep(/^limit:/).any?).to be(true)
    expect(stats.keys.grep(/^cancel:/).any?).to be(true)
    expect(stats.keys.grep(/^take:/).any?).to be(true)
    expect(stats.keys.grep(/^market:/).any?).to be(true)
    expect(stats.keys.grep(/^force:/).any?).to be(true)
  end
end
