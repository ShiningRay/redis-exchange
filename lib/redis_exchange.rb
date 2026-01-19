# frozen_string_literal: true

# RedisExchange::Client
# ----------------------
# High-level Ruby façade for the Redis/Lua matching engine.
#
# Responsibilities:
# - Load and register the `match_order.lua` script against a provided Redis
#   connection.
# - Expose convenience helpers to seed market metadata, manage balances,
#   submit limit and market orders, and clear a market during tests.
# - Surfaces `ticker(symbol)` which reads the `ticker:{symbol}` hash maintained
#   by the Lua script (last trade + best bid/ask snapshot).
#
# Numeric conventions:
# - All amounts are integer minor units; scales are defined in `seed_market`.
# - Keep values < 9e15 to stay within Lua double precision.

require 'json'
require 'redis' unless defined?(Redis)
require 'time'
require 'securerandom'

module RedisExchange
  TICKER_FIELDS = %w[
    last_price
    last_quantity
    last_quote
    last_timestamp
    best_bid_price
    best_bid_volume
    best_ask_price
    best_ask_volume
  ].freeze

  # Order Sides
  SIDE_BUY = 'BUY'
  SIDE_SELL = 'SELL'
  SIDES = [SIDE_BUY, SIDE_SELL].freeze

  # Order Types
  ORDER_TYPE_LIMIT = 'LIMIT'
  ORDER_TYPE_MARKET = 'MARKET'
  ORDER_TYPES = [ORDER_TYPE_LIMIT, ORDER_TYPE_MARKET].freeze

  # Order Statuses
  ORDER_STATUS_OPEN = 'OPEN'
  ORDER_STATUS_PARTIALLY_FILLED = 'PARTIALLY_FILLED'
  ORDER_STATUS_FILLED = 'FILLED'
  ORDER_STATUS_CANCELLED = 'CANCELLED'
  ORDER_STATUS_REJECTED = 'REJECTED'
  ORDER_STATUS_UNKNOWN = 'UNKNOWN'
  ORDER_STATUS_NOT_FOUND = 'NOT_FOUND'

  # Market Statuses
  MARKET_STATUS_OPEN = 'OPEN'
  MARKET_STATUS_HALTED = 'HALTED'
  MARKET_STATUS_CLOSED = 'CLOSED'
  MARKET_STATUS_MAINTENANCE = 'MAINTENANCE'
  MARKET_STATUSES = [
    MARKET_STATUS_OPEN,
    MARKET_STATUS_HALTED,
    MARKET_STATUS_CLOSED,
    MARKET_STATUS_MAINTENANCE
  ].freeze

  # Asset Statuses
  ASSET_STATUS_ACTIVE = 'ACTIVE'
  ASSET_STATUS_HALTED = 'HALTED'
  ASSET_STATUSES = [ASSET_STATUS_ACTIVE, ASSET_STATUS_HALTED].freeze

  # Balance Actions
  ACTION_ADD = 'ADD'
  ACTION_SUB = 'SUB'
  ACTION_LOCK = 'LOCK'
  ACTION_UNLOCK = 'UNLOCK'
  ACTION_ADD_LOCKED = 'ADD_LOCKED'
  ACTION_SUB_LOCKED = 'SUB_LOCKED'
  BALANCE_ACTIONS = [
    ACTION_ADD, ACTION_SUB, ACTION_LOCK, ACTION_UNLOCK,
    ACTION_ADD_LOCKED, ACTION_SUB_LOCKED
  ].freeze

  # Balance Buckets
  BUCKET_AVAILABLE = 'available'
  BUCKET_RESERVED = 'reserved'
  BUCKETS = [BUCKET_AVAILABLE, BUCKET_RESERVED].freeze

  # Ledger Reasons
  REASON_DEPOSIT = 'DEPOSIT'
  REASON_WITHDRAWAL = 'WITHDRAWAL'
  REASON_MANUAL = 'MANUAL'
  REASON_MANUAL_ADJUST = 'MANUAL_ADJUST'
  REASON_LOCK = 'LOCK'
  REASON_UNLOCK = 'UNLOCK'

  # Force Cancel Modes
  CANCEL_MODE_DELETE_ONLY = 'DELETE_ONLY'
  CANCEL_MODE_BEST_EFFORT_UNLOCK = 'BEST_EFFORT_UNLOCK'
  CANCEL_MODES = [CANCEL_MODE_DELETE_ONLY, CANCEL_MODE_BEST_EFFORT_UNLOCK].freeze

  # Max integer safe for Lua double precision (approx 9e15)
  MAX_SAFE_INTEGER = 9_000_000_000_000_000
end

require_relative 'redis_exchange/version'
## No Ruby fallback or in-memory shim; all logic uses real Redis + Lua

