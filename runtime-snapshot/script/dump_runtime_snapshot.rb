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
require "set"
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
# 3: ancestor_methods -- method names for every module appearing in a chain, so
#    the comparator can tell a reordering that changes dispatch from one that
#    cannot. Chains reference roughly twice as many modules as are in scope.
# 4: anonymous ancestor labels carry the constant that owns them. The origin file
#    alone is not an identity -- one store_accessor label covered 258 modules.
# 5: source_sha is only recorded when the extracted text is actually a definition.
#    It used to hash whatever statement sat on a metaprogrammed method's
#    source_location line, which was two thirds of all reported body changes.
# 6: body_sha -- method bodies are digested from the compiled instruction
#    sequence instead of from source text. 13% of methods had no source digest at
#    all, including every dynamically defined accessor.
# 7: constant values, and singleton labels no longer carry ActiveRecord's
#    "call X.connection to establish a connection" advisory.
# 8: constant values that are absolute paths are normalized, so a
#    Rails.root.join(...) constant no longer differs merely because the two
#    checkouts sit at different paths.
# 9: class_attributes -- __callbacks, _validators, default_scopes and the
#    resolved action callbacks. `included do` side effects were invisible to
#    every other section.
# 10: those values are stored structured (chain => filters) instead of a capped
#    summary string, so the comparator can say which filter moved or vanished.
#    The cap put the difference out of reach on the rows that mattered.
# 11: associations. A lost has_many was invisible everywhere else -- the readers
#    live in GeneratedAssociationMethods, which is excluded.
# 12: load_order.autoloaded -- classic's own require_or_load record. $LOADED_FEATURES
#    misses everything classic autoloads, because it uses Kernel#load.
# 13: three fidelity fixes, all of which produced differences that were not real.
#    (a) the pending-autoload guard asked Module#autoload? with inherit defaulting
#        to true, so a class defining its own SMS was skipped because Object had a
#        pending autoload for that name. Non-eager Zeitwerk snapshots only.
#    (b) hash constants are digested from sorted pairs; insertion order moved to
#        order_sha and is informational. One gem constant reported three digests
#        across four snapshots with identical content.
#    (c) load_order.autoloaded keeps insertion order, which is classic's file
#        completion order. It was sorted, which made it useless for detecting a
#        file that was read while still loading.
SCRIPT_VERSION = 13

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

# Surfaced as counts.body_digests. Bootsnap loads instruction sequences from a
# binary cache, and if that turned out to defeat RubyVM::InstructionSequence.of
# every body comparison would silently become a no-op. This is the number that
# says so on the first run rather than after a confusing report.
BODY_DIGEST_COUNT = [0]

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

  # Keeps the sidecar honest about what it holds.
  #
  # source_location for a metaprogrammed method points at the line that GENERATED
  # it, not at a definition -- a `has_many`, an `include`, an element of a symbol
  # list. RubyVM::AbstractSyntaxTree.of then hands back a SCOPE node spanning that
  # single line, and the fallback in source_range_for takes it without checking
  # the type, so whatever statement happens to live there would be stored as if it
  # were the method body. Nothing compares source text any more -- bodies are
  # compared by instruction sequence -- but a sidecar full of unrelated `include`
  # lines would mislead the next person who opens it to investigate a row.
  return ["generated", nil] unless text.lstrip.start_with?("def ", "def(", "define_method")

  sha = Digest::SHA256.hexdigest(text)

  SOURCE_TEXTS[sha] = text if CAPTURE_SOURCES

  ["ruby", sha]
end

# ---------------------------------------------------------------------------
# Body digest
#
# What the method actually compiles to, which is the only description of a method
# body that does not depend on source_location being trustworthy.
#
# It is not, for anything metaprogrammed. Sometimes it points at the line that
# generated the method and the text there is unrelated -- two thirds of the body
# changes this tool used to report were an `include` or a `has_many` sitting at
# the wrong line number. Sometimes there is nothing usable at all: every one of
# FacilitySettings' 626 generated accessors had no digest whatsoever, so a real
# difference in them was invisible. 13% of all methods were in that state.
#
# The instruction sequence has neither problem. Verified on 2.7.6: identical
# bodies hash equal across a file rename, a class rename, a line shift and a
# comment edit, and differ as soon as the code does.
# ---------------------------------------------------------------------------

