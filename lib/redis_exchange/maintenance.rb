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
    end

    # Update market precision and revise all active orders using batched processing.
    # Handles market status changes to ensure safety.
    # @param symbol [String]
    # @param new_price_scale [Integer]
    # @param new_quantity_scale [Integer]
    # @param batch_size [Integer] number of price levels to process per batch
    # @return [Hash] { updated_orders: Integer, status: 'OK' } or { error: String }
    def update_market_precision(symbol:, new_price_scale:, new_quantity_scale:, batch_size: 20)
      # 1. Ensure Market is NOT OPEN (Use MAINTENANCE mode)
      initial_status = @redis.hget("market:#{symbol}", 'status')
      return { error: 'UNKNOWN_MARKET' } unless initial_status

      if initial_status == 'OPEN'
        enable_market(symbol) # Sets status to MAINTENANCE
      end

      updated_count = 0
      
      begin
        # 2. Process BUY and SELL sides
        ['BUY', 'SELL'].each do |side|
          book_key = "book:#{symbol}:#{side}"
          price_members = @redis.zrange(book_key, 0, -1)
          
          price_members.each_slice(batch_size) do |batch|
            res = run_migrate_batch(symbol, side, new_price_scale, new_quantity_scale, batch)
            if res[:error]
              # Restore status and raise/return error
              disable_market(symbol) if initial_status == 'OPEN'
              return res
            end
            updated_count += res[:processed_orders].to_i
          end
        end

        # 3. Finalize and switch
        finalize_res = run_finalize_precision(symbol, new_price_scale, new_quantity_scale)
        if finalize_res[:error]
          disable_market(symbol) if initial_status == 'OPEN'
          return finalize_res
        end
        
      ensure
        # 4. Restore Status (if it was OPEN originally and we didn't crash)
        if initial_status == 'OPEN'
          current_status = @redis.hget("market:#{symbol}", 'status')
          if current_status == 'MAINTENANCE'
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
    # @return [Hash,String] returns Hash if output_path is nil; otherwise returns output_path
    def snapshot_balances(output_path: nil)
      enable
      
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
                  output.write(',') unless first_entry
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
        disable
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
  end
end
