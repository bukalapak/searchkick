require "active_model"
require "elasticsearch"
require "hashie"
require "searchkick/version"
require "searchkick/index"
require "searchkick/results"
require "searchkick/query"
require "searchkick/reindex_job"
require "searchkick/model"
require "searchkick/tasks"
require "searchkick/logging" if defined?(Rails)

# background jobs
begin
  require "active_job"
rescue LoadError
  # do nothing
end
require "searchkick/reindex_v2_job" if defined?(ActiveJob)

module Searchkick
  class MissingIndexError < StandardError; end
  class UnsupportedVersionError < StandardError; end
  class InvalidQueryError < Elasticsearch::Transport::Transport::Errors::BadRequest; end

  class << self
    attr_accessor :search_method_name
    attr_accessor :msearch_method_name
    attr_accessor :count_method_name
    attr_accessor :wordnet_path
    attr_accessor :timeout
    attr_accessor :open_timeout
    attr_accessor :models
  end
  self.search_method_name = :search
  self.count_method_name = :search_count
  self.msearch_method_name = :msearch
  self.wordnet_path = "/var/lib/wn_s.pl"
  self.timeout = 5
  self.open_timeout = 5
  self.models = []

  def self.client
    @client ||=
      Elasticsearch::Client.new(
        url: ENV["ELASTICSEARCH_URL"],
        transport_options: {request: {timeout: timeout, open_timeout: open_timeout}}
      )
  end

  def self.client=(client)
    @client = client
  end

  def self.server_version
    @server_version ||= client.info["version"]["number"]
  end

  def self.enable_callbacks
    Thread.current[:searchkick_callbacks_enabled] = true
  end

  def self.disable_callbacks
    Thread.current[:searchkick_callbacks_enabled] = false
  end

  def self.callbacks?
    Thread.current[:searchkick_callbacks_enabled].nil? || Thread.current[:searchkick_callbacks_enabled]
  end

  def self.env
    @env ||= ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"
  end
end

# TODO find better ActiveModel hook
ActiveModel::Callbacks.send(:include, Searchkick::Model)
ActiveRecord::Base.send(:extend, Searchkick::Model) if defined?(ActiveRecord)
