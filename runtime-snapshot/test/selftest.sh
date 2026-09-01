#!/usr/bin/env bash
#
# Self-test for the runtime-snapshot tooling.
#
#   runtime-snapshot/test/selftest.sh
#
# Builds two throwaway "applications" in a temp directory that reproduce the
# situations this tool exists to catch, runs the real dumper and comparator over
# them, and asserts the expected findings. No Rails, no database, no network --
# it stubs the handful of Rails methods the dumper touches.
#
# Run this before pointing the tooling at the real application. If it fails on
# your Ruby, the reports it produces are not trustworthy either.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$HERE/../script"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; printf '       %s\n' "${2:-}"; FAIL=$((FAIL + 1)); }

assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}

# ---------------------------------------------------------------------------
# A minimal stand-in for a booted Rails app.
# ---------------------------------------------------------------------------

cat > "$WORK/runner.rb" <<'RUBY'
require "pathname"
require "set"
APP_DIR = File.expand_path(ARGV[0])

# Present on both branches in a real application -- Zeitwerk's take_over unhooks
# it but leaves the constant. Defining it in the runner keeps the fixture
# symmetric; defining it in one application.rb made it a spurious finding.
module ActiveSupport
  module Dependencies
    def self.history; @history ||= Set.new; end
    def self.autoloaded_constants; @autoloaded_constants ||= []; end
  end
end
DUMP    = File.expand_path(ARGV[1])

module Rails
  Config = Struct.new(:eager_load, :autoloader, :autoload_paths, :eager_load_paths, :autoload_once_paths)
  App = Struct.new(:config)
  # Both loaders exist on both branches in a real application -- classic leaves
  # Rails.autoloaders in place with nothing registered, Zeitwerk fills them in.
  # Stubbed in the runner rather than in one application.rb for the same reason
  # Dependencies.history is: defining it on one side only makes it a finding.
  Loader = Struct.new(:unloadable_cpaths)
  Autoloaders = Struct.new(:main, :once)
  def self.autoloaders; @autoloaders ||= Autoloaders.new(Loader.new([]), Loader.new([])); end
  def self.root; Pathname.new(APP_DIR); end
  def self.env; "development"; end
  def self.version; "6.1.7"; end
  def self.application
    @application ||= App.new(Config.new(true, :zeitwerk, ["#{APP_DIR}/app"], ["#{APP_DIR}/app"], []))
  end
end

require "#{APP_DIR}/config/application"
load DUMP
RUBY

snapshot() { # app_dir label
  ( cd "$1" && \
    RUBYOPT="-r$SCRIPT_DIR/preboot_trace.rb" \
    SNAPSHOT_LABEL="$2" \
    SNAPSHOT_OUT="$WORK/snap/$2.json" \
    ruby "$WORK/runner.rb" "$1" "$SCRIPT_DIR/dump_runtime_snapshot.rb" ) 2>/dev/null
}

compare() { ruby "$SCRIPT_DIR/compare_runtime_snapshots.rb" "$WORK/snap/$1.json" "$WORK/snap/$2.json" "${@:3}"; }

count() { # label_a label_b key
  compare "$1" "$2" --format json "${@:4}" | ruby -rjson -e 'puts JSON.parse($stdin.read)["counts"][ARGV[0]]' "$3"
}

# ---------------------------------------------------------------------------
# Fixture: "classic" vs "zeitwerk"
#
# The zeitwerk side reproduces five things at once:
#   - widget.rb renamed into a namespaced directory and re-indented
#   - the decorator now loads BEFORE the class it decorates
#   - a concern is no longer included
#   - a constant is never loaded at all
#   - ZeitwerkIntegration's Object shim shows up in an ancestor chain
# ---------------------------------------------------------------------------

mkdir -p "$WORK/classic/config" "$WORK/classic/app" "$WORK/classic/lib"
mkdir -p "$WORK/zeitwerk/config" "$WORK/zeitwerk/app/store" "$WORK/zeitwerk/lib"

cat > "$WORK/classic/app/widget.rb" <<'RUBY'
module Trackable
  def track; "tracked"; end
end
module Auditable
  def audit; "audited"; end
end
module Reorderable
  def reorder; "reordered"; end
end
class Widget
  include Reorderable
  include Trackable
  include Auditable
  def price; 100; end
  def self.build; new; end
  # Contains a block, and this file is RENAMED on the zeitwerk side. A block's
  # disassembly embeds the defining file path, so without stripping it every
  # method like this would read as a body change on every moved file.
  def doubled; [1, 2].map { |x| x * 2 }; end
  # Absent from the zeitwerk fixture, so Widget's row carries a removal as well
  # as a body change -- the grouping has to fold both into one entry.
  def retired_helper; :gone; end
  private
  def secret; :sauce; end
end
RUBY

cat > "$WORK/classic/app/gadget.rb" <<'RUBY'
class Gadget
  def only_in_classic; 1; end
end
RUBY

cat > "$WORK/classic/lib/decorator.rb" <<'RUBY'
class Widget
  def price; 999; end
end
RUBY

# Shimmed exists on both sides and has no genuine ancestor difference, so any
# ancestor_diffs row it produces is purely the ZeitwerkIntegration shim below.
cat > "$WORK/classic/app/shimmed.rb" <<'RUBY'
class Shimmed
  def shimmed; 1; end
end
RUBY

# A metaprogrammed method whose source_location points at a line that is not its
# definition -- here the first line of a block, which the AST index records as a
# definition site. The dumper used to hash whatever text that range covered, so
# the two branches "differed" on a method neither of them changed. Only the block
# body differs between the fixtures; generated_one and real_one are identical.
cat > "$WORK/classic/app/meta.rb" <<'RUBY'
class MetaProbe
  [1].each do |i|
    i
  end
  module_eval("def generated_one; 1; end", __FILE__, 2)
  def real_one; 1; end
end

# The FacilitySettings shape: accessors defined by define_method, which have no
# usable source text at all. Their bodies are only comparable via the compiled
# instruction sequence.
class DynamicAccessors
  %w[alpha beta].each do |name|
    define_method(name) do
      settings[name].to_s
    end
  end

  def settings; { "alpha" => 1, "beta" => 2 }; end
end

RUBY

cat > "$WORK/zeitwerk/app/meta.rb" <<'RUBY'
class MetaProbe
  [2, 3].each do |i|
    i
  end
  module_eval("def generated_one; 1; end", __FILE__, 2)
  # a comment that changes the source text but not the compiled body
  def real_one; 1; end
end

class DynamicAccessors
  %w[alpha beta].each do |name|
    define_method(name) do
      settings.fetch(name).to_s
    end
  end

  def settings; { "alpha" => 1, "beta" => 2 }; end
end
RUBY

# Two reorder-only classes, to separate "the chain changed" from "dispatch
# changed". Both swap their include order between the branches; only Overlapping
# has two modules defining the same method, so only it can change what a call
# site reaches. Kept out of widget.rb because that class also loses a concern,
# and a row with a genuine deletion is semantic whatever else it contains.
# Anonymous modules, both created in THIS file, so the origin path cannot tell
# them apart -- attribution has to come from the chains that contain them.
#   Solo's is included into one class and nothing else.
#   Shared's is included into a concern that two classes include, so three chains
#   contain it; the concern is the most specific and must win.
# Identical in both fixtures: this is about labelling, not about a difference.
cat > "$WORK/classic/app/anon.rb" <<'RUBY'
class Solo
  include(Module.new do
    def solo_helper; :solo; end
  end)
end
module SharedConcern
  include(Module.new do
    def shared_helper; :shared; end
  end)
end
class UserA
  include SharedConcern
end
class UserB
  include SharedConcern
end
RUBY

# Zeitwerk side: Solo loses its anonymous module, the way a class loses its
# generated store_accessor module when the declaration stops running. Reported as
# a deletion of a label nobody can look up, which is what the provides: line is
# for. SharedConcern is untouched.
cat > "$WORK/zeitwerk/app/anon.rb" <<'RUBY'
class Solo
end
module SharedConcern
  include(Module.new do
    def shared_helper; :shared; end
  end)
end
class UserA
  include SharedConcern
end
class UserB
  include SharedConcern
end
RUBY

# The Dependencies.unhook! shape: a base that includes a module providing #load
# and #require, and on the zeitwerk side defines them directly on itself,
# shadowing the module. Alongside it, a class that shadows #require for its own
# reasons -- which must still be reported, or the collapse is too broad.
cat > "$WORK/classic/app/unhook.rb" <<'RUBY'
module FakeLoadable
  def load(f); f; end
  def require(f); f; end
end
class UnhookBase
  include FakeLoadable
end
class OwnRequire
  include FakeLoadable
end
RUBY

# Object itself gains #load and #require, exactly as Loadable.exclude_from(Object)
# does. Delegating to super keeps behaviour identical, so the dumper's own
# requires still work while the ancestry reproduces the real shape.
#
# OwnRequire is the negative case: it shadows #require for its own reasons, so its
# owner list changes by more than the arrival of Object and must still report.
cat > "$WORK/zeitwerk/app/unhook.rb" <<'RUBY'
module FakeLoadable
  def load(f); f; end
  def require(f); f; end
end
class Object
  def load(*args, &blk); super; end
  def require(*args, &blk); super; end
  private :load, :require
end
class UnhookBase
  include FakeLoadable
end
class OwnRequire
  include FakeLoadable
  def require(f); "mine"; end
end
RUBY

