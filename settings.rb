# USAGE
#
# For this example, I'm assuming the following:
# - You have `main` checked out at /home/developer/code/fms
# - You have your zeitwerk branch checked out at /home/developer/code/fms-worktrees/zeitwerk_upgrade_low_impact
# - You have this repository checked out at /home/developer/code/fms-cross-branch-scripts
#
# If your paths are different, please adjust the commands accordingly.
#
# 1. cd/checkout your main repro
#   cd ~/code/fms
#
# 2. Make sure ~/code/fms/config/environments/development.rb is configured with the config.eager_load value you are
#    testing for. Not working in eager mode is a show stopper, but not working in non-eager mode is also very bad.
#
# 3. Run the script and capture output.
#   DISABLE_SPRING=1 bin/rails runner ../fms-cross-branch-scripts/settings.rb > ../fms-cross-branch-scripts/output_main_settings.txt
#
# 4. cd/checkout your zeitwerk repro
#   cd ~/code/fms-worktrees/zeitwerk_upgrade_low_impact
#
# 5. Make sure ~/code/fms-worktrees/zeitwerk_upgrade_low_impact/config/environments/development.rb is configured with
#    the config.eager_load value you are testing for.
#
# 6. Run the script and capture output.
#   DISABLE_SPRING=1 bin/rails runner ../../fms-cross-branch-scripts/settings.rb > ../../fms-cross-branch-scripts/output_zeitwerk_settings.txt
#
# 7. Compare the output with diff or any other tool you want to use.
#
#   cd ~/fms-cross-branch-scripts
#   diff -u output_main_settings.txt output_zeitwerk_settings.txt > output_settings.diff

puts "Assertions for #{__FILE__}"
puts "RAILS_ROOT: %s" % [ Rails.root ]
puts "RAILS_ENV: %s" % [ Rails.env ]
puts "Eager load app: %s" % [ Rails.configuration.eager_load ]

puts "======================="

puts "loading Facility 725..."
facility = Facility.find(725)
pp facility
puts

puts "loading cubesmart Company..."
company = cubesmart = Company.cubesmart
pp cubesmart
puts

puts "Confirming Facility 725's Company is cubesmart..."
puts "facility.company_id=#{facility.company_id}, cubesmart.id=#{cubesmart.id}"
puts

puts "cubesmart raw settings hash:"
pp cubesmart.settings.data
puts
puts

puts "facility raw settings hash:"
pp facility.settings.data
puts
puts

puts "combined keys:"
keys = (facility.settings.data.keys + cubesmart.settings.data.keys).uniq.sort
pp keys
puts
puts

def settings_method_lookup(subject, key)
  settings = subject.settings

  if settings.respond_to?(key)
    settings.send(key)
  else
    "<<method lookup not available>>"
  end
end

def settings_hash_lookup(subject, key)
  settings = subject.settings
  data = settings.data

  if data.key?(key)
    data[key]
  else
    "<<key not in raw hash>>"
  end
end

keys.each do |key|
  puts "#{key}:"
  puts "\tcompany method:  %s" % [settings_method_lookup(cubesmart, key).inspect]
  puts "\tcompany raw:     %s" % [settings_hash_lookup(cubesmart, key).inspect]
  puts "\tfacility method: %s" % [settings_method_lookup(facility, key).inspect]
  puts "\tfacility raw:    %s" % [settings_hash_lookup(facility, key).inspect]
  puts
end