module RedisExchange
  # Client encapsulates Lua script execution and convenience helpers.
  class Client
    attr_reader :redis

    # @param redis [Redis,nil] configured Redis connection; if nil, auto-connect
    # Auto-connect priority: ENV['REDIS_URL'] -> 'redis://127.0.0.1:6379/0'
    def initialize(redis: nil)
      @redis = redis || Redis.new(url: (ENV['REDIS_URL'] || 'redis://127.0.0.1:6379/0'))

      @match_order_script = load_script('match_order.lua')
      @cancel_order_script = load_script('cancel_order.lua')
      @balance_op_script = load_script('balance_op.lua')
      @audit_script = load_script('audit_user_balance.lua')
      @update_precision_script = load_script('update_market_precision.lua')
    end

    # Submit a limit order and return the Redis/Lua response hash.
    # @param symbol [String] market symbol
    # @param side [String, Symbol] 'BUY' or 'SELL'
    # @param order_id [String] unique order identifier
    # @param user_id [String] owner of the order
    # @param price [Integer, Float, BigDecimal] limit price
    # @param quantity [Integer, Float, BigDecimal] quantity
    # @param timestamp_ms [Integer,nil] optional epoch in milliseconds
    # @param auto_scale [Boolean] if true, scales price and quantity using market config
    # @return [Hash] parsed Lua response
    def place_limit_order(symbol:, side:, order_id:, user_id:, price:, quantity:, timestamp_ms: nil, auto_scale: false)
      final_price = auto_scale ? scale_price(symbol, price) : price.to_i
      final_quantity = auto_scale ? scale_quantity(symbol, quantity) : quantity.to_i

      raise ArgumentError, 'price must be positive for limit orders' unless final_price.positive?
      raise ArgumentError, 'quantity must be positive for limit orders' unless final_quantity.positive?

      execute_order(
        symbol: symbol,
        side: side,
        order_type: RedisExchange::ORDER_TYPE_LIMIT,
        order_id: order_id,
        user_id: user_id,
        price_limit: final_price,
        quantity: final_quantity,
        timestamp_ms: timestamp_ms
      )
    end

    # Submit a market order; optional price_cap acts as a worst-case limit.
    # @param price_cap [Integer, Float, BigDecimal] 0 for uncapped markets
    # @param auto_scale [Boolean] if true, scales price_cap and quantity using market config
    # Other params mirror #place_limit_order
    def place_market_order(symbol:, side:, order_id:, user_id:, quantity:, price_cap: 0, timestamp_ms: nil, auto_scale: false)
      final_price_cap = auto_scale ? scale_price(symbol, price_cap) : price_cap.to_i
      final_quantity = auto_scale ? scale_quantity(symbol, quantity) : quantity.to_i

      raise ArgumentError, 'price_cap must be non-negative' if final_price_cap.negative?

      execute_order(
        symbol: symbol,
        side: side,
        order_type: RedisExchange::ORDER_TYPE_MARKET,
        order_id: order_id,
        user_id: user_id,
        price_limit: final_price_cap,
        quantity: final_quantity,
        timestamp_ms: timestamp_ms
      )
    end

    # Return the ticker hash for a market with integer values.
    # @param symbol [String] market symbol
    # @return [Hash{Symbol=>Integer}] last trade + top-of-book snapshot
    def ticker(symbol)
      raw = @redis.hgetall("ticker:#{symbol}")
      return {} if raw.empty?

      RedisExchange::TICKER_FIELDS.to_h do |field|
        [field.to_sym, raw.fetch(field, '0').to_i]
      end
    end

    # Seed or update market metadata.
    # @param symbol [String] market symbol (e.g., 'BTCUSDT')
    # @param base_asset [String] base asset code (e.g., 'BTC')
    # @param quote_asset [String] quote asset code (e.g., 'USDT')
    # @param price_scale [Integer] price precision scale (price in quote minor units)
    # @param quantity_scale [Integer] quantity precision scale (quantity in base minor units)
    # @param maker_fee_bps [Integer] maker fee in basis points (0..10000)
    # @param taker_fee_bps [Integer] taker fee in basis points (0..10000)
    # @param min_qty [Integer] minimum order quantity in base minor units
    # @param min_notional [Integer] minimum notional in quote minor units
    # @param trades_maxlen [Integer,nil] max trades stream length; nil uses default (1_000_000)
    # @param orders_maxlen [Integer,nil] max orders stream length; nil uses default (1_000_000)
    def seed_market(symbol:, base_asset:, quote_asset:, price_scale: 1, quantity_scale: 1,
                  maker_fee_bps: 0, taker_fee_bps: 0, min_qty: 1, min_notional: 1,
                  status: RedisExchange::MARKET_STATUS_OPEN, trades_maxlen: nil, orders_maxlen: nil)
      key = "market:#{symbol}"
      stat = status.to_s.upcase
      raise ArgumentError, 'invalid market status' unless RedisExchange::MARKET_STATUSES.include?(stat)
      mapping = {
        'base_asset' => base_asset,
        'quote_asset' => quote_asset,
        'price_scale' => price_scale,
        'quantity_scale' => quantity_scale,
        'maker_fee_bps' => maker_fee_bps,
        'taker_fee_bps' => taker_fee_bps,
        'min_qty' => min_qty,
        'min_notional' => min_notional,
        'status' => stat
      }
      mapping['trades_maxlen'] = trades_maxlen.to_i if trades_maxlen
      mapping['orders_maxlen'] = orders_maxlen.to_i if orders_maxlen
      @redis.hset(key, mapping)
    end

    def set_market_status(symbol:, status:)
      key = "market:#{symbol}"
      return { error: 'UNKNOWN_MARKET' } unless @redis.exists?(key)

      stat = status.to_s.upcase
      raise ArgumentError, 'invalid market status' unless RedisExchange::MARKET_STATUSES.include?(stat)

      @redis.hset(key, 'status', stat)
      market_config(symbol)
    end

    # Seed or update an asset's balance scale and status.
    # Balances and ledger entries MUST use this scale; matching converts market deltas into asset units.
    # @param asset [String] asset code (e.g., 'BTC')
    # @param balance_scale [Integer] integer minor unit scale for balances/ledger
    # @param status [String] 'ACTIVE' | 'HALTED'
    def seed_asset(asset:, balance_scale:, status: RedisExchange::ASSET_STATUS_ACTIVE)
      raise ArgumentError, 'balance_scale must be positive' unless balance_scale.to_i > 0
      stat = status.to_s.upcase
      raise ArgumentError, 'invalid status' unless RedisExchange::ASSET_STATUSES.include?(stat)
      key = "asset:#{asset}"
      mapping = {
        'balance_scale' => balance_scale.to_i,
        'status' => stat
      }
      @redis.hset(key, mapping)
    end

    # Read asset configuration.
    # @param asset [String]
    # @return [Hash] { balance_scale: Integer, status: String } or {}
    def asset_config(asset)
      raw = @redis.hgetall("asset:#{asset}")
      return {} if raw.empty?
      {
        balance_scale: raw.fetch('balance_scale', '0').to_i,
        status: raw.fetch('status', RedisExchange::ASSET_STATUS_ACTIVE)
      }
    end

    # Read market configuration.
    # @param symbol [String]
    # @return [Hash] { base_asset:, quote_asset:, price_scale:, quantity_scale:, status: } or {}
    def market_config(symbol)
      raw = @redis.hgetall("market:#{symbol}")
      return {} if raw.empty?
      {
        base_asset: raw.fetch('base_asset', nil),
        quote_asset: raw.fetch('quote_asset', nil),
        price_scale: raw.fetch('price_scale', '1').to_i,
        quantity_scale: raw.fetch('quantity_scale', '1').to_i,
        status: raw.fetch('status', RedisExchange::MARKET_STATUS_OPEN)
      }
    end

    # Validate that asset balance scales are compatible with a market's scales (integer multiples).
    # @return [Hash] { ok: true, base_factor: Integer, quote_factor: Integer } or { ok: false, error: 'ASSET_NOT_CONFIGURED'|'ASSET_SCALE_MISMATCH', asset: String, balance_scale: Integer, market_scale: Integer }
    def validate_asset_scales_for_market(base_asset:, quote_asset:, price_scale:, quantity_scale:)
      base_cfg = asset_config(base_asset)
      quote_cfg = asset_config(quote_asset)
      base_bs = base_cfg[:balance_scale].to_i
      quote_bs = quote_cfg[:balance_scale].to_i
      unless base_bs.positive? && quote_bs.positive?
        missing = !base_bs.positive? ? base_asset : quote_asset
        return { ok: false, error: 'ASSET_NOT_CONFIGURED', asset: missing }
      end
      ps = price_scale.to_i
      qs = quantity_scale.to_i
      base_factor = base_bs / qs
      quote_factor = quote_bs / ps
      unless (base_factor * qs) == base_bs
        return { ok: false, error: 'ASSET_SCALE_MISMATCH', asset: base_asset, balance_scale: base_bs, market_scale: qs }
      end
      unless (quote_factor * ps) == quote_bs
        return { ok: false, error: 'ASSET_SCALE_MISMATCH', asset: quote_asset, balance_scale: quote_bs, market_scale: ps }
      end
      { ok: true, base_factor: base_factor, quote_factor: quote_factor }
    end

    # Overwrite a user's available/reserved buckets for an asset.
    def set_balance(user_id:, asset:, available: 0, reserved: 0)
      key = "balance:#{user_id}"
      mapping = {
        "#{asset}:available" => available,
        "#{asset}:reserved" => reserved
      }
      @redis.hset(key, mapping)
    end

    # Fetch all balance fields for a user as integers keyed by symbols.
    # @param user_id [String]
    # @return [Hash{Symbol=>Integer}]
    # Get all balances for a user.
    # @param user_id [String] user identifier
    # @param auto_scale [Boolean] if true, converts integer balances to human-readable floats
    # @return [Hash{Symbol=>Integer,Float}]
    def balances(user_id, auto_scale: false)
      raw = @redis.hgetall("balance:#{user_id}")
      scales = {} if auto_scale

      raw.each_with_object({}) do |(field, value), result|
        val = value.to_i
        if auto_scale
          asset = field.split(':').first
          scales[asset] ||= (asset_config(asset)[:balance_scale] || 1)
          val = val.to_f / scales[asset]
        end
        result[field.to_sym] = val
      end
    end

    # Get balance for a specific asset.
    # @param user_id [String]
    # @param asset [String]
    # @param auto_scale [Boolean]
    # @return [Hash] { available: Integer|Float, reserved: Integer|Float }
    def balance(user_id:, asset:, auto_scale: false)
      key = "balance:#{user_id}"
      vals = @redis.hmget(key, "#{asset}:available", "#{asset}:reserved")
      available = vals[0].to_i
      reserved = vals[1].to_i

      if auto_scale
        scale = asset_config(asset)[:balance_scale] || 1
        available = available.to_f / scale
        reserved = reserved.to_f / scale
      end

      { available: available, reserved: reserved }
    end

    # Retrieve an order snapshot by id with typed fields.
    # @param order_id [String]
    # @return [Hash] empty hash when not found; otherwise typed fields
    #   Keys:
    #   - :order_id, :user_id, :symbol, :side, :type, :status (String)
    #   - :price, :quantity, :remaining, :created_at, :sequence (Integer)
    def order(order_id)
      raw = @redis.hgetall("order:#{order_id}")
      return {} if raw.empty?

      {
        order_id: raw.fetch('order_id', order_id),
        user_id: raw['user_id'],
        symbol: raw['symbol'],
        side: raw['side'],
        type: raw['type'],
        status: raw['status'],
        price: raw.fetch('price', '0').to_i,
        quantity: raw.fetch('quantity', '0').to_i,
        remaining: raw.fetch('remaining', '0').to_i,
        created_at: raw.fetch('created_at', '0').to_i,
        sequence: raw.fetch('sequence', '0').to_i
      }
    end

    # Cancel a resting order and release any reserved balances.
    # Returns a status hash mirroring Lua responses.
    def cancel_order(order_id)
      # We need symbol to determine seq key.
      # However, cancel_order.lua currently only takes order_key as KEYS[1].
      # To provide seq key as KEYS[2], we need to know the symbol beforehand.
      # But the caller only provides order_id.
      # Option 1: Look up symbol from order hash first (requires extra RTT).
      # Option 2: Change Lua script to accept symbol as ARGV and construct seq key? No, dynamic keys are bad for cluster.
      # But seq key is {seq:{symbol}}, so we need symbol in KEYS for cluster compatibility.
      
      # Let's read the order first to get the symbol.
      # This adds a round trip, but ensures correctness for cluster/key slots.
      symbol = @redis.hget("order:#{order_id}", "symbol")
      
      # If order is not found, the Lua script will handle it gracefully if we just pass a dummy key or handle it here.
      # If we don't find symbol, the order likely doesn't exist.
      return { status: 'NOT_FOUND', order_id: order_id } unless symbol

      payload = { 
        keys: ["order:#{order_id}", "seq:#{symbol}"], 
        argv: [order_id] 
      }
      raw = call_script(@cancel_order_script, payload)
      JSON.parse(raw, symbolize_names: true)
    end

    # Cancel all resting orders for a user across all markets.
    # Implemented in Ruby to avoid Lua script timeouts on large data sets.
    def cancel_all_orders(user_id)
      if maintenance.enabled?
        return { error: 'SYSTEM_MAINTENANCE' }
      end

      results = []
      touched_symbols = Set.new
      cursor = '0'
      loop do
        # 1. Scan user's order indexes
        cursor, keys = @redis.scan(cursor, match: "user_orders:#{user_id}:*", count: 100)
        
        keys.each do |index_key|
          # index_key format: user_orders:{user_id}:{symbol}
          symbol = index_key.split(':').last
          
          # 2. Get all order IDs for this symbol
          order_ids = @redis.zrange(index_key, 0, -1)
          
          order_ids.each do |oid|
            # 3. Cancel each order individually
            # This calls cancel_order.lua which handles status checks, balance release, etc.
            # It returns a Hash with :status, :order_id, :symbol etc. or :error
            res = cancel_order(oid)
            
            # 4. Collect successful cancellations
      if res[:status] == RedisExchange::ORDER_STATUS_CANCELLED
        results << res
        touched_symbols.add(symbol)
      elsif res[:error] == 'MARKET_MAINTENANCE'
        # Capture error but continue processing other orders (which might be in different markets)
        results << { order_id: oid, error: 'MARKET_MAINTENANCE' }
      elsif res[:status] == RedisExchange::ORDER_STATUS_NOT_FOUND || res[:status] == RedisExchange::ORDER_STATUS_UNKNOWN
         # Order might be already gone or finished, clean up index just in case?
         # cancel_order.lua doesn't clean up index if order not found in hash.
               # But if it's not found, we should probably remove it from ZSET to avoid stuck keys.
               # However, standard cancel_order doesn't know about user_id if order hash is gone.
               # Here we know the index_key, so we can clean it.
               @redis.zrem(index_key, oid)
            end
          end
        end
        
        break if cursor == '0'
      end
      
      # 5. Return results
      results
    end

    # Generic atomic balance operation.
    # @param user_id [String]
    # @param asset [String]
    # @param action [String] LOCK, UNLOCK, ADD, SUB, SUB_LOCKED, ADD_LOCKED
    # @param amount [Integer, Float, BigDecimal] positive amount
    # @param reason [String]
    # @param timestamp_ms [Integer,nil]
    # @param biz_id [String,nil]
    # @param auto_scale [Boolean]
    # @return [Hash]
    def operate_balance(user_id:, asset:, action:, amount:, reason: RedisExchange::REASON_MANUAL, timestamp_ms: nil, biz_id: nil, auto_scale: false)
      raise ArgumentError, 'user_id is required' if user_id.nil? || user_id.to_s.empty?
      raise ArgumentError, 'asset is required' if asset.nil? || asset.to_s.empty?
      raise ArgumentError, 'amount must be positive' unless amount.to_f.positive?

      final_amount = if auto_scale
                       scale_asset_amount(asset, amount)
                     else
                       amount.to_i
                     end

      timestamp = timestamp_ms || current_millis
      biz = (biz_id && !biz_id.to_s.empty?) ? biz_id.to_s : SecureRandom.uuid

      payload = {
        keys: ["balance:#{user_id}"],
        argv: [user_id, asset, final_amount.to_s, action, reason, timestamp.to_s, biz]
      }
      raw = call_script(@balance_op_script, payload)
      resp = JSON.parse(raw, symbolize_names: true)
      resp[:biz_id] = biz
      resp
    end

    def lock_funds(user_id:, asset:, amount:, reason: RedisExchange::REASON_LOCK, timestamp_ms: nil, biz_id: nil, auto_scale: false)
      operate_balance(
        user_id: user_id,
        asset: asset,
        action: RedisExchange::ACTION_LOCK,
        amount: amount,
        reason: reason,
        timestamp_ms: timestamp_ms,
        biz_id: biz_id,
        auto_scale: auto_scale
      )
    end

    def unlock_funds(user_id:, asset:, amount:, reason: RedisExchange::REASON_UNLOCK, timestamp_ms: nil, biz_id: nil, auto_scale: false)
      operate_balance(
        user_id: user_id,
        asset: asset,
        action: RedisExchange::ACTION_UNLOCK,
        amount: amount,
        reason: reason,
        timestamp_ms: timestamp_ms,
        biz_id: biz_id,
        auto_scale: auto_scale
      )
    end

    # Deposit funds into user's available balance for an asset.
    # @param user_id [String]
    # @param asset [String]
    # @param amount [Integer, Float, BigDecimal] positive amount
    # @param reason [String] optional reason (defaults to 'DEPOSIT')
    # @param timestamp_ms [Integer,nil]
    # @param biz_id [String,nil]
    # @param auto_scale [Boolean] if true, scales amount using asset's balance_scale
    # @return [Hash]
    def add_funds(user_id:, asset:, amount:, reason: RedisExchange::REASON_DEPOSIT, timestamp_ms: nil, biz_id: nil, auto_scale: false)
      operate_balance(
        user_id: user_id,
        asset: asset,
        action: RedisExchange::ACTION_ADD,
        amount: amount,
        reason: reason,
        timestamp_ms: timestamp_ms,
        biz_id: biz_id,
        auto_scale: auto_scale
      )
    end

    # Withdraw funds from user's available balance for an asset.
    # @param user_id [String]
    # @param asset [String]
    # @param amount [Integer, Float, BigDecimal] positive amount
    # @param reason [String] optional reason (defaults to 'WITHDRAWAL')
    # @param timestamp_ms [Integer,nil]
    # @param biz_id [String,nil]
    # @param auto_scale [Boolean] if true, scales amount using asset's balance_scale
    # @return [Hash]
    def sub_funds(user_id:, asset:, amount:, reason: RedisExchange::REASON_WITHDRAWAL, timestamp_ms: nil, biz_id: nil, auto_scale: false)
      operate_balance(
        user_id: user_id,
        asset: asset,
        action: RedisExchange::ACTION_SUB,
        amount: amount,
        reason: reason,
        timestamp_ms: timestamp_ms,
        biz_id: biz_id,
        auto_scale: auto_scale
      )
    end

    # Withdraw funds from user's reserved (locked) balance for an asset.
    # Useful for manual corrections or external liquidations.
    # @param user_id [String]
    # @param asset [String]
    # @param amount [Integer, Float, BigDecimal] positive amount
    # @param reason [String] optional reason (defaults to 'WITHDRAWAL')
    # @param timestamp_ms [Integer,nil]
    # @param biz_id [String,nil]
    # @param auto_scale [Boolean] if true, scales amount using asset's balance_scale
    # @return [Hash]
    def sub_locked_funds(user_id:, asset:, amount:, reason: RedisExchange::REASON_WITHDRAWAL, timestamp_ms: nil, biz_id: nil, auto_scale: false)
      operate_balance(
        user_id: user_id,
        asset: asset,
        action: RedisExchange::ACTION_SUB_LOCKED,
        amount: amount,
        reason: reason,
        timestamp_ms: timestamp_ms,
        biz_id: biz_id,
        auto_scale: auto_scale
      )
    end

    # 分页查询用户在某交易对的活跃订单（OPEN/PARTIALLY_FILLED 且 remaining>0）。
    # 依赖 Lua 维护的 ZSET 索引：`user_orders:{user_id}:{symbol}`，score 使用撮合序列。
    # @param user_id [String]
    # @param symbol [String]
    # @param page [Integer] 从 1 开始的页码
    # @param per_page [Integer] 每页条数，默认 50
    # @param direction [Symbol] :asc 或 :desc（根据序列顺序）
    # @return [Array<Hash>] 订单快照数组
    def active_orders(user_id:, symbol:, page: 1, per_page: 50, direction: :desc)
      page = page.to_i
      per_page = per_page.to_i
      page = 1 if page <= 0
      per_page = 50 if per_page <= 0

      index_key = "user_orders:#{user_id}:#{symbol}"
      start = (page - 1) * per_page
      stop = start + per_page - 1

      range_method = direction.to_sym == :asc ? :zrange : :zrevrange
      ids = Array(@redis.public_send(range_method, index_key, start, stop))
      return [] if ids.empty?

      ids.map { |id| order(id) }.select { |o| !o.empty? && o[:remaining].positive? && (o[:status] == RedisExchange::ORDER_STATUS_OPEN || o[:status] == RedisExchange::ORDER_STATUS_PARTIALLY_FILLED) }
    end

    # Build a TradeStreamConsumer for a market symbol.
    # Usage: consumer = exchange.trade_consumer(symbol: 'BTCUSDT', group: 'trades-consumers', consumer: 'worker-1')
    def trade_consumer(symbol:, group:, consumer:)
      require_relative 'redis_exchange/trade_stream_consumer'
      c = RedisExchange::TradeStreamConsumer.new(redis: @redis, symbol: symbol, group: group, consumer: consumer)
      c.ensure_group(start_id: '0')
      c
    end

    # Build a DepthStreamConsumer for a market symbol.
    # Usage: consumer = exchange.depth_consumer(symbol: 'BTCUSDT', group: 'depth-consumers', consumer: 'worker-1')
    def depth_consumer(symbol:, group:, consumer:)
      require_relative 'redis_exchange/depth_stream_consumer'
      c = RedisExchange::DepthStreamConsumer.new(redis: @redis, symbol: symbol, group: group, consumer: consumer)
      c.ensure_group(start_id: '$')
      c
    end

    def maintenance
      require_relative 'redis_exchange/maintenance'
      @maintenance ||= RedisExchange::Maintenance.new(@redis)
    end

    # Build an OrderStreamConsumer for a market symbol.
    # Usage: consumer = exchange.order_consumer(symbol: 'BTCUSDT', group: 'orders-consumers', consumer: 'worker-1')
    def order_consumer(symbol:, group:, consumer:)
      require_relative 'redis_exchange/order_stream_consumer'
      c = RedisExchange::OrderStreamConsumer.new(redis: @redis, symbol: symbol, group: group, consumer: consumer)
      c.ensure_group(start_id: '0')
      c
    end

    # Build a LedgerStreamConsumer for account ledger stream.
    # Usage: consumer = exchange.ledger_consumer(group: 'ledger-consumers', consumer: 'worker-1')
    def ledger_consumer(group:, consumer:, stream_key: 'account_ledger')
      require_relative 'redis_exchange/ledger_stream_consumer'
      c = RedisExchange::LedgerStreamConsumer.new(redis: @redis, group: group, consumer: consumer, stream_key: stream_key)
      c.ensure_group(start_id: '0')
      c
    end

    # Remove book, volume, sequence, trades, and ticker keys for tests.
    def clear_books(symbol)
      keys = [
        "book:#{symbol}:#{RedisExchange::SIDE_BUY}",
        "book:#{symbol}:#{RedisExchange::SIDE_SELL}",
        "volume:#{symbol}:#{RedisExchange::SIDE_BUY}",
        "volume:#{symbol}:#{RedisExchange::SIDE_SELL}",
        "seq:#{symbol}",
        "trades:#{symbol}",
        "orders:#{symbol}",
        "depth:#{symbol}",
        "ticker:#{symbol}"
      ]
      @redis.del(*keys)
    end

    # Snapshot the current book depth for both sides.
    # @param limit [Integer,nil] maximum number of price levels per side
    # @return [Hash{Symbol=>Array<Hash{Symbol=>Integer}>}]
    def order_book(symbol, limit: nil)
      limit = limit&.to_i
      {
        bids: fetch_book_side(symbol, RedisExchange::SIDE_BUY, descending: true, limit: limit),
        asks: fetch_book_side(symbol, RedisExchange::SIDE_SELL, descending: false, limit: limit)
      }
    end

    # Merge depth levels by aggregating volumes within price ranges.
    # This method consolidates multiple price levels into aggregated buckets for better visualization.
    # @param symbol [String] market symbol
    # @param side [String] 'BUY' or 'SELL'
    # @param bucket_size [Integer] price bucket size in scaled units for aggregation
    # @param limit [Integer,nil] maximum number of aggregated buckets to return
    # @return [Array<Hash{Symbol=>Integer}>] array of aggregated depth levels
    #   Each hash contains: :price, :volume, :original_levels (count of original levels merged)
    def merge_depth(symbol, side, bucket_size, limit: nil)
      raise ArgumentError, 'side must be BUY or SELL' unless RedisExchange::SIDES.include?(side.to_s.upcase)
      raise ArgumentError, 'bucket_size must be positive' unless bucket_size&.positive?

      side_up = side.to_s.upcase
      bucket_size = bucket_size.to_i
      limit = limit&.to_i

      # Fetch the full book side
      full_depth = fetch_book_side(symbol, side_up, descending: side_up == 'BUY', limit: nil)
      return [] if full_depth.empty?

      # Aggregate price levels into buckets
      merged_buckets = {}
      full_depth.each do |level|
        price = level[:price]
        volume = level[:volume]

        # Calculate bucket index based on price and bucket size
        bucket_index = (price / bucket_size).floor * bucket_size

        # Initialize bucket if not exists
        unless merged_buckets[bucket_index]
          merged_buckets[bucket_index] = {
            price: bucket_index,
            volume: 0,
            original_levels: 0
          }
        end

        # Aggregate volume and count levels
        merged_buckets[bucket_index][:volume] += volume
        merged_buckets[bucket_index][:original_levels] += 1
      end

      # Convert to sorted array
      result = merged_buckets.values
      if side_up == 'BUY'
        # For BUY side, sort by price descending (highest prices first)
        result.sort_by! { |bucket| -bucket[:price] }
      else
        # For SELL side, sort by price ascending (lowest prices first)
        result.sort_by! { |bucket| bucket[:price] }
      end

      # Apply limit if specified
      limit ? result.first(limit) : result
    end

    # Merge depth for both sides with configurable bucket sizes.
    # @param symbol [String] market symbol
    # @param buy_bucket_size [Integer] bucket size for BUY side
    # @param sell_bucket_size [Integer] bucket size for SELL side
    # @param limit [Integer,nil] maximum number of buckets per side
    # @return [Hash{Symbol=>Array<Hash{Symbol=>Integer}>}] merged depth for both sides
    def merge_depth_both_sides(symbol, buy_bucket_size, sell_bucket_size, limit: nil)
      {
        bids: merge_depth(symbol, RedisExchange::SIDE_BUY, buy_bucket_size, limit: limit),
        asks: merge_depth(symbol, RedisExchange::SIDE_SELL, sell_bucket_size, limit: limit)
      }
    end

    private

    def check_market_status(market_config)
      st = market_config[:status].to_s.upcase
      return nil if st == RedisExchange::MARKET_STATUS_OPEN

      case st
      when RedisExchange::MARKET_STATUS_HALTED then { error: 'MARKET_HALTED' }
      when RedisExchange::MARKET_STATUS_MAINTENANCE then { error: 'MARKET_MAINTENANCE' }
      when RedisExchange::MARKET_STATUS_CLOSED then { error: 'MARKET_CLOSED' }
      else { error: 'MARKET_CLOSED' }
      end
    end

    # Internal helper to execute the Lua script with typed arguments.
    def execute_order(symbol:, side:, order_type:, order_id:, user_id:, price_limit:, quantity:, timestamp_ms: nil)
      if maintenance.enabled?
        return { error: 'SYSTEM_MAINTENANCE' }
      end

      # Duplicate order check (Ruby layer optimization)
      if @redis.exists("order:#{order_id}", "order_tombstone:#{order_id}") > 0
        return { error: 'DUPLICATE_ORDER_ID' }
      end

      side_up = side.to_s.upcase
      raise ArgumentError, 'side must be BUY or SELL' unless RedisExchange::SIDES.include?(side_up)

      type_up = order_type.to_s.upcase
      raise ArgumentError, 'order_type must be LIMIT or MARKET' unless RedisExchange::ORDER_TYPES.include?(type_up)

      # Precision pre-check (Ruby layer): both price_limit and quantity are scaled integers.
      # Prevent sending arguments that would overflow Lua's double precision (~9e15).
      pl = price_limit.to_i
      qty = quantity.to_i
      if pl.negative? || qty <= 0
        return { error: 'INVALID_PRICE_OR_QUANTITY' }
      end
      if pl > 0
        # If either operand or the product breaches the bound, abort.
        # allow product equal to bound; overflow only when strictly greater
        if pl >= RedisExchange::MAX_SAFE_INTEGER || qty >= RedisExchange::MAX_SAFE_INTEGER || (pl.to_i * qty.to_i) > RedisExchange::MAX_SAFE_INTEGER
          return { error: 'PRECISION_OVERFLOW', details: "price_limit * quantity: #{pl} * #{qty}" }
        end
      end

      # Market status pre-check: reject orders if market is HALTED or CLOSED
      mc = market_config(symbol)
      return { error: 'UNKNOWN_MARKET' } if mc.empty?

      status_check = check_market_status(mc)
      return status_check if status_check

      # Asset scale compatibility pre-check: ensure asset balance scales are integer multiples
      # of market scales before invoking the Lua matcher. This surfaces friendly errors early.
      scale_check = validate_asset_scales_for_market(
        base_asset: mc[:base_asset],
        quote_asset: mc[:quote_asset],
        price_scale: mc[:price_scale],
        quantity_scale: mc[:quantity_scale]
      )
      unless scale_check[:ok]
        err = { error: scale_check[:error] }
        [:asset, :balance_scale, :market_scale].each do |k|
          v = scale_check[k]
          err[k] = v if v
        end
        return err
      end

      ts = (timestamp_ms || current_millis).to_i
      keys = market_keys(symbol: symbol, user_id: user_id)
      script_payload = {
        keys: [
          keys[:market],
          keys[:sequence],
          keys[:book_buy],
          keys[:book_sell],
          keys[:volume_buy],
          keys[:volume_sell],
          keys[:balance],
          keys[:trades],
          keys[:orders]
        ],
        argv: [
          symbol,
          side_up,
          type_up,
          order_id,
          user_id,
          price_limit.to_s,
          quantity.to_s,
          ts.to_s
        ]
      }

      raw = execute_via_match_script(script_payload)
      JSON.parse(raw, symbolize_names: true)
    end

    # Build all Redis keys touched by the Lua script for a market/user pair.
    def market_keys(symbol:, user_id:)
      {
        market: "market:#{symbol}",
        sequence: "seq:#{symbol}",
        book_buy: "book:#{symbol}:#{RedisExchange::SIDE_BUY}",
        book_sell: "book:#{symbol}:#{RedisExchange::SIDE_SELL}",
        volume_buy: "volume:#{symbol}:#{RedisExchange::SIDE_BUY}",
        volume_sell: "volume:#{symbol}:#{RedisExchange::SIDE_SELL}",
        balance: "balance:#{user_id}",
        trades: "trades:#{symbol}",
        orders: "orders:#{symbol}"
      }
    end

    # Current epoch time in milliseconds.
    def current_millis
      (Time.now.to_f * 1000).floor
    end

    # Simple Lua script wrapper using SCRIPT LOAD + EVALSHA.
    class LuaScript
      def initialize(source)
        @source = source
        @sha = nil
      end

      def call(redis, keys:, argv:)
        @sha ||= redis.script(:load, @source)
        redis.evalsha(@sha, keys: keys, argv: argv)
      rescue ::Redis::CommandError => e
        if e.message =~ /NOSCRIPT/
          @sha = redis.script(:load, @source)
          retry
        else
          raise
        end
      end
    end

    def register_script(lua_source)
      raise ArgumentError, 'missing Lua source' unless lua_source && !lua_source.empty?
      LuaScript.new(lua_source)
    end

    def execute_via_match_script(script_payload)
      call_script(@match_order_script, script_payload)
    end

    def read_script(path)
      return nil unless path && File.exist?(path)

      File.read(path)
    end

    def load_script(filename)
      path = File.expand_path("../redis_scripts/#{filename}", __dir__)
      register_script(read_script(path))
    end

    def call_script(script, payload)
      script.call(@redis, **payload)
    end

    def collect_order_keys
      collect_keys('order:*')
    end

    def collect_queue_keys(symbol, side)
      collect_keys("queue:#{symbol}:#{side}:*")
    end

    def collect_keys(pattern)
      if @redis.respond_to?(:scan)
        cursor = '0'
        keys = []
        loop do
          scan_result = @redis.scan(cursor, match: pattern, count: 200)
          cursor = scan_result[0]
          keys.concat(Array(scan_result[1]))
          break if cursor == '0'
        end
        keys
      elsif @redis.respond_to?(:keys)
        Array(@redis.keys(pattern))
      else
        []
      end
    end

    def fetch_book_side(symbol, side, descending:, limit:)
      if supports_sorted_book?
        return fetch_sorted_book_side(symbol, side, descending: descending, limit: limit)
      end

      queue_keys = collect_queue_keys(symbol, side)
      entries = queue_keys.map do |key|
        price = key.split(':').last
        {
          price: price.to_i,
          volume: @redis.hget("volume:#{symbol}:#{side}", price).to_i
        }
      end
      entries.select! { |row| row[:volume].positive? }
      entries.sort_by! { |row| descending ? -row[:price] : row[:price] }
      limit ? entries.first(limit) : entries
    end

    def supports_sorted_book?
      @redis.respond_to?(:zrange) && @redis.respond_to?(:zrevrange)
    end

    def fetch_sorted_book_side(symbol, side, descending:, limit:)
      book_key = "book:#{symbol}:#{side}"
      volume_key = "volume:#{symbol}:#{side}"

      range_method = descending ? :zrevrange : :zrange
      stop = limit ? limit - 1 : -1
      raw = @redis.public_send(range_method, book_key, 0, stop, with_scores: true)
      pairs = if raw.is_a?(Array) && raw.first.is_a?(Array)
        raw
      else
        Array(raw).each_slice(2).to_a
      end
      list = pairs.map do |member, score|
        price_str = member.to_s
        {
          price: price_str.to_i,
          volume: @redis.hget(volume_key, price_str).to_i,
          score: score.to_f
        }
      end
      list.select! { |row| row[:volume].positive? }
      limit ? list.first(limit) : list
    end
    

    # Fallback-related helpers removed; cancellations handled via Lua scripts.

    private

    # Scale a human-readable asset amount (e.g., 1.5 BTC) into an integer using balance_scale.
    def scale_asset_amount(asset, amount)
      cfg = asset_config(asset)
      scale = cfg[:balance_scale] || 1
      (amount.to_f * scale).floor
    end

    # Scale a human-readable price into an integer using market price_scale.
    def scale_price(symbol, price)
      cfg = market_config(symbol)
      scale = cfg[:price_scale] || 1
      (price.to_f * scale).floor
    end

    # Scale a human-readable quantity into an integer using market quantity_scale.
    def scale_quantity(symbol, quantity)
      cfg = market_config(symbol)
      scale = cfg[:quantity_scale] || 1
      (quantity.to_f * scale).floor
    end

    # Unscale an integer amount into a human-readable float using balance_scale.
    def unscale_asset_amount(asset, integer_amount)
      cfg = asset_config(asset)
      scale = cfg[:balance_scale] || 1
      integer_amount.to_f / scale
    end
  end
end
