# runtime-snapshot/script/dump_runtime_snapshot.rb
# frozen_string_literal: true
#
# Captures the runtime state of a booted Rails application so that two branches
# (classic autoloader vs Zeitwerk) can be compared. Run via bin/snapshot, or
# directly:
#
#   RUBYOPT="-r/abs/path/runtime-snapshot/script/preboot_trace.rb" \
#   SNAPSHOT_OUT=snapshots/main-eager.json \
#   DISABLE_SPRING=1 bin/rails runner /abs/path/runtime-snapshot/script/dump_runtime_snapshot.rb
#
# WHAT IT CAPTURES
#
#   1. the order files were loaded            (load_order.files, load_order.class_bodies)
#   2. which classes/modules exist            (constants)
#   3. ancestors, in order                    (constants.*.ancestors)
#   4. methods defined directly on each       (constants.*.methods)
#   5. the source text of those methods       (source_sha + sources sidecar)
#
# TWO INVARIANTS THIS SCRIPT MUST UPHOLD
#
#   * It must never trigger an autoload. In non-eager mode the whole point is to
#     observe what boot alone loaded; a snapshot that loads things while looking
#     at them measures itself. Hence enumeration via ObjectSpace rather than
#     const_get/constantize, and hence the note on const_source_location below.
#
#   * It must be deterministic. Two runs against an unchanged checkout must
#     produce byte-identical output outside the "meta" block, or `diff` on the
#     raw snapshots is worthless and the comparator's "no differences" result
#     cannot be trusted. That means: no object ids, no timestamps, no
#     ObjectSpace iteration order leaking into the output, sorted hash keys.

# Captured before this script requires anything, so that files pulled in by the
# snapshot machinery itself are not misreported as part of the application's
# boot. Paired with the preboot baseline, this brackets the boot exactly.
POST_BOOT_FEATURES = $LOADED_FEATURES.dup

require "json"
require "digest"
require "rbconfig"
require "time"
require "socket"
require "fileutils"

# ---------------------------------------------------------------------------
# Stop tracing immediately.
#
# The TracePoints installed by preboot_trace.rb are still live. Everything from
# here on is this script's own doing, not the application's boot, and must not
# pollute the trace.
# ---------------------------------------------------------------------------

TRACE = defined?($FMS_SNAPSHOT_TRACE) ? $FMS_SNAPSHOT_TRACE : nil

if TRACE
  Array(TRACE[:tracepoints]).each do |tp|
    begin
      tp.disable
    rescue StandardError
      nil
    end
  end
end

TRACE_INSTALLED = !TRACE.nil?

unless TRACE_INSTALLED
  warn <<~WARNING
    [snapshot] WARNING: preboot_trace.rb was not loaded.

    Load-order data (load_order.files, load_order.class_bodies) will be empty or
    incomplete, because a runner script starts after boot has already finished.
    Re-run with:

      RUBYOPT="-r<path>/runtime-snapshot/script/preboot_trace.rb"

    Constant, ancestor and method data below are still valid.
  WARNING
end

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

# 2: namespace closure -- namespaces Zeitwerk autovivifies are recorded rather
#    than dropped for owning no methods and no application-side definition site.
SCRIPT_VERSION = 2

OUT_PATH        = ENV["SNAPSHOT_OUT"]
SOURCES_PATH    = ENV["SNAPSHOT_SOURCES_OUT"]
LABEL           = ENV["SNAPSHOT_LABEL"] || "snapshot"
CAPTURE_SOURCES = ENV.fetch("SNAPSHOT_SOURCE_TEXT", "1") == "1"
INCLUDE_ANON    = ENV.fetch("SNAPSHOT_INCLUDE_ANONYMOUS", "0") == "1"

ROOT = Rails.root.to_s.freeze
ROOT_PREFIX = "#{ROOT}/"

# ---------------------------------------------------------------------------
# Safe introspection
#
# Application and gem code overrides `name`, `==`, `respond_to?`, `hash` and
# friends more often than you would hope -- this repo's earlier script carries a
# comment about REXML::Functions defining its own `name`. Dispatching normally
# means a single hostile class can crash the dump or silently corrupt it. Every
# reflective call below goes through an unbound method bound to the target, so
# we always get Ruby's implementation regardless of what the class did.
# ---------------------------------------------------------------------------

