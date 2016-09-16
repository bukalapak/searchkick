module Searchkick
  class Query
    extend Forwardable

    attr_reader :klass, :term, :options
    attr_accessor :body

    def_delegators :execute, :map, :each, :any?, :empty?, :size, :length, :slice, :[], :to_ary,
      :records, :results, :suggestions, :each_with_hit, :with_details, :facets, :aggregations, :aggs,
      :took, :error, :model_name, :entry_name, :total_count, :total_entries,
      :current_page, :per_page, :limit_value, :padding, :total_pages, :num_pages,
      :offset_value, :offset, :previous_page, :prev_page, :next_page, :first_page?, :last_page?,
      :out_of_range?, :hits


    def initialize(klass, term, options = {})
      if term.is_a?(Hash)
        options = term
        term = "*"
      else
        term = term.to_s
      end

      if options[:emoji]
        term = EmojiParser.parse_unicode(term) { |e| " #{e.name} " }.strip
      end

      @klass = klass
      @term = term
      @options = options
      @match_suffix = options[:match] || searchkick_options[:match] || "analyzed"

      prepare
    end

    def searchkick_index
      klass ? klass.searchkick_index : nil
    end

    def searchkick_options
      klass ? klass.searchkick_options : {}
    end

    def searchkick_klass
      klass ? klass.searchkick_klass : nil
    end

    def params
      index =
        if options[:index_name]
          Array(options[:index_name]).map { |v| v.respond_to?(:searchkick_index) ? v.searchkick_index.name : v }.join(",")
        elsif searchkick_index
          searchkick_index.name
        else
          "_all"
        end

      params = {
        index: index,
        body: body
      }
      params.merge!(type: @type) if @type
      params.merge!(routing: @routing) if @routing
      params
    end

    def execute
      @execute ||= begin
        begin
          response = execute_search
          if @misspellings_below && response["hits"]["total"] < @misspellings_below
            prepare
            response = execute_search
          end
        rescue => e # TODO rescue type
          handle_error(e)
        end
        handle_response(response)
      end
    end

    def to_curl
      query = params
      type = query[:type]
      index = query[:index].is_a?(Array) ? query[:index].join(",") : query[:index]

      # no easy way to tell which host the client will use
      host = Searchkick.client.transport.hosts.first
      credentials = (host[:user] || host[:password]) ? "#{host[:user]}:#{host[:password]}@" : nil
      "curl #{host[:protocol]}://#{credentials}#{host[:host]}:#{host[:port]}/#{CGI.escape(index)}#{type ? "/#{type.map { |t| CGI.escape(t) }.join(',')}" : ''}/_search?pretty -d '#{query[:body].to_json}'"
    end

    def handle_response(response)
      # apply facet limit in client due to
      # https://github.com/elasticsearch/elasticsearch/issues/1305
      @facet_limits.each do |field, limit|
        field = field.to_s
        facet = response["facets"][field]
        response["facets"][field]["terms"] = facet["terms"].first(limit)
        response["facets"][field]["other"] = facet["total"] - facet["terms"].sum { |term| term["count"] }
      end

      opts = {
        page: @page,
        per_page: @per_page,
        padding: @padding,
        load: @load,
        includes: options[:include] || options[:includes],
        json: !options[:json].nil?,
        match_suffix: @match_suffix,
        highlighted_fields: @highlighted_fields || []
      }

      # set execute for multi search
      @execute = Searchkick::Results.new(searchkick_klass, response, opts)
    end

    private

    def handle_error(e)
      status_code = e.message[1..3].to_i
      if status_code == 404
        raise MissingIndexError, "Index missing - run #{reindex_command}"
      elsif status_code == 500 && (
        e.message.include?("IllegalArgumentException[minimumSimilarity >= 1]") ||
        e.message.include?("No query registered for [multi_match]") ||
        e.message.include?("[match] query does not support [cutoff_frequency]]") ||
        e.message.include?("No query registered for [function_score]]")
      )

        raise UnsupportedVersionError, "This version of Searchkick requires Elasticsearch 1.0 or greater"
      elsif status_code == 400
        if e.message.include?("[multi_match] analyzer [searchkick_search_nostem] not found")
          raise InvalidQueryError, "Bad mapping - run #{reindex_command}"
        else
          raise InvalidQueryError, e.message
        end
      else
        raise e
      end
    end

    def reindex_command
      searchkick_klass ? "#{searchkick_klass.name}.reindex" : "reindex"
    end

    def execute_search
      Searchkick.client.search(params)
    end

    def prepare
      boost_fields, fields = set_fields

      operator = options[:operator] || (options[:partial] ? "or" : "and")

      # pagination
      page = [options[:page].to_i, 1].max
      per_page = (options[:limit] || options[:per_page] || 1_000).to_i
      padding = [options[:padding].to_i, 0].max
      offset = options[:offset] || (page - 1) * per_page + padding

      # model and eagar loading
      load = options[:load].nil? ? true : options[:load]

      conversions_field = searchkick_options[:conversions]
      personalize_field = searchkick_options[:personalize]

      all = term == "*"

      options[:json] ||= options[:body]
      if options[:json]
        payload = options[:json]
      else
        if options[:query]
          payload = options[:query]
        elsif options[:similar]
          similar_filters = []
          options[:must_match]&.each do |field|
            similar_filters << term_filters(field, options[:like_text][field])
            options[:like_text].delete(field)
          end
          must_match = [
            {
              filtered: {
                filter: similar_filters
              }
            }
          ]

          similar_fields = []
          similar_terms = []
          options[:like_text].each do |field,term|
            if options[:fields].include?(field)
              similar_fields << "#{field}.analyzed"
              similar_terms << term
            end
          end
          similar_terms = similar_terms.join(" ")
          should_match = [
            {
              more_like_this: {
                fields: similar_fields,
                like_text: similar_terms,
                min_doc_freq: 1,
                min_term_freq: 1,
                analyzer: "searchkick_search2"
              }
            }
          ]

          payload = {
            bool: {
              must: must_match,
              should: should_match
            }
          }
        elsif all
          payload = {
            match_all: {}
          }
        else
          if options[:autocomplete]
            payload = {
              multi_match: {
                fields: fields,
                query: term,
                analyzer: "searchkick_autocomplete_search"
              }
            }
          else
            match_type = options[:match] if options[:match].in?([:phrase])
            queries = [
              {
                multi_match:{
                  query: term,
                  type: match_type || "cross_fields",
                  fields: boost_fields,
                  operator: operator,
                  boost: options[:fuzziness_factor] || 10,
                  analyzer: "searchkick_search_nostem"
                }
              },
              {
                multi_match:{
                  query: term,
                  type: match_type || "cross_fields",
                  fields: boost_fields,
                  operator: operator,
                  boost: options[:fuzziness_factor] || 10,
                  analyzer: "searchkick_search2_nostem"
                }
              }
            ]
            misspellings = options.has_key?(:misspellings) ? options[:misspellings] : options[:mispellings]
            edit_distance = (misspellings.is_a?(Hash) && (misspellings[:edit_distance] || misspellings[:distance])) || 1 if misspellings != false
            if edit_distance && edit_distance > 0
              queries << {
                multi_match:{
                  query: term,
                  type: match_type || "best_fields",
                  fields: boost_fields,
                  operator: operator,
                  fuzziness: edit_distance,
                  max_expansions: 100,
                  analyzer: "searchkick_search_nostem"
                }
              }
              queries << {
                multi_match:{
                  query: term,
                  type: match_type || "best_fields",
                  fields: boost_fields,
                  operator: operator,
                  fuzziness: edit_distance,
                  max_expansions: 100,
                  analyzer: "searchkick_search2_nostem"
                }
              }
            end

            payload = {
              dis_max: {
                queries: queries
              }
            }
          end

          if conversions_field && options[:conversions] != false && options[:relevance] && options[:relevance][:on]
            # wrap payload in a bool query
            function_params = options[:relevance]
            script_score =
              if below12?
                {script_score: {script: "doc['count'].value"}}
              else
                {field_value_factor: {field: "#{conversions_field}.count", factor: function_params[:factor], modifier: function_params[:modifier]}}
              end

            payload = {
              bool: {
                must: payload,
                should: {
                  nested: {
                    path: conversions_field,
                    score_mode: function_params[:score_mode],
                    query: {
                      function_score: {
                        boost_mode: function_params[:boost_mode],
                        query: {
                          match: {
                            "#{conversions_field}.query" => term
                          }
                        }
                      }.merge(script_score)
                    }
                  }
                }
              }
            }
          end
        end

        custom_filters = []
        multiply_filters = []

        set_boost_by(multiply_filters, custom_filters)
        set_boost_where(custom_filters, personalize_field)
        set_boost_by_distance(custom_filters) if options[:boost_by_distance] || options[:decay]

        if custom_filters.any?
          payload = {
            function_score: {
              functions: custom_filters,
              query: payload,
              score_mode: "sum"
            }
          }
        end

        if multiply_filters.any?
          payload = {
            function_score: {
              functions: multiply_filters,
              query: payload,
              score_mode: "multiply"
            }
          }
        end

        payload = {
          query: payload,
          size: per_page,
          from: offset
        }
        payload[:explain] = options[:explain] if options[:explain]

        # order
        set_order(payload) if options[:order]

        # filters
        filters = where_filters(options[:where])
        set_filters(payload, filters) if filters.any?

        # facets
        set_facets(payload) if options[:facets]

        # aggregations
        set_aggregations(payload) if options[:aggs]

        # suggestions
        set_suggestions(payload) if options[:suggest]

        # highlight
        set_highlights(payload, fields) if options[:highlight]

        # An empty array will cause only the _id and _type for each hit to be returned
        # doc for :select - http://www.elasticsearch.org/guide/reference/api/search/fields/
        # doc for :select_v2 - https://www.elastic.co/guide/en/elasticsearch/reference/current/search-request-source-filtering.html
        if options[:select]
          payload[:fields] = options[:select] if options[:select] != true
        elsif options[:select_v2]
          if options[:select_v2] == []
            payload[:fields] = [] # intuitively [] makes sense to return no fields, but ES by default returns all fields
          else
            payload[:_source] = options[:select_v2]
          end
        elsif load
          # don't need any fields since we're going to load them from the DB anyways
          payload[:fields] = []
        end

        if options[:type] || (klass != searchkick_klass && searchkick_index)
          @type = [options[:type] || klass].flatten.map { |v| searchkick_index.klass_document_type(v) }
        end

        # routing
        @routing = options[:routing] if options[:routing]
      end

      @body = payload
      @facet_limits = @facet_limits || {}
      @page = page
      @per_page = per_page
      @padding = padding
      @load = load
    end

    def set_fields
      boost_fields = []
      fields = options[:fields] || searchkick_options[:searchable]
      fields =
        if fields
          if options[:autocomplete]
            fields.map { |f| "#{f}.autocomplete" }
          else
            fields.map do |value|
              k, v = value.is_a?(Hash) ? value.to_a.first : [value, options[:match] || searchkick_options[:match] || :word]
              k2, boost = k.to_s.split("^", 2)
              field = "#{k2}.#{v == :word ? 'analyzed' : v}"
              boost_fields << ( boost ? "#{field}^#{boost}" : field )
              field
            end
          end
        else
          if options[:autocomplete]
            (searchkick_options[:autocomplete] || []).map { |f| "#{f}.autocomplete" }
          else
            ["_all"]
          end
        end
      boost_fields = fields if boost_fields.empty?
      [boost_fields, fields]
    end

    def set_boost_by_distance(custom_filters)
      boost_by_distance = options[:boost_by_distance] || options[:decay] || {}
      # modified to support multiple decay functions
      custom_filters.concat(
        boost_by_distance.map do |field, value|
          function_params = value.slice(:origin, :scale, :offset, :decay)
          {
            filter: {
              exists: {
                field: field
              }
            },
            (value[:function] || :gauss) => {
              field => function_params
            },
            weight: value[:weight] || 1
          }
        end
      )
    end

    def set_boost_by(multiply_filters, custom_filters)
      boost_by = options[:boost_by] || options[:refine_boost] || {}
      if boost_by.is_a?(Array)
        boost_by = Hash[boost_by.map { |f| [f, {factor: 1}] }]
      elsif boost_by.is_a?(Hash)
        multiply_by, boost_by = boost_by.partition { |_, v| v[:boost_mode] == "multiply" }.map { |i| Hash[i] }
      end
      boost_by[options[:boost]] = {factor: 1} if options[:boost]

      custom_filters.concat boost_filters(boost_by, log: true)
      multiply_filters.concat boost_filters(multiply_by || {})
    end

    def set_boost_where(custom_filters, personalize_field)
      boost_where = options[:boost_where] || {}
      if options[:user_id] && personalize_field
        boost_where[personalize_field] = options[:user_id]
      end
      if options[:personalize]
        boost_where = boost_where.merge(options[:personalize])
      end
      boost_where.each do |field, value|
        if value.is_a?(Array) && value.first.is_a?(Hash)
          value.each do |value_factor|
            custom_filters << custom_filter(field, value_factor[:value], value_factor[:factor])
          end
        elsif value.is_a?(Hash)
          custom_filters << custom_filter(field, value[:value], value[:factor])
        else
          factor = 1000
          custom_filters << custom_filter(field, value, factor)
        end
      end
    end

    def set_suggestions(payload)
      suggest_fields = (searchkick_options[:suggest] || []).map(&:to_s)

      # intersection
      if options[:fields]
        suggest_fields &= options[:fields].map { |v| (v.is_a?(Hash) ? v.keys.first : v).to_s.split("^", 2).first }
      end

      if suggest_fields.any?
        payload[:suggest] = {text: term}
        suggest_fields.each do |field|
          payload[:suggest][field] = {
            phrase: {
              field: "#{field}.suggest"
            }
          }
        end
      end
    end

    def set_highlights(payload, fields)
      payload[:highlight] = {
        fields: Hash[fields.map { |f| [f, {}] }]
      }

      if options[:highlight].is_a?(Hash)
        if (tag = options[:highlight][:tag])
          payload[:highlight][:pre_tags] = [tag]
          payload[:highlight][:post_tags] = [tag.to_s.gsub(/\A</, "</")]
        end

        if (fragment_size = options[:highlight][:fragment_size])
          payload[:highlight][:fragment_size] = fragment_size
        end
        if (encoder = options[:highlight][:encoder])
          payload[:highlight][:encoder] = encoder
        end

        highlight_fields = options[:highlight][:fields]
        if highlight_fields
          payload[:highlight][:fields] = {}

          highlight_fields.each do |name, opts|
            payload[:highlight][:fields]["#{name}.#{@match_suffix}"] = opts || {}
          end
        end
      end

      @highlighted_fields = payload[:highlight][:fields].keys
    end

    def set_aggregations(payload)
      aggs = options[:aggs]
      payload[:aggs] = {}

      aggs = Hash[aggs.map { |f| [f, {}] }] if aggs.is_a?(Array) # convert to more advanced syntax

      aggs.each do |field, agg_options|
        size = agg_options[:limit] ? agg_options[:limit] : 1_000
        shared_agg_options = agg_options.slice(:order, :min_doc_count)

        if agg_options[:stat_aggs]
          payload[:aggs][agg_options[:stat_aggs]] = {
            stats: {
              field: agg_options[:field] || field
            }.merge(shared_agg_options)
          }
        elsif agg_options[:ranges]
          payload[:aggs][field] = {
            range: {
              field: agg_options[:field] || field,
              ranges: agg_options[:ranges]
            }.merge(shared_agg_options)
          }
        elsif agg_options[:date_ranges]
          payload[:aggs][field] = {
            date_range: {
              field: agg_options[:field] || field,
              ranges: agg_options[:date_ranges]
            }.merge(shared_agg_options)
          }
        else
          payload[:aggs][field] = {
            terms: {
              field: agg_options[:field] || field,
              size: size
            }.merge(shared_agg_options)
          }
        end

        where = {}
        where = (options[:where] || {}).reject { |k| k == field } if options[:smart_aggs]
        agg_filters = where_filters(where.merge(agg_options[:where] || {}))
        if agg_filters.any?
          payload[:aggs][field] = {
            filter: {
              bool: {
                must: agg_filters
              }
            },
            aggs: {
              field => payload[:aggs][field]
            }
          }
        end
      end
    end

    def set_facets(payload)
      facets = options[:facets] || {}
      facets = Hash[facets.map { |f| [f, {}] }] if facets.is_a?(Array) # convert to more advanced syntax
      facet_limits = {}
      payload[:facets] = {}

      facets.each do |field, facet_options|
        # ask for extra facets due to
        # https://github.com/elasticsearch/elasticsearch/issues/1305
        size = facet_options[:limit] ? facet_options[:limit] + 150 : 1_000

        if facet_options[:ranges]
          payload[:facets][field] = {
            range: {
              field.to_sym => facet_options[:ranges]
            }
          }
        elsif facet_options[:stats]
          payload[:facets][field] = {
            terms_stats: {
              key_field: field,
              value_script: below14? ? "doc.score" : "_score",
              size: size
            }
          }
        else
          payload[:facets][field] = {
            terms: {
              field: facet_options[:field] || field,
              size: size
            }
          }
        end

        facet_limits[field] = facet_options[:limit] if facet_options[:limit]

        # offset is not possible
        # http://elasticsearch-users.115913.n3.nabble.com/Is-pagination-possible-in-termsStatsFacet-td3422943.html

        facet_options.deep_merge!(where: options.fetch(:where, {}).reject { |k| k == field }) if options[:smart_facets] == true
        facet_filters = where_filters(facet_options[:where])
        if facet_filters.any?
          payload[:facets][field][:facet_filter] = {
            and: {
              filters: facet_filters
            }
          }
        end
      end

      @facet_limits = facet_limits
    end

    def set_filters(payload, filters)
      payload[:query] = {
        filtered: {
          query: payload[:query],
          filter: {
            bool: {
              must: filters
            }
          }
        }
      }
    end

    def set_order(payload)
      order = options[:order].is_a?(Enumerable) ? options[:order] : {options[:order] => :asc}
      # TODO id transformation for arrays
      payload[:sort] = order.is_a?(Array) ? order : Hash[order.map { |k, v| [k.to_s == "id" ? :_id : k, v] }]
    end

    def where_filters(where)
      filters = []
      (where || {}).each do |field, value|
        field = :_id if field.to_s == "id"

        if field == :or
          value.each do |or_clause|
            filters << {or: or_clause.map { |or_statement| {and: where_filters(or_statement)} }}
          end
        else
          # expand ranges
          if value.is_a?(Range)
            value = {gte: value.first, (value.exclude_end? ? :lt : :lte) => value.last}
          end

          value = {in: value} if value.is_a?(Array)

          if value.is_a?(Hash)
            value.each do |op, op_value|
              case op
              when :within, :bottom_right
                # do nothing
              when :near
                filters << {
                  geo_distance: {
                    field => location_value(op_value),
                    distance: value[:within] || "50mi"
                  }
                }
              when :top_left
                filters << {
                  geo_bounding_box: {
                    field => {
                      top_left: location_value(op_value),
                      bottom_right: location_value(value[:bottom_right])
                    }
                  }
                }
              when :regexp # support for regexp queries without using a regexp ruby object
                filters << {regexp: {field => {value: op_value}}}
              when :not # not equal
                filters << {not: {filter: term_filters(field, op_value)}}
              when :all
                op_value.each do |value|
                  filters << term_filters(field, value)
                end
              when :in
                filters << term_filters(field, op_value)
              else
                range_query =
                  case op
                  when :gt
                    {from: op_value, include_lower: false}
                  when :gte
                    {from: op_value, include_lower: true}
                  when :lt
                    {to: op_value, include_upper: false}
                  when :lte
                    {to: op_value, include_upper: true}
                  else
                    raise "Unknown where operator: #{op.inspect}"
                  end
                # issue 132
                if (existing = filters.find { |f| f[:range] && f[:range][field] })
                  existing[:range][field].merge!(range_query)
                else
                  filters << {range: {field => range_query}}
                end
              end
            end
          else
            filters << term_filters(field, value)
          end
        end
      end
      filters
    end

    def term_filters(field, value)
      if value.is_a?(Array) # in query
        if value.any?(&:nil?)
          {or: [term_filters(field, nil), term_filters(field, value.compact)]}
        else
          {in: {field => value}}
        end
      elsif value.nil?
        {missing: {"field" => field, existence: true, null_value: true}}
      elsif value.is_a?(Regexp)
        {regexp: {field => {value: value.source}}}
      else
        {term: {field => value}}
      end
    end

    def custom_filter(field, value, factor)
      {
        filter: {
          and: where_filters(field => value)
        },
        boost_factor: factor
      }
    end

    def boost_filters(boost_by, options = {})
      boost_by.map do |field, value|
        log = value.key?(:log) ? value[:log] : options[:log]
        value[:factor] ||= 1
        script_score =
          if below12?
            script = log ? "log(doc['#{field}'].value + 2.718281828)" : "doc['#{field}'].value"
            {script_score: {script: "#{value[:factor].to_f} * #{script}"}}
          else
            {field_value_factor: {field: field, factor: value[:factor].to_f, modifier: value[:modifier] || (log ? "ln2p" : nil)}}
          end

        {
          filter: {
            exists: {
              field: field
            }
          }
        }.merge(script_score)
        .merge({ weight: value[:weight] || 1 })
      end
    end

    def location_value(value)
      if value.is_a?(Array)
        value.map(&:to_f).reverse
      else
        value
      end
    end

    def below12?
      below_version?("1.2.0")
    end

    def below14?
      below_version?("1.4.0")
    end

    def below20?
      below_version?("2.0.0")
    end

    def below_version?(version)
      Gem::Version.new(Searchkick.server_version) < Gem::Version.new(version)
    end
  end
end
