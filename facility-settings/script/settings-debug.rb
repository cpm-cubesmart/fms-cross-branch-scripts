# USAGE
#
# 1. cd/checkout your repro
#   cd ~/code/fms
#
# 3. Run the script
#   DISABLE_SPRING=1 bin/rails runner ../fms-cross-branch-scripts/settings-debug.rb
#
# 4. GLHF!

TEST_KEY = :change_passwords_every

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


def setting_value(subject, debug: true)
  settings = subject.settings
  binding.pry if debug
  settings.send(TEST_KEY)
end

puts "Testing #{TEST_KEY}:"
puts "\tCompany:"
pp setting_value(cubesmart)
puts

puts "\tFacility:"
pp setting_value(facility)
puts
