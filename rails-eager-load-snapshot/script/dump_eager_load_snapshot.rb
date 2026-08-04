# script/dump_eager_load_snapshot.rb
# frozen_string_literal: true

require "json"
require "set"

root = Rails.root.to_s

INCLUDE_ANONYMOUS_CONSTANTS =
  ENV.fetch("CONSTANT_DUMP_INCLUDE_ANONYMOUS", "0") == "1"

class EagerLoadFileTracker
  attr_reader :events

  def initialize
    @events = []
    @installed = false
  end

  def install!
    return if @installed

    tracker = self

    Kernel.module_eval do
      unless method_defined?(:__constant_dump_original_require__)
        alias_method :__constant_dump_original_require__, :require

        define_method(:require) do |path|
          before = $LOADED_FEATURES.dup
          result = __constant_dump_original_require__(path)
          after = $LOADED_FEATURES

          added = after - before

          tracker.record(
            type: "require",
            argument: path,
            result: result,
            loaded_features_added: added
          )

          result
        end
      end

      unless method_defined?(:__constant_dump_original_load__)
        alias_method :__constant_dump_original_load__, :load

        define_method(:load) do |path, wrap = false|
          result = __constant_dump_original_load__(path, wrap)

          tracker.record(
            type: "load",
            argument: path,
            result: result,
            loaded_features_added: []
          )

          result
        end
      end
    end

    @installed = true
  end

  def record(type:, argument:, result:, loaded_features_added:)
    @events << {
      "type" => type,
      "argument" => argument.to_s,
      "result" => result,
      "loaded_features_added" => loaded_features_added
    }
  end
end

def normalize_path(path, root)
  return nil if path.nil?

  path = path.to_s

  absolute =
    if path.start_with?("/")
      path
    else
      begin
        File.expand_path(path)
      rescue
        path
      end
    end

  if absolute.start_with?("#{root}/")
    absolute.sub("#{root}/", "")
  else
    absolute
  end
end

def real_module_name(mod)
  # Avoid calling mod.name directly because some modules/classes override `name`.
  # Example: REXML::Functions defines its own `name` method.
  Module.instance_method(:name).bind(mod).call
rescue
  nil
end

def real_module_type(mod)
  mod.is_a?(Class) ? "class" : "module"
rescue
  "unknown"
end

def anonymous_constant_name?(name)
  name.include?("#<Class:") || name.include?("#<Module:")
end

def normalize_constant_name(name)
  name
    .gsub(/#<Class:0x[0-9a-fA-F]+>/, "#<Class:ANONYMOUS>")
    .gsub(/#<Module:0x[0-9a-fA-F]+>/, "#<Module:ANONYMOUS>")
end

def source_files_for_module(mod, root)
  source_locations = []

  begin
    method_names =
      mod.instance_methods(false) +
      mod.private_instance_methods(false) +
      mod.protected_instance_methods(false)

    method_names.each do |method_name|
      location =
        begin
          mod.instance_method(method_name).source_location
        rescue
          nil
        end

      source_locations << location if location
    end
  rescue
  end

  begin
    mod.singleton_methods(false).each do |method_name|
      location =
        begin
          mod.method(method_name).source_location
        rescue
          nil
        end

      source_locations << location if location
    end
  rescue
  end

  source_locations
    .compact
    .map(&:first)
    .uniq
    .map { |path| normalize_path(path, root) }
    .compact
    .sort
end

def ignored_constant_name?(name)
  return true if rails_generated_constant_name?(name)

  ignored_prefixes = [
    "ActiveRecord::",
    "ActiveSupport::",
    "ActionController::",
    "ActionView::",
    "ActionMailer::",
    "ActionCable::",
    "ActiveJob::",
    "ActiveModel::",
    "Arel::",
    "Bundler::",
    "Gem::",
    "JSON::",
    "Nokogiri::",
    "Rack::",
    "Rails::",
    "RSpec::",
    "ActionDispatch::",
    "Devise::Mailer::",
  ]

  ignored_prefixes.any? { |prefix| name.start_with?(prefix) }
end

def rails_generated_constant_name?(name)
  name.end_with?(
    "::GeneratedAttributeMethods",
    "::GeneratedAssociationMethods"
  )
end

def dump_constants(root)
  constants = {}

  ObjectSpace.each_object(Module) do |mod|
    original_name = real_module_name(mod)

    next if original_name.nil? || original_name.empty?
    next if ignored_constant_name?(original_name)

    anonymous = anonymous_constant_name?(original_name)

    next if anonymous && !INCLUDE_ANONYMOUS_CONSTANTS

    normalized_name = normalize_constant_name(original_name)

    constants[normalized_name] = {
      "original_name" => normalized_name == original_name ? nil : original_name,
      "anonymous" => anonymous,
      "type" => real_module_type(mod),
      "source_files" => source_files_for_module(mod, root)
    }
  end

  constants.sort.to_h
end

def rails_paths
  {
    "autoload_paths" =>
      Rails.application.config.autoload_paths.map(&:to_s).sort,
    "eager_load_paths" =>
      Rails.application.config.eager_load_paths.map(&:to_s).sort
  }
end

tracker = EagerLoadFileTracker.new
tracker.install!

loaded_features_before = $LOADED_FEATURES.dup

# Rails.application.eager_load!

loaded_features_after = $LOADED_FEATURES.dup
loaded_features_added = loaded_features_after - loaded_features_before

events = tracker.events

required_or_loaded_files =
  events.flat_map do |event|
    added = event.fetch("loaded_features_added", [])

    if added.any?
      added
    else
      [event.fetch("argument")]
    end
  end

required_or_loaded_files =
  required_or_loaded_files
    .map { |path| normalize_path(path, root) }
    .compact
    .uniq
    .sort

loaded_features_added =
  loaded_features_added
    .map { |path| normalize_path(path, root) }
    .compact
    .uniq
    .sort

normalized_events =
  events.map do |event|
    event.merge(
      "argument" => normalize_path(event.fetch("argument"), root),
      "loaded_features_added" =>
        event.fetch("loaded_features_added")
          .map { |path| normalize_path(path, root) }
          .compact
          .sort
    )
  end

constants = dump_constants(root)

output = {
  "rails_env" => Rails.env,
  "rails_version" => Rails.version,
  "root" => root,
  "options" => {
    "include_anonymous_constants" => INCLUDE_ANONYMOUS_CONSTANTS
  },
  "paths" => rails_paths,
  "eager_load" => {
    "loaded_feature_count" => loaded_features_added.size,
    "required_or_loaded_file_count" => required_or_loaded_files.size,
    "loaded_features_added" => loaded_features_added,
    "required_or_loaded_files" => required_or_loaded_files,
    "events" => normalized_events
  },
  "constant_count" => constants.size,
  "constants" => constants
}

puts JSON.pretty_generate(output)
