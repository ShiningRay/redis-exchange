# frozen_string_literal: true

require 'spec_helper'
require 'csv'
require 'fileutils'
require 'open3'

RSpec.describe 'Export RDB Data Script' do
  let(:redis) { Redis.new(url: ENV['SPEC_REDIS_URL'] || 'redis://127.0.0.1:6379/15') }
  let(:exchange) { RedisExchange::Client.new(redis: redis) }
  let(:script_path) { File.expand_path('../../script/export_rdb_data.sh', __FILE__) }
  let(:dump_file) { File.expand_path('../../tmp/dump.rdb', __FILE__) }
  let(:tmp_dir) { File.expand_path('../../tmp', __FILE__) }

  before do
    redis.flushall
    FileUtils.mkdir_p(tmp_dir)
    # Ensure no leftover files
    Dir.glob("#{tmp_dir}/*.csv").each { |f| File.delete(f) }
    Dir.glob("#{tmp_dir}/*.id").each { |f| File.delete(f) }
  end

  after do
    redis.flushall
    FileUtils.rm_rf(tmp_dir)
  end

  it 'exports balances correctly from RDB' do
    # 1. Prepare Data
    # User 1: 100 USDT available, 50 USDT reserved
    exchange.add_funds(user_id: 'u1', asset: 'USDT', amount: 150_000)
    exchange.lock_funds(user_id: 'u1', asset: 'USDT', amount: 50_000)

    # User 2: 2 BTC available, 0 reserved
    exchange.add_funds(user_id: 'u2', asset: 'BTC', amount: 200_000_000)

    # User 3: Mixed assets
    exchange.add_funds(user_id: 'u3', asset: 'ETH', amount: 5_000_000)
    exchange.add_funds(user_id: 'u3', asset: 'USDT', amount: 1_000)

    # 2. Trigger Redis Save to generate RDB
    # Note: We cannot change CONFIG in some environments. We assume local Redis writes to default location.
    # We will try to find where it wrote the file.
    
    # Configure Redis to use an older RDB version (v9) if possible, but Redis 7 uses v10 by default and cannot be downgraded easily via config.
    # Instead, we will rely on rdbtools supporting v10 or patching the test to skip if rdbtools fails due to version.
    
    redis.save

    # Get Redis config to find where the dump is
    # redis.config returns a Hash in newer redis gems, or array in older ones.
    # The error "no implicit conversion of String into Integer" suggests it might be returning an Array (key, val) or we are accessing it wrong.
    # Let's handle both or check return type.
    config_dir = redis.config('GET', 'dir')
    dir = config_dir.is_a?(Hash) ? config_dir['dir'] : config_dir[1]
    
    config_dbfilename = redis.config('GET', 'dbfilename')
    dbfilename = config_dbfilename.is_a?(Hash) ? config_dbfilename['dbfilename'] : config_dbfilename[1]
    
    actual_dump_path = File.join(dir, dbfilename)

    # Copy to our tmp location for safety/isolation
    FileUtils.cp(actual_dump_path, dump_file)

    # Verify RDB exists
    expect(File.exist?(dump_file)).to be true

    # 3. Run Export Script
    # The script expects to be run from the project root or we need to adjust paths.
    # We'll run it and pass the dump file path.
    # Note: The script outputs files to the CURRENT working directory.
    # We should switch to tmp_dir to run the script so outputs land there.
    
    # Use our built-in rdb-cli
    rdb_cli_path = File.expand_path('../../bin/rdb-cli', __FILE__)
    
    cmd = "cd #{tmp_dir} && RDB_CLI_CMD='#{rdb_cli_path}' #{script_path} dump.rdb"
    stdout_str, stderr_str, status = Open3.capture3(cmd)
    
    unless status.success?
      puts "STDOUT:\n#{stdout_str}"
      puts "STDERR:\n#{stderr_str}"
    end

    expect(status.success?).to be(true), "Script failed: #{stderr_str}"

    # 4. Verify Snapshot ID
    # The script renames balances.csv to balances_<SNAPSHOT_ID>.csv
    # We scan for the file.
    
    # Debug: Check directory content
    puts "Tmp dir content: #{Dir.entries(tmp_dir)}"
    
    generated_files = Dir.glob(File.join(tmp_dir, "balances_*.csv"))
    expect(generated_files).not_to be_empty
    
    balances_csv_path = generated_files.first
    filename_suffix = File.basename(balances_csv_path).scan(/balances_(.*).csv/).flatten.first
    
    expect(filename_suffix).not_to be_nil
    
    # Expect format: ID_TIMESTAMP (e.g., "1695649068107-0_1695649068107")
    expect(filename_suffix).to match(/^\d+-\d+_\d+$/)


    # Debug: Print CSV content
    puts "CSV Content:"
    puts File.read(balances_csv_path)

    # 5. Verify CSV Content vs Redis Data
    csv_data = CSV.read(balances_csv_path, headers: true)
    
    # Helper to find row
    find_row = ->(user, asset) {
      csv_data.find { |row| row['user_id'] == user && row['asset'] == asset }
    }

    # Verify u1 USDT
    u1_usdt = find_row.call('u1', 'USDT')
    expect(u1_usdt).not_to be_nil
    expect(u1_usdt['available']).to eq('100000')
    expect(u1_usdt['reserved']).to eq('50000')

    # Verify u2 BTC
    u2_btc = find_row.call('u2', 'BTC')
    expect(u2_btc).not_to be_nil
    expect(u2_btc['available']).to eq('200000000')
    expect(u2_btc['reserved']).to eq('0') # Script defaults missing to 0

    # Verify u3 ETH
    u3_eth = find_row.call('u3', 'ETH')
    expect(u3_eth).not_to be_nil
    expect(u3_eth['available']).to eq('5000000')
    expect(u3_eth['reserved']).to eq('0')

    # Verify u3 USDT
    u3_usdt = find_row.call('u3', 'USDT')
    expect(u3_usdt).not_to be_nil
    expect(u3_usdt['available']).to eq('1000')
    expect(u3_usdt['reserved']).to eq('0')

    # Total rows check (u1:1, u2:1, u3:2 = 4 rows)
    expect(csv_data.count).to eq(4)
  end
end