# A subclass that defines its own copy of a parent method on the classic side
# only. The removal is real -- it stopped defining it -- but the method is still
# callable through the parent, which is the distinction a bare "-" loses. This is
# the class_attribute shape: BaseMailer stops owning __callbacks, ActionMailer's
# still answers.
cat > "$WORK/classic/app/shadowing.rb" <<'RUBY'
class ShadowParent
  def self.setting; :parent; end
end
class ShadowChild < ShadowParent
  def self.setting; :child; end
end
RUBY

cat > "$WORK/zeitwerk/app/shadowing.rb" <<'RUBY'
class ShadowParent
  def self.setting; :parent; end
end
class ShadowChild < ShadowParent
end
RUBY

# A method a prepended module shadows.
#
# Module#instance_method resolves the ancestry, so asking the CLASS for a method
# the prepended module also defines hands back the module's. The dumper took the
# names from instance_methods(false) -- correctly, the class's own -- and then
# read file, line and body digest off the wrong method object.
#
# Prepended is the direct check: both records exist, and each must describe its
# own definition.
cat > "$WORK/classic/app/prepended.rb" <<'RUBY'
module PrependedPatch
  def value
    :module_body
  end
end

class Prepended
  prepend PrependedPatch

  def value
    :own_body
  end
end
RUBY

cp "$WORK/classic/app/prepended.rb" "$WORK/zeitwerk/app/prepended.rb"

# PrependedDrift is the consequence, and the reason this is worth a fixture: the
# module's body is identical on both branches and the CLASS's own body is not.
# Read through the module, both sides digest the same bytes and the pair compares
# clean -- a real change to a real method, reported as no change at all. Which is
# exactly the shape of an engine extension prepended over an app class.
cat > "$WORK/classic/app/prepended_drift.rb" <<'RUBY'
module PrependedDriftPatch
  def compute
    :module_body
  end
end

class PrependedDrift
  prepend PrependedDriftPatch

  def compute
    :classic_own_body
  end
end
RUBY

cat > "$WORK/zeitwerk/app/prepended_drift.rb" <<'RUBY'
module PrependedDriftPatch
  def compute
    :module_body
  end
end

class PrependedDrift
  prepend PrependedDriftPatch

  def compute
    :zeitwerk_own_body
  end
end
RUBY

# Class attributes. The stub has no ActiveSupport, so these stand in for the
# __callbacks shape: a singleton reader returning name => ordered filter list.
#   Registrar  -- a filter stops being registered (the BaseMailer case)
#   Steady     -- identical on both, must not be reported
#   Opaque     -- holds something unserializable, must never be reported
#   NoAttrs    -- does not respond to the reader at all, must not raise
cat > "$WORK/classic/app/classattrs.rb" <<'RUBY'
class Registrar
  def self.__callbacks; { process_action: [:set_locale, :log_delivery] }; end
end
class Steady
  def self.__callbacks; { process_action: [:always] }; end
end
module Sweeper
  def notify_sweeper; end
end
module Indexer
  def reindex; end
end
class Shuffled
  include Sweeper
  include Indexer
  def self.__callbacks; { commit: [:reindex, :notify_sweeper] }; end
end
# Ownership of a class_attribute reader changing without the value changing is
# not a finding -- an assignment that writes back the inherited value creates
# ownership and nothing else. But ownership changing WITH the value is exactly
# what the section exists for, so the two must not be conflated.
class AttrParent
  def self.__callbacks; { process_action: [:inherited_filter] }; end
end
class InertOwner < AttrParent
  def self.__callbacks; { process_action: [:inherited_filter] }; end   # same value
end
class RealOwner < AttrParent
  def self.__callbacks; { process_action: [:extra_filter] }; end       # different value
end
class Opaque
  def self.__callbacks; Object.new; end
end
class NoAttrs
  def self.plain; 1; end
end
RUBY

cat > "$WORK/zeitwerk/app/classattrs.rb" <<'RUBY'
class Registrar
  def self.__callbacks; { process_action: [] }; end
end
module Sweeper
  def notify_sweeper; end
end
module Indexer
  def reindex; end
end
class AttrParent
  def self.__callbacks; { process_action: [:inherited_filter] }; end
end
class InertOwner < AttrParent; end   # no longer owns it; inherits the same value
class RealOwner  < AttrParent; end   # no longer owns it; inherits a DIFFERENT value
class Shuffled
  include Sweeper
  include Indexer
  def self.__callbacks; { commit: [:notify_sweeper, :reindex] }; end
end
class Steady
  def self.__callbacks; { process_action: [:always] }; end
end
class Opaque
  def self.__callbacks; Object.new; end
end
class NoAttrs
  def self.plain; 1; end
end
RUBY

# Associations. The stub has no ActiveRecord, so this reproduces the reflection
# API the dumper reads: reflect_on_all_associations returning objects with name,
# macro and options. Ledger loses one association and changes an option on
# another; Untouched must not be reported.
cat > "$WORK/classic/app/assocs.rb" <<'RUBY'
Reflection = Struct.new(:name, :macro, :options)
class Ledger
  def self.reflect_on_all_associations
    [Reflection.new(:payments, :has_many, { dependent: :destroy }),
     Reflection.new(:import_batch, :belongs_to, {}),
     Reflection.new(:tenant, :belongs_to, { optional: true })]
  end
end
class Untouched
  def self.reflect_on_all_associations
    [Reflection.new(:things, :has_many, {})]
  end
end
RUBY

cat > "$WORK/zeitwerk/app/assocs.rb" <<'RUBY'
Reflection = Struct.new(:name, :macro, :options)
class Ledger
  def self.reflect_on_all_associations
    [Reflection.new(:payments, :has_many, { dependent: :nullify }),
     Reflection.new(:tenant, :belongs_to, { optional: true })]
  end
end
class Untouched
  def self.reflect_on_all_associations
    [Reflection.new(:things, :has_many, {})]
  end
end
RUBY

# The case that motivated the three-signal union: a file that only monkey-patches
# and never executes a class or module body.
#   patched_both.rb -- loaded on BOTH sides. Classic reaches it with Kernel#load,
#     which never registers in $LOADED_FEATURES, and it has no class body, so the
#     only thing that sees it on the classic side is Dependencies.history.
#     Must NOT be reported.
#   patched_zeitwerk_only.rb -- genuinely one-sided. Must be reported.
cat > "$WORK/classic/app/patched_both.rb" <<'RUBY'
Widget.class_eval { def patched_helper; :patched; end }
RUBY
cp "$WORK/classic/app/patched_both.rb" "$WORK/zeitwerk/app/patched_both.rb"

cat > "$WORK/zeitwerk/app/patched_zeitwerk_only.rb" <<'RUBY'
Widget.class_eval { def only_here; :here; end }
RUBY

# One ancestor gains a method that three subclasses inherit. That is ONE fact,
# and the report has to say so once with a count rather than four times -- the
# real application produced 20,423 rows that were 13 facts.
cat > "$WORK/classic/app/inherited.rb" <<'RUBY'
module SharedHook
  def shared_hook; :from_module; end
end
class SharedBase
  include SharedHook
end
class SubOne   < SharedBase; end
class SubTwo   < SharedBase; end
class SubThree < SharedBase; end
RUBY

# SharedBase now defines shared_hook itself, shadowing the module. Inherited by
# SharedBase plus its three subclasses = 4 classes, 1 row.
cat > "$WORK/zeitwerk/app/inherited.rb" <<'RUBY'
module SharedHook
  def shared_hook; :from_module; end
end
class SharedBase
  include SharedHook
  def shared_hook; :from_class; end
end
class SubOne   < SharedBase; end
class SubTwo   < SharedBase; end
class SubThree < SharedBase; end
RUBY

# Constant values. Only simple ones are digested; a lambda records its kind and
# must never be reported as changed, however much its inspect churns.
cat > "$WORK/classic/app/values.rb" <<'RUBY'
class Tunables
  ROOT_FILE = Rails.root.join("config", "thing.yml").to_s
  LIMIT = 50
  KINDS = %w[alpha beta].freeze
  NESTED = { "a" => [1, 2], "b" => :sym }.freeze
  STABLE = "unchanged"
  CALLBACK = ->(x) { x }
end
RUBY

cat > "$WORK/zeitwerk/app/values.rb" <<'RUBY'
class Tunables
  ROOT_FILE = Rails.root.join("config", "thing.yml").to_s
  LIMIT = 75
  KINDS = %w[beta alpha].freeze
  NESTED = { "a" => [1, 2], "b" => :sym }.freeze
  STABLE = "unchanged"
  CALLBACK = ->(y) { y * 2 }
end
RUBY

cat > "$WORK/classic/app/reorders.rb" <<'RUBY'
module Alpha
  def alpha; 1; end
end
module Beta
  def beta; 2; end
end
module Collide
  def shared; :collide; end
end
module Crash
  def shared; :crash; end
end
class Harmless
  include Alpha
  include Beta
end
class Overlapping
  include Collide
  include Crash
end
RUBY

# Classic creates the namespace from the `module` keyword in an application
# file, so const_source_location points at app/depot.rb. The zeitwerk side
# autovivifies it the way Zeitwerk does; see the counterpart below.
cat > "$WORK/classic/app/depot.rb" <<'RUBY'
module Depot
  class Crate
    def pack; :packed; end
  end
end
RUBY

