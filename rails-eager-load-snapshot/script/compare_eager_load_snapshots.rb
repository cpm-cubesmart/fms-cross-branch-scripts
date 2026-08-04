# script/compare_eager_load_snapshots.rb
# frozen_string_literal: true

require "json"
require "set"

classic_path, zeitwerk_path, renames_path = ARGV

unless classic_path && zeitwerk_path
  abort <<~USAGE
    Usage:
      ruby script/compare_eager_load_snapshots.rb tmp/eager-load-classic.json tmp/eager-load-zeitwerk.json [tmp/git-renames.json]
  USAGE
end

classic = JSON.parse(File.read(classic_path))
zeitwerk = JSON.parse(File.read(zeitwerk_path))

renames =
  if renames_path
    JSON.parse(File.read(renames_path))
  else
    { "old_to_new" => {}, "new_to_old" => {} }
  end

old_to_new = renames.fetch("old_to_new", {})
new_to_old = renames.fetch("new_to_old", {})

# Canonicalize paths to the Zeitwerk/current-branch path.
#
# Classic snapshot likely contains old paths.
# Zeitwerk snapshot likely contains new paths.
#
# So:
#   classic old/path.rb  -> new/path.rb
#   zeitwerk new/path.rb -> new/path.rb
#
def canonical_path(path, old_to_new)
  old_to_new.fetch(path, path)
end

IGNORED_GEM_SOURCE_PATH_PATTERNS = [
  # %r{/gems/rack-[^/]+/},
  # %r{/gems/rack-cors-[^/]+/}
].freeze

def ignored_source_path?(path)
  IGNORED_GEM_SOURCE_PATH_PATTERNS.any? { |pattern| path.match?(pattern) }
end

def app_source_files_for(constant_data)
  constant_data
    .fetch("source_files", [])
    .reject { |path| path.start_with?("/") }
    .sort
end

def filter_ignored_source_paths(paths)
  paths.reject { |path| ignored_source_path?(path) }.sort
end

def canonicalize_path_list(paths, old_to_new)
  paths.map { |path| canonical_path(path, old_to_new) }.uniq.sort
end

def canonicalize_snapshot_files(snapshot, old_to_new)
  eager_load = snapshot.fetch("eager_load")

  {
    "required_or_loaded_files" =>
      canonicalize_path_list(
        eager_load.fetch("required_or_loaded_files"),
        old_to_new
      ),

    "loaded_features_added" =>
      canonicalize_path_list(
        eager_load.fetch("loaded_features_added"),
        old_to_new
      )
  }
end

def canonicalize_constants(constants, old_to_new)
  constants.transform_values do |data|
    data.merge(
      "source_files" =>
        canonicalize_path_list(data.fetch("source_files", []), old_to_new)
    )
  end
end

classic_constants =
  canonicalize_constants(classic.fetch("constants"), old_to_new)

zeitwerk_constants =
  canonicalize_constants(zeitwerk.fetch("constants"), old_to_new)

classic_eager_files =
  canonicalize_snapshot_files(classic, old_to_new)

zeitwerk_eager_files =
  canonicalize_snapshot_files(zeitwerk, old_to_new)

classic_constant_names = classic_constants.keys.to_set
zeitwerk_constant_names = zeitwerk_constants.keys.to_set

classic_files =
  classic_eager_files.fetch("required_or_loaded_files").to_set

zeitwerk_files =
  zeitwerk_eager_files.fetch("required_or_loaded_files").to_set

classic_loaded_features =
  classic_eager_files.fetch("loaded_features_added").to_set

zeitwerk_loaded_features =
  zeitwerk_eager_files.fetch("loaded_features_added").to_set

def section(title, rows)
  puts
  puts "## #{title} (#{rows.size})"
  rows.sort.each { |row| puts row }
end

puts "# Eager load snapshot diff"

if old_to_new.any?
  puts
  puts "Using rename map with #{old_to_new.size} renamed path(s)."
  puts "Paths are canonicalized to current-branch names."
end

section(
  "Constants missing in Zeitwerk",
  classic_constant_names - zeitwerk_constant_names
)

section(
  "Constants new in Zeitwerk",
  zeitwerk_constant_names - classic_constant_names
)

section(
  "Files required/loaded during eager load in classic only",
  classic_files - zeitwerk_files
)

section(
  "Files required/loaded during eager load in Zeitwerk only",
  zeitwerk_files - classic_files
)

section(
  "$LOADED_FEATURES additions in classic only",
  classic_loaded_features - zeitwerk_loaded_features
)

section(
  "$LOADED_FEATURES additions in Zeitwerk only",
  zeitwerk_loaded_features - classic_loaded_features
)

common_constants = classic_constant_names & zeitwerk_constant_names

type_changes = common_constants.select do |name|
  classic_constants[name]["type"] != zeitwerk_constants[name]["type"]
end

puts
puts "## Constant type changes (#{type_changes.size})"
type_changes.sort.each do |name|
  puts "#{name}: #{classic_constants[name]["type"]} -> #{zeitwerk_constants[name]["type"]}"
end

source_file_changes = common_constants.select do |name|
  classic_files = app_source_files_for(classic_constants[name])
  zeitwerk_files = app_source_files_for(zeitwerk_constants[name])

  classic_files != zeitwerk_files
end

puts
puts "## App constant source file changes (#{source_file_changes.size})"
source_file_changes.sort.each do |name|
  classic_files = app_source_files_for(classic_constants[name])
  zeitwerk_files = app_source_files_for(zeitwerk_constants[name])

  puts "#{name}:"
  puts "  classic:  #{classic_files.join(", ")}"
  puts "  zeitwerk: #{zeitwerk_files.join(", ")}"
end

if old_to_new.any?
  puts
  puts "## Applied rename map (#{old_to_new.size})"
  old_to_new.sort.each do |old_path, new_path|
    puts "#{old_path} -> #{new_path}"
  end
end