# Everything that identifies WHERE the code lives rather than WHAT it does. The
# last two matter most on this migration: without them, namespacing a class or
# moving a file would change the digest of every method containing a block.
def normalize_disasm(text)
  text.lines.filter_map do |line|
    next if line.start_with?("== disasm", "== catch table", "local table", "|")

    line = line.sub(/\A\s*\d{4} /, "")               # bytecode offset
    line = line.gsub(/\(\s*\d+\)(\[[^\]]*\])?/, "")  # "( 3)" and "( 3)[LiCa]"
    line = line.gsub(/ in <[^>]*>/, "")              # "block (2 levels) in <class:Foo>"
    line = line.gsub(%r{/\S+\.rb}, "")               # absolute paths
    line = line.rstrip

    line.empty? ? nil : line
  end.join("\n")
end

# Returns [body_kind, body_sha], mirroring method_source: when there is no digest
# the kind says why.
#
#   "iseq"        -> digested
#   "native"      -> C function, there is no instruction sequence
#   "gem"         -> outside Rails.root, skipped by the same policy as source text
#   "unavailable" -> a Ruby method whose iseq could not be read. Should be rare;
#                    if it is not, see counts.body_digests and the Bootsnap note
#                    in the runbook.
def body_digest(unbound_method, normalized_file)
  # Order matters: a C function has no source_location, so the app_path? test
  # below would call it a gem method and the native kind would never be reached.
  return ["native", nil] if safe { unbound_method.source_location }.nil?
  return ["gem", nil] unless app_path?(normalized_file)

  iseq = safe { RubyVM::InstructionSequence.of(unbound_method) }

  return ["unavailable", nil] if iseq.nil?

  disasm = safe { iseq.disasm }

  return ["unavailable", nil] if disasm.nil?

  ["iseq", Digest::SHA256.hexdigest(normalize_disasm(disasm))]
end

# ---------------------------------------------------------------------------
# Constant values
#
# Constants that are Modules or Classes are captured as constants in their own
# right. This covers everything else -- LIMIT = 50, KINDS = %w[...] -- whose
# value can differ when load order changes which assignment ran last.
#
# Only values with a stable, meaningful serialization get a digest. Anything else
# records its kind and no digest, so the comparator can say "not comparable"
# rather than inventing a difference out of an object address.
# ---------------------------------------------------------------------------

UM_CONSTANTS = Module.instance_method(:constants)
UM_CONST_GET = Module.instance_method(:const_get)
UM_AUTOLOAD_P = Module.instance_method(:autoload?)

# Module#autoload? defaults to inherit = true, and -- unlike const_get -- a
# constant defined on the receiver does NOT stop the ancestor walk. The lookup
# only ends at a pending autoload entry or at the end of the chain, so a class
# that defines its own SMS reports Object's pending autoload for SMS:
#
#   c = Class.new { const_set(:SMS, "sms") }
#   Object.autoload(:SMS, "app/models/sms.rb")
#   c.autoload?(:SMS)         # => "app/models/sms.rb"   <- not ours
#   c.autoload?(:SMS, false)  # => nil
#   c.const_get(:SMS, false)  # => "sms"
#
# That dropped Lead::Kinds::SMS and MoveInInstructionsSentTenantEvent::
# DeliveryMethods::SMS from every non-eager Zeitwerk snapshot: app/models/sms.rb
# defines a top-level SMS, which is a pending autoload until something loads it,
# and both classes have Object in their ancestors. Under classic there is no Ruby
# autoload to find, and under eager load everything is already resolved -- so the
# guard and the getter disagreeing only shows up in one of the four snapshots.
#
# The second argument arrived in Ruby 2.7. Feature-detected rather than assumed,
# because safe{} would swallow the ArgumentError on an older Ruby and leave the
# guard silently passing every pending autoload through to const_get.
AUTOLOAD_P_TAKES_INHERIT =
  begin
    Module.new.autoload?(:UnlikelyToExist, false)
    true
  rescue ArgumentError
    false
  end

