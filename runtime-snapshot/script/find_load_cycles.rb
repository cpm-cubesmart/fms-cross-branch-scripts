# runtime-snapshot/script/find_load_cycles.rb
# frozen_string_literal: true
#
# Finds files that were read while they were still being written -- the failure
# that silently cost FacilitySettings all 622 of its generated setting accessors
# on the Zeitwerk branch.
#
#   ruby script/find_load_cycles.rb snapshots/zeitwerk-eager.json
#
# THE SHAPE
#
#   defaultable/company_settings.rb starts loading
#     DEFAULTS = {}                       <- assigned, not yet populated
#     ... something here reaches FacilitySettings ...
#       facility_settings.rb starts loading
#         include Defaultable::CompanySettings   <- already in the constant table,
#                                                   so no autoload and no wait
#         generate_default_setting_methods(DEFAULTS)   <- reads the empty hash
#       facility_settings.rb finishes
#     ... DEFAULTS finishes being populated ...
#   defaultable/company_settings.rb finishes
#
# No exception, no missing constant, no failed boot: just a macro that read a
# half-built value and generated nothing. Whichever file loads first wins, which
# is why a migration that changes load order is where this surfaces.
#
# HOW IT IS DETECTED
#
# The snapshot already records both halves of the interval, on two independent
# clocks that never have to be reconciled:
#
#   load_order.class_bodies   START order      -- TracePoint(:class), fires when
#                                                 a class or module body opens
#   load_order.files          COMPLETION order -- $LOADED_FEATURES, which CRuby
#                                                 appends to after a file has
#                                                 finished evaluating
#   load_order.autoloaded     COMPLETION order -- classic's Dependencies.history,
#                                                 appended after require_or_load
#                                                 returns. The only such signal on
#                                                 the classic branch, which loads
#                                                 app files with Kernel#load and so
#                                                 never touches $LOADED_FEATURES.
#
# A was still in flight while B loaded iff start(A) < start(B) and done(B) < done(A)
# -- ordinary parenthesis matching. It needs only the two rank orders, not a shared
# timeline, which is what makes this work without new instrumentation.
#
# Nesting alone is not a finding: every autoload nests. What makes it one is the
# second condition -- that a constant defined in B takes an ancestor from A. B
# therefore saw whatever A had defined at that instant, and nothing A defined
# afterwards.
#
# WHAT IT CANNOT SEE
#
# A body that reads an incomplete constant without inheriting or including
# anything from it. That is the literal mechanism above -- the `include` is a
# correlated signal, not the injury. Catching it needs enter/exit events on one
# clock, which means wrapping Kernel#require ahead of Bundler and Bootsnap.
# Deferred: the ancestor signal found both real instances in this application with
# no false positives.

require "json"
require "set"

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

options = { exit_code: false, json: false }
paths = []

args = ARGV.dup
until args.empty?
  arg = args.shift
  case arg
  when "--exit-code" then options[:exit_code] = true
  when "--json"      then options[:json] = true
  when "-h", "--help"
    puts <<~USAGE
      Usage: find_load_cycles.rb <snapshot.json> [options]

        --exit-code   exit 1 when any re-entrant load is found
        --json        emit the findings as JSON instead of a report

      Reports files that were read while still loading, and the constants that
      took an ancestor from them. See the header of this file for the mechanism.
    USAGE
    exit 0
  else
    if arg.start_with?("-")
      warn "unknown option: #{arg}"
      exit 2
    end
    paths << arg
  end
end

if paths.length != 1
  warn "Usage: find_load_cycles.rb <snapshot.json> [--exit-code] [--json]"
  exit 2
end

snapshot_path = paths.first

unless File.file?(snapshot_path)
  warn "error: no such snapshot: #{snapshot_path}"
  exit 2
end

SNAPSHOT = JSON.parse(File.read(snapshot_path))
LABEL = (SNAPSHOT["identity"] || {})["label"] || File.basename(snapshot_path, ".json")

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# normalize_path rewrites everything outside the checkout to a bracketed root
# (<gems>/..., <ruby>/...), so an application file is exactly one that has not
# been bracketed and is not still absolute.
def app_path?(path)
  return false if path.nil? || path.empty?

  !path.start_with?("<", "/")
end

# require_or_load chomps ".rb" and nothing else, so history entries arrive without
# it while class_bodies and $LOADED_FEATURES keep it. Restoring it here is what
# lets the two clocks be keyed on the same string -- the comparator had the same
# bug once, in the other order.
def with_extension(path)
  return path if path.nil?
  return path if File.basename(path).include?(".")

  "#{path}.rb"
end

# ---------------------------------------------------------------------------
# Clocks
# ---------------------------------------------------------------------------

load_order = SNAPSHOT["load_order"] || {}

start_rank = {}
(load_order["class_bodies"] || []).each_with_index do |event, index|
  file = event.is_a?(Hash) ? event["file"] : event
  next if file.nil?

  start_rank[file] ||= index
end

# Two completion clocks, kept apart on purpose. $LOADED_FEATURES and
# Dependencies.history are separate sequences: an index in one says nothing about
# an index in the other, and interleaving them produces confident nonsense. On the
# classic branch this ran against a sorted history and reported 14,768 pairs.
def rank_list(list)
  ranks = {}
  Array(list).each_with_index do |entry, index|
    file = entry.is_a?(Hash) ? entry["file"] : entry
    next if file.nil?

    ranks[with_extension(file)] ||= index
  end
  ranks
end

autoloaded = Array(load_order["autoloaded"])

