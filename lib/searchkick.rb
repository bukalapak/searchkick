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
require "searchkick/middleware"
require "searchkick/logging" if defined?(ActiveSupport::Notifications)

# background jobs
begin
  require "active_job"
rescue LoadError
  # do nothing
end
require "searchkick/reindex_v2_job" if defined?(ActiveJob)

module Searchkick
  class Error < StandardError; end
  class MissingIndexError < Error; end
  class UnsupportedVersionError < Error; end
  class InvalidQueryError < Elasticsearch::Transport::Transport::Errors::BadRequest; end
  class DangerousOperation < Error; end
  class ImportError < Error; end

  class << self
    attr_accessor :search_method_name, :wordnet_path, :timeout, :models, :msearch_method_name, :count_method_name, :open_timeout
    attr_writer :client, :env, :search_timeout
  end
  self.search_method_name = :search
  self.msearch_method_name = :msearch
  self.count_method_name = :search_count
  self.wordnet_path = "/var/lib/wn_s.pl"
  self.timeout = 5
  self.open_timeout = 5
  self.models = []

  def self.client
    @client ||=
      Elasticsearch::Client.new(
        url: ENV["ELASTICSEARCH_URL"],
        transport_options: {request: {timeout: timeout, open_timeout: open_timeout}}
      ) do |f|
        f.use Searchkick::Middleware
      end
  end

  def self.env
    @env ||= ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"
  end

  def self.search_timeout
    @search_timeout || timeout
  end

  def self.server_version
    @server_version ||= client.info["version"]["number"]
  end

  def self.enable_callbacks
    self.callbacks_value = nil
  end

  def self.disable_callbacks
    self.callbacks_value = false
  end

  def self.callbacks?
    Thread.current[:searchkick_callbacks_enabled].nil? || Thread.current[:searchkick_callbacks_enabled]
  end

  def self.callbacks(value)
    if block_given?
      previous_value = callbacks_value
      begin
        self.callbacks_value = value
        yield
        perform_bulk if callbacks_value == :bulk
      ensure
        self.callbacks_value = previous_value
      end
    else
      self.callbacks_value = value
    end
  end

  def self.queue_items(items)
    queued_items.concat(items)
    perform_bulk unless callbacks_value == :bulk
  end

  def self.perform_bulk
    items = queued_items
    clear_queued_items
    perform_items(items)
  end

  def self.perform_items(items)
    if items.any?
      response = client.bulk(body: items)
      if response["errors"]
        first_with_error = response["items"].map do |item|
          (item["index"] || item["delete"] || item["update"])
        end.find { |item| item["error"] }
        raise Searchkick::ImportError, "#{first_with_error["error"]} on item with id '#{first_with_error["_id"]}'"
      end
    end
  end

  def self.queued_items
    Thread.current[:searchkick_queued_items] ||= []
  end

  def self.clear_queued_items
    Thread.current[:searchkick_queued_items] = []
  end

  def self.callbacks_value
    Thread.current[:searchkick_callbacks_enabled]
  end

  def self.callbacks_value=(value)
    Thread.current[:searchkick_callbacks_enabled] = value
  end

  def self.callbacks(value)
    if block_given?
      previous_value = callbacks_value
      begin
        self.callbacks_value = value
        yield
        perform_bulk if callbacks_value == :bulk
      ensure
        self.callbacks_value = previous_value
      end
    else
      self.callbacks_value = value
    end
  end

  def self.search(term = nil, options = {}, &block)
    query = Searchkick::Query.new(nil, term, options)
    block.call(query.body) if block
    if options[:execute] == false
      query
    else
      query.execute
    end
  end

  def self.multi_search(queries)
    if queries.any?
      responses = client.msearch(body: queries.flat_map { |q| [q.params.except(:body), q.body] })["responses"]
      queries.each_with_index do |query, i|
        query.handle_response(responses[i])
      end
    end
    nil
  end
end

# TODO find better ActiveModel hook
ActiveModel::Callbacks.send(:include, Searchkick::Model)
ActiveRecord::Base.send(:extend, Searchkick::Model) if defined?(ActiveRecord)