# True only when this module's own constant table holds a pending autoload for
# the name. Paired with const_get(name, false) below: same module, same rule.
def pending_autoload?(mod, const_name)
  if AUTOLOAD_P_TAKES_INHERIT
    safe { UM_AUTOLOAD_P.bind(mod).call(const_name, false) }
  else
    # No way to ask about this module alone. Skipping on an inherited hit is the
    # safe direction -- it loses a constant, where the alternative risks firing
    # the autoload this script exists not to fire.
    safe { UM_AUTOLOAD_P.bind(mod).call(const_name) }
  end
end

MAX_VALUE_DEPTH = 6
MAX_VALUE_ITEMS = 500

# Returns a canonical string, or nil when the value is not worth digesting.
#
# Array order is part of the value and is always kept. Hash order is not: it
# survives in Ruby, but a constant hash built by iterating something whose order
# follows load order reorders itself for reasons that have nothing to do with
# what the application does. Net::SSH::Connection::Session::MAP produced three
# different digests across four snapshots with identical keys and values -- and
# two of those three were the same branch, so it did not even track the thing
# being compared.
#
# So it is serialized twice: canonical: true sorts the pairs and feeds "sha",
# which is what a difference is judged on; canonical: false keeps insertion
# order and feeds "order_sha", which is recorded only when it differs and is
# reported informationally. Sorting cannot hide a real change -- keys are unique,
# so any changed key or value changes the sorted set too.
def serialize_value(value, depth = 0, canonical: false)
  return nil if depth > MAX_VALUE_DEPTH

  case value
  when nil, true, false then value.inspect
  when Integer, Float   then value.inspect
  when String
    # A constant holding Rails.root.join(...) differs between two checkouts for
    # no reason except where they sit on disk -- and that was 15 of the first 17
    # value differences reported against the real application. normalize_path is
    # the same rule the rest of the snapshot uses for every file path it records.
    #
    # Guarded on a leading "/" deliberately: a string that merely contains a
    # path-shaped fragment should still be compared literally.
    "s#{(value.start_with?('/') ? normalize_path(value) || value : value).inspect}"
  when Symbol           then "y#{value.inspect}"
  when Array
    return nil if value.length > MAX_VALUE_ITEMS

    parts = value.map { |v| serialize_value(v, depth + 1, canonical: canonical) }
    parts.any?(&:nil?) ? nil : "[#{parts.join(',')}]"
  when Hash
    return nil if value.length > MAX_VALUE_ITEMS

    parts = value.map do |k, v|
      key = serialize_value(k, depth + 1, canonical: canonical)
      val = serialize_value(v, depth + 1, canonical: canonical)
      key && val ? "#{key}=>#{val}" : nil
    end
    return nil if parts.any?(&:nil?)

    parts = parts.sort if canonical
    "{#{parts.join(',')}}"
  when Set
    parts = value.to_a.map { |v| serialize_value(v, depth + 1, canonical: canonical) }
    parts.any?(&:nil?) ? nil : "#<Set:[#{parts.sort.join(',')}]>"
  end
end

def value_kind(value)
  case value
  when nil then "nil"
  when true, false then "boolean"
  when Integer then "integer"
  when Float then "float"
  when String then "string"
  when Symbol then "symbol"
  when Array then "array"
  when Hash then "hash"
  when Set then "set"
  when Proc, Method then "callable"
  else value.class.to_s
  end
end