UM_NAME         = Module.instance_method(:name)
UM_ANCESTORS    = Module.instance_method(:ancestors)
UM_INSPECT      = Module.instance_method(:inspect)
UM_INSTANCE_METHODS   = Module.instance_method(:instance_methods)
UM_PRIVATE_METHODS    = Module.instance_method(:private_instance_methods)
UM_PROTECTED_METHODS  = Module.instance_method(:protected_instance_methods)
UM_INSTANCE_METHOD    = Module.instance_method(:instance_method)
UM_SINGLETON_CLASS    = ::Kernel.instance_method(:singleton_class)
UM_IS_A               = ::Kernel.instance_method(:is_a?)
UM_SUPERCLASS         = Class.instance_method(:superclass)

def safe(default = nil)
  yield
rescue Exception # rubocop:disable Lint/RescueException
  default
end

def mod_name(mod)
  safe { UM_NAME.bind(mod).call }
end

def mod_class?(mod)
  safe(false) { UM_IS_A.bind(mod).call(Class) }
end

def mod_inspect(mod)
  safe("#<unknown>") { UM_INSPECT.bind(mod).call }
end

def mod_singleton_class(mod)
  safe { UM_SINGLETON_CLASS.bind(mod).call }
end

# ---------------------------------------------------------------------------
# Path normalization
#
# The two checkouts live at different absolute paths (~/code/fms vs a worktree),
# and gems resolve through version- and machine-specific directories. Without
# canonicalization every single path differs and the diff is 100% noise.
#
# Order matters: gems are checked BEFORE the Rails.root check, because an app
# that vendors its bundle (vendor/bundle/...) would otherwise have every gem
# file classified as application code -- which would drag the entire dependency
# tree into the "app constants" scope.
# ---------------------------------------------------------------------------

# Matches .../gems/<name>-<version>/rest and .../bundler/gems/<name>-<sha>/rest.
# The `-<digit>` requirement keeps a legitimate app directory named "gems"
# (app/gems/foo/bar.rb) from being mistaken for a gem root.
GEM_PATH_RE = %r{\A.*/(?:bundler/)?gems/([^/]+-[0-9a-f][^/]*)/(.*)\z}.freeze

RUBY_PREFIXES = [
  RbConfig::CONFIG["rubylibdir"],
  RbConfig::CONFIG["sitelibdir"],
  RbConfig::CONFIG["vendorlibdir"],
  RbConfig::CONFIG["libdir"],
  RbConfig::CONFIG["prefix"]
].compact.reject(&:empty?).uniq.sort_by { |p| -p.length }.freeze

NORMALIZED_PATH_CACHE = {}

def normalize_path(path)
  return nil if path.nil?

  key = path.to_s
  return nil if key.empty?

  return NORMALIZED_PATH_CACHE[key] if NORMALIZED_PATH_CACHE.key?(key)

  NORMALIZED_PATH_CACHE[key] = compute_normalized_path(key)
end

def compute_normalized_path(path)
  # Ruby reports a range of things that are not files in source_location and
  # const_source_location, and every one of them has to be fenced off before
  # File.expand_path gets hold of it -- expanding a non-path yields
  # "#{Dir.pwd}/<thing>", which under Rails.root then looks exactly like
  # application code and drags core into the app scope:
  #
  #   "(eval)", "(irb)"     eval'd code
  #   "<internal:pack>"     core methods implemented in Ruby (2.7+)
  #   "ruby", 0             constants defined by the interpreter prelude
  #   "-e"                  code from the command line
  #
  # The general rule: a real source file is always absolute here, because Rails
  # requires everything by absolute path. Anything relative that does not exist
  # on disk is a pseudo-location.
  return "<pseudo:#{path}>" if path.start_with?("(", "<") || path == "-e"

  absolute =
    if path.start_with?("/")
      path
    else
      expanded = safe { File.expand_path(path) }
      return "<pseudo:#{path}>" if expanded.nil? || !safe(false) { File.file?(expanded) }

      expanded
    end

  if (match = GEM_PATH_RE.match(absolute))
    return "<gems>/#{match[1]}/#{match[2]}"
  end

  RUBY_PREFIXES.each do |prefix|
    return "<ruby>/#{absolute[(prefix.length + 1)..]}" if absolute.start_with?("#{prefix}/")
  end

  return absolute[ROOT_PREFIX.length..] if absolute.start_with?(ROOT_PREFIX)

  absolute