cat > "$WORK/classic/config/application.rb" <<'RUBY'
require_relative "../app/widget"
require_relative "../app/gadget"
require_relative "../app/shimmed"
require_relative "../app/depot"
require_relative "../app/reorders"
require_relative "../app/anon"
require_relative "../app/meta"
# Kernel#load, not require: this is what classic autoloading does, and it is why
# $LOADED_FEATURES alone cannot see the file. Recorded in history the way
# require_or_load records it.
load File.expand_path("../app/patched_both.rb", __dir__)
# chomp(".rb") is what require_or_load does before expanding, so history holds
# extension-less paths. Reproduced here because getting that wrong made every
# autoloaded file an orphan twin -- 3,757 of them against the real application.
ActiveSupport::Dependencies.history << File.expand_path("../app/patched_both", __dir__)
require_relative "../app/assocs"
require_relative "../app/classattrs"
require_relative "../app/shadowing"
require_relative "../app/prepended"
require_relative "../app/prepended_drift"
require_relative "../app/unhook"
require_relative "../app/inherited"
require_relative "../app/values"
require_relative "../lib/decorator"
# Classic's own record of what const_missing resolved. Widget is managed on both
# sides; Depot::Crate and Gadget are not managed under zeitwerk, and Gadget is
# additionally missing from its constants entirely; MetaProbe moves to zeitwerk's
# once loader, which has to count as managed or it reads as a loss.
ActiveSupport::Dependencies.autoloaded_constants.concat(
  %w[Widget Depot::Crate Gadget MetaProbe]
)
RUBY

# Same class bodies, re-indented one level (as a namespacing change would do),
# minus Auditable. Gadget is never required. Decorator loads first. Reorderable
# is included last rather than first, so it stays in the chain but changes
# position -- the case an LCS diff can only express as a delete plus an insert.
cat > "$WORK/zeitwerk/app/store/widget.rb" <<'RUBY'
module Trackable
    def track; "tracked"; end
end
module Auditable
    def audit; "audited"; end
end
module Reorderable
    def reorder; "reordered"; end
end
class Widget
    include Trackable
    include Reorderable
    def price; 100; end
    def self.build; new; end
    def doubled; [1, 2].map { |x| x * 2 }; end
    private
    def secret; :sauce; end
end
RUBY

cp "$WORK/classic/lib/decorator.rb" "$WORK/zeitwerk/lib/decorator.rb"

# What Rails 6 does at the end of ZeitwerkIntegration.take_over. Prepending to
# Object itself would land in every chain in the dump; one class is enough to
# make the row countable.
cat > "$WORK/zeitwerk/app/shimmed.rb" <<'RUBY'
module ActiveSupport
  module Dependencies
    module ZeitwerkIntegration
      module RequireDependency
        def require_dependency(filename); require filename; end
      end
    end
  end
end
class Shimmed
  prepend ActiveSupport::Dependencies::ZeitwerkIntegration::RequireDependency
  def shimmed; 1; end
end
RUBY

# The Zeitwerk half of the namespace fixture. This file stands in for the gem:
# it lives OUTSIDE Rails.root and autovivifies the namespace before anything
# nested in it loads, exactly as Zeitwerk does for a directory with no matching
# .rb file. app/depot.rb then only reopens it, which does not move
# const_source_location -- so without the namespace closure pass Depot has
# neither an application definition site nor any methods, and disappears.
mkdir -p "$WORK/fakegem"
cat > "$WORK/fakegem/autovivify.rb" <<'RUBY'
Object.const_set(:Depot, Module.new)
RUBY

cat > "$WORK/zeitwerk/app/depot.rb" <<'RUBY'
module Depot
  class Crate
    def pack; :packed; end
  end
end
RUBY

# Same modules, opposite include order in both classes.
cat > "$WORK/zeitwerk/app/reorders.rb" <<'RUBY'
module Alpha
  def alpha; 1; end
end
module Beta
  def beta; 2; end
end
module Collide
  def shared; :collide; end
end
module Crash
  def shared; :crash; end
end
class Harmless
  include Beta
  include Alpha
end
class Overlapping
  include Crash
  include Collide
end
RUBY

cat > "$WORK/zeitwerk/config/application.rb" <<'RUBY'
require_relative "../../fakegem/autovivify"
require_relative "../lib/decorator"
require_relative "../app/store/widget"
require_relative "../app/shimmed"
require_relative "../app/depot"
require_relative "../app/reorders"
require_relative "../app/anon"
require_relative "../app/meta"
require_relative "../app/patched_both"
require_relative "../app/patched_zeitwerk_only"
require_relative "../app/assocs"
require_relative "../app/classattrs"
require_relative "../app/shadowing"
require_relative "../app/prepended"
require_relative "../app/prepended_drift"
require_relative "../app/unhook"
require_relative "../app/inherited"
require_relative "../app/values"
# Zeitwerk's registry is everything the loader set an autoload for, loaded or
# not. Registered::NeverLoaded is that second half: registered here, defined
# nowhere, and therefore absent from `constants` on both sides.
Rails.autoloaders.main.unloadable_cpaths.concat(%w[Widget Registered::NeverLoaded])
Rails.autoloaders.once.unloadable_cpaths << "MetaProbe"
RUBY

mkdir -p "$WORK/snap"

echo
echo "runtime-snapshot self-test (ruby $(ruby -e 'print RUBY_VERSION'))"
echo

snapshot "$WORK/classic"  classic   > /dev/null
snapshot "$WORK/classic"  classic2  > /dev/null
snapshot "$WORK/zeitwerk" zeitwerk  > /dev/null

for f in classic zeitwerk; do
  [ -s "$WORK/snap/$f.json" ] || { bad "snapshot $f was produced" "no output file"; }
done

echo "-- snapshot integrity --"

assert_eq "preboot trace fired (load order is available)" \
  "true" \
  "$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["identity"]["preboot_trace_installed"]' "$WORK/snap/classic.json")"

assert_eq "no constants skipped during introspection" \
  "0" \
  "$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["counts"]["skipped"]' "$WORK/snap/classic.json")"

assert_eq "no duplicate constant names" \
  "0" \
  "$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["counts"]["duplicate_names"]' "$WORK/snap/classic.json")"

# The whole comparison rests on this: an unchanged checkout must snapshot to the
# same bytes, or "no differences" means nothing.
DETERMINISTIC="$(ruby -rjson -e '
a = JSON.parse(File.read(ARGV[0])); b = JSON.parse(File.read(ARGV[1]))
[a, b].each { |h| h.delete("meta"); h["identity"].delete("label") }
puts a == b
' "$WORK/snap/classic.json" "$WORK/snap/classic2.json")"
assert_eq "two runs of an unchanged checkout are identical" "true" "$DETERMINISTIC"

assert_eq "a snapshot compared against itself reports zero differences" \
  "0" \
  "$(compare classic classic2 --format json | ruby -rjson -e 'puts JSON.parse($stdin.read)["semantic_total"]')"

echo
echo "-- findings --"

assert_eq "a constant that stopped loading is reported" \
  "1" "$(count classic zeitwerk constants_missing)"

# The 1 above is also the proof that Depot was NOT reported: it has no methods
# and its only definition site is outside Rails.root on the zeitwerk side, so
# before the namespace closure pass it dropped out of the snapshot and showed up
# here as a second, bogus "no longer loaded". Assert on the key as well as the
# count, so a regression that drops the count for some other reason still fails.
assert_eq "a namespace autovivified outside Rails.root is still recorded" \
  "true" \
  "$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["constants"].key?("Depot")' "$WORK/snap/zeitwerk.json")"

assert_eq "the constant nested inside it is recorded too" \
  "true" \
  "$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["constants"].key?("Depot::Crate")' "$WORK/snap/zeitwerk.json")"

# Resolution order: for one method name, which ancestors define it and in what
# order. A chain that merely reordered without changing any of those lists is not
# a finding -- that was 625 rows of pure noise on the real application.

res_rows() { compare classic zeitwerk --format json "$@" \
  | ruby -rjson -e 'puts JSON.generate(JSON.parse($stdin.read)["resolution_order_changes"])'; }

# Harmless swapped Alpha and Beta, which define nothing in common, so nothing
# resolves differently. Overlapping swapped Collide and Crash, which both define
# #shared, so it does.
assert_eq "a reorder that changes no method's resolution is not reported" \
  "0" "$(res_rows | ruby -rjson -e 'puts JSON.parse(ARGV[0]).count { |r| r["examples"].include?("Harmless") }' "$(res_rows)")"

assert_eq "a reorder that changes which definition wins is reported" \
  "shared" \
  "$(res_rows | ruby -rjson -e 'r = JSON.parse(ARGV[0]).find { |x| x["examples"].include?("Overlapping") }
                                puts(r ? r["method"] : "(none)")' "$(res_rows)")"

assert_eq "and it names the owners on both sides, winner first" \
  "Collide|Crash" \
  "$(res_rows | ruby -rjson -e 'r = JSON.parse(ARGV[0]).find { |x| x["examples"].include?("Overlapping") }
                                puts "#{r["b"].first}|#{r["a"].first}"' "$(res_rows)")"

# The whole reason for grouping: SharedBase gains a method that three subclasses
# inherit. That is one fact, not four rows.
assert_eq "one change inherited by several classes is one grouped row" \
  "1" \
  "$(res_rows | ruby -rjson -e 'puts JSON.parse(ARGV[0]).count { |r| r["method"] == "shared_hook" }' "$(res_rows)")"