# ---------------------------------------------------------------------------
# Class attribute values
#
# Ancestors and method sets cannot see what an `included do ... end` block did.
# Registering a callback, composing a default_scope and declaring a validation
# all leave the chain and the method list untouched -- they write a value into a
# class_attribute -- so a load-order change that stops one of them happening is
# invisible to every other section.
#
# It surfaced on this migration as four mailer classes losing OWNERSHIP of
# __callbacks while their chains, their methods and every other class_attribute
# stayed identical. That said something changed; it could not say whether the
# callbacks themselves differed.
#
# A curated list rather than every class_attribute: _routes, _layout,
# default_params and the rest are expected to differ and would need their own
# triage pass. These four carry behaviour.
# ---------------------------------------------------------------------------

CLASS_ATTRIBUTES = %w[
  __callbacks
  _validators
  default_scopes
  _process_action_callbacks
].freeze

MAX_SUMMARY = 300

# An ActiveSupport::CallbackChain is a live object -- ordering and identity are
# stable, the object is not. What matters is which filters run in which order, so
# each chain reduces to its filter list. A filter that is not a symbol (a proc, a
# callable object) is recorded by class: its identity would churn every run.
def serialize_filters(chain)
  chain.map do |entry|
    # An ActiveSupport::Callback wraps the thing that runs; a validator or a
    # default_scope is the thing itself. Unwrap only when there is something to
    # unwrap, or every non-callback attribute serializes to a list of <nil>.
    filter = safe(false) { entry.respond_to?(:filter) } ? safe { entry.filter } : entry

    case filter
    when Symbol, String then filter.to_s
    when nil then "<nil>"
    else "<#{safe { filter.class.to_s } || 'unknown'}>"
    end
  end
end

MAX_CHAIN = 400

# Structured, not a formatted string. The comparator has to diff these per chain
# and say "one filter moved" or "one filter is gone" -- a flat summary made every
# row two long, near-identical blobs with the difference somewhere in the middle,
# and truncating it put the difference out of reach entirely.
#
# Returns { chain name => [filter, ...] }, or nil when the value is not shaped
# like something worth comparing.
def serialize_class_attribute(value)
  case value
  when Hash
    # __callbacks: name => CallbackChain. _validators: attribute => [validator].
    out = {}

    value.each do |name, chain|
      return nil unless safe(false) { chain.respond_to?(:map) }

      out[name.to_s] = serialize_filters(chain).first(MAX_CHAIN)
    end

    out
  when Array
    # default_scopes and friends: one unnamed list.
    { "(list)" => serialize_filters(value).first(MAX_CHAIN) }
  end
end

# ---------------------------------------------------------------------------
# Associations
#
# A lost `has_many` is invisible to every other section: the reader methods live
# in GeneratedAssociationMethods, which is excluded as a timing artifact, and the
# reflection is not a constant, a method the class owns, or an ancestor. It
# surfaced once here only by accident -- as a missing autosave_associated_records
# callback -- and that is not a mechanism to rely on. Associations decide what
# `descendants`-driven and STI queries do, so they get captured directly.
# ---------------------------------------------------------------------------

# Never touches reflection.klass, .table_name or anything else that constantizes
# or reaches for a connection: that would autoload the target and corrupt the
# non-eager snapshot, which is the one invariant this script cannot break.
def association_records(mod)
  singleton = mod_singleton_class(mod)
  return {} if singleton.nil?

  reflector = :reflect_on_all_associations
  return {} unless safe(false) { UM_INSTANCE_METHODS.bind(singleton).call(true).include?(reflector) }

  reflections = safe { mod.public_send(reflector) } || []
  out = {}

  reflections.each do |reflection|
    name = safe { reflection.name.to_s }
    next if name.nil?

    options = safe({}) { reflection.options } || {}

    # Option keys are recorded even when the value will not serialize, so an
    # option arriving or vanishing is visible whatever it holds.
    serialized = options.keys.sort_by(&:to_s).to_h do |key|
      value = options[key]
      # inspect, not serialize_value: this string is displayed as well as
      # digested, and serialize_value's type prefixes (y:foo for a symbol) are
      # for disambiguating a hash, not for reading.
      readable =
        case value
        when nil, true, false, Integer, Float, String, Symbol then safe { value.inspect }
        when Array, Hash then safe { serialize_value(value) }
        end

      [key.to_s, readable || "<#{safe { value.class.to_s } || 'unknown'}>"]
    end

    out[name] = {
      "macro" => safe { reflection.macro.to_s } || "unknown",
      "options" => serialized
    }
  end

  out.sort.to_h
