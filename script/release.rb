#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'io/console'

VERSION_FILE = 'lib/redis_exchange/version.rb'

def run_command(cmd)
  puts "=> Running: #{cmd}"
  system(cmd, exception: true)
end

def current_branch
  `git rev-parse --abbrev-ref HEAD`.strip
end

def git_clean?
  `git status --porcelain`.empty?
end

def read_version
  content = File.read(VERSION_FILE)
  match = content.match(/VERSION\s*=\s*['"]([^'"]+)['"]/)
  return match[1] if match
  
  raise "Could not find VERSION in #{VERSION_FILE}"
end

def bump_version(current_version, type)
  major, minor, patch = current_version.split('.').map(&:to_i)
  
  case type
  when 'major'
    major += 1
    minor = 0
    patch = 0
  when 'minor'
    minor += 1
    patch = 0
  when 'patch'
    patch += 1
  else
    raise "Unknown bump type: #{type}"
  end
  
  "#{major}.#{minor}.#{patch}"
end

def update_version_file(new_version)
  content = File.read(VERSION_FILE)
  new_content = content.sub(/VERSION\s*=\s*['"]([^'"]+)['"]/, "VERSION = '#{new_version}'")
  File.write(VERSION_FILE, new_content)
end

# Main execution
puts "🚀 Starting Release Process..."

# 1. Check prerequisites
unless git_clean?
  puts "❌ Error: Git working directory is not clean. Please commit or stash changes."
  exit 1
end

start_branch = current_branch
puts "Current branch: #{start_branch}"

# 2. Switch to main and merge dev
puts "\n🔄 Switching to main and merging dev..."
run_command("git checkout main")
run_command("git pull origin main") if system("git remote | grep -q origin") # Only pull if origin exists
run_command("git merge dev")

# 3. Bump version
current_ver = read_version
puts "\nCurrent Version: #{current_ver}"
print "Select bump type (major/minor/patch) [patch]: "
bump_type = $stdin.gets.chomp.downcase
bump_type = 'patch' if bump_type.empty?

unless %w[major minor patch].include?(bump_type)
  puts "❌ Invalid bump type."
  run_command("git checkout #{start_branch}")
  exit 1
end

new_ver = bump_version(current_ver, bump_type)
puts "Target Version: #{new_ver}"

puts "Proceed? (y/n)"
unless $stdin.gets.chomp.downcase == 'y'
  puts "Aborted."
  run_command("git checkout #{start_branch}")
  exit 0
end

update_version_file(new_ver)
puts "✅ Updated #{VERSION_FILE} to #{new_ver}"

# 4. Commit version bump
run_command("git add #{VERSION_FILE}")
run_command("git commit -m 'chore: bump version to #{new_ver}'")

# 5. Run rake release
puts "\n📦 Running rake release (Tagging, Building, Pushing)..."
begin
  run_command("bundle exec rake release")
rescue StandardError => e
  puts "❌ Release failed: #{e.message}"
  puts "You are currently on branch main. Please check the state."
  exit 1
end

# 6. Sync back to dev
puts "\n🔄 Syncing back to dev..."
run_command("git checkout dev")
run_command("git merge main")
run_command("git push origin dev") if system("git remote | grep -q origin")

puts "\n✨ Release #{new_ver} completed successfully!"