assert_eq "and the row carries how many classes see it" \
  "4" \
  "$(res_rows | ruby -rjson -e 'r = JSON.parse(ARGV[0]).find { |x| x["method"] == "shared_hook" }
                                puts(r ? r["classes"] : 0)' "$(res_rows)")"

assert_eq "the dumper records method names for chain members" \
  "track" \
  "$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["ancestor_methods"].fetch("Trackable", []).join(",")' "$WORK/snap/classic.json")"

# The whole point of the map: chains reference modules that are not in scope as
# constants, and without their method names no resolution order can be computed.
assert_eq "including modules that are not captured as constants" \
  "true" \
  "$(ruby -rjson -e 'snap = JSON.parse(File.read(ARGV[0]))
                     puts(snap["ancestor_methods"].key?("Kernel") && !snap["constants"].key?("Kernel"))' "$WORK/snap/classic.json")"

assert_eq "a decorator loading before its class is context on the class it affects" \
  "1" "$(compare classic zeitwerk | grep -c 'opened by classic:')"

# Dependencies.unhook! defines load/require directly on Object, shadowing the
# classic hook. That is the mode switch itself, seen once per class -- 6 rows over
# ~4,400 classes each on the real application.
assert_eq "the autoloader unhook is collapsed by default" \
  "0" \
  "$(res_rows | ruby -rjson -e 'puts JSON.parse(ARGV[0]).count { |r| r["examples"].include?("UnhookBase") }' "$(res_rows)")"

assert_eq "--include-autoloader-shims brings it back" \
  "2" \
  "$(compare classic zeitwerk --format json --include-autoloader-shims \
     | ruby -rjson -e 'd = JSON.parse($stdin.read)
                       rows = d["resolution_order_changes"] + d["resolution_super_only"]
                       puts rows.count { |r| r["examples"].include?("UnhookBase") }')"

# The guard on the collapse being too broad: OwnRequire shadows #require for its
# own reasons, so its list changes by more than the arrival of Object.
# The prepended-shadow record. `meth` reads one method out of one constant's own
# method list -- the list the dumper built, so these assert what was recorded and
# not what Ruby would answer now.
meth() { # snapshot constant method field
  ruby -rjson -e '
    s = JSON.parse(File.read(ARGV[0]))
    c = s["constants"][ARGV[1]] or abort "no constant #{ARGV[1]}"
    m = (c["methods"] || []).find { |x| x["name"] == ARGV[2] && x["kind"] == "instance" }
    puts m ? m[ARGV[3]].to_s : "(absent)"
  ' "$WORK/snap/$1.json" "$2" "$3" "$4"
}

# Both own it, so both must be recorded -- reading the class's entry off the
# module was the bug.
assert_eq "a class and the module prepended over it both record the method" \
  "true true" \
  "$([ "$(meth classic Prepended value name)" != "(absent)" ] && printf true || printf false; printf ' '; [ "$(meth classic PrependedPatch value name)" != "(absent)" ] && printf true || printf false)"

# The two definitions sit on different lines of one file. Reading through the
# chain gave the class the module's line.
assert_eq "the class's record points at its own definition, not the module's" \
  "false" \
  "$([ "$(meth classic Prepended value line)" = "$(meth classic PrependedPatch value line)" ] && printf true || printf false)"

assert_eq "and its body digest is its own, not the module's" \
  "false" \
  "$([ "$(meth classic Prepended value body_sha)" = "$(meth classic PrependedPatch value body_sha)" ] && printf true || printf false)"

# The module's own record was never wrong; assert it stayed right.
assert_eq "the prepended module still records its own definition" \
  "true" \
  "$([ -n "$(meth classic PrependedPatch value body_sha)" ] && [ "$(meth classic PrependedPatch value body_sha)" != "(absent)" ] && printf true || printf false)"

# The consequence, and the regression this fixture exists for: with both sides
# digesting the module, this comparison came out clean.
assert_eq "a change to a shadowed method's own body is reported" \
  "1" \
  "$(compare classic zeitwerk --format json | ruby -rjson -e '
      puts JSON.parse($stdin.read)["method_set_changes"]
              .select { |e| e["constant"] == "PrependedDrift" }
              .sum { |e| e["changed"].length }')"

# ...and reported against the class, not against the module, whose body is
# identical on both branches.
assert_eq "the prepended module is not reported as changed" \
  "0" \
  "$(compare classic zeitwerk --format json | ruby -rjson -e '
      puts JSON.parse($stdin.read)["method_set_changes"]
              .select { |e| e["constant"] == "PrependedDriftPatch" }
              .sum { |e| e["changed"].length + e["removed"].length + e["added"].length }')"

assert_eq "a class shadowing the same method for its own reasons still reports" \
  "1" \
  "$(res_rows | ruby -rjson -e 'puts JSON.parse(ARGV[0]).count { |r| r["examples"].include?("OwnRequire") }' "$(res_rows)")"

# Constant values: LIMIT changed, KINDS reordered (order is the finding), NESTED
# and STABLE identical, CALLBACK a lambda that must never be reported.
vals() { compare classic zeitwerk --format json \
  | ruby -rjson -e 'puts JSON.generate(JSON.parse($stdin.read)["constant_value_changes"])'; }

assert_eq "a constant whose value changed is reported" \
  "Tunables::KINDS,Tunables::LIMIT" \
  "$(vals | ruby -rjson -e 'puts JSON.parse(ARGV[0]).map { |r| r["constant"] }.sort.join(",")' "$(vals)")"

# Asserting the COUNT is not enough: constant_value_changes was counted in the
# header for four versions with no renderer at all, so the findings were real and
# invisible. Assert the text report actually shows the row.
assert_eq "and it appears in the text report, not just the counts" \
  "1" "$(compare classic zeitwerk | grep -c '~ Tunables::LIMIT')"

# The general form of that bug: any section counted in the header must have a
# renderer. This compares the two lists the way an audit would.
assert_eq "every counted section has a renderer" \
  "" "$(compare classic zeitwerk | grep '^!! BUG' || true)"

# ... and the reader has to be able to get from the count to the rows. The
# heading leads with the same snake_case id the counts block is keyed by, so a
# number read up top is a token to search for down here.
assert_eq "a section heading leads with its id and its count" \
  "1" "$(compare classic zeitwerk | grep -c '^## constants_missing ([0-9]')"

# The general form: an id in a heading that names nothing in the counts block is
# decoration rather than a cross-reference. comm -23 lists headings with no
# counts line, which must be empty.
heading_ids() { compare classic zeitwerk | sed -n 's/^## \([a-z_][a-z_]*\) (.*/\1/p' | sort -u; }
counts_ids()  { compare classic zeitwerk | sed -n 's/^  \([a-z_][a-z_]*\)  *[0-9].*/\1/p' | sort -u; }

assert_eq "every heading id is a line in the counts block" \
  "" "$(comm -23 <(heading_ids) <(counts_ids))"

# A non-symbol filter is recorded by class, so several can share one label and an
# index lookup returns the same slot for all of them -- "4 -> 4", a move of zero.
assert_eq "a repeated filter label reports a count, not a null move" \
  "0" "$(compare classic zeitwerk | grep -cE '^ +[a-z_]+: <[A-Za-z:]+>  ([0-9]+) -> \1$')"

# The fixture apps live at different temp paths, so a constant built from
# Rails.root differs unless it is normalized the way every other path is.
assert_eq "a constant holding an absolute app path is not reported" \
  "0" \
  "$(vals | ruby -rjson -e 'puts JSON.parse(ARGV[0]).count { |r| r["constant"].include?("ROOT_FILE") }' "$(vals)")"

# Associations. A lost has_many is invisible to every other section -- the reader
# methods live in GeneratedAssociationMethods, which is collapsed.
assocs() { compare classic zeitwerk --format json \
  | ruby -rjson -e 'puts JSON.generate(JSON.parse($stdin.read)["association_changes"])'; }

assert_eq "a removed association is reported" \
  "removed:belongs_to:import_batch" \
  "$(assocs | ruby -rjson -e 'r = JSON.parse(ARGV[0]).find { |x| x["association"] == "import_batch" }
                              puts "#{r["status"]}:#{r["macro"]}:#{r["association"]}"' "$(assocs)")"

assert_eq "a changed association option is reported with both values" \
  "dependent: :destroy -> :nullify" \
  "$(assocs | ruby -rjson -e 'r = JSON.parse(ARGV[0]).find { |x| x["association"] == "payments" }
                              puts r["details"].join("; ")' "$(assocs)")"

assert_eq "an unchanged association is not reported" \
  "0" \
  "$(assocs | ruby -rjson -e 'puts JSON.parse(ARGV[0]).count { |x| x["constant"] == "Untouched" }' "$(assocs)")"

# Class attribute values -- the included-do side effects nothing else can see.
attrs() { compare classic zeitwerk --format json \
  | ruby -rjson -e 'puts JSON.generate(JSON.parse($stdin.read)["class_attribute_changes"])'; }

assert_eq "a class attribute whose value changed is reported" \
  "RealOwner,Registrar" \
  "$(attrs | ruby -rjson -e 'puts JSON.parse(ARGV[0]).map { |r| r["constant"] }.sort.join(",")' "$(attrs)")"

assert_eq "and the row names the filters that vanished" \
  "process_action: set_locale, log_delivery" \
  "$(attrs | ruby -rjson -e 'c = JSON.parse(ARGV[0]).find { |r| r["constant"] == "Registrar" }["chains"].first
                             puts "#{c["chain"]}: #{c["removed"].join(", ")}"' "$(attrs)")"

