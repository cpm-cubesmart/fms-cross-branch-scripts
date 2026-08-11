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
  summary_only: false,
  format: "text",
  exit_code: false,
  strict: false,
  include_generated_ancestors: false,
  include_zeitwerk_shims: false,
  include_autoloader_shims: false,
  max_per_section: 100
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: compare_runtime_snapshots.rb CLASSIC.json ZEITWERK.json [options]"

  opts.on("--renames PATH", "git rename map from dump_git_renames.rb") { |v| options[:renames] = v }
  opts.on("--ignore PATH", "allowlist of triaged differences") { |v| options[:ignore] = v }
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
  opts.on("--include-autoloader-shims", "keep the load/require/const_missing rows that Dependencies.unhook! produces") do
    options[:include_autoloader_shims] = true
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
# Only when there is no extension at all: require_or_load chomps ".rb" and
# nothing else, so a path that still ends in ".rake" is already intact.
def with_extension(path)
  return path if path.nil?
  return path if File.basename(path).include?(".")

  "#{path}.rb"
end

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

KINDS = %w[constant ancestor file method section].freeze

class IgnoreList
  # Every rule that failed to parse, and every rule that never matched anything.
  # Surfaced as warnings once the comparison has run -- a rule that quietly does
  # nothing is indistinguishable from a rule doing its job, and that is the most
  # common way triage goes wrong.
  attr_reader :problems

  Rule = Struct.new(:pattern, :kind, :line, :hits)

  def initialize(path)
    @rules = Hash.new { |h, k| h[k] = [] }
    @problems = []

    return unless path && File.file?(path)

    File.readlines(path).each_with_index do |line, i|
      # A "#" opens a comment only at the start of a line or after whitespace,
      # and never when it is followed by "<". Both exclusions are load-bearing:
      # "method Widget#price" uses it as the instance-method separator, and every
      # anonymous ancestor label starts "#<anonymous module ...", so a blanket
      # strip makes those impossible to write a rule for at all.
      # (chomp first: \z will not match before the trailing newline, which is why
      # comments used to survive into the pattern and quietly kill the rule.)
      line = line.chomp.sub(/(?:\A|\s)#(?!<).*\z/, "").strip
      next if line.empty?

      kind, _, pattern = line.partition(/\s+/)
      pattern = pattern.strip

      unless KINDS.include?(kind)
        @problems << "line #{i + 1}: unknown rule kind #{kind.inspect} (expected #{KINDS.join(', ')})"
        next
      end

      if pattern.empty?
        @problems << "line #{i + 1}: #{kind} rule has no pattern"
        next
      end

      @rules[kind] << Rule.new(normalize(kind, pattern), kind, i + 1, 0)
    end
  end

  # A trailing "/**" matches exactly one directory level under FNM_PATHNAME, so
  # "vendor/**" is a synonym for "vendor/*" -- which is never what anyone writing
  # it means, and reads as though it worked. "vendor/**/*" is the recursive form.
  def normalize(kind, pattern)
    return pattern unless kind == "file"

    pattern.end_with?("/**") ? "#{pattern}/*" : pattern
  end

  def constant?(name)
    match?("constant", name, File::FNM_EXTGLOB)
  end

  # Matches a label as it appears *inside* an ancestors/singleton_ancestors chain,
  # i.e. the chain member -- unlike constant?, which matches the chain owner.
  # FNM_PATHNAME is deliberately off so "*" crosses "::".
  def ancestor?(label)
    return false if label.nil?

    match?("ancestor", label, File::FNM_EXTGLOB)
  end

  def file?(path)
    return false if path.nil?

    match?("file", path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
  end

  # "Widget#price" for instance methods, "Widget.build" for singleton methods.
  def method?(constant, kind, name)
    # Credited to the constant rule that matched, not to a method rule, or every
    # constant rule would look unused.
    return true if constant?(constant)

    match?("method", "#{constant}#{kind == 'singleton' ? '.' : '#'}#{name}", File::FNM_EXTGLOB)
  end

  def section?(id)
    match?("section", id, 0, exact: true)
  end

  def unused
    @rules.values.flatten.reject { |r| r.hits.positive? }
          .sort_by { |r| r.line }
          .map { |r| "#{r.kind} #{r.pattern}" }
  end

  private

  def match?(kind, value, flags, exact: false)
    hit = false

    @rules[kind].each do |rule|
      next unless exact ? rule.pattern == value : File.fnmatch?(rule.pattern, value, flags)

      rule.hits += 1
      hit = true
    end

    hit
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
  # ActiveSupport::Dependencies.require_or_load chomps ".rb" before expanding, so
  # classic's own load record holds extension-less paths while $LOADED_FEATURES
  # and the class-body trace hold real filenames. Left alone, every file classic
  # autoloaded contributes a twin that matches nothing on the other side -- 3,757
  # of them on this application. Restored before canonical_path, because the
  # rename map is keyed on real filenames too.
  load_order["autoloaded"] = Array(load_order["autoloaded"]).map { |f| canonical_path(with_extension(f)) }
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
resolution_changes = []
attribute_ownership_only = []

# Per-branch, NOT unioned: which methods a chain member owns is exactly what can
# differ, and unioning would hide it.
METHODS_A = (snapshot_a["ancestor_methods"] || {}).transform_values(&:to_set)
METHODS_B = (snapshot_b["ancestor_methods"] || {}).transform_values(&:to_set)

# Labels that own a different set of methods on the two branches. A constant
# whose chain never moved still resolves differently if one of its ancestors
# gained or lost a method -- that is how "Object now defines #require" surfaces,
# and filtering on "the chain changed" alone misses 2,980 of the 3,606 affected
# constants.
CHANGED_OWNERS = ((METHODS_A.keys | METHODS_B.keys).select do |label|
  METHODS_A[label] != METHODS_B[label]
end).to_set

# ActiveSupport::Dependencies.unhook! cannot un-include a module, so turning
# classic autoloading off is implemented by defining the originals directly on
# the base, shadowing the included hook:
#
#   Loadable.exclude_from(Object)            -> Object gains #load and #require
#   ModuleConstMissing.exclude_from(Module)  -> Module gains #const_missing
#
# That is the mode switch itself, seen once per class.
#
# Matched by shape, not by method name: the change must be the arrival of exactly
# that owner and nothing else. Usually it lands at the front, but a class that
# already shadows const_missing (anything descending from Delegator) sees it
# inserted mid-chain instead -- same fact, and there is no other way for Object to
# start owning #require or Module to start owning #const_missing. A class defining
# its own #require, or Object gaining some other method, still reports.
AUTOLOADER_SHIMS = { "load" => "Object", "require" => "Object", "const_missing" => "Module" }.freeze

def autoloader_shim?(method_name, owners_a, owners_b)
  shadower = AUTOLOADER_SHIMS[method_name]

  return false if shadower.nil?
  return false if owners_a.include?(shadower)
  return false unless owners_b.count(shadower) == 1

  owners_b - [shadower] == owners_a
end

# For one ancestor chain: method name => the ancestors defining it, in resolution
# order. The first entry wins the call; the rest are what `super` walks.
# Where a method the class stopped defining now comes from, or nil if nothing in
# the B-side chain defines it any more. Computed on demand rather than retained
# for every (constant, chain, method) pair, of which there are millions; there
# are only ever a handful of removals.
def still_resolves_in_b(constant, method)
  chain_key = method["kind"] == "singleton" ? "singleton_ancestors" : "ancestors"
  chain = CONSTANTS_B.dig(constant, chain_key) || []

  chain.find { |label| METHODS_B[label]&.include?(method["name"]) }
end

# Which ancestor defines the method a callback filter names. A row saying
# "update_glli_display_codes moved 5 -> 0" tells you something moved; naming the
# module that defines it tells you WHICH include point moved, which is the thing
# you actually go and change. Resolved from the chain data already in the
# snapshot -- no extra capture needed.
def filter_owner(constant, filter, constants, owned)
  return nil unless filter =~ /\A[a-z_][A-Za-z0-9_]*[?!=]?\z/

  chain = constants.dig(constant, "ancestors") || []
  owner = chain.find { |label| owned[label]&.include?(filter) }

  # The class itself is not informative -- that is where you already are.
  owner == constant ? nil : owner
end

# A class_attribute reader gains or loses its singleton definition whenever
# something assigns the attribute -- and an assignment that writes back the value
# already inherited creates ownership without changing anything. On this
# migration that produced six rows across two sections for four mailer classes
# whose effective callbacks were byte-identical.
#
# Only ever true when BOTH sides captured a comparable value and the two are
# equal. A missing capture, an unserializable value, or any difference at all
# leaves the row exactly where it was: the whole point of the section is to catch
# a callback that stopped being registered.
def inert_class_attribute?(constant, method_name)
  a = CONSTANTS_A.dig(constant, "class_attributes", method_name)
  b = CONSTANTS_B.dig(constant, "class_attributes", method_name)

  return false if a.nil? || b.nil?
  return false if a["chains"].nil? || b["chains"].nil?

  a["chains"] == b["chains"]
end

def resolution_map(chain, owned)
  map = {}

  chain.each do |label|
    names = owned[label]
    next if names.nil?

    names.each { |m| (map[m] ||= []) << label }
  end

  map
end

common.each do |name|
  a = CONSTANTS_A[name]
  b = CONSTANTS_B[name]

  if a["superclass"] != b["superclass"]
    superclass_changes << { "constant" => name, "a" => a["superclass"], "b" => b["superclass"] }
  end

  %w[ancestors singleton_ancestors].each do |key|
    list_a = a[key] || []
    list_b = b[key] || []

    # Cheap gate: a chain that is identical and contains no label whose own
    # methods moved cannot resolve anything differently.
    next if list_a == list_b && list_a.none? { |l| CHANGED_OWNERS.include?(l) }

    map_a = resolution_map(list_a, METHODS_A)
    map_b = resolution_map(list_b, METHODS_B)

    # Union, not intersection. A concern that stops being included takes its
    # methods with it, and the class then has no definition at all -- which
    # method_set_changes cannot see either, because that only compares methods a
    # class owns directly. An empty owner list is the finding.
    (map_a.keys | map_b.keys).each do |method_name|
      owners_a = map_a[method_name] || []
      owners_b = map_b[method_name] || []

      next if owners_a == owners_b
      next if IGNORE.method?(name, key == "singleton_ancestors" ? "singleton" : "instance", method_name)
      next if !options[:include_autoloader_shims] && autoloader_shim?(method_name, owners_a, owners_b)

      # The winner is what a call reaches. When it is unchanged, only `super`
      # sees the difference -- a materially weaker finding, and one that should
      # not sit next to a definition that genuinely moved or vanished.
      effect =
        if owners_b.empty? then "now undefined"
        elsif owners_a.empty? then "newly defined"
        elsif owners_a.first != owners_b.first then "winner changed"
        else "super chain only"
        end

      row = {
        "constant" => name, "chain" => key, "method" => method_name,
        "effect" => effect, "a" => owners_a, "b" => owners_b
      }

      if key == "singleton_ancestors" && inert_class_attribute?(name, method_name)
        attribute_ownership_only << row
      else
        resolution_changes << row
      end
    end
  end
end

# One row per distinct change rather than per affected class. The same fact --
# "Object now defines #require, shadowing Dependencies::Loadable" -- is inherited
# by every class in the application, and listing it 4,000 times is what made the
# old ancestors section unreadable. 20,423 pairs collapse to 13 rows.
resolution_super_only, resolution_changes =
  resolution_changes.partition { |r| r["effect"] == "super chain only" }

group_resolution = lambda do |rows|
  rows.group_by { |r| [r["chain"], r["method"], r["a"], r["b"]] }
      .map do |(chain, method_name, owners_a, owners_b), group|
        {
          "method" => method_name, "chain" => chain,
          "effect" => group.first["effect"],
          "a" => owners_a, "b" => owners_b,
          "classes" => group.length,
          "examples" => group.first(3).map { |r| r["constant"] }.sort
        }
      end.sort_by { |r| [-r["classes"], r["method"]] }
end

resolution_changes = group_resolution.call(resolution_changes)
resolution_super_only = group_resolution.call(resolution_super_only)

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

# Reopen order is no longer a section of its own: a class opened by several files
# is normal in a namespaced app, and if the end state matches it is not a finding.
# It is kept as context, attached to classes that DO have a real finding, because
# it is the usual explanation for which definition won.
REOPENED = {}

(sites_a.keys | sites_b.keys).each do |name|
  list_a = sites_a[name]
  list_b = sites_b[name]

  next unless list_a.uniq.length > 1 || list_b.uniq.length > 1
  next if list_a == list_b

  REOPENED[name] = { "a" => list_a, "b" => list_b }
end

# ---------------------------------------------------------------------------
# Sections 6/7/8/11: methods
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Constant values
#
# The snapshot records constants that are Modules or Classes as constants in
# their own right; this covers the rest -- LIMIT = 50, KINDS = %w[...] -- whose
# value can change when load order changes which assignment ran last.
#
# Only simple values carry a digest. Anything else records its kind and no
# digest, and a pair where either side is uncomparable is NOT reported as a
# difference: saying nothing is correct, inventing one is not.
# ---------------------------------------------------------------------------

constant_value_changes = []

common.each do |name|
  values_a = CONSTANTS_A[name]["values"] || {}
  values_b = CONSTANTS_B[name]["values"] || {}

  (values_a.keys | values_b.keys).sort.each do |const|
    label = "#{name}::#{const}"
    next if IGNORE.constant?(label)

    va = values_a[const]
    vb = values_b[const]

    if va.nil? || vb.nil?
      constant_value_changes << {
        "constant" => label, "status" => va.nil? ? "only_in_b" : "only_in_a",
        "a" => va && va["kind"], "b" => vb && vb["kind"]
      }
      next
    end

    next if va["sha"].nil? || vb["sha"].nil?
    next if va["sha"] == vb["sha"]

    constant_value_changes << {
      "constant" => label, "status" => "changed",
      "a" => va["kind"], "b" => vb["kind"]
    }
  end
end

# ---------------------------------------------------------------------------
# Class attribute values
#
# What `included do ... end` did. Registering a callback, composing a
# default_scope and declaring a validation all leave the ancestor chain and the
# method list untouched, so nothing else in this report can see them stop
# happening.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Associations
#
# Membership first: an association that arrives or vanishes changes what queries
# return and what STI/descendants-driven code sees. Option changes are reported
# too -- a `dependent:` or `class_name:` that moved is a behaviour change -- but
# an option whose value would not serialize is recorded by kind, never guessed at.
# ---------------------------------------------------------------------------

association_changes = []

common.each do |name|
  assoc_a = CONSTANTS_A[name]["associations"] || {}
  assoc_b = CONSTANTS_B[name]["associations"] || {}

  next if assoc_a == assoc_b

  (assoc_a.keys | assoc_b.keys).sort.each do |assoc|
    a = assoc_a[assoc]
    b = assoc_b[assoc]

    next if a == b
    next if IGNORE.method?(name, "instance", assoc)

    if a.nil? || b.nil?
      association_changes << {
        "constant" => name, "association" => assoc,
        "status" => a.nil? ? "added" : "removed",
        "macro" => (a || b)["macro"]
      }
      next
    end

    details = []
    details << "#{a['macro']} -> #{b['macro']}" if a["macro"] != b["macro"]

    opts_a = a["options"] || {}
    opts_b = b["options"] || {}

    (opts_a.keys | opts_b.keys).sort.each do |opt|
      next if opts_a[opt] == opts_b[opt]

      details << "#{opt}: #{opts_a.fetch(opt, '(absent)')} -> #{opts_b.fetch(opt, '(absent)')}"
    end

    association_changes << {
      "constant" => name, "association" => assoc,
      "status" => "changed", "macro" => a["macro"], "details" => details
    }
  end
end

# Membership and ordering are graded differently, on purpose. A callback that
# stops being registered changes what runs; a callback that runs at a different
# point in the chain usually does not, and there are nine of those on this
# migration against one real removal. Ordering goes informational so the removal
# is visible.
class_attribute_changes = []
class_attribute_order_only = []

common.each do |name|
  attrs_a = CONSTANTS_A[name]["class_attributes"] || {}
  attrs_b = CONSTANTS_B[name]["class_attributes"] || {}

  (attrs_a.keys | attrs_b.keys).sort.each do |attr|
    va = attrs_a[attr]
    vb = attrs_b[attr]

    next if va.nil? || vb.nil?

    chains_a = va["chains"]
    chains_b = vb["chains"]

    next if chains_a.nil? || chains_b.nil? || chains_a == chains_b
    next if IGNORE.method?(name, "singleton", attr)

    membership = []
    reordered = []

    (chains_a.keys | chains_b.keys).sort.each do |chain|
      list_a = chains_a[chain] || []
      list_b = chains_b[chain] || []

      next if list_a == list_b

      gone = list_a - list_b
      arrived = list_b - list_a

      owners = {}
      (gone | arrived | list_a).each do |filter|
        owner = filter_owner(name, filter, CONSTANTS_A, METHODS_A) ||
                filter_owner(name, filter, CONSTANTS_B, METHODS_B)
        owners[filter] = owner if owner
      end

      if gone.empty? && arrived.empty?
        reordered << { "chain" => chain, "a" => list_a, "b" => list_b, "owners" => owners }
      else
        membership << { "chain" => chain, "removed" => gone, "added" => arrived, "owners" => owners }
      end
    end

    row = { "constant" => name, "attribute" => attr }

    class_attribute_changes << row.merge("chains" => membership) if membership.any?
    class_attribute_order_only << row.merge("chains" => reordered) if membership.empty? && reordered.any?
  end
end

# One row per class, not per method. What you act on is "this class does not have
# the same methods on both branches" -- the individual names are the detail, and
# reading them together is what tells you whether a decorator failed to load or a
# single definition moved.
#
# Method bodies are compared by the digest of their compiled instruction
# sequence, not by source text. That is what makes a dynamically defined accessor
# comparable at all -- 13% of methods had no source digest, including every one of
# FacilitySettings' 626 generated accessors -- and it drops the dependence on
# source_location that produced two thirds of the body changes this section used
# to report. Formatting, comments, file moves and namespacing do not register.
#
# Printing the source diff was tried and removed: the same information is in the
# pull request, in a better renderer.
method_set_changes = []
visibility_changes = []
signature_changes = []

common.each do |name|
  by_key_a = CONSTANTS_A[name].fetch("methods", []).to_h { |m| [method_key(m), m] }
  by_key_b = CONSTANTS_B[name].fetch("methods", []).to_h { |m| [method_key(m), m] }

  removed = []
  added = []
  changed = []

  (by_key_a.keys - by_key_b.keys).sort.each do |key|
    m = by_key_a[key]
    next if IGNORE.method?(name, m["kind"], m["name"])

    # "This class stopped defining it" and "this method is gone" are very
    # different findings, and a bare "-" reads as the second. Five of the six
    # removals on the real application are the first: a class_attribute writer
    # that stopped running, so the reader is no longer defined on that singleton
    # while the parent's still answers the call.
    provider = still_resolves_in_b(name, m)

    entry = {
      "method" => method_label(name, m), "file" => m["file"], "line" => m["line"],
      "inherited_from" => provider
    }

    if m["kind"] == "singleton" && inert_class_attribute?(name, m["name"])
      # Bare method name, matching what the resolution pass records, so the two
      # views of one ownership change collapse to a single row.
      attribute_ownership_only << { "constant" => name, "method" => m["name"], "effect" => "no longer owns" }
    else
      removed << entry
    end
  end

  (by_key_b.keys - by_key_a.keys).sort.each do |key|
    m = by_key_b[key]
    next if IGNORE.method?(name, m["kind"], m["name"])

    added << { "method" => method_label(name, m), "file" => m["file"], "line" => m["line"] }
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

    if a["body_sha"] && b["body_sha"] && a["body_sha"] != b["body_sha"]
      changed << {
        "method" => label,
        "file_a" => a["file"], "line_a" => a["line"], "sha_a" => a["body_sha"],
        "file_b" => b["file"], "line_b" => b["line"], "sha_b" => b["body_sha"]
      }
    elsif a["params"] != b["params"]
      # Reached when there is no source hash to compare (native/gem methods).
      # A changed arity there still means a different definition won.
      signature_changes << {
        "method" => label, "a" => a["params"], "b" => b["params"],
        "file_a" => a["file"], "file_b" => b["file"]
      }
    end
  end

  next if removed.empty? && added.empty? && changed.empty?

  method_set_changes << {
    "constant" => name,
    "opened_by" => REOPENED[name],
    "removed" => removed,
    "added" => added,
    "changed" => changed
  }
end

# Fed from two places -- the resolution pass and the method-set pass -- which see
# the same ownership change from different angles. One row per fact.
attribute_ownership_only = attribute_ownership_only
                           .group_by { |r| [r["constant"], r["method"]] }
                           .map { |(constant, method_name), rows| { "constant" => constant, "method" => method_name, "effect" => rows.first["effect"] } }
                           .sort_by { |r| [r["constant"], r["method"]] }

# ---------------------------------------------------------------------------
# Sections 9/10: files
# ---------------------------------------------------------------------------

# No single signal sees a file load on both branches.
#
#   $LOADED_FEATURES  gems and explicit requires -- but classic autoloads with
#                     Kernel#load, which never registers there, so on the classic
#                     branch this is missing essentially the whole application
#   class_bodies      anything that executed a class or module keyword, however it
#                     was loaded -- but blind to a file that only does
#                     Foo.class_eval { ... } or define_method
#   autoloaded        classic's own require_or_load record, which is the only
#                     signal that sees that last category on the classic side
#
# Comparing any one of them compares the autoloader rather than the application:
# on this migration $LOADED_FEATURES alone reported 3,747 files as "zeitwerk only"
# while 99% of them had demonstrably executed on main.
def loaded_file_set(snapshot)
  order = snapshot.fetch("load_order", {})

  files = Array(order["files"]).to_set
  files.merge(Array(order["autoloaded"]))
  files.merge(Array(order["class_bodies"]).map { |e| e["file"] }.compact)
  files
end

set_a = loaded_file_set(snapshot_a)
set_b = loaded_file_set(snapshot_b)

files_only_a = (set_a - set_b).reject { |f| IGNORE.file?(f) }.sort
files_only_b = (set_b - set_a).reject { |f| IGNORE.file?(f) }.sort

# ---------------------------------------------------------------------------
# Counts and exit status
# ---------------------------------------------------------------------------

counts = {
  "constants_missing" => missing.length,
  "constants_extra" => extra.length,
  "superclass_changes" => superclass_changes.length,
  "constant_value_changes" => constant_value_changes.length,
  "association_changes" => association_changes.length,
  "class_attribute_changes" => class_attribute_changes.length,
  "class_attribute_order_only" => class_attribute_order_only.length,
  "resolution_super_only" => resolution_super_only.length,
  "attribute_ownership_only" => attribute_ownership_only.length,
  "resolution_order_changes" => resolution_changes.length,
  "method_set_changes" => method_set_changes.length,
  "visibility_changes" => visibility_changes.length,
  "signature_diffs" => signature_changes.length,
  "files_only_a" => files_only_a.length,
  "files_only_b" => files_only_b.length
}

# Semantic sections describe the runtime state itself, which is what has to
# match. The informational ones describe the mechanism that produced it, and are
# expected to differ: Zeitwerk eager-loads alphabetically per root directory, so
# its file set and ordering will never match classic's require order.
#
# Deliberately absent: reopen order (normal in a namespaced app, and only matters
# through the method-set change it causes -- so it is attached there as context),
# whole-chain ancestor reordering (superseded by per-method resolution order),
# line-number-only moves, load-order moves, and methods that changed file with an
# identical body. Each described a mechanism rather than an outcome.
SEMANTIC_SECTIONS = %w[
  constants_missing constants_extra superclass_changes constant_value_changes
  association_changes class_attribute_changes
  resolution_order_changes method_set_changes visibility_changes signature_diffs
].freeze

# Ordering, as opposed to membership. A callback that runs at a different point
# in a chain, or a definition that moved below the one that already won, is a
# real difference that is very unlikely to be a regression -- and there are an
# order of magnitude more of them. Keeping them out of the semantic total is what
# lets the membership changes be seen.
INFORMATIONAL_SECTIONS = %w[
  class_attribute_order_only resolution_super_only attribute_ownership_only
  files_only_a files_only_b
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
EXPECTED_SCRIPT_VERSION = 12

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

# Without classic's own load record the file sections lose their only view of a
# file that monkey-patches and never executes a class body -- and they degrade
# silently, reporting a clean comparison of an incomplete set.
[[id_a, snapshot_a, label_a], [id_b, snapshot_b, label_b]].each do |id, snapshot, label|
  next if id["zeitwerk_enabled"]
  next if snapshot.dig("counts", "autoloaded").to_i.positive?

  warnings << "#{label}: classic autoloader, but no ActiveSupport::Dependencies.history " \
              "was captured. Files it loaded with Kernel#load are invisible, so the " \
              "files_only_* sections under-report. Re-snapshot with script version 12+."
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

# Every IGNORE predicate has run by now -- section? last, in semantic_total just
# above -- so the hit counts are final.
IGNORE.problems.each { |p| warnings << "ignore list: #{p}" }

unused_rules = IGNORE.unused

unless unused_rules.empty?
  warnings << "ignore list: #{unused_rules.length} rule(s) matched nothing: " \
              "#{unused_rules.join(', ')}"
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
    "constant_value_changes" => constant_value_changes,
    "association_changes" => association_changes,
    "class_attribute_changes" => class_attribute_changes,
    "class_attribute_order_only" => class_attribute_order_only,
    "resolution_super_only" => resolution_super_only,
    "attribute_ownership_only" => attribute_ownership_only,
    "resolution_order_changes" => resolution_changes,
    "method_set_changes" => method_set_changes,
    "visibility_changes" => visibility_changes,
    "signature_diffs" => signature_changes,
    "files_only_a" => files_only_a,
    "files_only_b" => files_only_b
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

# Every id the report actually rendered. A section can be counted in the header
# and have no renderer at all -- that happened to constant_value_changes, which
# spent four versions reporting a number nobody could look at. Checked at the end
# rather than against a hand-kept manifest, because a manifest is exactly as easy
# to forget as the renderer was.
RENDERED_SECTIONS = Set.new

def section(id, title, rows, note: nil)
  RENDERED_SECTIONS << id
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

# An anonymous module has no name to look up, so say what it does. Named modules
# are left alone -- you can go read them.
render_resolution = lambda do |row|
  arrow = row["chain"] == "singleton_ancestors" ? "." : "#"

  puts "  #{arrow}#{row['method']}   #{row['classes']} class#{row['classes'] == 1 ? '' : 'es'}   [#{row['effect']}]"
  puts "       #{row['a'].empty? ? '(not defined)' : row['a'].join(' -> ')}"
  puts "    => #{row['b'].empty? ? '(not defined)' : row['b'].join(' -> ')}"
  puts "       e.g. #{row['examples'].join(', ')}"
end

section("resolution_order_changes", "Method resolution changed", resolution_changes,
        note: "For one method name, the ancestors that define it, in the order Ruby " \
              "consults them. The first entry wins the call. Everything here changes which " \
              "definition a call reaches, or removes it entirely. Grouped by the change " \
              "itself, because a change inherited from a shared ancestor is one fact, not " \
              "one per subclass -- the count is how many classes see it.") do |row|
  render_resolution.call(row)
end

def owner_note(chain_row, filter)
  owner = (chain_row["owners"] || {})[filter]
  owner ? "   (defined by #{owner})" : ""
end

section("constant_value_changes", "Constants whose value differs", constant_value_changes,
        note: "Compared by digest, and only for simple values -- strings, symbols, " \
              "numbers, booleans, nil, and arrays/hashes/sets of those. A constant " \
              "holding anything else records its kind and is never reported as changed. " \
              "Absolute paths are normalized, so a Rails.root.join(...) constant does not " \
              "differ merely because the checkouts sit at different paths.") do |row|
  case row["status"]
  when "only_in_a" then puts "  - #{row['constant']}   (#{row['a']}, only in #{label_a})"
  when "only_in_b" then puts "  + #{row['constant']}   (#{row['b']}, only in #{label_b})"
  else                  puts "  ~ #{row['constant']}   (#{row['a']})"
  end
end

section("association_changes", "Associations differ", association_changes,
        note: "A lost or gained association changes what queries return, and is invisible " \
              "to every other section -- the reader methods live in " \
              "GeneratedAssociationMethods, which is collapsed as a timing artifact.") do |row|
  case row["status"]
  when "removed" then puts "  - #{row['constant']} #{row['macro']} :#{row['association']}"
  when "added"   then puts "  + #{row['constant']} #{row['macro']} :#{row['association']}"
  else
    puts "  ~ #{row['constant']} #{row['macro']} :#{row['association']}"
    row["details"].each { |d| puts "      #{d}" }
  end
end

section("class_attribute_changes", "Class attribute membership changed", class_attribute_changes,
        note: "What an `included do` block did -- callbacks, validations, default scopes. " \
              "These leave the ancestor chain and the method list untouched, so no other " \
              "section can see one stop happening. Only entries that arrived or vanished " \
              "are here; ones that merely moved are in class_attribute_order_only.") do |row|
  puts "  #{row['constant']}.#{row['attribute']}"

  row["chains"].each do |c|
    c["removed"].each { |f| puts "    #{c['chain']}: - #{f}#{owner_note(c, f)}" }
    c["added"].each   { |f| puts "    #{c['chain']}: + #{f}#{owner_note(c, f)}" }
  end
end

section("class_attribute_order_only", "Class attribute ordering changed", class_attribute_order_only,
        note: "Same entries, different order. after_commit and friends run in registration " \
              "order, so this can matter -- but it is usually one module being included at a " \
              "different point, and it is not where a regression normally hides.") do |row|
  puts "  #{row['constant']}.#{row['attribute']}"

  row["chains"].each do |c|
    # Name what actually moved rather than printing both lists in full.
    moved = c["a"].reject.with_index { |f, i| c["b"][i] == f }
    moved = c["a"] if moved.empty?

    moved.first(3).each do |f|
      # A position only means something when the label appears once on each side.
      # Non-symbol filters are recorded by class, so several can share a label and
      # index() would report the same slot for all of them.
      if c["a"].count(f) == 1 && c["b"].count(f) == 1
        puts "    #{c['chain']}: #{f}  #{c['a'].index(f)} -> #{c['b'].index(f)}#{owner_note(c, f)}"
      else
        puts "    #{c['chain']}: #{c['a'].count(f)} x #{f} reordered#{owner_note(c, f)}"
      end
    end

    puts "    #{c['chain']}: ... and #{moved.length - 3} more" if moved.length > 3
  end
end

section("resolution_super_only", "Method resolution order below the winner changed", resolution_super_only,
        note: "The same definition still wins the call. Only what `super` walks moved, so " \
              "this is inert unless the winning definition calls super.") do |row|
  render_resolution.call(row)
end

section("method_set_changes", "Classes whose methods differ", method_set_changes,
        note: "- only in #{label_a}, + only in #{label_b}, ~ same method, different body. " \
              "Bodies are compared by the digest of their compiled instruction sequence, so " \
              "comments, formatting, file moves and namespacing do not count -- only a change " \
              "in what the method does. Read the change itself on the pull request.") do |row|
  puts "  #{row['constant']}"

  row["removed"].each do |m|
    puts "    - #{m['method']}   (was #{m['file']}:#{m['line']})"
    puts "        still resolves, now inherited from #{m['inherited_from']}" if m["inherited_from"]
  end
  row["added"].each   { |m| puts "    + #{m['method']}   (#{m['file']}:#{m['line']})" }

  # One generator produces hundreds of accessors, and a change to it changes
  # every one of their bodies. Listing them individually buried FacilitySettings'
  # real finding under 622 rows; they collapse to the two define_method sites
  # that produced them.
  row["changed"].group_by { |m| [m["file_a"], m["line_a"], m["file_b"], m["line_b"]] }
                .each do |(file_a, line_a, file_b, line_b), group|
    where = file_a == file_b ? "#{file_a}:#{line_a} -> :#{line_b}" : "#{file_a}:#{line_a} -> #{file_b}:#{line_b}"

    if group.length == 1
      puts "    ~ #{group.first['method']}   (#{where})"
    else
      puts "    ~ #{group.length} methods defined at #{where}"
      puts "        #{group.first(4).map { |m| m['method'].split(/[#.]/, 2).last }.join(', ')}#{group.length > 4 ? ', ...' : ''}"
    end
  end

  # Reopen order is not a finding on its own, but when a class does have one it
  # is usually the explanation: it says which file's definition ran last.
  opened = row["opened_by"]
  next if opened.nil?

  puts "      opened by #{label_a}: #{opened['a'].join(' -> ')}"
  puts "      opened by #{label_b}: #{opened['b'].join(' -> ')}"
end

section("visibility_changes", "Method visibility changes", visibility_changes) do |row|
  puts "  #{row['method']}: #{row['a']} -> #{row['b']}"
end

section("signature_diffs", "Method signature differences", signature_changes,
        note: "Parameter lists differ. Shown for methods with no comparable source hash.") do |row|
  puts "  #{row['method']}"
  puts "    #{label_a}: (#{row['a'].join(', ')})   #{row['file_a']}"
  puts "    #{label_b}: (#{row['b'].join(', ')})   #{row['file_b']}"
end


section("attribute_ownership_only", "Class attribute ownership changed, value did not",
        attribute_ownership_only,
        note: "A class_attribute reader stopped (or started) being defined on this class's " \
              "own singleton, while the value it resolves to is byte-identical on both " \
              "branches. An assignment that wrote back the value already inherited creates " \
              "ownership without changing behaviour. Listed rather than dropped -- if the " \
              "value ever does differ, it appears in class_attribute_changes instead.") do |row|
  puts "  #{row['constant']}.#{row['method']}   (#{row['effect']})"
end

section("files_only_a", "Files loaded in #{label_a} only", files_only_a) do |file|
  puts "  #{file}"
end

section("files_only_b", "Files loaded in #{label_b} only", files_only_b) do |file|
  puts "  #{file}"
end


if OLD_TO_NEW.any?
  puts
  puts "## Rename map applied (#{OLD_TO_NEW.size})"
  puts
  emit(OLD_TO_NEW.sort) { |old_path, new_path| puts "  #{old_path} -> #{new_path}" }
end

# A section that is counted but never rendered means the report is lying about
# what it contains -- a bug in this script, not a finding about the application.
unrendered = (SEMANTIC_SECTIONS + INFORMATIONAL_SECTIONS).reject { |id| RENDERED_SECTIONS.include?(id) }

unless unrendered.empty?
  puts
  puts "!! BUG in compare_runtime_snapshots.rb: #{unrendered.join(', ')} " \
       "#{unrendered.length == 1 ? 'is' : 'are'} counted in the header but never rendered."
  puts "   Any findings there are invisible. Add the missing section(...) call."
end

puts
if semantic_total.zero?
  puts "No semantic differences.#{informational_total.positive? ? " (#{informational_total} informational)" : ''}"
else
  puts "#{semantic_total} semantic difference(s) remaining."
end

exit(options[:exit_code] && (semantic_total.positive? || (options[:strict] && informational_total.positive?)) ? 1 : 0)
