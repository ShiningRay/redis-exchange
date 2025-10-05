# frozen_string_literal: true

require 'json'

module RedisExchange
  # Minimal in-memory Redis replacement supporting the subset of commands
  # required by the specs. Stores string values and mimics basic Redis
  # semantics so the client can operate without the fakeredis gem.
  class InMemoryRedis
    def initialize
      @data = {}
    end

    def flushdb
      @data.clear
    end

    def del(*keys)
      keys.each { |key| @data.delete(key) }
      keys.length
    end

    def set(key, value)
      @data[key] = { type: :string, value: value.to_s }
      'OK'
    end

    def get(key)
      entry = @data[key]
      entry && entry[:value]
    end

    def incr(key)
      entry = @data[key] ||= { type: :string, value: '0' }
      entry[:type] = :string
      entry[:value] = (entry[:value].to_i + 1).to_s
      entry[:value].to_i
    end

    def hset(key, hash_or_field, value = nil)
      store = ensure_hash(key)
      if hash_or_field.is_a?(Hash)
        hash_or_field.each do |field, val|
          store[field.to_s] = val.to_s
        end
      else
        store[hash_or_field.to_s] = value.to_s
      end
      store.size
    end

    def hget(key, field)
      hash_store = hash_value(key)
      hash_store && hash_store[field.to_s]
    end

    def hgetall(key)
      hash_value(key)&.dup || {}
    end

    def hincrby(key, field, delta)
      store = ensure_hash(key)
      current = store[field.to_s].to_i
      store[field.to_s] = (current + delta).to_s
      store[field.to_s].to_i
    end

    def hdel(key, *fields)
      store = hash_value(key)
      return 0 unless store

      removed = 0
      fields.flatten.each do |field|
        removed += 1 if store.delete(field.to_s)
      end
      removed
    end

    def lrange(key, start, stop)
      list = list_value(key)
      return [] unless list

      normalized_start = normalize_index(start, list.length)
      normalized_stop = normalize_index(stop, list.length)
      return [] if normalized_start > normalized_stop

      list[normalized_start..normalized_stop] || []
    end

    def rpush(key, value)
      list = ensure_list(key)
      list << value
      list.length
    end

    def lpush(key, value)
      list = ensure_list(key)
      list.unshift(value)
      list.length
    end

    def lpop(key)
      list = list_value(key)
      return nil unless list

      list.shift
    end

    def lrem(key, count, value)
      list = list_value(key)
      return 0 unless list

      removed = 0
      if count.zero?
        list.delete_if do |item|
          if item == value
            removed += 1
            true
          else
            false
          end
        end
      elsif count.positive?
        list.each_index do |idx|
          break if removed >= count
          next unless list[idx] == value

          list[idx] = nil
          removed += 1
        end
        list.compact!
      else # count negative removes from tail
        reverse = list.reverse
        reverse.each_index do |idx|
          break if removed >= count.abs
          next unless reverse[idx] == value

          reverse[idx] = nil
          removed += 1
        end
        list.replace(reverse.reverse.compact)
      end

      removed
    end

    def llen(key)
      list_value(key)&.length.to_i
    end

    def keys(pattern = '*')
      regex = glob_to_regex(pattern)
      @data.keys.select { |key| regex.match?(key) }
    end

    def register_script(_source)
      MatchingScript.new(self)
    end

    private

    def ensure_hash(key)
      entry = @data[key]
      if entry && entry[:type] != :hash
        raise TypeError, "Key #{key} is not a hash"
      end
      entry ||= { type: :hash, value: {} }
      @data[key] = entry
      entry[:value]
    end

    def hash_value(key)
      entry = @data[key]
      entry && entry[:type] == :hash ? entry[:value] : nil
    end

    def ensure_list(key)
      entry = @data[key]
      if entry && entry[:type] != :list
        raise TypeError, "Key #{key} is not a list"
      end
      entry ||= { type: :list, value: [] }
      @data[key] = entry
      entry[:value]
    end

    def list_value(key)
      entry = @data[key]
      entry && entry[:type] == :list ? entry[:value] : nil
    end

    def normalize_index(index, length)
      return length + index if index.negative?

      index
    end

    def glob_to_regex(pattern)
      escaped = pattern.chars.map do |char|
        case char
        when '*'
          '.*'
        when '?'
          '.'
        when '.'
          '\\.'
        else
          Regexp.escape(char)
        end
      end.join
      Regexp.new("^#{escaped}$")
    end

    # Script wrapper used by the client when fakeredis is unavailable.
    class MatchingScript
      def initialize(redis)
        @redis = redis
      end

      def call(keys:, argv:)
        engine = MatchingEngine.new(@redis)
        JSON.generate(engine.process_keys_and_args(keys: keys, argv: argv))
      end
    end
  end
end