# Same filters, different order. Very unlikely to be a regression, an order of
# magnitude more common, so it must not sit in the semantic total next to a
# callback that genuinely stopped being registered.
order_rows() { compare classic zeitwerk --format json \
  | ruby -rjson -e 'puts JSON.generate(JSON.parse($stdin.read)["class_attribute_order_only"])'; }

assert_eq "a reordered chain is informational, not semantic" \
  "Shuffled" \
  "$(order_rows | ruby -rjson -e 'puts JSON.parse(ARGV[0]).map { |r| r["constant"] }.join(",")' "$(order_rows)")"

# An ownership change with no value change is inert: an assignment that wrote back
# the inherited value. Six rows across two sections said this about four mailer
# classes whose effective callbacks were byte-identical.
own_rows() { compare classic zeitwerk --format json \
  | ruby -rjson -e 'puts JSON.generate(JSON.parse($stdin.read)["attribute_ownership_only"])'; }

assert_eq "an ownership change with an identical value is informational" \
  "InertOwner" \
  "$(own_rows | ruby -rjson -e 'puts JSON.parse(ARGV[0]).map { |r| r["constant"] }.join(",")' "$(own_rows)")"

assert_eq "and it is gone from the semantic sections" \
  "0" \
  "$(compare classic zeitwerk --format json | ruby -rjson -e '
     d = JSON.parse($stdin.read)
     rows = d["resolution_order_changes"].flat_map { |r| r["examples"] } +
            d["method_set_changes"].map { |r| r["constant"] }
     puts rows.count("InertOwner")')"

# The guard: same shape, different value, must stay exactly where it was.
assert_eq "an ownership change WITH a value change stays semantic" \
  "1" \
  "$(compare classic zeitwerk --format json | ruby -rjson -e '
     puts JSON.parse($stdin.read)["method_set_changes"].count { |r| r["constant"] == "RealOwner" }')"

assert_eq "and it is not in the informational bucket" \
  "0" \
  "$(own_rows | ruby -rjson -e 'puts JSON.parse(ARGV[0]).count { |r| r["constant"] == "RealOwner" }' "$(own_rows)")"

# Naming the module that defines a filter turns "something moved" into "this
# module's include point moved", which is the thing you go and change.
assert_eq "a reordered filter names the module that defines it" \
  "Indexer|Sweeper" \
  "$(order_rows | ruby -rjson -e 'o = JSON.parse(ARGV[0]).first["chains"].first["owners"]
                                  puts "#{o["reindex"]}|#{o["notify_sweeper"]}"' "$(order_rows)")"

assert_eq "and it is excluded from the semantic total" \
  "0" \
  "$(compare classic zeitwerk --format json | ruby -rjson -e '
     c = JSON.parse($stdin.read)["counts"]; puts c["class_attribute_order_only"] - 1')"

assert_eq "an attribute holding an unserializable value is never reported" \
  "0" \
  "$(attrs | ruby -rjson -e 'puts JSON.parse(ARGV[0]).count { |r| r["constant"] == "Opaque" }' "$(attrs)")"

assert_eq "and it is recorded with its kind so the skip is visible" \
  "Object:" \
  "$(ruby -rjson -e 'v = JSON.parse(File.read(ARGV[0]))["constants"]["Opaque"]["class_attributes"]["__callbacks"]
                     puts "#{v["kind"]}:#{v["sha"]}"' "$WORK/snap/classic.json")"

assert_eq "a class that does not respond to the reader records nothing" \
  "{}" \
  "$(ruby -rjson -e 'require "json"
                     puts JSON.generate(JSON.parse(File.read(ARGV[0]))["constants"]["NoAttrs"]["class_attributes"])' "$WORK/snap/classic.json")"

assert_eq "a constant holding a lambda is never reported as changed" \
  "0" \
  "$(vals | ruby -rjson -e 'puts JSON.parse(ARGV[0]).count { |r| r["constant"].include?("CALLBACK") }' "$(vals)")"

assert_eq "and it is recorded with its kind so the skip is visible" \
  "callable:" \
  "$(ruby -rjson -e 'v = JSON.parse(File.read(ARGV[0]))["constants"]["Tunables"]["values"]["CALLBACK"]
                     puts "#{v["kind"]}:#{v["sha"]}"' "$WORK/snap/classic.json")"

assert_eq "a simple constant carries a digest" \
  "integer:yes" \
  "$(ruby -rjson -e 'v = JSON.parse(File.read(ARGV[0]))["constants"]["Tunables"]["values"]["LIMIT"]
                     puts "#{v["kind"]}:#{v["sha"] ? "yes" : "no"}"' "$WORK/snap/classic.json")"

# method_set_changes counts CLASSES; these count the methods inside them, which
# is what the old per-method sections used to report.
set_field() { # field [compare args]
  local field="$1"; shift
  compare classic zeitwerk --format json "$@" \
    | ruby -rjson -e 'puts JSON.parse($stdin.read)["method_set_changes"].sum { |r| r[ARGV[0]].length }' "$field"
}

# Widget#price (definition changed hands), the two DynamicAccessors bodies, the
# Registrar/Shuffled __callbacks readers -- whose bodies return the values -- and
# PrependedDrift#compute, which is only visible once the class's own definition
# is the one being digested.
assert_eq "the method whose definition changed hands is reported" \
  "7" "$(set_field changed)"

# Widget#retired_helper is defined nowhere else, so it must NOT be annotated;
# ShadowChild.setting still comes from the parent, so it must be.
removed_rows() { compare classic zeitwerk --format json \
  | ruby -rjson -e 'puts JSON.generate(JSON.parse($stdin.read)["method_set_changes"].flat_map { |r| r["removed"] })'; }

assert_eq "a removal that still resolves names where it now comes from" \
  "#<Class:ShadowParent>" \
  "$(removed_rows | ruby -rjson -e 'r = JSON.parse(ARGV[0]).find { |m| m["method"] == "ShadowChild.setting" }
                                    puts(r ? r["inherited_from"].to_s : "(no row)")' "$(removed_rows)")"

assert_eq "a genuine removal is not annotated" \
  "" \
  "$(removed_rows | ruby -rjson -e 'r = JSON.parse(ARGV[0]).find { |m| m["method"] == "Widget#retired_helper" }
                                    puts r["inherited_from"].to_s' "$(removed_rows)")"

# Widget#retired_helper, ShadowChild.setting, and RealOwner.__callbacks -- whose
# ownership change is NOT suppressed, because its value differs.
assert_eq "a class that lost a method is reported" \
  "3" "$(set_field removed)"

# Widget is the only class with both a lost method and a changed body, so the
# per-class grouping has to fold them into one row rather than two.
assert_eq "the section groups by class, not by method" \
  "Widget" \
  "$(compare classic zeitwerk --format json | ruby -rjson -e '
     rows = JSON.parse($stdin.read)["method_set_changes"]
     puts rows.select { |r| r["changed"].any? && r["removed"].any? }.map { |r| r["constant"] }.join(",")')"

# A method whose recorded source_location points at a block rather than at its
# own definition must not be hashed at all -- hashing whatever text lived there
# was two thirds of every body change reported against the real application.
assert_eq "a metaprogrammed method gets no source hash" \
  "generated:" \
  "$(ruby -rjson -e 'm = JSON.parse(File.read(ARGV[0]))["constants"]["MetaProbe"]["methods"]
                     g = m.find { |x| x["name"] == "generated_one" }
                     puts "#{g["source"]}:#{g["source_sha"]}"' "$WORK/snap/classic.json")"

assert_eq "and the real method beside it still is" \
  "ruby" \
  "$(ruby -rjson -e 'm = JSON.parse(File.read(ARGV[0]))["constants"]["MetaProbe"]["methods"]
                     puts m.find { |x| x["name"] == "real_one" }["source"]' "$WORK/snap/classic.json")"

assert_eq "so the block around it changing is not reported as a body change" \
  "0" "$(compare classic zeitwerk --format json | ruby -rjson -e '
     rows = JSON.parse($stdin.read)["method_set_changes"]
     puts rows.count { |r| r["constant"] == "MetaProbe" }')"

# The FacilitySettings case. define_method accessors have no usable source text,
# so before bodies were digested from the instruction sequence a real change in
# them produced nothing at all -- 13% of every method in the application.
# generated_one has no source digest at all -- exactly the state every one of
# FacilitySettings' 626 accessors is in -- and must still be comparable.
assert_eq "a method with no source digest still gets a body digest" \
  "generated::iseq:yes" \
  "$(ruby -rjson -e 'm = JSON.parse(File.read(ARGV[0]))["constants"]["MetaProbe"]["methods"]
                     a = m.find { |x| x["name"] == "generated_one" }
                     puts "#{a["source"]}:#{a["source_sha"]}:#{a["body"]}:#{a["body_sha"] ? "yes" : "no"}"' \
       "$WORK/snap/classic.json")"

assert_eq "and so does a define_method accessor" \
  "iseq:yes" \
  "$(ruby -rjson -e 'm = JSON.parse(File.read(ARGV[0]))["constants"]["DynamicAccessors"]["methods"]
                     a = m.find { |x| x["name"] == "alpha" }
                     puts "#{a["body"]}:#{a["body_sha"] ? "yes" : "no"}"' "$WORK/snap/classic.json")"