end

def app_path?(normalized)
  return false if normalized.nil?

  !normalized.start_with?("/", "<", "(")
end

# Object addresses are re-randomized every run. Anything derived from `inspect`
# must have them scrubbed or the snapshot is nondeterministic.
def normalize_anonymous(text)
  return text if text.nil?

  text
    .gsub(/#<Class:0x[0-9a-fA-F]+>/, "#<Class:ANONYMOUS>")
    .gsub(/#<Module:0x[0-9a-fA-F]+>/, "#<Module:ANONYMOUS>")
    .gsub(/0x[0-9a-fA-F]{6,}/, "0xANON")
end

# ---------------------------------------------------------------------------
# Source extraction
# ---------------------------------------------------------------------------

FILE_LINES_CACHE = {}
MAX_SOURCE_FILE_BYTES = 4 * 1024 * 1024

def file_lines(absolute_path)
  return FILE_LINES_CACHE[absolute_path] if FILE_LINES_CACHE.key?(absolute_path)

  lines =
    safe do
      if File.file?(absolute_path) && File.size(absolute_path) <= MAX_SOURCE_FILE_BYTES
        File.readlines(absolute_path)
      end
    end

  FILE_LINES_CACHE[absolute_path] = lines
end

# ---------------------------------------------------------------------------
# Locating a method's source range
#
# RubyVM::AbstractSyntaxTree.of(method) is exact but re-parses the entire file
# on every call -- measured at ~3.4ms per method on a 15KB file, which over a
# large application's method count runs to several minutes, every snapshot.
# Since this tool is meant to be re-run in a tight loop, that cost matters.
#
# Instead each file is parsed once and every definition node indexed by its
# starting line, which is the same line a method's source_location reports.
# Measured 100x faster with zero range mismatches over a 400-method file.
#
# The one case the index cannot resolve is two definitions starting on the same
# line ("def one; end; def two; end"), where the line is ambiguous. Those fall
# back to the slow exact call rather than guessing.
# ---------------------------------------------------------------------------

DEF_NODE_TYPES = %i[DEFN DEFS ITER].freeze

AST_INDEX_CACHE = {}

def collect_def_ranges(node, out)
  return unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

  if DEF_NODE_TYPES.include?(node.type)
    (out[node.first_lineno] ||= []) << [node.first_lineno, node.last_lineno]
  end

  node.children.each { |child| collect_def_ranges(child, out) }
end

# Returns { starting_line => [[first, last], ...] }. Only line ranges are kept,
# never Node objects, so the parsed tree can be collected immediately -- holding
# a full AST per application file would be a lot of resident memory for nothing.
def ast_index(absolute_path)
  return AST_INDEX_CACHE[absolute_path] if AST_INDEX_CACHE.key?(absolute_path)

  index =
    safe do
      next nil unless File.file?(absolute_path)
      next nil if File.size(absolute_path) > MAX_SOURCE_FILE_BYTES

      out = {}
      collect_def_ranges(RubyVM::AbstractSyntaxTree.parse_file(absolute_path), out)
      out
    end

  AST_INDEX_CACHE[absolute_path] = index
end

def source_range_for(unbound_method, absolute_path, line)
  index = ast_index(absolute_path)

  if index && line
    candidates = index[line]
    return candidates.first if candidates && candidates.length == 1
  end

  node = safe { RubyVM::AbstractSyntaxTree.of(unbound_method) }

  node && [node.first_lineno, node.last_lineno]
end

# Strip the common indentation and trailing whitespace before hashing.
#
# This matters more than it looks. A very common Zeitwerk change is wrapping a
# previously top-level class in a module namespace, which re-indents every line
# of the file without changing a single token of logic. Hashing raw text would
# report every method in the file as "source changed" and bury the handful of
# real changes.
def normalize_source(text)
  lines = text.split("\n", -1)
  lines.pop while lines.any? && lines.last.strip.empty?

  indents =
    lines.reject { |line| line.strip.empty? }
         .map { |line| line[/\A[ \t]*/].length }

  dedent = indents.min || 0

  lines
    .map { |line| line.strip.empty? ? "" : line[dedent..].to_s.rstrip }
    .join("\n") + "\n"
end

SOURCE_TEXTS = {}

# Returns [source_kind, source_sha]. source_kind explains *why* there is no sha
# when there isn't one, so a missing hash is never ambiguous:
#
#   "ruby"      -> extracted, hashed
#   "native"    -> C function, no Ruby source exists
#   "generated" -> attr_accessor / Struct / similar; a real source_location but
#                  no AST node, so there is nothing to extract
#   "eval"      -> defined in eval'd code, source not on disk
#   "internal"  -> core method implemented in Ruby rather than C
#                  ("<internal:pack>"), so there is no file to read
#   "gem"       -> real Ruby source, but outside Rails.root so we deliberately
#                  skip hashing it (same Gemfile.lock => same bytes)
#   "unreadable"-> file went missing or is too large
def method_source(unbound_method, normalized_file)
  location = safe { unbound_method.source_location }

  return ["native", nil] if location.nil?

  absolute, line = location

  return ["eval", nil] if absolute.nil? || absolute.start_with?("(")
  return ["internal", nil] if absolute.start_with?("<")
  return ["gem", nil] unless app_path?(normalized_file)

  range = source_range_for(unbound_method, absolute, line)

  # A real source_location but no definition node: attr_accessor, Struct
  # members, and similar generated methods. There is nothing to extract.
  return ["generated", nil] if range.nil?

  lines = file_lines(absolute)

  return ["unreadable", nil] if lines.nil?

  first = range[0] - 1
  last  = range[1] - 1

  return ["unreadable", nil] if first.negative? || last >= lines.length || last < first

  text = normalize_source(lines[first..last].join)
  sha = Digest::SHA256.hexdigest(text)

  SOURCE_TEXTS[sha] = text if CAPTURE_SOURCES

  ["ruby", sha]
end

# ---------------------------------------------------------------------------
# Methods owned directly by a module
#
# Only methods the module itself defines -- inherited and included ones belong
# to their real owner and are captured there. What a class assembles from its
# ancestors is covered by the ancestors chain instead.
# ---------------------------------------------------------------------------

def collect_methods(owner, kind, out)
  return if owner.nil?

  {
    "public"    => UM_INSTANCE_METHODS,
    "protected" => UM_PROTECTED_METHODS,
    "private"   => UM_PRIVATE_METHODS
  }.each do |visibility, reflector|
    names = safe([]) { reflector.bind(owner).call(false) } || []

    names.each do |method_name|
      unbound = safe { UM_INSTANCE_METHOD.bind(owner).call(method_name) }
      next if unbound.nil?

      location = safe { unbound.source_location }
      file = location && normalize_path(location[0])
      line = location && location[1]

      source_kind, source_sha = method_source(unbound, file)

      params =
        safe([]) { unbound.parameters } || []

      out << {
        "name" => method_name.to_s,
        "kind" => kind,
        "visibility" => visibility,
        "params" => params.map { |type, pname| pname ? "#{type}:#{pname}" : type.to_s },
        "file" => file,
        "line" => line,
        "source" => source_kind,
        "source_sha" => source_sha
      }
    end
  end
end

# Cheap scope test: does this module directly own any method defined under
# Rails.root? Reads source_location only -- no parameters, no source extraction,
# no record building -- and stops at the first hit, so a gem class with no
# application methods costs one pass over its own method names.
def owns_app_code?(mod)
  [mod, mod_singleton_class(mod)].each do |owner|
    next if owner.nil?

    [UM_INSTANCE_METHODS, UM_PROTECTED_METHODS, UM_PRIVATE_METHODS].each do |reflector|
      names = safe([]) { reflector.bind(owner).call(false) } || []

      names.each do |method_name|
        unbound = safe { UM_INSTANCE_METHOD.bind(owner).call(method_name) }
        next if unbound.nil?

        location = safe { unbound.source_location }
        next if location.nil?

        return true if app_path?(normalize_path(location[0]))
      end
    end
  end

  false
end

# ---------------------------------------------------------------------------
# Ancestor labelling
#
# Anonymous modules are common in ancestor chains (generated concerns, Module.new
# mixins). Labelling them all "#<Module:ANONYMOUS>" would make the ancestors diff
# unreadable, and their object addresses are not stable across runs. Instead we
# identify them by the file their methods come from, which is both stable and
# actually tells you which mixin moved.
# ---------------------------------------------------------------------------

def anonymous_label(mod)
  kind = mod_class?(mod) ? "class" : "module"

  files =
    safe([]) do
      names = UM_INSTANCE_METHODS.bind(mod).call(false)
      names.map { |n| safe { UM_INSTANCE_METHOD.bind(mod).call(n).source_location&.first } }
    end || []

  origin = files.compact.map { |f| normalize_path(f) }.compact.uniq.sort.first

  origin ? "#<anonymous #{kind} @ #{origin}>" : "#<anonymous #{kind}>"
end

def ancestor_label(mod)
  name = mod_name(mod)

  return normalize_anonymous(name) if name && !name.empty?

  # Singleton classes have no name but a stable, meaningful inspect
  # ("#<Class:Facility>"), which is exactly the label we want.
  inspected = normalize_anonymous(mod_inspect(mod))

  return inspected if inspected&.start_with?("#<Class:") && !inspected.include?("ANONYMOUS")

  anonymous_label(mod)
end

def ancestors_of(mod)
  list = safe { UM_ANCESTORS.bind(mod).call }

  return nil if list.nil?

  list.map { |ancestor| ancestor_label(ancestor) }
end

# ---------------------------------------------------------------------------
# Which constants are in scope
#
# Included if the constant is defined under Rails.root, OR if any method it
# owns is defined under Rails.root. The second clause is what pulls in gem and
# stdlib classes that application code reopens -- the monkey patches whose load
# order is precisely what this migration puts at risk.
# ---------------------------------------------------------------------------

# Rails synthesises these per ActiveRecord model, and their contents depend on
# whether the schema has been read yet -- a timing artifact, not a load-order
# fact. Excluded as constants; the comparator collapses them in ancestor chains.
def generated_by_rails?(name)
  name.end_with?("::GeneratedAttributeMethods", "::GeneratedAssociationMethods")
end

def const_source_location_for(name)
  # NOTE: Module.const_source_location does NOT resolve pending autoloads --
  # verified on 2.7: given `autoload :Foo, "foo"`, it returns the location of
  # the autoload call and leaves $LOADED_FEATURES untouched. That is what makes
  # it safe to call here; anything that triggered the autoload would corrupt the
  # non-eager snapshot it is supposed to be measuring.
  safe { Module.const_source_location(name) }
end

# Three distinct outcomes, and conflating them mislabels core classes:
#   nil  -> constant is not defined (should not happen here)
#   []   -> defined in C, so there is no Ruby definition site at all
#   [f,l]-> defined in Ruby at f:l
def const_location_for(name)
  location = const_source_location_for(name)

  native = location.is_a?(Array) && location.empty?
  file =
    if native
      "<native>"
    elsif location.is_a?(Array) && location[0]
      normalize_path(location[0])
    end
  line = location.is_a?(Array) ? location[1] : nil

  [file, line, native]
end

def build_entry(mod, const_file, const_line, origin)
  methods = []
  collect_methods(mod, "instance", methods)
  collect_methods(mod_singleton_class(mod), "singleton", methods)
  methods.sort_by! { |m| [m["kind"], m["name"], m["visibility"]] }

  ancestors = ancestors_of(mod)

  singleton = mod_singleton_class(mod)
  singleton_ancestors = singleton ? ancestors_of(singleton) : nil

  superclass =
    if mod_class?(mod)
      parent = safe { UM_SUPERCLASS.bind(mod).call }
      parent ? ancestor_label(parent) : nil
    end

  ancestors_digest = Digest::SHA256.hexdigest(Array(ancestors).join("\n"))
  methods_digest = Digest::SHA256.hexdigest(JSON.generate(methods))

  {
    "kind" => mod_class?(mod) ? "class" : "module",
    "origin" => origin,
    "superclass" => superclass,
    "const_file" => const_file,
    "const_line" => const_line,
    "ancestors" => ancestors,
    "singleton_ancestors" => singleton_ancestors,
    "methods" => methods,
    "digests" => {
      "ancestors" => ancestors_digest,
      "methods" => methods_digest,
      "all" => Digest::SHA256.hexdigest(
        [superclass.to_s, ancestors_digest, methods_digest].join("\n")
      )
    }
  }
end

def origin_for(const_in_app, const_native, const_file)
  if const_in_app
    "app"
  elsif const_native || const_file
    # Defined in C or in a gem, but application code owns some of its methods --
    # i.e. the app reopened it. These are the monkey patches whose load order
    # this migration puts at risk.
    "reopened_gem"
  else
    # No definition site at all (Class.new assigned to a constant, etc.). Its
    # app-owned methods are the only evidence, and they say it is ours.
    "app"
  end
end

def record_constant(constants, duplicates, name, entry)
  existing = constants[name]

  if existing.nil?
    constants[name] = entry
  elsif existing["digests"]["all"] != entry["digests"]["all"]
    # Two live objects claiming the same constant name -- almost always a stale
    # copy left behind by a reload. Which one ObjectSpace yields first is not
    # stable, so pick by digest to keep the snapshot deterministic, and surface
    # it: if this list is non-empty the snapshot was taken against a reloaded
    # process and the pair may not be trustworthy.
    duplicates << name

    constants[name] = entry if entry["digests"]["all"] < existing["digests"]["all"]
  end
end

skipped = []
duplicates = []
constants = {}

# Every named module on the heap, keyed by name. The namespace pass below needs
# to turn a parent name back into a module object, and this is the only way to
# do it that cannot trigger a pending autoload -- Object.const_get would, and
# would corrupt the very non-eager snapshot this script exists to measure.
# Values are arrays because a reload cycle can leave two objects claiming one
# name; both go through the same digest tiebreak as everything else.
by_name = {}

# Names admitted with origin "app". The namespace pass walks the prefixes of
# these only, so a gem namespace is never dragged in behind a reopened_gem entry.
app_names = []

# A reload cycle (to_prepare blocks in development, or Zeitwerk unloading) can
# leave the previous version of a class on the heap. It is unreachable, but its
# name is cached on the object, so it still answers to Module#name and would
# show up here as a second, stale "Widget". Collecting first removes most of
# them; whatever survives is resolved deterministically below.
GC.start

# Materialise the module list before doing any work on it. ObjectSpace's
# iteration walks the heap, and allocating heavily inside the block (which
# building the whole snapshot certainly does) is not safe.
all_modules = []
ObjectSpace.each_object(Module) { |mod| all_modules << mod }

all_modules.each do |mod|
  name = mod_name(mod)

  next if name.nil? || name.empty?

  (by_name[name] ||= []) << mod

  next if generated_by_rails?(name)

  anonymous = name.include?("#<Class:") || name.include?("#<Module:")
  next if anonymous && !INCLUDE_ANON

  begin
    const_file, const_line, const_native = const_location_for(name)

    const_in_app = app_path?(const_file)

    # Decide scope BEFORE building method records. Almost every module on the
    # heap belongs to a gem and will be discarded, and building full records
    # (parameters, source extraction, hashing) for all of them before throwing
    # them away is the single most expensive thing this script could do.
    has_app_methods = const_in_app ? true : owns_app_code?(mod)

    next unless const_in_app || has_app_methods

    origin = origin_for(const_in_app, const_native, const_file)
    normalized_name = normalize_anonymous(name)

    app_names << normalized_name if origin == "app"

    record_constant(constants, duplicates, normalized_name,
                    build_entry(mod, const_file, const_line, origin))
  rescue Exception => e # rubocop:disable Lint/RescueException
    # Recorded rather than dropped. A subsystem that systematically explodes
    # during introspection would otherwise be absent from both snapshots and
    # look like agreement.
    skipped << { "name" => name, "error" => "#{e.class}: #{e.message}" }
  end
end

# ---------------------------------------------------------------------------
# Namespace closure
#
# Zeitwerk autovivifies an implicit namespace -- a directory with no matching
# .rb file -- with Object.const_set(cname, Module.new) from inside the gem,
# before any file nested in it is loaded. Module.const_source_location then
# points into the gem, and a later `module Foo` in an application file only
# REOPENS the module: it does not update the recorded location (verified on
# 2.7). A pure namespace owns no methods either, so it fails both scope tests
# above and vanishes from the snapshot -- while every constant nested inside it
# stays. Classic mode creates the same constant from the `module` keyword in an
# application file, so it survives there.
#
# Left alone the asymmetry reports every namespace on the zeitwerk branch as
# "no longer loaded", which is the whole eager-mode worklist and none of it real.
# ---------------------------------------------------------------------------

namespace_names = []

app_names.uniq.each do |name|
  parts = name.split("::")
  next if parts.length < 2

  (1...parts.length).each do |i|
    prefix = parts[0, i].join("::")
    namespace_names << prefix unless constants.key?(prefix)
  end
end

# Sorted so insertion order does not depend on ObjectSpace's iteration order --
# two runs of an unchanged checkout have to produce identical bytes.
namespace_names.uniq!
namespace_names.sort!

namespace_names.each do |name|
  next if name.include?("#<Class:") || name.include?("#<Module:")

  Array(by_name[name]).each do |mod|
    const_file, const_line, const_native = const_location_for(name)

    record_constant(constants, duplicates, name,
                    build_entry(mod, const_file, const_line,
                                origin_for(app_path?(const_file), const_native, const_file)))
  rescue Exception => e # rubocop:disable Lint/RescueException
    skipped << { "name" => name, "error" => "#{e.class}: #{e.message}" }
  end
end

# ---------------------------------------------------------------------------
# Load order
# ---------------------------------------------------------------------------

preload_script = safe { File.expand_path(__dir__) }

baseline = TRACE ? TRACE[:loaded_features_baseline] : []
baseline_set = {}
baseline.each { |f| baseline_set[f] = true }

# The boot window is everything between the preboot baseline and the moment this
# script started running. POST_BOOT_FEATURES excludes json/digest/socket/etc.
# that the snapshot machinery itself pulls in -- those are identical on both
# branches, but leaving them in makes the load-order diff harder to read and
# inflates loaded_files by a couple of dozen entries.
boot_window = POST_BOOT_FEATURES.reject { |f| baseline_set[f] }

# $LOADED_FEATURES is append-ordered by the VM, which makes it the one load-order
# source that survives both Bootsnap's instruction-sequence cache and
# autoload-triggered requires that never pass through a Ruby-level Kernel#require.
loaded_files =
  boot_window
    .reject { |f| preload_script && f.to_s.start_with?("#{preload_script}/") }
    .map { |f| normalize_path(f) }
    .compact

class_bodies =
  if TRACE
    TRACE[:class_events].map do |name, kind, path, line|
      {
        "name" => name ? normalize_anonymous(name) : nil,
        "kind" => kind,
        "file" => normalize_path(path),
        "line" => line
      }
    end
  else
    []
  end

script_compiled =
  if TRACE
    TRACE[:script_compiled].map { |p| normalize_path(p) }.compact
  else
    []
  end

# ---------------------------------------------------------------------------
# Identity -- what the comparator uses to refuse mismatched pairs
# ---------------------------------------------------------------------------

# Returns the command's stripped output, or nil if git failed / this is not a
# repository. An empty-but-successful result (a clean `status --porcelain`) is
# returned as "" and must stay distinguishable from nil -- conflating them makes
# every clean checkout report itself as dirty.
def git(root, *args)
  output = safe { IO.popen(["git", "-C", root, *args], err: File::NULL, &:read) }

  return nil if output.nil? || !$?&.success?

  output.strip
end

zeitwerk_enabled =
  safe do
    if Rails.respond_to?(:autoloaders) && Rails.autoloaders.respond_to?(:zeitwerk_enabled?)
      Rails.autoloaders.zeitwerk_enabled?
    end
  end

branch = git(ROOT, "rev-parse", "--abbrev-ref", "HEAD")
porcelain = git(ROOT, "status", "--porcelain")

identity = {
  "label" => LABEL,
  "rails_env" => Rails.env.to_s,
  "eager_load" => safe { Rails.application.config.eager_load },
  "autoloader" => safe { Rails.application.config.autoloader.to_s },
  "zeitwerk_enabled" => zeitwerk_enabled,
  "rails_version" => Rails.version,
  "ruby_version" => RUBY_VERSION,
  "root" => ROOT,
  "branch" => branch,
  "sha" => git(ROOT, "rev-parse", "HEAD"),
  "dirty" => porcelain.nil? ? nil : !porcelain.empty?,
  "bootsnap_active" => defined?(Bootsnap) ? true : false,
  "preboot_trace_installed" => TRACE_INSTALLED,
  "presumed_root_matched" => TRACE ? (TRACE[:presumed_root] == ROOT) : nil,
  "script_version" => SCRIPT_VERSION,
  "capture_sources" => CAPTURE_SOURCES
}

if TRACE && TRACE[:presumed_root] != ROOT
  warn "[snapshot] WARNING: preboot hook assumed root #{TRACE[:presumed_root].inspect} " \
       "but Rails.root is #{ROOT.inspect}. Class-body trace data is likely incomplete " \
       "(run bin/rails from the application directory)."
end

paths = {
  "autoload_paths" => safe([]) {
    Rails.application.config.autoload_paths.map { |p| normalize_path(p) }.compact.sort
  },
  "eager_load_paths" => safe([]) {
    Rails.application.config.eager_load_paths.map { |p| normalize_path(p) }.compact.sort
  },
  "autoload_once_paths" => safe([]) {
    Rails.application.config.autoload_once_paths.map { |p| normalize_path(p) }.compact.sort
  }
}

snapshot = {
  "meta" => {
    "generated_at" => Time.now.utc.iso8601,
    "hostname" => safe { Socket.gethostname },
    "pid" => Process.pid
  },
  "identity" => identity,
  "paths" => paths,
  "load_order" => {
    "files" => loaded_files,
    "class_bodies" => class_bodies,
    "script_compiled" => script_compiled,
    "dropped_class_events" => TRACE ? TRACE[:dropped_class_events] : nil
  },
  "counts" => {
    "constants" => constants.size,
    "methods" => constants.values.sum { |c| c["methods"].length },
    "loaded_files" => loaded_files.length,
    "class_bodies" => class_bodies.length,
    "skipped" => skipped.length,
    "duplicate_names" => duplicates.uniq.length
  },
  "skipped" => skipped.sort_by { |s| s["name"] },
  "duplicate_names" => duplicates.uniq.sort,
  "constants" => constants.sort.to_h
}

if OUT_PATH
  FileUtils.mkdir_p(File.dirname(OUT_PATH))
  File.write(OUT_PATH, JSON.generate(snapshot))

  if CAPTURE_SOURCES
    sources_path = SOURCES_PATH || OUT_PATH.sub(/\.json\z/, "") + ".sources.json"
    File.write(sources_path, JSON.generate(SOURCE_TEXTS.sort.to_h))
  end

  warn format(
    "[snapshot] %s: %d constants, %d methods, %d loaded files, %d class bodies, %d skipped -> %s",
    LABEL,
    snapshot["counts"]["constants"],
    snapshot["counts"]["methods"],
    snapshot["counts"]["loaded_files"],
    snapshot["counts"]["class_bodies"],
    snapshot["counts"]["skipped"],
    OUT_PATH
  )
else
  puts JSON.generate(snapshot)
end
