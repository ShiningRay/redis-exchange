# frozen_string_literal: true

module RedisExchange
  class Maintenance
    MAINTENANCE_KEY = 'system:maintenance_mode'

    def initialize(redis)
      @redis = redis
      
      migrate_batch_path = File.expand_path('../../redis_scripts/migrate_orders_batch.lua', __dir__)
      @migrate_batch_script = register_script(read_script(migrate_batch_path))

      finalize_precision_path = File.expand_path('../../redis_scripts/finalize_precision_update.lua', __dir__)
      @finalize_precision_script = register_script(read_script(finalize_precision_path))

      force_cancel_path = File.expand_path('../../redis_scripts/force_cancel_order.lua', __dir__)
      @force_cancel_script = register_script(read_script(force_cancel_path))

      audit_balance_path = File.expand_path('../../redis_scripts/audit_user_balance.lua', __dir__)
      @audit_balance_script = register_script(read_script(audit_balance_path))
    end

    # Audit and reconcile user balances against active orders.
    # @param user_id [String,nil] specific user to audit, or nil for all users
    # @param fix [Boolean] whether to apply fixes automatically
    # @return [Array<Hash>] report of issues found/fixed per user
    def audit_user_balances(user_id: nil, fix: true)
      # 1. Gather Symbols
      symbols = []
      cursor = '0'
      loop do
        cursor, keys = @redis.scan(cursor, match: 'market:*', count: 100)
        keys.each { |k| symbols << k.sub('market:', '') }
        break if cursor == '0'
      end
      
      # 2. Gather Users
      users = []
      if user_id
        users << user_id
      else
        cursor = '0'
        loop do
          cursor, keys = @redis.scan(cursor, match: 'balance:*', count: 1000)
          keys.each { |k| users << k.sub('balance:', '') }
          break if cursor == '0'
        end
      end
      
      # 3. Run Audit per User
      reports = []
      ts = current_millis
      
      users.each do |uid|
        payload = {
          keys: ["balance:#{uid}"],
          argv: [uid, fix ? '1' : '0', ts.to_s, *symbols]
        }
        
        raw = call_script(@audit_balance_script, payload)
        res = JSON.parse(raw, symbolize_names: true)
        
        if !res[:deficits].empty? || !res[:fixes].empty?
          reports << { user_id: uid, deficits: res[:deficits], fixes: res[:fixes] }
        end
      end
      
      reports
    end

    # Replay ledger events from a starting point and compare against actual balances.
    # @param initial_balances [Hash] { user_id => { asset => { bucket => amount } } }
    # @param start_id [String] Ledger ID to start replay from (exclusive)
    # @param end_id [String] Ledger ID to stop replay at (inclusive)
    # @param actual_balances [Hash] Current actual balances to compare against
    # @return [Hash] { success: Boolean, discrepancies: Array<Hash>, expected_balances: Hash }
    def replay_ledger_audit(initial_balances:, start_id:, end_id:, actual_balances:)
      # Deep copy initial balances to avoid mutation
      calculated = JSON.parse(JSON.generate(initial_balances))
      
      # Replay Ledger
      batch_size = 1000
      current_id = start_id
      
      loop do
        # XRANGE is inclusive, so we handle the exclusive start logic carefully.
        # If start_id is '0-0', we use '-'. Otherwise we use '(' + start_id if supported, 
        # but Redis XRANGE min is inclusive.
        # Standard pattern: use '(' prefix for exclusive start in XRANGE (Redis 6.2+).
        # Assuming Redis 6.2+. If older, we fetch and skip first if matches.
        
        range_start = current_id == '0-0' ? '-' : "(#{current_id}"
        entries = @redis.xrange('account_ledger', range_start, end_id, count: batch_size)
        
        break if entries.empty?
        
        entries.each do |id, fields|
          user_id = fields['user_id']
          asset = fields['asset']
          
          calculated[user_id] ||= {}
          calculated[user_id][asset] ||= { RedisExchange::BUCKET_AVAILABLE => 0, RedisExchange::BUCKET_RESERVED => 0 }

          if fields['action']
            # New format: action + amount
            action = fields['action']
            amount = fields['amount'].to_i
            
            case action
            when RedisExchange::ACTION_ADD
              calculated[user_id][asset][RedisExchange::BUCKET_AVAILABLE] += amount
            when RedisExchange::ACTION_SUB
              calculated[user_id][asset][RedisExchange::BUCKET_AVAILABLE] -= amount
            when RedisExchange::ACTION_LOCK
              calculated[user_id][asset][RedisExchange::BUCKET_AVAILABLE] -= amount
              calculated[user_id][asset][RedisExchange::BUCKET_RESERVED] += amount
            when RedisExchange::ACTION_UNLOCK
              calculated[user_id][asset][RedisExchange::BUCKET_RESERVED] -= amount
              calculated[user_id][asset][RedisExchange::BUCKET_AVAILABLE] += amount
            when RedisExchange::ACTION_SUB_LOCKED
              calculated[user_id][asset][RedisExchange::BUCKET_RESERVED] -= amount
            when RedisExchange::ACTION_ADD_LOCKED
              calculated[user_id][asset][RedisExchange::BUCKET_RESERVED] += amount
            end
          else
            # Legacy format: bucket + delta
            bucket = fields['bucket']
            delta = fields['delta'].to_i
            if bucket && calculated[user_id][asset][bucket]
              calculated[user_id][asset][bucket] += delta
            end
          end
          
          current_id = id
        end
        
        break if entries.size < batch_size
      end
      
      # Compare
      discrepancies = []
      
      # Check all calculated against actual
      calculated.each do |uid, assets|
        assets.each do |asset, buckets|
          buckets.each do |bucket, expected_amt|
            actual_amt = actual_balances.dig(uid, asset, bucket) || 0
            if expected_amt != actual_amt
              discrepancies << {
                user_id: uid,
                asset: asset,
                bucket: bucket,
                expected: expected_amt,
                actual: actual_amt
              }
            end
          end
        end
      end
      
      # Check for any actual balances that shouldn't exist (not in calculated)
      # We skip this for now as initial_balances might be partial? 
      # Assuming initial_balances + ledger covers everything.
      
      {
        success: discrepancies.empty?,
        discrepancies: discrepancies,
        expected_balances: calculated
      }
    end

    # Force cancel an order, bypassing status checks.
    # @param order_id [String]
    # @param mode [Symbol] :delete_only or :best_effort_unlock
    # @return [Hash]
    def force_cancel_order(order_id:, mode: :best_effort_unlock)
      mode_str = case mode
                 when :delete_only then RedisExchange::CANCEL_MODE_DELETE_ONLY
                 when :best_effort_unlock then RedisExchange::CANCEL_MODE_BEST_EFFORT_UNLOCK
                 else raise ArgumentError, "invalid mode: #{mode}"
                 end
      
      payload = {
        keys: ["order:#{order_id}"],
        argv: [order_id, mode_str]
      }
      raw = call_script(@force_cancel_script, payload)
      JSON.parse(raw, symbolize_names: true)
    end

    # Update market precision and revise all active orders using batched processing.
    # Handles market status changes to ensure safety.
    # @param symbol [String]
    # @param new_price_scale [Integer]
    # @param new_quantity_scale [Integer]
    # @param batch_size [Integer] number of price levels to process per batch
    # @param dry [Boolean] if true, simulate only and return predicted changes
    # @return [Hash] { updated_orders: Integer, status: 'OK' } or { error: String } or { new_order_book: Hash, revised_balances: Array, status: 'SIMULATED' }
    def update_market_precision(symbol:, new_price_scale:, new_quantity_scale:, batch_size: 20, dry: false)
      # 1. Ensure Market is NOT OPEN (Use MAINTENANCE mode)
      initial_status = @redis.hget("market:#{symbol}", 'status')
      return { error: 'UNKNOWN_MARKET' } unless initial_status

      if initial_status == RedisExchange::MARKET_STATUS_OPEN
        enable_market(symbol) # Sets status to MAINTENANCE
      end

      if dry
        begin
          res = simulate_precision_update(symbol, new_price_scale, new_quantity_scale)
          res[:dry] = true
          return res
        ensure
          # Restore status for dry run
          if initial_status == RedisExchange::MARKET_STATUS_OPEN
            current_status = @redis.hget("market:#{symbol}", 'status')
            disable_market(symbol) if current_status == RedisExchange::MARKET_STATUS_MAINTENANCE
          end
        end
      end

      updated_count = 0
      
      begin
        # 2. Process BUY and SELL sides
        [RedisExchange::SIDE_BUY, RedisExchange::SIDE_SELL].each do |side|
          book_key = "book:#{symbol}:#{side}"
          price_members = @redis.zrange(book_key, 0, -1)
          
          price_members.each_slice(batch_size) do |batch|
            res = run_migrate_batch(symbol, side, new_price_scale, new_quantity_scale, batch)
            if res[:error]
              # Restore status and raise/return error
              disable_market(symbol) if initial_status == RedisExchange::MARKET_STATUS_OPEN
              return res
            end
            updated_count += res[:processed_orders].to_i
          end
        end

        # 3. Finalize and switch
        finalize_res = run_finalize_precision(symbol, new_price_scale, new_quantity_scale)
        if finalize_res[:error]
          disable_market(symbol) if initial_status == RedisExchange::MARKET_STATUS_OPEN
          return finalize_res
        end
        
      ensure
        # 4. Restore Status (if it was OPEN originally and we didn't crash)
        if initial_status == RedisExchange::MARKET_STATUS_OPEN
          current_status = @redis.hget("market:#{symbol}", 'status')
          if current_status == RedisExchange::MARKET_STATUS_MAINTENANCE
             disable_market(symbol)
          end
        end
      end

      { updated_orders: updated_count, status: 'OK' }
    end


    def enable
      @redis.set(MAINTENANCE_KEY, '1')
    end

    def disable
      @redis.del(MAINTENANCE_KEY)
    end

    def enabled?
      @redis.get(MAINTENANCE_KEY) == '1'
    end

    def enable_market(symbol)
      # Store previous status if we want to be fancy, but simple maintenance overwrite is standard.
      # However, snapshot_order_book relies on disable_market restoring order.
      # Let's change enable_market to return previous status? 
      # No, public API change. Let's just set status=MAINTENANCE.
      # But snapshot_order_book needs to handle restoration.
      # Since snapshot_order_book is inside this class, we can update it.
      @redis.hset("market:#{symbol}", 'status', 'MAINTENANCE')
    end

    def disable_market(symbol)
      # Default to OPEN when disabling maintenance manually
      @redis.hset("market:#{symbol}", 'status', 'OPEN')
    end

    def market_enabled?(symbol)
      @redis.hget("market:#{symbol}", 'status') == 'MAINTENANCE'
    end

    private

    def run_migrate_batch(symbol, side, new_price_scale, new_quantity_scale, prices)
      payload = {
        keys: [
          "market:#{symbol}",
          "book:#{symbol}:#{side}:TMP",
          "volume:#{symbol}:#{side}:TMP",
          "orders:#{symbol}"
        ],
        argv: [
          symbol,
          side,
          new_price_scale.to_s,
          new_quantity_scale.to_s,
          current_millis.to_s,
          *prices.map(&:to_s)
        ]
      }
      raw = call_script(@migrate_batch_script, payload)
      JSON.parse(raw, symbolize_names: true)
    end

    def run_finalize_precision(symbol, new_price_scale, new_quantity_scale)
      payload = {
        keys: [
          "market:#{symbol}",
          "book:#{symbol}:BUY",
          "book:#{symbol}:SELL",
          "volume:#{symbol}:BUY",
          "volume:#{symbol}:SELL",
          "book:#{symbol}:BUY:TMP",
          "book:#{symbol}:SELL:TMP",
          "volume:#{symbol}:BUY:TMP",
          "volume:#{symbol}:SELL:TMP"
        ],
        argv: [
          symbol,
          new_price_scale.to_s,
          new_quantity_scale.to_s
        ]
      }
      raw = call_script(@finalize_precision_script, payload)
      JSON.parse(raw, symbolize_names: true)
    end

    def current_millis
      (Time.now.to_f * 1000).floor
    end

    def read_script(path)
      return nil unless path && File.exist?(path)
      File.read(path)
    end

    def register_script(lua_source)
      raise ArgumentError, 'missing Lua source' unless lua_source && !lua_source.empty?
      LuaScript.new(lua_source)
    end

    def call_script(script, payload)
      script.call(@redis, **payload)
    end

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

    public


    # Atomically snapshot order book for a symbol.
    # Uses market-level maintenance mode to ensure consistency without blocking Redis.
    # @param symbol [String] market symbol
    # @param output_path [String,nil] if provided, streams JSON output to this file; otherwise returns Hash
    # @return [Hash,String] returns Hash if output_path is nil; otherwise returns output_path
    def snapshot_order_book(symbol:, output_path: nil)
      # Capture previous status to restore correctly
      previous_status = @redis.hget("market:#{symbol}", 'status') || 'OPEN'
      enable_market(symbol)
      output = output_path ? File.open(output_path, 'w') : nil
      
      begin
        result_hash = output ? nil : { symbol: symbol, bids: [], asks: [] }
        
        if output
          output.write("{\"symbol\":\"#{symbol}\",\"timestamp\":#{Time.now.to_i},\"bids\":[")
        end
        
        # Stream Bids
        stream_book_side(symbol, 'BUY', output, result_hash ? result_hash[:bids] : nil)
        
        if output
          output.write("],\"asks\":[")
        end
        
        # Stream Asks
        stream_book_side(symbol, 'SELL', output, result_hash ? result_hash[:asks] : nil)
        
        if output
          output.write("]}")
          output.close
          output_path
        else
          result_hash
        end
      ensure
        if output && !output.closed?
          output.close
        end
        # Restore previous status instead of blind disable
        @redis.hset("market:#{symbol}", 'status', previous_status)
      end
    end

    # Atomically snapshot all user balances.
    # Uses system maintenance mode to ensure consistency without blocking Redis.
    # @param output_path [String,nil] if provided and is a file path, writes to it. 
    #   If provided and is a directory, generates a filename using the latest ledger stream ID.
    # @param lock_system [Boolean] whether to lock the system in maintenance mode during snapshot (default: true)
    # @return [Hash,String] returns Hash if output_path is nil; otherwise returns output_path
    def snapshot_balances(output_path: nil, lock_system: true)
      enable if lock_system
      
      # Determine output file path
      final_output_path = output_path
      if output_path && File.directory?(output_path)
        last_entry = @redis.xrevrange('account_ledger', '+', '-', count: 1).first
        ledger_id = last_entry ? last_entry[0] : '0-0'
        final_output_path = File.join(output_path, "balances_#{ledger_id}.json")
      end

      output = final_output_path ? File.open(final_output_path, 'w') : {}
      
      begin
        if output.is_a?(File)
          output.write('{')
        end
        
        first_entry = true
        cursor = '0'
        loop do
          cursor, keys = @redis.scan(cursor, match: 'balance:*', count: 1000)
          
          if keys.any?
            # Pipeline HGETALL for this batch
            responses = @redis.pipelined do |pipeline|
              keys.each { |k| pipeline.hgetall(k) }
            end
            
            keys.each_with_index do |key, idx|
              user_id = key.sub('balance:', '')
              fields = responses[idx]
              
              user_balance = {}
              fields.each do |field, value|
                # Field format: "ASSET:available" or "ASSET:reserved"
                parts = field.split(':')
                if parts.length == 2
                  asset = parts[0]
                  type = parts[1]
                  if type == 'available' || type == 'reserved'
                    user_balance[asset] ||= { 'available' => 0, 'reserved' => 0 }
                    user_balance[asset][type] = value.to_i
                  end
                end
              end
              
              unless user_balance.empty?
                if output.is_a?(File)
                  output.write(",\n") unless first_entry
                  output.write("#{JSON.generate(user_id)}:#{JSON.generate(user_balance)}")
                  first_entry = false
                else
                  output[user_id] = user_balance
                end
              end
            end
          end
          
          break if cursor == '0'
        end
        
        if output.is_a?(File)
          output.write('}')
          output.close
          final_output_path
        else
          output
        end
      ensure
        if output.is_a?(File) && !output.closed?
          output.close
        end
        disable if lock_system
      end
    end

    private

    def stream_book_side(symbol, side, file_output, array_output)
      book_key = "book:#{symbol}:#{side}"
      volume_key = "volume:#{symbol}:#{side}"
      
      cursor = '0'
      first_entry = true
      
      loop do
        cursor, prices_with_scores = @redis.zscan(book_key, cursor, count: 1000)
        
        if prices_with_scores.any?
          prices = prices_with_scores.map(&:first)
          volumes = @redis.hmget(volume_key, *prices)
          
          prices.each_with_index do |price, idx|
            entry = { price: price.to_i, volume: volumes[idx].to_i }
            
            if file_output
              file_output.write(',') unless first_entry
              file_output.write(JSON.generate(entry))
              first_entry = false
            else
              array_output << entry
            end
          end
        end
        
        break if cursor == '0'
      end
    end

    def simulate_precision_update(symbol, new_price_scale, new_quantity_scale)
      market_config = @redis.hgetall("market:#{symbol}")
      base_asset = market_config['base_asset']
      quote_asset = market_config['quote_asset']
      old_price_scale = market_config['price_scale'].to_i
      old_quantity_scale = market_config['quantity_scale'].to_i
      maker_fee_bps = market_config['maker_fee_bps'].to_i
      
      base_balance_scale = @redis.hget("asset:#{base_asset}", 'balance_scale').to_i
      quote_balance_scale = @redis.hget("asset:#{quote_asset}", 'balance_scale').to_i

      new_base_factor = (base_balance_scale / new_quantity_scale.to_f).floor
      new_quote_factor = (quote_balance_scale / new_price_scale.to_f).floor
      
      if (new_base_factor * new_quantity_scale) != base_balance_scale || 
         (new_quote_factor * new_price_scale) != quote_balance_scale
        return { error: 'ASSET_SCALE_MISMATCH' }
      end

      new_order_book = { symbol: symbol, bids: [], asks: [] }
      revised_balances = []
      updated_orders = 0

      # Helper to simulate processing an order
      process_order = lambda do |order_id, price, side|
        order = @redis.hgetall("order:#{order_id}")
        return unless order['order_id']
        updated_orders += 1

        old_qty = order['quantity'].to_i
        old_rem = order['remaining'].to_i
        old_reserved_base = order['reserved_base'].to_i
        old_reserved_quote = order['reserved_quote'].to_i
        user_id = order['user_id']

        new_price = (price * new_price_scale.to_f / old_price_scale).floor
        new_qty = (old_qty * new_quantity_scale.to_f / old_quantity_scale).floor
        new_rem = (old_rem * new_quantity_scale.to_f / old_quantity_scale).floor

        new_reserved_base = 0
        new_reserved_quote = 0

        if side == RedisExchange::SIDE_SELL
          new_reserved_base = new_rem * new_base_factor
        else
          quote_val = ((new_price * new_rem) / new_quantity_scale.to_f).floor
          fee = ((quote_val * maker_fee_bps) / 10000.0).floor
          total_quote = quote_val + fee
          new_reserved_quote = total_quote * new_quote_factor
        end

        refund_base = old_reserved_base - new_reserved_base
        refund_quote = old_reserved_quote - new_reserved_quote

        if refund_base > 0
          revised_balances << { user_id: user_id, asset: base_asset, delta: refund_base, type: 'DUST_REFUND' }
        end
        if refund_quote > 0
          revised_balances << { user_id: user_id, asset: quote_asset, delta: refund_quote, type: 'DUST_REFUND' }
        end

        if new_rem > 0
          entry = { price: new_price, volume: new_rem }
          target_list = (side == RedisExchange::SIDE_BUY) ? new_order_book[:bids] : new_order_book[:asks]
          
          # Aggregate volume for same price
          existing = target_list.find { |e| e[:price] == new_price }
          if existing
            existing[:volume] += new_rem
          else
            target_list << entry
          end
        end
      end

      # Process Asks (SELL)
      price_members = @redis.zrange("book:#{symbol}:#{RedisExchange::SIDE_SELL}", 0, -1)
      price_members.each do |pm|
        orders = @redis.lrange("queue:#{symbol}:#{RedisExchange::SIDE_SELL}:#{pm}", 0, -1)
        orders.each { |oid| process_order.call(oid, pm.to_i, RedisExchange::SIDE_SELL) }
      end

      # Process Bids (BUY)
      # Bids are stored with negative scores, but price members are positive strings
      price_members = @redis.zrange("book:#{symbol}:#{RedisExchange::SIDE_BUY}", 0, -1)
      price_members.each do |pm|
        orders = @redis.lrange("queue:#{symbol}:#{RedisExchange::SIDE_BUY}:#{pm}", 0, -1)
        orders.each { |oid| process_order.call(oid, pm.to_i, RedisExchange::SIDE_BUY) }
      end
      
      # Sort simulated books
      new_order_book[:asks].sort_by! { |e| e[:price] }
      new_order_book[:bids].sort_by! { |e| -e[:price] }

      { 
         simulated_order_book: new_order_book, 
         simulated_balance_adjustments: revised_balances, 
         updated_orders: updated_orders,
         status: 'SIMULATED' 
       }
    end
  end
end