# The number that says whether Bootsnap defeated the whole approach.
assert_eq "the snapshot reports how many bodies it managed to digest" \
  "true" \
  "$(ruby -rjson -e 'c = JSON.parse(File.read(ARGV[0]))["counts"]
                     puts(c["body_digests"].to_i > c["methods"].to_i / 2)' "$WORK/snap/classic.json")"

assert_eq "and a change to its body is reported" \
  "DynamicAccessors#alpha,DynamicAccessors#beta" \
  "$(compare classic zeitwerk --format json | ruby -rjson -e '
     row = JSON.parse($stdin.read)["method_set_changes"].find { |r| r["constant"] == "DynamicAccessors" }
     puts(row ? row["changed"].map { |m| m["method"] }.sort.join(",") : "(no row)")')"

# Widget#doubled contains a block and its file is renamed between the fixtures.
# A block's disassembly names the file it was defined in, so this is the guard on
# stripping paths out before hashing.
assert_eq "a block-bearing method whose file moved is not a body change" \
  "0" "$(compare classic zeitwerk --format json | ruby -rjson -e '
     rows = JSON.parse($stdin.read)["method_set_changes"]
     puts rows.sum { |r| r["changed"].count { |m| m["method"] == "Widget#doubled" } }')"

# real_one gains a comment on the zeitwerk side, which changes its source text
# and not its compiled body.
assert_eq "a comment-only edit is not a body change" \
  "0" "$(compare classic zeitwerk --format json | ruby -rjson -e '
     rows = JSON.parse($stdin.read)["method_set_changes"]
     puts rows.sum { |r| r["changed"].count { |m| m["method"] == "MetaProbe#real_one" } }')"

# widget.rb moved. Without a rename map it reads as removed-here-added-there in
# the load set; with one, both sides resolve to the same path.
FILES_NO_MAP=$(( $(count classic zeitwerk files_only_a) + $(count classic zeitwerk files_only_b) ))

cat > "$WORK/renames.json" <<'JSON'
{"old_to_new": {"app/widget.rb": "app/store/widget.rb"},
 "new_to_old": {"app/store/widget.rb": "app/widget.rb"}}
JSON

FILES_MAP=$(( $(count classic zeitwerk files_only_a --renames "$WORK/renames.json") \
            + $(count classic zeitwerk files_only_b --renames "$WORK/renames.json") ))

# The reason the file set is a union of three signals. patched_both.rb loads on
# BOTH sides but is invisible to two of them on the classic side: Kernel#load
# never touches $LOADED_FEATURES, and Foo.class_eval executes no class body.
# Only Dependencies.history sees it. Reporting it would be a false positive on
# every monkey-patch file in the application.
files_side() { compare classic zeitwerk --format json \
  | ruby -rjson -e 'puts JSON.generate(JSON.parse($stdin.read)[ARGV[0]])' "$1"; }

assert_eq "a monkey-patch file loaded on both sides is not reported" \
  "0" \
  "$(files_side files_only_b | ruby -rjson -e 'puts JSON.parse(ARGV[0]).count { |f| f.include?("patched_both") }' "$(files_side files_only_b)")"

assert_eq "and one loaded on a single side is" \
  "1" \
  "$(files_side files_only_b | ruby -rjson -e 'puts JSON.parse(ARGV[0]).count { |f| f.include?("patched_zeitwerk_only") }' "$(files_side files_only_b)")"

# history holds "app/patched_both", the other two signals hold
# "app/patched_both.rb". Without restoring the extension they never dedupe and
# every classic-autoloaded file is reported as main-only.
assert_eq "an extension-less load record does not become an orphan row" \
  "0" \
  "$(files_side files_only_a | ruby -rjson -e 'puts JSON.parse(ARGV[0]).count { |f| !f.end_with?(".rb") }' "$(files_side files_only_a)")"

assert_eq "the classic load record is captured" \
  "true" \
  "$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["counts"]["autoloaded"].to_i.positive?' "$WORK/snap/classic.json")"

# Losing that record degrades the file sections silently, so it has to be loud.
# Losing that record degrades the file sections silently, so it has to be loud.
# Asserted per label: the real classic snapshot has history and must not warn.
assert_eq "a classic snapshot WITH a load record does not warn" \
  "0" "$(compare classic zeitwerk | grep -c '^!  warning: classic: classic autoloader')"

ruby -rjson -e 's = JSON.parse(File.read(ARGV[0])); s["counts"]["autoloaded"] = 0
                File.write(ARGV[1], JSON.generate(s))' \
  "$WORK/snap/classic.json" "$WORK/snap/nohistory.json"

assert_eq "and one without it warns" \
  "1" "$(compare nohistory zeitwerk | grep -c '^!  warning: classic: classic autoloader')"

echo
echo "-- autoload registry --"

# Which constants each autoloader considers its own. Nothing else in the snapshot
# answers that, so a constant that stops being managed compares clean everywhere
# else and only shows up as an edit that stops taking effect in development.
registry_rows() { compare classic zeitwerk --format json \
  | ruby -rjson -e 'puts JSON.generate(JSON.parse($stdin.read)[ARGV[0]])' "$1"; }

has_row() { # section constant
  ruby -rjson -e 'puts JSON.parse(ARGV[0]).include?(ARGV[1])' "$(registry_rows "$1")" "$2"
}

assert_eq "classic's constant record is captured" \
  "true" \
  "$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["counts"]["autoloaded_constants"].to_i.positive?' "$WORK/snap/classic.json")"

assert_eq "zeitwerk's loader registry is captured" \
  "true" \
  "$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["counts"]["unloadable_main"].to_i.positive?' "$WORK/snap/zeitwerk.json")"

# The false-positive guard: managed on both sides is the normal case and must be
# silent, or the section is one row per application constant.
assert_eq "a constant both autoloaders manage is not reported" \
  "false false" \
  "$(has_row autoload_managed_only_a Widget) $(has_row autoload_managed_only_b Widget)"

assert_eq "a constant only classic autoloaded is reported" \
  "true" "$(has_row autoload_managed_only_a Depot::Crate)"

assert_eq "a constant zeitwerk registered but never loaded is reported" \
  "true" "$(has_row autoload_managed_only_b Registered::NeverLoaded)"

# The once loader manages autoload_once_paths. Leaving it out of the union would
# report everything it holds as no longer managed.
assert_eq "the once loader counts as managed" \
  "false" "$(has_row autoload_managed_only_a MetaProbe)"

# Two annotations, because "absent from B" has two very different causes and the
# row is unreadable without knowing which.
assert_eq "a row that is also a constants_missing finding says so" \
  "1" "$(compare classic zeitwerk | grep -c '^  Gadget   (also in constants_missing)$')"

assert_eq "a registered-but-unloaded row says so" \
  "1" "$(compare classic zeitwerk | grep -c '^  Registered::NeverLoaded   (registered, not loaded)$')"

# An empty registry compares clean against anything, so it has to be loud -- the
# same silent degradation as a missing Dependencies.history.
assert_eq "a snapshot with a registry does not warn" \
  "0" "$(compare classic zeitwerk | grep -c 'registered no constants at all')"

ruby -rjson -e 's = JSON.parse(File.read(ARGV[0]))
                %w[autoloaded_constants unloadable_main unloadable_once].each { |k| s["counts"][k] = 0 }
                File.write(ARGV[1], JSON.generate(s))' \
  "$WORK/snap/classic.json" "$WORK/snap/noregistry.json"

assert_eq "and one without it warns" \
  "1" "$(compare noregistry zeitwerk | grep -c '^!  warning: classic: the autoloader registered no constants')"

if [ "$FILES_MAP" -lt "$FILES_NO_MAP" ]; then
  ok "the rename map collapses a moved file ($FILES_NO_MAP -> $FILES_MAP)"
else
  bad "the rename map collapses a moved file" "expected fewer than $FILES_NO_MAP, got $FILES_MAP"
fi

# The zeitwerk fixture is indented one level deeper throughout. Only the one
# method whose definition genuinely changed hands may show a source difference.
assert_eq "re-indentation alone is not reported as a source change" \
  "7" "$(set_field changed --renames "$WORK/renames.json")"

echo
echo "-- guards --"

# Same snapshots, different eager_load: must refuse rather than emit a diff.
ruby -rjson -e '
s = JSON.parse(File.read(ARGV[0])); s["identity"]["eager_load"] = false
File.write(ARGV[1], JSON.generate(s))
' "$WORK/snap/classic.json" "$WORK/snap/mismatched.json"

compare classic mismatched > "$WORK/guard.txt" 2>&1
assert_eq "mismatched eager_load is refused (exit 2)" "2" "$?"

if grep -q "not comparable" "$WORK/guard.txt"; then
  ok "the refusal explains why"
else
  bad "the refusal explains why" "$(tail -2 "$WORK/guard.txt")"
fi

compare classic zeitwerk --exit-code --summary-only > /dev/null 2>&1
assert_eq "--exit-code returns 1 while differences remain" "1" "$?"

compare classic classic2 --exit-code --summary-only > /dev/null 2>&1
assert_eq "--exit-code returns 0 when there are none" "0" "$?"

# Ignore list must subtract from the counts.
cat > "$WORK/ignore.txt" <<'TXT'
constant Gadget
TXT
assert_eq "the ignore list removes a triaged constant" \
  "0" "$(count classic zeitwerk constants_missing --ignore "$WORK/ignore.txt")"

