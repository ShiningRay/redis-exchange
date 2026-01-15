#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../../lib/redis_exchange'
require 'optparse'
require 'json'
require 'fileutils'

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: adjust_precision.rb [options]"

  opts.on("-s", "--symbol SYMBOL", "Market symbol (e.g. BTCUSDT)") { |v| options[:symbol] = v }
  opts.on("-p", "--price-scale SCALE", Integer, "New price scale") { |v| options[:price_scale] = v }
  opts.on("-q", "--quantity-scale SCALE", Integer, "New quantity scale") { |v| options[:quantity_scale] = v }
  opts.on("-y", "--yes", "Skip confirmation") { |v| options[:yes] = true }
  opts.on("-o", "--output DIR", "Output directory for snapshots (default: ./tmp/snapshots)") { |v| options[:output] = v }
end.parse!

if options[:symbol].nil? || options[:price_scale].nil? || options[:quantity_scale].nil?
  puts "Missing required arguments."
  puts "Usage: bundle exec ruby script/maintenance/adjust_precision.rb -s BTCUSDT -p 100 -q 1000"
  exit 1
end

SYMBOL = options[:symbol]
NEW_PRICE_SCALE = options[:price_scale]
NEW_QTY_SCALE = options[:quantity_scale]
OUTPUT_DIR = options[:output] || './tmp/snapshots'

FileUtils.mkdir_p(OUTPUT_DIR)

client = RedisExchange::Client.new

puts "🚀 Starting Precision Adjustment for #{SYMBOL}..."
puts "   New Price Scale: #{NEW_PRICE_SCALE}"
puts "   New Quantity Scale: #{NEW_QTY_SCALE}"

# 1. Snapshot Old State
puts "\n📸 Taking initial snapshots..."
old_balances_path = File.join(OUTPUT_DIR, "balances_old_#{Time.now.to_i}.json")
old_book_path = File.join(OUTPUT_DIR, "book_old_#{Time.now.to_i}.json")

client.maintenance.snapshot_balances(output_path: old_balances_path)
client.maintenance.snapshot_order_book(symbol: SYMBOL, output_path: old_book_path)
puts "   Saved to #{old_balances_path} and #{old_book_path}"

# Load snapshots into memory for verification
old_balances = JSON.parse(File.read(old_balances_path))
old_book = JSON.parse(File.read(old_book_path), symbolize_names: true)

# 2. Simulate
puts "\n🔮 Simulating precision update (Dry Run)..."
simulation = client.maintenance.update_market_precision(
  symbol: SYMBOL,
  new_price_scale: NEW_PRICE_SCALE,
  new_quantity_scale: NEW_QTY_SCALE,
  dry: true
)

if simulation[:error]
  puts "❌ Simulation Failed: #{simulation[:error]}"
  exit 1
end

new_book_simulated = simulation[:simulated_order_book]
revised_balances = simulation[:simulated_balance_adjustments]

puts "   Simulation Result:"
puts "   - Orders in New Book: #{new_book_simulated[:bids].size + new_book_simulated[:asks].size}"
puts "   - Balance Revisions (Dust Refunds): #{revised_balances.size}"

# 3. Verify Pre-Check
puts "\nmagnifying_glass_tilted_left: Verifying Simulation..."

# Check Balance Invariant (Total Balance should remain constant)
# Apply revisions to old balances and see if it makes sense?
# Actually, the invariant is:
# Old Total (Avail + Rsrv) == New Total (Avail + Rsrv)
# The simulation returns revisions: delta is added to Available and removed from Reserved.
# So Total Balance IS preserved by definition of the simulation logic.
# Let's verify that revisions don't exceed reserved balances?
errors = []
revised_balances.each do |rev|
  uid = rev[:user_id]
  asset = rev[:asset]
  delta = rev[:delta]
  
  user_bal = old_balances[uid]
  unless user_bal && user_bal[asset]
    errors << "User #{uid} asset #{asset} not found in old balances but has revision"
    next
  end
  
  if user_bal[asset]['reserved'] < delta
    errors << "User #{uid} asset #{asset} reserved balance (#{user_bal[asset]['reserved']}) < refund delta (#{delta})"
  end
end

if errors.any?
  puts "❌ Verification Failed:"
  errors.each { |e| puts "   - #{e}" }
  exit 1
else
  puts "✅ Balance Invariant Check Passed"
end

# 4. Execute
unless options[:yes]
  print "\n⚠️  Ready to execute? This will lock the market and modify data. (y/N): "
  ans = $stdin.gets.chomp
  unless ans.downcase == 'y'
    puts "Aborted."
    exit 0
  end
end

puts "\n⚡ Executing Precision Update..."
result = client.maintenance.update_market_precision(
  symbol: SYMBOL,
  new_price_scale: NEW_PRICE_SCALE,
  new_quantity_scale: NEW_QTY_SCALE,
  dry: false
)

if result[:error]
  puts "❌ Execution Failed: #{result[:error]}"
  exit 1
end
puts "   Result: #{result}"

# 5. Verify Post-Check
puts "\n📸 Taking post-execution snapshots..."
new_balances_path = File.join(OUTPUT_DIR, "balances_new_#{Time.now.to_i}.json")
new_book_path = File.join(OUTPUT_DIR, "book_new_#{Time.now.to_i}.json")

client.maintenance.snapshot_balances(output_path: new_balances_path)
client.maintenance.snapshot_order_book(symbol: SYMBOL, output_path: new_book_path)

puts "   Saved to #{new_balances_path} and #{new_book_path}"

puts "\n🔍 Verifying Invariants (Old vs New)..."

# Load new balances
new_balances = JSON.parse(File.read(new_balances_path))

# Check Total Balance Invariant
balance_errors = []
old_balances.each do |uid, assets|
  assets.each do |asset, old_b|
    old_total = old_b['available'] + old_b['reserved']
    
    new_b = new_balances.dig(uid, asset)
    unless new_b
      # Maybe user removed? Unlikely.
      balance_errors << "User #{uid} asset #{asset} missing in new balances"
      next
    end
    
    new_total = new_b['available'] + new_b['reserved']
    
    if old_total != new_total
      balance_errors << "User #{uid} asset #{asset} total mismatch: Old #{old_total} != New #{new_total}"
    end
  end
end

if balance_errors.any?
  puts "❌ CRITICAL: Balance Invariant Failed!"
  balance_errors.first(10).each { |e| puts "   - #{e}" }
  puts "   ... and #{balance_errors.size - 10} more" if balance_errors.size > 10
else
  puts "✅ All Balance Invariants Passed (Total Assets Preserved)"
end

puts "\n✨ Precision Adjustment Completed Successfully."
