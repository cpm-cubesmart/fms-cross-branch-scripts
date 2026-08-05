#!/usr/bin/env ruby
# runtime-snapshot/script/compare_runtime_snapshots.rb
# frozen_string_literal: true
#
# Diffs two runtime snapshots produced by dump_runtime_snapshot.rb and prints a
# worklist, ordered so the most actionable differences come first.
#
#   ruby compare_runtime_snapshots.rb A.json B.json [options]
#
# A should be the base/classic branch and B the Zeitwerk branch, matching the
# argument order of dump_git_renames.rb, so that the rename map's old -> new
# direction lines up.
#
# The report is designed to be run over and over: add a to_prepare block on the
# Zeitwerk branch, re-snapshot, re-compare, watch the counts fall. The header
# exists so that progress is visible without reading the body.

require "json"
require "set"
require "optparse"

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

options = {
  renames: nil,
  ignore: nil,
  sources_a: nil,
  sources_b: nil,
  summary_only: false,
  format: "text",
  exit_code: false,
  strict: false,
  include_generated_ancestors: false,
  include_zeitwerk_shims: false,
  source_diff: true,
  max_per_section: 100
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: compare_runtime_snapshots.rb CLASSIC.json ZEITWERK.json [options]"

  opts.on("--renames PATH", "git rename map from dump_git_renames.rb") { |v| options[:renames] = v }
  opts.on("--ignore PATH", "allowlist of triaged differences") { |v| options[:ignore] = v }
  opts.on("--sources-a PATH", "sources sidecar for A (default: alongside A)") { |v| options[:sources_a] = v }
  opts.on("--sources-b PATH", "sources sidecar for B (default: alongside B)") { |v| options[:sources_b] = v }
  opts.on("--summary-only", "counts header only") { options[:summary_only] = true }
  opts.on("--format FORMAT", %w[text json], "text (default) or json") { |v| options[:format] = v }
  opts.on("--exit-code", "exit 1 while semantic differences remain") { options[:exit_code] = true }
  opts.on("--strict", "with --exit-code, also fail on informational sections") { options[:strict] = true }
  opts.on("--include-generated-ancestors", "keep Rails' Generated*Methods modules in ancestor chains") do
    options[:include_generated_ancestors] = true
  end
  opts.on("--include-zeitwerk-shims", "keep ZeitwerkIntegration's Object shims in ancestor chains") do
    options[:include_zeitwerk_shims] = true
  end
  opts.on("--no-source-diff", "list changed methods without printing source diffs") do
    options[:source_diff] = false
  end
  opts.on("--max-per-section N", Integer, "cap rows per section (0 = unlimited, default 100)") do |v|
    options[:max_per_section] = v
  end
  opts.on("-h", "--help") { puts opts; exit 0 }
end

parser.parse!

path_a, path_b = ARGV

unless path_a && path_b
  warn parser.banner
  warn "\nRun with --help for options."
  exit 2
end

snapshot_a = JSON.parse(File.read(path_a))
snapshot_b = JSON.parse(File.read(path_b))

label_a = snapshot_a.dig("identity", "label") || File.basename(path_a, ".json")
label_b = snapshot_b.dig("identity", "label") || File.basename(path_b, ".json")

def load_sources(explicit, snapshot_path)
  path = explicit || snapshot_path.sub(/\.json\z/, "") + ".sources.json"

  return {} unless File.file?(path)

  JSON.parse(File.read(path))
rescue StandardError
  {}
end

sources_a = load_sources(options[:sources_a], path_a)
sources_b = load_sources(options[:sources_b], path_b)

# ---------------------------------------------------------------------------
# Rename map
#
# The classic branch refers to files by their old paths; the Zeitwerk branch has
# moved and renamed a lot of them. Without canonicalizing, every renamed file
# reads as "deleted here, added there" and swamps the real findings.
# ---------------------------------------------------------------------------

renames =
  if options[:renames] && File.file?(options[:renames])
    JSON.parse(File.read(options[:renames]))
  else
    {}
  end

OLD_TO_NEW = renames.fetch("old_to_new", {})

# A path that is both the old name of one rename and the new name of another
# (an A -> B, B -> C shuffle) would be rewritten inconsistently. Rare, but
# silently wrong if it happens, so those paths are left alone and reported.
AMBIGUOUS_RENAMES = (OLD_TO_NEW.keys & OLD_TO_NEW.values).to_set

def canonical_path(path)
  return path if path.nil?
  return path if AMBIGUOUS_RENAMES.include?(path)

  OLD_TO_NEW.fetch(path, path)
end

# Anonymous ancestors are labelled by their defining file
# ("#<anonymous module @ app/models/concerns/foo.rb>"), so the rename map has to
# reach inside the label too.
def canonical_label(label)
  return label if label.nil? || !label.include?("@ ")

  label.sub(/@ (.+)>\z/) { "@ #{canonical_path(Regexp.last_match(1))}>" }
end

# ---------------------------------------------------------------------------
# Ignore list
#
# Line-based so it can be maintained by hand as differences get triaged:
#
#   constant Legacy::*
#   ancestor ActiveSupport::ForkTracker::*
#   file     db/schema.rb
#   method   Widget#price
#   method   Widget.build
#   section  load_order
# ---------------------------------------------------------------------------

class IgnoreList
  def initialize(path)
    @constants = []
    @ancestors = []
    @files = []
    @methods = []
    @sections = Set.new

    return unless path && File.file?(path)

    File.readlines(path).each do |line|
      line = line.sub(/#.*\z/, "").strip
      next if line.empty?

      kind, _, pattern = line.partition(/\s+/)
      pattern = pattern.strip
      next if pattern.empty?

      case kind
      when "constant" then @constants << pattern
      when "ancestor" then @ancestors << pattern
      when "file"     then @files << pattern
      when "method"   then @methods << pattern
      when "section"  then @sections << pattern
      end
    end
  end

  def constant?(name)
    @constants.any? { |p| File.fnmatch?(p, name, File::FNM_EXTGLOB) }
  end

  # Matches a label as it appears *inside* an ancestors/singleton_ancestors chain,
  # i.e. the chain member -- unlike constant?, which matches the chain owner.
  # FNM_PATHNAME is deliberately off so "*" crosses "::".
  def ancestor?(label)
    return false if label.nil?

    @ancestors.any? { |p| File.fnmatch?(p, label, File::FNM_EXTGLOB) }
  end

  def file?(path)
    return false if path.nil?

    @files.any? { |p| File.fnmatch?(p, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
  end

  # "Widget#price" for instance methods, "Widget.build" for singleton methods.
  def method?(constant, kind, name)
    return true if constant?(constant)

    label = "#{constant}#{kind == 'singleton' ? '.' : '#'}#{name}"
    @methods.any? { |p| File.fnmatch?(p, label, File::FNM_EXTGLOB) }
  end

  def section?(id)
    @sections.include?(id)
  end
end

IGNORE = IgnoreList.new(options[:ignore])

# ---------------------------------------------------------------------------
# Canonicalization of a whole snapshot
# ---------------------------------------------------------------------------

GENERATED_ANCESTOR_RE = /::Generated(Attribute|Association)Methods\z/.freeze

# ZeitwerkIntegration.take_over finishes with Object.prepend(RequireDependency), so
# on the zeitwerk side this lands in every Object-descended ancestor chain and every
# singleton chain -- one global fact, re-reported once per constant. It is always an
# addition, never carries per-constant information, and the mode switch it reflects
# is already asserted from identity.eager_load / identity.zeitwerk_enabled. Matched
# on the namespace prefix rather than the one module name so sibling shims are
# covered too.
ZEITWERK_SHIM_ANCESTOR_RE = /\AActiveSupport::Dependencies::ZeitwerkIntegration::/.freeze

def canonicalize!(snapshot, include_generated, include_zeitwerk_shims)
  snapshot.fetch("constants", {}).each_value do |data|
    data["const_file"] = canonical_path(data["const_file"])

    %w[ancestors singleton_ancestors].each do |key|
      list = data[key]
      next if list.nil?

      list = list.map { |label| canonical_label(label) }
      list = list.reject { |label| label =~ GENERATED_ANCESTOR_RE } unless include_generated
      list = list.reject { |label| label =~ ZEITWERK_SHIM_ANCESTOR_RE } unless include_zeitwerk_shims
      list = list.reject { |label| IGNORE.ancestor?(label) }
      data[key] = list
    end

    # Not filtered: a prepended module can never be a superclass.
    data["superclass"] = canonical_label(data["superclass"])

    data.fetch("methods", []).each { |m| m["file"] = canonical_path(m["file"]) }
  end

  load_order = snapshot.fetch("load_order", {})
  load_order["files"] = Array(load_order["files"]).map { |f| canonical_path(f) }
  Array(load_order["class_bodies"]).each { |e| e["file"] = canonical_path(e["file"]) }

  snapshot
end

canonicalize!(snapshot_a, options[:include_generated_ancestors], options[:include_zeitwerk_shims])
canonicalize!(snapshot_b, options[:include_generated_ancestors], options[:include_zeitwerk_shims])

CONSTANTS_A = snapshot_a.fetch("constants", {})
CONSTANTS_B = snapshot_b.fetch("constants", {})

# ---------------------------------------------------------------------------
# Diff helpers
# ---------------------------------------------------------------------------

# Standard LCS diff. Only ever run on short sequences (ancestor chains, method
# bodies), so the O(n*m) table is fine. Load order uses the LIS approach below
# instead, because those sequences run to thousands of entries.
def lcs_diff(a, b)
  n = a.length
  m = b.length
  table = Array.new(n + 1) { Array.new(m + 1, 0) }

  (n - 1).downto(0) do |i|
    (m - 1).downto(0) do |j|
      table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : [table[i + 1][j], table[i][j + 1]].max
    end
  end

  result = []
  i = 0
  j = 0

  while i < n && j < m
    if a[i] == b[j]
      result << [:same, a[i]]
      i += 1
      j += 1
    elsif table[i + 1][j] >= table[i][j + 1]
      result << [:del, a[i]]
      i += 1
    else
      result << [:add, b[j]]
      j += 1
    end
  end

  result.concat(a[i..].map { |x| [:del, x] }) if i < n
  result.concat(b[j..].map { |x| [:add, x] }) if j < m
  result
end

# Longest increasing subsequence of B-positions, walked in A-order. Whatever is
# NOT in that subsequence is the minimal set of items that had to move.
#
# This is what makes the load-order section readable: a raw diff of two 8000-line
# orderings reports thousands of changes, when the actual finding is "these 40
# files moved relative to everything else".
def out_of_order(sequence)
  return [] if sequence.empty?

  tails = []
  tail_indexes = []
  predecessors = Array.new(sequence.length)

  sequence.each_with_index do |value, index|
    position = tails.bsearch_index { |t| t >= value } || tails.length

    tails[position] = value
    tail_indexes[position] = index
    predecessors[index] = position.positive? ? tail_indexes[position - 1] : nil
  end

  keep = Set.new
  cursor = tail_indexes.last

  while cursor
    keep << cursor
    cursor = predecessors[cursor]
  end

  (0...sequence.length).reject { |i| keep.include?(i) }
end

def method_key(method)
  "#{method['kind']}:#{method['name']}"
end

def method_label(constant, method)
  "#{constant}#{method['kind'] == 'singleton' ? '.' : '#'}#{method['name']}"
end

# ---------------------------------------------------------------------------
# Section 1/2: constants
# ---------------------------------------------------------------------------

names_a = CONSTANTS_A.keys.to_set
names_b = CONSTANTS_B.keys.to_set

missing = (names_a - names_b).reject { |n| IGNORE.constant?(n) }.sort
extra   = (names_b - names_a).reject { |n| IGNORE.constant?(n) }.sort
common  = (names_a & names_b).reject { |n| IGNORE.constant?(n) }.sort

# ---------------------------------------------------------------------------
# Sections 3/4: superclass and ancestors
# ---------------------------------------------------------------------------

superclass_changes = []
ancestor_changes = []

common.each do |name|
  a = CONSTANTS_A[name]
  b = CONSTANTS_B[name]

  if a["superclass"] != b["superclass"]
    superclass_changes << { "constant" => name, "a" => a["superclass"], "b" => b["superclass"] }
  end

  %w[ancestors singleton_ancestors].each do |key|
    list_a = a[key] || []
    list_b = b[key] || []
    next if list_a == list_b

    ancestor_changes << {
      "constant" => name,
      "chain" => key,
      "diff" => lcs_diff(list_a, list_b).reject { |op, _| op == :same }
                                        .map { |op, value| [op.to_s, value] }
    }
  end
end

# ---------------------------------------------------------------------------
# Section 5: class reopen order
#
# A class opened in more than one file is a monkey patch, a decorator, or a
# concern being mixed in after the fact -- and which definition wins depends
# entirely on the order those files run. Classic fixes that order with explicit
# requires in application.rb; Zeitwerk does not. This section is the direct
# check on that.
# ---------------------------------------------------------------------------

def definition_sites(snapshot)
  sites = Hash.new { |h, k| h[k] = [] }

  Array(snapshot.dig("load_order", "class_bodies")).each do |event|
    name = event["name"]
    next if name.nil?

    sites[name] << event["file"]
  end

  sites
end

sites_a = definition_sites(snapshot_a)
sites_b = definition_sites(snapshot_b)

reopen_changes = []

(sites_a.keys | sites_b.keys).sort.each do |name|
  next if IGNORE.constant?(name)

  list_a = sites_a[name]
  list_b = sites_b[name]

  # Only interesting where something was actually reopened.
  next unless list_a.uniq.length > 1 || list_b.uniq.length > 1
  next if list_a == list_b

  reopen_changes << { "constant" => name, "a" => list_a, "b" => list_b }
end

# ---------------------------------------------------------------------------
# Sections 6/7/8/11: methods
# ---------------------------------------------------------------------------

methods_added = []
methods_removed = []
visibility_changes = []
source_changes = []
signature_changes = []
relocations = []
line_only_changes = []

common.each do |name|
  by_key_a = CONSTANTS_A[name].fetch("methods", []).to_h { |m| [method_key(m), m] }
  by_key_b = CONSTANTS_B[name].fetch("methods", []).to_h { |m| [method_key(m), m] }

  (by_key_a.keys - by_key_b.keys).sort.each do |key|
    m = by_key_a[key]
    next if IGNORE.method?(name, m["kind"], m["name"])

    methods_removed << { "constant" => name, "method" => method_label(name, m), "file" => m["file"] }
  end

  (by_key_b.keys - by_key_a.keys).sort.each do |key|
    m = by_key_b[key]
    next if IGNORE.method?(name, m["kind"], m["name"])

    methods_added << { "constant" => name, "method" => method_label(name, m), "file" => m["file"] }
  end

  (by_key_a.keys & by_key_b.keys).sort.each do |key|
    a = by_key_a[key]
    b = by_key_b[key]

    next if IGNORE.method?(name, a["kind"], a["name"])

    label = method_label(name, a)

    if a["visibility"] != b["visibility"]
      visibility_changes << {
        "method" => label, "a" => a["visibility"], "b" => b["visibility"]
      }
    end

    if a["source_sha"] && b["source_sha"] && a["source_sha"] != b["source_sha"]
      source_changes << {
        "method" => label,
        "file_a" => a["file"], "line_a" => a["line"], "sha_a" => a["source_sha"],
        "file_b" => b["file"], "line_b" => b["line"], "sha_b" => b["source_sha"]
      }
    elsif a["params"] != b["params"]
      # Reached when there is no source hash to compare (native/gem methods).
      # A changed arity there still means a different definition won.
      signature_changes << {
        "method" => label, "a" => a["params"], "b" => b["params"],
        "file_a" => a["file"], "file_b" => b["file"]
      }
    elsif a["file"] != b["file"]
      relocations << {
        "method" => label, "a" => a["file"], "b" => b["file"], "source" => a["source"]
      }
    elsif a["line"] != b["line"]
      line_only_changes << { "method" => label, "file" => a["file"], "a" => a["line"], "b" => b["line"] }
    end
  end
end

# ---------------------------------------------------------------------------
# Sections 9/10: files
# ---------------------------------------------------------------------------

files_a = Array(snapshot_a.dig("load_order", "files"))
files_b = Array(snapshot_b.dig("load_order", "files"))

set_a = files_a.to_set
set_b = files_b.to_set

files_only_a = (set_a - set_b).reject { |f| IGNORE.file?(f) }.sort
files_only_b = (set_b - set_a).reject { |f| IGNORE.file?(f) }.sort

index_a = {}
files_a.each_with_index { |f, i| index_a[f] ||= i }

index_b = {}
files_b.each_with_index { |f, i| index_b[f] ||= i }

shared_in_a_order = files_a.select { |f| set_b.include?(f) && !IGNORE.file?(f) }
positions = shared_in_a_order.map { |f| index_b[f] }

# Ranks are reported as positions in each snapshot's full load sequence, so the
# two numbers are directly comparable.
moved_files = out_of_order(positions).map do |i|
  file = shared_in_a_order[i]
  { "file" => file, "rank_a" => index_a[file], "rank_b" => index_b[file] }
end

# ---------------------------------------------------------------------------
# Counts and exit status
# ---------------------------------------------------------------------------

counts = {
  "constants_missing" => missing.length,
  "constants_extra" => extra.length,
  "superclass_changes" => superclass_changes.length,
  "ancestor_diffs" => ancestor_changes.length,
  "reopen_order_changes" => reopen_changes.length,
  "methods_removed" => methods_removed.length,
  "methods_added" => methods_added.length,
  "visibility_changes" => visibility_changes.length,
  "source_diffs" => source_changes.length,
  "signature_diffs" => signature_changes.length,
  "method_relocations" => relocations.length,
  "files_only_a" => files_only_a.length,
  "files_only_b" => files_only_b.length,
  "load_order_moves" => moved_files.length,
  "line_only_changes" => line_only_changes.length
}

# Semantic sections describe the runtime state itself, which is what has to
# match. The informational ones describe the mechanism that produced it --
# Zeitwerk eager-loads alphabetically per root directory, so its file ordering
# will never match classic's require order and driving that to zero is not a
# goal. Line numbers move whenever a file is edited at all.
SEMANTIC_SECTIONS = %w[
  constants_missing constants_extra superclass_changes ancestor_diffs
  reopen_order_changes methods_removed methods_added visibility_changes
  source_diffs signature_diffs method_relocations
].freeze

INFORMATIONAL_SECTIONS = %w[
  files_only_a files_only_b load_order_moves line_only_changes
].freeze

semantic_total = SEMANTIC_SECTIONS.sum { |k| IGNORE.section?(k) ? 0 : counts[k] }
informational_total = INFORMATIONAL_SECTIONS.sum { |k| IGNORE.section?(k) ? 0 : counts[k] }

# ---------------------------------------------------------------------------
# Identity guard
# ---------------------------------------------------------------------------

warnings = []
errors = []

id_a = snapshot_a.fetch("identity", {})
id_b = snapshot_b.fetch("identity", {})

if id_a["rails_env"] != id_b["rails_env"]
  errors << "RAILS_ENV differs: #{id_a['rails_env']} vs #{id_b['rails_env']}"
end

if id_a["eager_load"] != id_b["eager_load"]
  errors << "config.eager_load differs: #{id_a['eager_load'].inspect} vs " \
            "#{id_b['eager_load'].inspect} -- these snapshots are not comparable. " \
            "Set the same value in config/environments/#{id_a['rails_env']}.rb in both " \
            "checkouts and re-snapshot."
end

if id_a["script_version"] != id_b["script_version"]
  errors << "snapshots were produced by different script versions " \
            "(#{id_a['script_version']} vs #{id_b['script_version']}); re-snapshot both"
end

# Keep in step with SCRIPT_VERSION in dump_runtime_snapshot.rb. The mismatch
# check above only catches a mixed pair; two equally stale snapshots would
# compare cleanly and quietly reproduce whatever the old dumper got wrong.
EXPECTED_SCRIPT_VERSION = 2

if id_a["script_version"] == id_b["script_version"] &&
   id_a["script_version"].to_i < EXPECTED_SCRIPT_VERSION
  warnings << "both snapshots were produced by script version " \
              "#{id_a['script_version']} but the dumper is now at " \
              "#{EXPECTED_SCRIPT_VERSION}; re-snapshot both to pick up its fixes"
end

[["a", id_a, label_a], ["b", id_b, label_b]].each do |_, id, label|
  warnings << "#{label}: preboot trace was not installed; load-order sections are empty" unless id["preboot_trace_installed"]
  warnings << "#{label}: working tree is dirty" if id["dirty"]
  warnings << "#{label}: Rails.root did not match the preboot hook's assumed root; " \
              "class-body data is incomplete" if id["presumed_root_matched"] == false
end

if id_a["bootsnap_active"] != id_b["bootsnap_active"]
  warnings << "Bootsnap active on one side only (#{id_a['bootsnap_active']} vs #{id_b['bootsnap_active']})"
end

if OLD_TO_NEW.empty?
  warnings << "no rename map supplied (--renames); renamed files will show as " \
              "removed-and-added throughout"
end

unless AMBIGUOUS_RENAMES.empty?
  warnings << "#{AMBIGUOUS_RENAMES.size} path(s) are both an old and a new name in the " \
              "rename map and were left uncanonicalized: #{AMBIGUOUS_RENAMES.to_a.sort.join(', ')}"
end

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

if options[:format] == "json"
  puts JSON.pretty_generate(
    "a" => label_a,
    "b" => label_b,
    "counts" => counts,
    "semantic_total" => semantic_total,
    "informational_total" => informational_total,
    "errors" => errors,
    "warnings" => warnings,
    "constants_missing" => missing,
    "constants_extra" => extra,
    "superclass_changes" => superclass_changes,
    "ancestor_diffs" => ancestor_changes,
    "reopen_order_changes" => reopen_changes,
    "methods_removed" => methods_removed,
    "methods_added" => methods_added,
    "visibility_changes" => visibility_changes,
    "source_diffs" => source_changes,
    "signature_diffs" => signature_changes,
    "method_relocations" => relocations,
    "files_only_a" => files_only_a,
    "files_only_b" => files_only_b,
    "load_order_moves" => moved_files,
    "line_only_changes" => line_only_changes
  )

  exit(options[:exit_code] && (semantic_total.positive? || (options[:strict] && informational_total.positive?)) ? 1 : 0)
end

LIMIT = options[:max_per_section]

def emit(rows)
  limit = LIMIT.to_i

  if limit.positive? && rows.length > limit
    rows.first(limit).each { |row| yield row }
    puts "  ... and #{rows.length - limit} more (--max-per-section=0 for all)"
  else
    rows.each { |row| yield row }
  end
end

def section(id, title, rows, note: nil)
  return if rows.empty?
  return if IGNORE.section?(id)

  puts
  puts "## #{title} (#{rows.length})"
  puts "   #{note}" if note
  puts
  emit(rows) { |row| yield row }
end

puts "# Runtime snapshot diff"
puts "  A (base):     #{label_a}   #{id_a['branch'] || '?'} @ #{(id_a['sha'] || '?')[0, 10]}"
puts "  B (zeitwerk): #{label_b}   #{id_b['branch'] || '?'} @ #{(id_b['sha'] || '?')[0, 10]}"
puts "  mode:         #{id_a['rails_env']}, eager_load=#{id_a['eager_load'].inspect}"
puts

width = counts.keys.map(&:length).max

puts "  -- semantic (drive these to zero) --"
SEMANTIC_SECTIONS.each do |key|
  suffix = IGNORE.section?(key) ? "  (ignored)" : ""
  puts format("  %-#{width}s %6d%s", key, counts[key], suffix)
end

puts
puts "  -- informational (expected to differ) --"
INFORMATIONAL_SECTIONS.each do |key|
  suffix = IGNORE.section?(key) ? "  (ignored)" : ""
  puts format("  %-#{width}s %6d%s", key, counts[key], suffix)
end

puts
puts "  semantic total: #{semantic_total}"

errors.each { |e| puts "\n!! ERROR: #{e}" }
warnings.each { |w| puts "!  warning: #{w}" }

unless errors.empty?
  puts
  puts "Refusing to report details: the snapshots are not comparable."
  exit 2
end

if options[:summary_only]
  exit(options[:exit_code] && (semantic_total.positive? || (options[:strict] && informational_total.positive?)) ? 1 : 0)
end

section("constants_missing", "Constants present in #{label_a} but missing in #{label_b}", missing,
        note: "The primary worklist: these are no longer being loaded.") do |name|
  data = CONSTANTS_A[name]
  puts "  #{name}  (#{data['origin']}, defined #{data['const_file']}:#{data['const_line']})"
end

section("constants_extra", "Constants present in #{label_b} but not in #{label_a}", extra) do |name|
  data = CONSTANTS_B[name]
  puts "  #{name}  (#{data['origin']}, defined #{data['const_file']}:#{data['const_line']})"
end

section("superclass_changes", "Superclass changes", superclass_changes) do |row|
  puts "  #{row['constant']}: #{row['a'].inspect} -> #{row['b'].inspect}"
end

section("ancestor_diffs", "Ancestor chain differences", ancestor_changes,
        note: "- only in #{label_a}, + only in #{label_b}. Order within the chain is significant.") do |row|
  puts "  #{row['constant']} (#{row['chain']}):"
  row["diff"].each { |op, value| puts "    #{op == 'del' ? '-' : '+'} #{value}" }
end

section("reopen_order_changes", "Class reopen-order changes", reopen_changes,
        note: "Classes opened by more than one file. Which definition wins depends on this order.") do |row|
  puts "  #{row['constant']}:"
  puts "    #{label_a}: #{row['a'].join(' -> ')}"
  puts "    #{label_b}: #{row['b'].join(' -> ')}"
end

section("methods_removed", "Methods defined in #{label_a} but not in #{label_b}", methods_removed) do |row|
  puts "  #{row['method']}   (was #{row['file']})"
end

section("methods_added", "Methods defined in #{label_b} but not in #{label_a}", methods_added) do |row|
  puts "  #{row['method']}   (#{row['file']})"
end

section("visibility_changes", "Method visibility changes", visibility_changes) do |row|
  puts "  #{row['method']}: #{row['a']} -> #{row['b']}"
end

section("source_diffs", "Method source differences", source_changes,
        note: "Indentation-normalized, so re-indenting a file does not appear here.") do |row|
  puts "  #{row['method']}"
  puts "    #{label_a}: #{row['file_a']}:#{row['line_a']}"
  puts "    #{label_b}: #{row['file_b']}:#{row['line_b']}"

  if options[:source_diff]
    text_a = sources_a[row["sha_a"]]
    text_b = sources_b[row["sha_b"]]

    if text_a && text_b
      lcs_diff(text_a.split("\n"), text_b.split("\n")).each do |op, line|
        marker = { same: " ", del: "-", add: "+" }[op]
        puts "      #{marker} #{line}"
      end
    else
      puts "      (source text unavailable; re-run the snapshot with SNAPSHOT_SOURCE_TEXT=1)"
    end
  end

  puts
end

section("signature_diffs", "Method signature differences", signature_changes,
        note: "Parameter lists differ. Shown for methods with no comparable source hash.") do |row|
  puts "  #{row['method']}"
  puts "    #{label_a}: (#{row['a'].join(', ')})   #{row['file_a']}"
  puts "    #{label_b}: (#{row['b'].join(', ')})   #{row['file_b']}"
end

section("method_relocations", "Methods that moved file (identical source)", relocations,
        note: "A rename the git map did not catch, or a genuine move.") do |row|
  puts "  #{row['method']}: #{row['a']} -> #{row['b']}"
end

section("files_only_a", "Files loaded in #{label_a} only", files_only_a) do |file|
  puts "  #{file}"
end

section("files_only_b", "Files loaded in #{label_b} only", files_only_b) do |file|
  puts "  #{file}"
end

section("load_order_moves", "Files that moved in load order", moved_files,
        note: "Minimal set of files that had to move. Zeitwerk eager-loads " \
              "alphabetically per root directory, so this is expected to be large; " \
              "it explains the sections above rather than being a target itself.") do |row|
  puts format("  %-70s %6d -> %6d", row["file"], row["rank_a"], row["rank_b"])
end

section("line_only_changes", "Methods that only changed line number", line_only_changes) do |row|
  puts "  #{row['method']}: #{row['file']} #{row['a']} -> #{row['b']}"
end

if OLD_TO_NEW.any?
  puts
  puts "## Rename map applied (#{OLD_TO_NEW.size})"
  puts
  emit(OLD_TO_NEW.sort) { |old_path, new_path| puts "  #{old_path} -> #{new_path}" }
end

puts
if semantic_total.zero?
  puts "No semantic differences.#{informational_total.positive? ? " (#{informational_total} informational)" : ''}"
else
  puts "#{semantic_total} semantic difference(s) remaining."
end

exit(options[:exit_code] && (semantic_total.positive? || (options[:strict] && informational_total.positive?)) ? 1 : 0)