# "ancestor" matches a chain member, not the chain owner: striking these from
# both chains leaves them identical, so Widget's row disappears entirely.
# The anonymous rule also proves "#<" is not treated as a comment -- every
# anonymous label starts with it, so the pattern would otherwise be stripped away
# and the rule would silently become a bare "ancestor" with no pattern.
cat > "$WORK/ignore-ancestor.txt" <<'TXT'
ancestor Auditable
ancestor Reorderable
ancestor Collide
ancestor Crash
ancestor #<anonymous module of Solo*
TXT
assert_eq "an ancestor rule removes a triaged chain member" \
  "0" \
  "$(compare classic zeitwerk --format json --ignore "$WORK/ignore-ancestor.txt" \
     | ruby -rjson -e 'rows = JSON.parse($stdin.read)["resolution_order_changes"]
                       puts rows.count { |r| r["examples"].include?("Overlapping") }')"

# Globs cross "::" -- the escape hatch for the next globally-prepended module.
cat > "$WORK/ignore-glob.txt" <<'TXT'
ancestor ActiveSupport::Dependencies::ZeitwerkIntegration::*
TXT
# Without the glob the shim contributes #require_dependency to Shimmed; with it,
# the label is struck from the chain and the row disappears.
shim_rows() { compare classic zeitwerk --format json --include-zeitwerk-shims "$@" \
  | ruby -rjson -e 'rows = JSON.parse($stdin.read)["resolution_order_changes"]
                    puts rows.count { |r| r["method"] == "require_dependency" }'; }

assert_eq "the shim is visible with --include-zeitwerk-shims" "1" "$(shim_rows)"

assert_eq "an ancestor glob crosses :: and reaches the shim on its own" \
  "0" "$(shim_rows --ignore "$WORK/ignore-glob.txt")"

# A rule that quietly does nothing is worse than no rule -- you cross it off the
# triage list and move on. Each of these used to be silent.

warnings_for() { # ignore-file
  compare classic zeitwerk --format json --ignore "$1" \
    | ruby -rjson -e 'puts JSON.parse($stdin.read)["warnings"].grep(/ignore list/).join("\n")'
}

# "app/store/widget.rb" is two levels deep. Under FNM_PATHNAME a trailing /**
# stops one level short, so this rule used to be a no-op; it now normalizes to
# /**/* and reaches the file. (files_only_b also holds an out-of-root path from
# the fakegem fixture, which no app/ pattern can match -- hence 1, not 0.)
printf 'file app/**\n'   > "$WORK/ignore-recursive.txt"
printf 'file app/**/*\n' > "$WORK/ignore-explicit.txt"
printf 'file app/*\n'    > "$WORK/ignore-onelevel.txt"

assert_eq "a trailing /** in a file rule recurses instead of stopping one level down" \
  "1" "$(count classic zeitwerk files_only_b --ignore "$WORK/ignore-recursive.txt")"

assert_eq "and matches exactly what the explicit recursive form matches" \
  "$(count classic zeitwerk files_only_b --ignore "$WORK/ignore-explicit.txt")" \
  "$(count classic zeitwerk files_only_b --ignore "$WORK/ignore-recursive.txt")"

# Guards the rewrite: if /** were normalized to something that matches anything,
# or if a single * had been widened too, this would drop to 1.
assert_eq "a single * still matches only one level" \
  "2" "$(count classic zeitwerk files_only_b --ignore "$WORK/ignore-onelevel.txt")"

cat > "$WORK/ignore-typo.txt" <<'TXT'
constnat Gadget
method
TXT
assert_eq "a misspelled rule kind is reported with its line number" \
  "1" "$(warnings_for "$WORK/ignore-typo.txt" | grep -c 'line 1: unknown rule kind "constnat"')"

assert_eq "a rule with no pattern is reported too" \
  "1" "$(warnings_for "$WORK/ignore-typo.txt" | grep -c 'line 2: method rule has no pattern')"

cat > "$WORK/ignore-unused.txt" <<'TXT'
constant Gadget
constant Nonexistent::Thing
TXT
assert_eq "a rule that matches nothing is reported" \
  "1" "$(warnings_for "$WORK/ignore-unused.txt" | grep -c 'matched nothing: constant Nonexistent::Thing')"

# Guards the hit tracking: if it credited every rule, or none, this would fail.
assert_eq "a rule that does match is not reported as unused" \
  "0" "$(warnings_for "$WORK/ignore-unused.txt" | grep -c 'constant Gadget')"

# Comments are the documented way to record WHY a rule exists, and they used to
# end up inside the pattern -- silently reducing the rule to a glob that matched
# nothing. The "#" in "Widget#price" must survive, though.
cat > "$WORK/ignore-comments.txt" <<'TXT'
# Gadget is deliberately not loaded on the zeitwerk branch.
constant Gadget   # confirmed 2026-08-05
TXT
assert_eq "an inline comment does not become part of the pattern" \
  "0" "$(count classic zeitwerk constants_missing --ignore "$WORK/ignore-comments.txt")"

assert_eq "and a commented rule is not reported as unused or malformed" \
  "" "$(warnings_for "$WORK/ignore-comments.txt")"

cat > "$WORK/ignore-hash.txt" <<'TXT'
method Widget#price   # the hash here is a method separator, not a comment
TXT
assert_eq "a # inside a method rule survives comment stripping" \
  "0" "$(warnings_for "$WORK/ignore-hash.txt" | grep -c 'matched nothing')"

echo
echo "-- anonymize --"

# --anonymize redacts the identity of the machine and the checkouts, never the
# findings. What it is FOR is a run whose output leaves this machine, and the
# artifact that produces is --anonymize together with --summary-only.

# The fixture apps are not git repositories, so identity.branch and identity.sha
# come out nil and a header assertion would pass against nothing. Planted, the
# way the eager_load and script-version guards are.
ruby -rjson -e 's = JSON.parse(File.read(ARGV[0]))
                s["identity"]["branch"] = "topsecret-branch"
                s["identity"]["sha"] = "deadbeefcafe1234"
                File.write(ARGV[1], JSON.generate(s))' \
  "$WORK/snap/classic.json" "$WORK/snap/identified.json"

# Asserted in both directions: without the negative case the positive one would
# also pass against a header that stopped being rendered at all.
assert_eq "the header names the branch and SHA by default" \
  "1" "$(compare identified zeitwerk | grep -c 'topsecret-branch @ deadbeefca')"

assert_eq "and --anonymize drops both" \
  "0" "$(compare identified zeitwerk --anonymize | grep -c 'topsecret-branch\|deadbeefca')"

# The labels are how you tell the two sides apart. Dropping them would make the
# report unreadable rather than anonymous.
assert_eq "the labels survive --anonymize" \
  "1" "$(compare identified zeitwerk --anonymize | grep -c '^  A (base):     classic$')"

anon_warnings_for() { # ignore-file
  compare classic zeitwerk --format json --anonymize --ignore "$1" \
    | ruby -rjson -e 'puts JSON.parse($stdin.read)["warnings"].grep(/ignore list/).join("\n")'
}

# An ignore rule is a glob written over application constant names, and it used
# to ride out in a warning that --summary-only keeps.
assert_eq "an unused rule is counted, not quoted" \
  "1 0" \
  "$(anon_warnings_for "$WORK/ignore-unused.txt" | grep -c 'rule(s) matched nothing$') $(anon_warnings_for "$WORK/ignore-unused.txt" | grep -c 'Nonexistent::Thing')"

# Same for a malformed rule: the message quotes the line's first token, which is
# as likely as not a constant name. The line number is what survives, because it
# is what you act on and it says nothing.
assert_eq "a malformed rule keeps its line number and loses its text" \
  "1 0" \
  "$(anon_warnings_for "$WORK/ignore-typo.txt" | grep -c 'malformed rule(s) at line(s) 1, 2') $(anon_warnings_for "$WORK/ignore-typo.txt" | grep -c 'constnat')"

# The third leak: an A -> B, B -> C shuffle is reported by path.
ruby -rjson -e 'File.write(ARGV[0], JSON.generate(
  "old_to_new" => { "app/a.rb" => "app/b.rb", "app/b.rb" => "app/c.rb" }))' \
  "$WORK/renames-ambiguous.json"

ambiguous() { compare classic zeitwerk --renames "$WORK/renames-ambiguous.json" "$@" \
  | grep '^!  warning: 1 path'; }

assert_eq "an ambiguous rename is named by default" \
  "1" "$(ambiguous | grep -c 'app/b.rb')"

assert_eq "and counted without its path under --anonymize" \
  "1 0" "$(ambiguous --anonymize | grep -c 'uncanonicalized$') $(ambiguous --anonymize | grep -c 'app/b.rb')"

# The claim the whole mode rests on. --summary-only removes the rows,
# --anonymize removes what is left, and neither does the other's job.
assert_eq "--anonymize --summary-only carries nothing from the application" \
  "0" \
  "$(compare classic zeitwerk --anonymize --summary-only | grep -c 'Widget\|Gadget\|Depot\|MetaProbe\|app/')"

# ... and the counts are still there, or it would be safe and useless.
assert_eq "while still reporting the counts" \
  "1" \
  "$(compare classic zeitwerk --anonymize --summary-only | grep -c '^  semantic total: [0-9]')"

echo
echo "-- hostile introspection --"

mkdir -p "$WORK/hostile/config" "$WORK/hostile/app"
cat > "$WORK/hostile/app/hostile.rb" <<'RUBY'
class Hostile
  def self.name; raise "no name for you"; end
  def self.ancestors; raise "no ancestors"; end
  def self.instance_methods(*); raise "nope"; end
  def self.respond_to?(*); raise "nope"; end
  def self.==(*); raise "nope"; end
  def real_method; 1; end