end

def class_attribute_values(mod)
  singleton = mod_singleton_class(mod)
  return {} if singleton.nil?

  out = {}

  CLASS_ATTRIBUTES.each do |name|
    # Read only. respond_to? through the unbound reflector so a hostile class
    # cannot lie, and no attempt is ever made to define the reader.
    next unless safe(false) { UM_INSTANCE_METHODS.bind(singleton).call(true).include?(name.to_sym) }

    value = safe { mod.public_send(name) }
    next if value.nil?

    chains = safe { serialize_class_attribute(value) }
    entry = { "kind" => safe { value_kind(value) } || "unknown" }
    entry["chains"] = chains.sort.to_h if chains

    out[name] = entry
  end

  out
end

def constant_values(mod)
  names = safe([]) { UM_CONSTANTS.bind(mod).call(false) } || []
  out = {}

  names.each do |const_name|
    # THE line that makes this safe to run against a non-eager snapshot.
    # Reading the value of a pending autoload would load it, and the whole point
    # of the non-eager pair is to measure what boot alone loaded. Ruby's own
    # autoload is visible here; Rails classic autoloading goes through
    # const_missing, so an unloaded constant is simply not listed at all.
    next if pending_autoload?(mod, const_name)

    value = safe { UM_CONST_GET.bind(mod).call(const_name, false) }

    # Modules and classes are captured as constants elsewhere.
    next if value.is_a?(Module)

    serialized = safe { serialize_value(value, canonical: true) }
    entry = { "kind" => safe { value_kind(value) } || "unknown" }

    if serialized
      entry["sha"] = Digest::SHA256.hexdigest(serialized)

      # Only recorded when the value contains a hash whose insertion order is not
      # already the sorted order -- otherwise every constant in the snapshot would
      # carry a duplicate digest. A missing order_sha therefore means "order and
      # content agree", which is what the comparator falls back to.
      ordered = safe { serialize_value(value, canonical: false) }
      entry["order_sha"] = Digest::SHA256.hexdigest(ordered) if ordered && ordered != serialized
    end

    out[const_name.to_s] = entry
  end

  out.sort.to_h
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
      body_kind, body_sha = body_digest(unbound, file)

      BODY_DIGEST_COUNT[0] += 1 if body_sha

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
        "source_sha" => source_sha,
        "body" => body_kind,
        "body_sha" => body_sha
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

# Anonymous module -> [owning chain length, owning constant name].
#
# The origin file alone is not an identity: every class calling store_accessor
# gets its own Module.new whose methods are all define_method'd inside
# active_record/store.rb, so hundreds of distinct modules would share one label.
# The report then cannot say which one moved, and the ancestor_methods map unions
# all of their methods into a single useless entry.
#
# The owner is the MOST SPECIFIC constant whose chain contains the module --
# smallest ancestor chain, ties broken by name so it stays deterministic.
# "The only constant that contains it" would be wrong: a class's own generated
# module is also in every subclass's chain, and a concern's module is in the
# chain of everything that includes the concern. Smallest-chain picks the class
# itself in the first case and the concern in the second, which is the answer
# wanted in both. A module genuinely included into two unrelated constants gets
# an arbitrary but stable one of them.
ANON_OWNER = {}.compare_by_identity

def record_anonymous_owners(owner_name, mod)
  [mod, mod_singleton_class(mod)].each do |root|
    next if root.nil?

    list = safe { UM_ANCESTORS.bind(root).call }
    next if list.nil?

    candidate = [list.length, owner_name]

    list.each do |ancestor|
      name = mod_name(ancestor)
      next if name && !name.empty?

      current = ANON_OWNER[ancestor]
      ANON_OWNER[ancestor] = candidate if current.nil? || (candidate <=> current) == -1
    end
  end
