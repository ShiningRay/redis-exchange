namespace :audit do
  desc "Audit and reconcile user balances against active orders"
  task balances: :environment do
    require 'redis_exchange'
    
    # Configuration from environment variables
    redis_url = ENV['REDIS_URL']
    user_id = ENV['USER_ID'] # Optional: audit specific user
    fix_mode = ENV['FIX'] != 'false' # Default true, set FIX=false for dry-run
    
    puts "Starting balance audit..."
    puts "Target: #{user_id ? "User #{user_id}" : "All Users"}"
    puts "Mode: #{fix_mode ? "Fix & Report" : "Report Only"}"
    puts "Redis: #{redis_url || 'Default'}"
    puts "-" * 40
    
    exchange = RedisExchange::Client.new(redis: (redis_url ? Redis.new(url: redis_url) : nil))
    
    begin
      reports = exchange.maintenance.audit_user_balances(user_id: user_id, fix: fix_mode)
      
      if reports.empty?
        puts "✅ No discrepancies found."
      else
        puts "⚠️  Found #{reports.size} user(s) with discrepancies:"
        
        reports.each do |r|
          puts "\nUser: #{r[:user_id]}"
          
          unless r[:deficits].empty?
            puts "  Deficits (Insufficient Funds):"
            r[:deficits].each do |d|
              puts "    - #{d[:asset]}: #{d[:amount]} (Missing)"
            end
          end
          
          unless r[:fixes].empty?
            puts "  Adjustments #{fix_mode ? 'Applied' : 'Proposed'}:"
            r[:fixes].each do |f|
              action_icon = f[:action] == 'LOCK' ? '🔒' : '🔓'
              puts "    #{action_icon} #{f[:action]} #{f[:asset]}: #{f[:amount]}"
            end
          end
        end
      end
    rescue StandardError => e
      puts "❌ Error during audit: #{e.message}"
      puts e.backtrace.join("\n")
      exit 1
    end
    
    puts "-" * 40
    puts "Audit completed."
  end
end

# Simple shim to allow :environment prerequisite if running in Rails context,
# or ignore it if running standalone.
task :environment do
end