# A sorted list is not a clock. autoloaded was stored sorted through script
# version 12, which turned every alphabetical accident into a nesting claim --
# so refuse it rather than rank against it. Short lists are exempt because a
# handful of files can be in alphabetical order by chance.
autoloaded_sorted = autoloaded.length > 100 && autoloaded == autoloaded.sort

DONE_RANKS = {
  "$LOADED_FEATURES" => rank_list(load_order["files"]),
  "Dependencies.history" => (autoloaded_sorted ? {} : rank_list(autoloaded))
}.freeze

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------

CONSTANTS = SNAPSHOT["constants"] || {}

file_of = {}
kind_of = {}
CONSTANTS.each do |name, entry|
  file_of[name] = entry["const_file"]
  kind_of[name] = entry["kind"]
end

# Returns the clock that ranks both files, or nil. Preferring $LOADED_FEATURES is
# arbitrary but has to be deterministic -- it is the VM's own record, and on the
# Zeitwerk branch it covers everything.
def shared_clock(a, b)
  DONE_RANKS.each_value do |ranks|
    return ranks if ranks.key?(a) && ranks.key?(b)
  end
  nil
end

findings = Hash.new { |h, k| h[k] = [] }
skipped_no_clock = 0
pairs_considered = 0

CONSTANTS.each do |name, entry|
  b = entry["const_file"]
  next unless app_path?(b)
  next unless start_rank.key?(b)

  superclass = entry["superclass"]

  (entry["ancestors"] || []).each do |ancestor|
    next if ancestor == name
    next if ancestor.start_with?("#<")

    a = file_of[ancestor]
    next if a.nil? || a == b
    next unless app_path?(a)
    next unless start_rank.key?(a)

    # A opened first. Necessary but nowhere near sufficient -- almost every
    # ancestor's file opened first.
    next unless start_rank[a] < start_rank[b]

    pairs_considered += 1

    ranks = shared_clock(a, b)
    if ranks.nil?
      skipped_no_clock += 1
      next
    end

    # ...and had not finished when B finished. This is the whole test.
    next unless ranks[b] < ranks[a]

    findings[a] << {
      "in_flight_file" => a,
      "defined_file" => b,
      "constant" => name,
      "ancestor" => ancestor,
      # A class ancestor was inherited, a module was mixed in. Inheriting from a
      # half-built class is the worse of the two: a subclass reads its superclass's
      # macros, callbacks and class attributes at definition time.
      "relation" => kind_of[ancestor] == "class" ? "inherits" : "includes"
    }
  end
end

ordered = findings.keys.sort.map { |a| [a, findings[a].sort_by { |f| [f["defined_file"], f["constant"]] }] }
total = ordered.sum { |_, rows| rows.length }

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if options[:json]
  puts JSON.pretty_generate(
    "snapshot" => LABEL,
    "findings" => ordered.flat_map { |_, rows| rows },
    "coverage" => {
      "app_files_with_start_rank" => start_rank.keys.count { |f| app_path?(f) },
      "loaded_features_ranked" => DONE_RANKS["$LOADED_FEATURES"].size,
      "history_ranked" => DONE_RANKS["Dependencies.history"].size,
      "history_refused_as_sorted" => autoloaded_sorted,
      "pairs_considered" => pairs_considered,
      "pairs_skipped_no_shared_clock" => skipped_no_clock
    }
  )
  exit(options[:exit_code] && total.positive? ? 1 : 0)
end

puts "# Re-entrant loads in #{LABEL}"
puts

if autoloaded_sorted
  puts "! load_order.autoloaded is in sorted order (#{autoloaded.length} entries), so it"
  puts "! carries no completion order and was not used. Snapshots before script version 13"
  puts "! stored it sorted; re-snapshot to cover files that only classic autoloading sees."
  puts
end

if total.zero?
  puts "  No file was read while it was still loading."
  puts
else
  puts "## Files read while still loading (#{ordered.length})"
  puts "   Each of these had not finished executing when the file below it opened a class"
  puts "   body that took an ancestor from it. Whatever it defines after that point was not"
  puts "   there to be read -- a macro reading a constant it is still building generates"
  puts "   nothing, and raises nothing."
  puts

  ordered.each do |a, rows|
    puts "  #{a}"
    rows.chunk_while { |x, y| x["defined_file"] == y["defined_file"] }.each do |group|
      puts "    was still loading when #{group.first['defined_file']} defined:"
      group.each { |row| puts "      #{row['constant']}  #{row['relation']}  #{row['ancestor']}" }
    end
    puts
  end
end

# Coverage, always, because a pair that could not be ranked is indistinguishable
# in the output from a pair that was ranked and found clean.
puts "## Coverage"
puts
puts "  app files with a start rank      #{start_rank.keys.count { |f| app_path?(f) }}"
puts "  ranked by $LOADED_FEATURES       #{DONE_RANKS['$LOADED_FEATURES'].size}"
puts "  ranked by Dependencies.history   #{DONE_RANKS['Dependencies.history'].size}#{autoloaded_sorted ? '   (refused: sorted)' : ''}"
puts "  ancestor pairs tested            #{pairs_considered}"

if skipped_no_clock.positive?
  puts "  pairs skipped, no shared clock   #{skipped_no_clock}"
  puts
  puts "  A skipped pair is not a clean pair. The two files' completion times were"
  puts "  recorded by different mechanisms, which cannot be compared to each other."
end

exit(options[:exit_code] && total.positive? ? 1 : 0)
