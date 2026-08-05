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
APP_DIR = File.expand_path(ARGV[0])
DUMP    = File.expand_path(ARGV[1])

module Rails
  Config = Struct.new(:eager_load, :autoloader, :autoload_paths, :eager_load_paths, :autoload_once_paths)
  App = Struct.new(:config)
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
class Widget
  include Trackable
  include Auditable
  def price; 100; end
  def self.build; new; end
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
require_relative "../lib/decorator"
RUBY

# Same class bodies, re-indented one level (as a namespacing change would do),
# minus Auditable. Gadget is never required. Decorator loads first.
cat > "$WORK/zeitwerk/app/store/widget.rb" <<'RUBY'
module Trackable
    def track; "tracked"; end
end
module Auditable
    def audit; "audited"; end
end
class Widget
    include Trackable
    def price; 100; end
    def self.build; new; end
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

cat > "$WORK/zeitwerk/config/application.rb" <<'RUBY'
require_relative "../../fakegem/autovivify"
require_relative "../lib/decorator"
require_relative "../app/store/widget"
require_relative "../app/shimmed"
require_relative "../app/depot"
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

assert_eq "a concern that stopped being included is reported" \
  "1" "$(count classic zeitwerk ancestor_diffs)"

# The 1 above is also the proof that Shimmed's ZeitwerkIntegration shim was
# collapsed -- uncollapsed it would be its own row. Rails prepends that module to
# Object, so left in it is one global fact re-reported once per constant.
assert_eq "--include-zeitwerk-shims brings the shim back" \
  "2" "$(count classic zeitwerk ancestor_diffs --include-zeitwerk-shims)"

assert_eq "a decorator loading before its class is reported" \
  "1" "$(count classic zeitwerk reopen_order_changes)"

assert_eq "the method whose definition changed hands is reported" \
  "1" "$(count classic zeitwerk source_diffs)"

# Trackable#track, Widget#price, Widget#secret and Widget.build all moved file.
# Without a rename map they are relocations; with one they must vanish.
RELOC_NO_MAP="$(count classic zeitwerk method_relocations)"
if [ "$RELOC_NO_MAP" -gt 0 ]; then
  ok "moved methods are reported when no rename map is supplied ($RELOC_NO_MAP)"
else
  bad "moved methods are reported when no rename map is supplied" "got 0"
fi

cat > "$WORK/renames.json" <<'JSON'
{"old_to_new": {"app/widget.rb": "app/store/widget.rb"},
 "new_to_old": {"app/store/widget.rb": "app/widget.rb"}}
JSON

assert_eq "the rename map collapses those relocations to zero" \
  "0" "$(count classic zeitwerk method_relocations --renames "$WORK/renames.json")"

# The zeitwerk fixture is indented one level deeper throughout. Only the one
# method whose definition genuinely changed hands may show a source difference.
assert_eq "re-indentation alone is not reported as a source change" \
  "1" "$(count classic zeitwerk source_diffs --renames "$WORK/renames.json")"

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

# "ancestor" matches a chain member, not the chain owner: ignoring Auditable
# removes it from both chains, so Widget's row disappears entirely.
cat > "$WORK/ignore-ancestor.txt" <<'TXT'
ancestor Auditable
TXT
assert_eq "an ancestor rule removes a triaged chain member" \
  "0" "$(count classic zeitwerk ancestor_diffs --ignore "$WORK/ignore-ancestor.txt")"

# Globs cross "::" -- the escape hatch for the next globally-prepended module.
cat > "$WORK/ignore-glob.txt" <<'TXT'
ancestor ActiveSupport::Dependencies::ZeitwerkIntegration::*
TXT
assert_eq "an ancestor glob crosses :: and reaches the shim on its own" \
  "1" "$(count classic zeitwerk ancestor_diffs --include-zeitwerk-shims \
           --ignore "$WORK/ignore-glob.txt")"

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
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m%d passed, 0 failed\033[0m\n\n' "$PASS"
  exit 0
else
  printf '\033[31m%d passed, %d FAILED\033[0m\n\n' "$PASS" "$FAIL"
  exit 1
fi