end
class Sneaky
  def self.name; "TotallyDifferentName"; end
  def real_method; 2; end
end
RUBY
echo 'require_relative "../app/hostile"' > "$WORK/hostile/config/application.rb"

snapshot "$WORK/hostile" hostile > /dev/null

assert_eq "classes that override name/ancestors/== do not crash the dump" \
  "0" \
  "$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["counts"]["skipped"]' "$WORK/snap/hostile.json")"

assert_eq "a class that lies about its name is keyed by its real one" \
  "true" \
  "$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["constants"].key?("Sneaky")' "$WORK/snap/hostile.json")"

assert_eq "a class that raises from ancestors is still captured" \
  "true" \
  "$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["constants"].key?("Hostile")' "$WORK/snap/hostile.json")"

echo
echo "-- pending autoloads --"

# Module#autoload? defaults to inherit = true, and a constant defined on the
# receiver does NOT stop the ancestor walk. So a class defining its own SMS used
# to be skipped because Object had a pending autoload for that name -- which is
# how Lead::Kinds::SMS vanished from the non-eager Zeitwerk snapshot while being
# defined three characters away in the same class body.
mkdir -p "$WORK/autoload-guard/config" "$WORK/autoload-guard/app"

cat > "$WORK/autoload-guard/app/never_loaded.rb" <<'RUBY'
raise "the snapshot triggered a pending autoload"
RUBY

cat > "$WORK/autoload-guard/app/holder.rb" <<'RUBY'
class Holder
  # Same name as the pending top-level autoload registered below, and defined
  # right here. This is the one that must survive.
  SMS = "local"
  # A genuinely pending autoload on this very module. This one must still be
  # skipped -- reading it would load the file, which is the whole reason the
  # guard exists.
  autoload :Later, File.expand_path("never_loaded.rb", __dir__)
end
RUBY

cat > "$WORK/autoload-guard/config/application.rb" <<'RUBY'
Object.autoload(:SMS, File.expand_path("../app/never_loaded.rb", __dir__))
require_relative "../app/holder"
RUBY

snapshot "$WORK/autoload-guard" autoload_guard > /dev/null

value_of() { # snapshot constant name
  ruby -rjson -e '
    c = JSON.parse(File.read(ARGV[0]))["constants"][ARGV[1]]
    v = c && (c["values"] || {})[ARGV[2]]
    puts(v && v["sha"] ? "recorded" : "absent")
  ' "$WORK/snap/$1.json" "$2" "$3"
}

assert_eq "a constant shadowed by a pending top-level autoload is still recorded" \
  "recorded" "$(value_of autoload_guard Holder SMS)"

assert_eq "a pending autoload on the module itself is still skipped" \
  "absent" "$(value_of autoload_guard Holder Later)"

echo
echo "-- constant hash ordering --"

# A constant hash built by iterating something that follows load order reorders
# for reasons unrelated to behaviour. Net::SSH::Connection::Session::MAP produced
# three digests across four snapshots with identical contents, two of them from
# the same branch -- so hash pairs are digested sorted, and insertion order is
# reported separately.
for variant in same reordered changed; do
  mkdir -p "$WORK/hash-$variant/config" "$WORK/hash-$variant/app"
  echo 'require_relative "../app/hash_order"' > "$WORK/hash-$variant/config/application.rb"
done

cat > "$WORK/hash-same/app/hash_order.rb" <<'RUBY'
module HashOrder
  MAP = { alpha: 1, beta: 2 }
end
RUBY

cat > "$WORK/hash-reordered/app/hash_order.rb" <<'RUBY'
module HashOrder
  MAP = { beta: 2, alpha: 1 }
end
RUBY

cat > "$WORK/hash-changed/app/hash_order.rb" <<'RUBY'
module HashOrder
  MAP = { beta: 2, alpha: 99 }
end
RUBY

snapshot "$WORK/hash-same"      hash_same      > /dev/null
snapshot "$WORK/hash-reordered" hash_reordered > /dev/null
snapshot "$WORK/hash-changed"   hash_changed   > /dev/null

assert_eq "a hash that only reordered is not a value change" \
  "0" "$(count hash_same hash_reordered constant_value_changes)"

assert_eq "and it is reported as an ordering difference instead" \
  "1" "$(count hash_same hash_reordered constant_value_order_only)"

# The guard that matters: sorting the pairs must not be able to hide a real
# difference. Same reordering as above, plus one changed value.
assert_eq "a hash whose value changed is still a value change" \
  "1" "$(count hash_same hash_changed constant_value_changes)"

assert_eq "and it is not filed as ordering only" \
  "0" "$(count hash_same hash_changed constant_value_order_only)"

echo
echo "-- re-entrant loads --"

# The FacilitySettings failure: a file read while it was still being written.
# Whichever of the two loads first decides whether the second sees a finished
# definition or a half-built one, which is why changing load order surfaces it.
mkdir -p "$WORK/reentrant/config" "$WORK/reentrant/app"

cat > "$WORK/reentrant/app/mod_a.rb" <<'RUBY'
module ModA
  PARTIAL = {}
  # Mid-body. ClassB loads, includes this module, and sees PARTIAL empty --
  # everything below this line does not exist yet as far as ClassB is concerned.
  require_relative "class_b"
  PARTIAL[:filled] = true
end
RUBY

cat > "$WORK/reentrant/app/class_b.rb" <<'RUBY'
class ClassB
  include ModA
end
RUBY

cat > "$WORK/reentrant/app/base_a.rb" <<'RUBY'
class BaseA
  require_relative "child_b"
end
RUBY

cat > "$WORK/reentrant/app/child_b.rb" <<'RUBY'
class ChildB < BaseA
end
RUBY

# The false-positive guard. An ordinary concern, included by an ordinary class,
# with nothing re-entrant about it. If this ever shows up, the detector is
# reporting nesting rather than re-entrancy and is worthless on a real app.
cat > "$WORK/reentrant/app/clean_mod.rb" <<'RUBY'
module CleanMod
  FULLY = :built
end
RUBY

cat > "$WORK/reentrant/app/clean_class.rb" <<'RUBY'
require_relative "clean_mod"
class CleanClass
  include CleanMod
end
RUBY

cat > "$WORK/reentrant/config/application.rb" <<'RUBY'
require_relative "../app/mod_a"
require_relative "../app/base_a"
require_relative "../app/clean_class"
RUBY

snapshot "$WORK/reentrant" reentrant > /dev/null

cycles() { ruby "$SCRIPT_DIR/find_load_cycles.rb" "$WORK/snap/$1.json" "${@:2}"; }

cycles_json() { # label ruby-expression-over-parsed-json
  cycles "$1" --json | ruby -rjson -e 'j = JSON.parse($stdin.read); puts (eval ARGV[0])' "$2"
}

assert_eq "a file read while still loading is reported" \
  "2" "$(cycles_json reentrant 'j["findings"].length')"

assert_eq "the module included mid-body is named, with its file" \
  "app/mod_a.rb" \
  "$(cycles_json reentrant 'j["findings"].find { |f| f["constant"] == "ClassB" }["in_flight_file"]')"

assert_eq "and it is labelled as an include" \
  "includes" \
  "$(cycles_json reentrant 'j["findings"].find { |f| f["constant"] == "ClassB" }["relation"]')"

# Worse than an include: a subclass reads its superclass's macros, callbacks and
# class attributes at definition time, so a half-built superclass is silent.
assert_eq "a superclass that was still loading is labelled as inheritance" \
  "inherits" \
  "$(cycles_json reentrant 'j["findings"].find { |f| f["constant"] == "ChildB" }["relation"]')"

assert_eq "an ordinary include of a finished module is not reported" \
  "0" "$(cycles_json reentrant 'j["findings"].count { |f| f["constant"] == "CleanClass" }')"

assert_eq "both constants that read an incomplete file are named" \
  "ChildB,ClassB" \
  "$(cycles_json reentrant 'j["findings"].map { |f| f["constant"] }.sort.join(",")')"

assert_eq "--exit-code returns 1 when a re-entrant load is found" \
  "1" "$(cycles reentrant --exit-code > /dev/null 2>&1; echo $?)"

# A sorted list is not a clock. autoloaded was stored sorted through script
# version 12, and ranking against it claimed 14,768 re-entrant pairs on the real
# application -- every one of them an alphabetical accident.
ruby -rjson -e '
  s = JSON.parse(File.read(ARGV[0]))
  s["load_order"]["autoloaded"] = (1..200).map { |i| format("app/f%03d.rb", i) }
  File.write(ARGV[1], JSON.generate(s))
' "$WORK/snap/reentrant.json" "$WORK/snap/reentrant_sorted.json"

assert_eq "a sorted autoloaded list is refused rather than ranked" \
  "1" "$(cycles reentrant_sorted | grep -c 'sorted order')"

assert_eq "and the refusal is visible in the coverage block" \
  "1" "$(cycles reentrant_sorted | grep -c 'refused: sorted')"

# Coverage is printed because a pair that could not be ranked looks exactly like
# a pair that was ranked and found clean.
assert_eq "coverage is reported even when nothing is found" \
  "1" "$(cycles hash_same | grep -c '## Coverage')"

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m%d passed, 0 failed\033[0m\n\n' "$PASS"
  exit 0
else
  printf '\033[31m%d passed, %d FAILED\033[0m\n\n' "$PASS" "$FAIL"
  exit 1
fi