end

# Reflection over every method of every anonymous module, repeated for each of the
# thousands of chains it appears in, is pure waste -- the answer cannot change.
ANON_LABEL_CACHE = {}.compare_by_identity

def anonymous_label(mod)
  cached = ANON_LABEL_CACHE[mod]
  return cached if cached

  ANON_LABEL_CACHE[mod] = compute_anonymous_label(mod)
end

def compute_anonymous_label(mod)
  kind = mod_class?(mod) ? "class" : "module"

  files =
    safe([]) do
      names = UM_INSTANCE_METHODS.bind(mod).call(false)
      names.map { |n| safe { UM_INSTANCE_METHOD.bind(mod).call(n).source_location&.first } }
    end || []

  origin = files.compact.map { |f| normalize_path(f) }.compact.uniq.sort.first
  owner = ANON_OWNER[mod]&.last
  qualified = owner ? "anonymous #{kind} of #{owner}" : "anonymous #{kind}"

  origin ? "#<#{qualified} @ #{origin}>" : "#<#{qualified}>"
end

def ancestor_label(mod)
  name = mod_name(mod)

  return normalize_anonymous(name) if name && !name.empty?

  # Singleton classes have no name but a stable, meaningful inspect
  # ("#<Class:Facility>"), which is exactly the label we want.
  #
  # ActiveRecord overrides inspect on classes without an established connection,
  # giving "#<Class:Facility (call 'Facility.connection' to establish a
  # connection)>". These labels are now the identity of a row in the resolution
  # order section, so the advisory tail has to go -- it depends on connection
  # state rather than on the class.
  inspected = normalize_anonymous(mod_inspect(mod))
  inspected = inspected.sub(/\A(#<Class:[^\s>]+)\s.*>\z/, '\1>') if inspected

  return inspected if inspected&.start_with?("#<Class:") && !inspected.include?("ANONYMOUS")

  anonymous_label(mod)
end

# Method names owned by every module that turns up in any ancestor chain, keyed
# by the label the chain uses.
#
# The comparator needs this to answer the only question that makes a reordering
# matter for dispatch: did the module that moved cross anything defining the same
# method name? It cannot answer that from the constants alone -- chains reference
# roughly twice as many modules as are in scope, and the gem mixins that sit in
# every ActiveRecord chain own no application code, so they are never captured.
#
# One rule covers both chains: the methods a member contributes are its OWN
# instance methods. In a singleton chain the members are singleton classes and
# extended modules, whose instance methods are exactly what dispatches there.
ANCESTOR_METHODS = {}

# Identity-keyed so each distinct module is reflected once no matter how many
# chains it appears in. compare_by_identity never calls #hash or #eql? on the
# key, which keeps it safe against classes that override them.
ANCESTOR_METHODS_SEEN = {}.compare_by_identity

def record_ancestor_methods(label, mod)
  return if ANCESTOR_METHODS_SEEN.key?(mod)

  ANCESTOR_METHODS_SEEN[mod] = true

  names =
    [UM_INSTANCE_METHODS, UM_PROTECTED_METHODS, UM_PRIVATE_METHODS].flat_map do |reflector|
      (safe([]) { reflector.bind(mod).call(false) } || []).map(&:to_s)
    end

  # Union rather than first-wins. Two distinct anonymous modules can share a
  # label, and which one is visited first depends on ObjectSpace order -- taking
  # either would make the snapshot nondeterministic. Union is order-independent,
  # and erring towards more names is the safe direction for overlap detection.
  existing = ANCESTOR_METHODS[label]
  ANCESTOR_METHODS[label] = existing ? existing | names : names
end

def ancestors_of(mod)
  list = safe { UM_ANCESTORS.bind(mod).call }

  return nil if list.nil?

  list.map do |ancestor|
    label = ancestor_label(ancestor)
    record_ancestor_methods(label, ancestor)
    label
  end
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
    "values" => constant_values(mod),
    "class_attributes" => class_attribute_values(mod),
    "associations" => association_records(mod),
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

# Constants that passed the scope test, held until the ownership pass below has
# run. Records cannot be built inline any more, because building one labels its
# whole ancestor chain and an anonymous module's label depends on chains that may
# not have been walked yet.
in_scope = []

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

    in_scope << [normalized_name, mod, const_file, const_line, origin]
  rescue Exception => e # rubocop:disable Lint/RescueException
    # Recorded rather than dropped. A subsystem that systematically explodes
    # during introspection would otherwise be absent from both snapshots and
    # look like agreement.
    skipped << { "name" => name, "error" => "#{e.class}: #{e.message}" }
  end
end

# Attribute anonymous modules before anything is labelled: a label cannot be
# computed until every chain that might claim ownership has been seen. Walks the
# chains only -- no method reflection, which is what makes a second pass cheap.
in_scope.each { |name, mod, _file, _line, _origin| safe { record_anonymous_owners(name, mod) } }

in_scope.each do |name, mod, const_file, const_line, origin|
  record_constant(constants, duplicates, name,
                  build_entry(mod, const_file, const_line, origin))
rescue Exception => e # rubocop:disable Lint/RescueException
  skipped << { "name" => name, "error" => "#{e.class}: #{e.message}" }
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

# These were not in the ownership pass -- they are being discovered now, after it
# ran. An anonymous module reachable only from a rescued namespace therefore keeps
# the unqualified label. Namespaces hold no methods of their own and their chains
# are short, so in practice there is nothing here to attribute.

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

# Classic autoloading loads application files with Kernel#load, which does NOT
# append to $LOADED_FEATURES -- so on the classic branch the file-level record
# above is missing essentially the whole application. ActiveSupport::Dependencies
# keeps its own record of what it require_or_load'ed, and that is the only signal
# that sees a file which monkey-patches without ever executing a class body.
#
# Under Zeitwerk, unhook! leaves this an empty Set. That is correct: there,
# $LOADED_FEATURES already has everything.
autoloaded_files =
  safe([]) do
    next [] unless defined?(ActiveSupport::Dependencies)
    next [] unless ActiveSupport::Dependencies.respond_to?(:history)

    # Deliberately NOT sorted. require_or_load appends to history *after* the
    # file finishes loading ("Record history *after* loading so first load gets
    # warnings"), which makes this classic's completion order -- the counterpart
    # to $LOADED_FEATURES on the Zeitwerk side, and the only such signal there,
    # since classic loads app files with Kernel#load. find_load_cycles.rb needs
    # it to tell a file that was still executing from one that had finished.
    # Everything downstream of this treats it as a set, so losing the sort costs
    # nothing.
    ActiveSupport::Dependencies.history.map { |f| normalize_path(f) }.compact.uniq
  end || []

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
    "autoloaded" => autoloaded_files,
    "class_bodies" => class_bodies,
    "script_compiled" => script_compiled,
    "dropped_class_events" => TRACE ? TRACE[:dropped_class_events] : nil
  },
  "counts" => {
    "constants" => constants.size,
    "methods" => constants.values.sum { |c| c["methods"].length },
    "body_digests" => BODY_DIGEST_COUNT[0],
    "loaded_files" => loaded_files.length,
    "autoloaded" => autoloaded_files.length,
    "class_bodies" => class_bodies.length,
    "skipped" => skipped.length,
    "duplicate_names" => duplicates.uniq.length,
    "ancestor_modules" => ANCESTOR_METHODS.size
  },
  "skipped" => skipped.sort_by { |s| s["name"] },
  "duplicate_names" => duplicates.uniq.sort,
  # Names only -- no parameters, source or digests. Deduplicated globally, so a
  # module mixed into 4000 chains is stored once.
  "ancestor_methods" => ANCESTOR_METHODS.sort.to_h.transform_values(&:sort),
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
