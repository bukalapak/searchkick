module Searchkick
  class Query
    attr_reader :klass, :term, :options
    attr_accessor :body, :respond

    def initialize(klass, term, options = {})
      if term.is_a?(Hash)
        options = term
        term = "*"
      else
        term = term.to_s
      end

      @klass = klass
      @term = term
      @options = options

      below12 = Gem::Version.new(Searchkick.server_version) < Gem::Version.new("1.2")
      below14 = Gem::Version.new(Searchkick.server_version) < Gem::Version.new("1.4")

      boost_fields = {}
      fields =
        if options[:fields]
          if options[:autocomplete]
            options[:fields].map{|f| "#{f}.autocomplete" }
          else
            options[:fields].map do |value|
              k, v = value.is_a?(Hash) ? value.to_a.first : [value, :word]
              k2, boost = k.to_s.split("^", 2)
              field = "#{k2}.#{v == :word ? "analyzed" : v}"
              boost_fields[field] = boost.to_i if boost
              field
            end
          end
        else
          if options[:autocomplete]
            (searchkick_options[:autocomplete] || []).map{|f| "#{f}.autocomplete" }
          else
            ["_all"]
          end
        end

      sfields = fields
      sfields = sfields.map do |p|
        boost_fields[p] ? "#{p}^#{boost_fields[p]}" : p
      end

      operator = options[:operator] || (options[:partial] ? "or" : "and")

      # pagination
      page = [options[:page].to_i, 1].max
      per_page = (options[:limit] || options[:per_page] || 100).to_i
      per_page = 0 if options[:search_type] == "count"
      padding = [options[:padding].to_i, 0].max
      offset = options[:offset] || (page - 1) * per_page + padding

      # model and eagar loading
      load = options[:load].nil? ? true : options[:load]

      conversions_field = searchkick_options[:conversions]
      personalize_field = searchkick_options[:personalize]

      all = term == "*"
      facet_limits = {}

      options[:json] ||= options[:body]
      if options[:json]
        payload = options[:json]
      else
        if options[:query]
          payload = options[:query]
        elsif options[:similar]
          similar_filters = []
          options[:must_match] ||= []
          options[:must_match].each do |field|
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
                analyzer: "searchkick_search2_nostem"
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
                  fields: sfields,
                  operator: "and",
                  boost: options[:fuzziness_factor] || 10,
                  analyzer: "searchkick_search_nostem"
                }
              },
              {
                multi_match:{
                  query: term,
                  type: match_type || "cross_fields",
                  fields: sfields,
                  operator: "and",
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
                  fields: sfields,
                  operator: "and",
                  fuzziness: edit_distance,
                  max_expansions: 100,
                  analyzer: "searchkick_search_nostem"
                }
              }
              queries << {
                multi_match:{
                  query: term,
                  type: match_type || "best_fields",
                  fields: sfields,
                  operator: "and",
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

          if options[:relevance] && options[:relevance][:on] && conversions_field && options[:conversions] != false
            # wrap payload in a bool query

            config = options[:relevance]
            script_score =
              if below12
                {script_score: {script: "doc['count'].value"}}
              else
                {field_value_factor: {field: "count", factor: config[:factor], modifier:config[:modifier]}}
              end

            payload = {
              bool: {
                must: payload,
                should: {
                  nested: {
                    path: conversions_field,
                    score_mode: config[:score_mode],
                    query: {
                      function_score: {
                        boost_mode: config[:boost_mode],
                        query: {
                          match: {
                            query: term
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

        unless below12
          refine_boost = options[:refine_boost] || {}

          refine_boost.each do |field, value|
            value[:modifier] ||= "ln2p"
            value[:factor] ||= 1

            script_score =
              {field_value_factor: {field: field, factor: value[:factor].to_f, modifier: value[:modifier]}}
              # {script_score: {
              #   script: "3/(1+(DateTime.now().getMillis() - doc['#{decay}'].date.getMillis())/86400000) \
              #     < 0.013574660633484163 ? 0 : doc['#{field}'].value*(3/(1+(DateTime.now().getMillis() - \
              #     doc['#{decay}'].date.getMillis())/86400000)-0.013574660633484163)"}
            script_score.merge!({weight: value[:weight]}) if value[:weight]

            custom_filters << {
              filter: {
                exists: {
                  field: field
                }
              }
            }.merge(script_score)
          end

          decay = options[:decay] || {}

          decay.each do |field,value|
            decay = {scale: value[:scale]}
            decay.merge!({origin: value[:origin]}) if value[:origin]
            decay.merge!({offset: value[:offset]}) if value[:offset]
            decay.merge!({decay: value[:decay]}) if value[:decay]

            value[:function] ||= :gauss
            script_score = {value[:function] => {field=>decay}}
            script_score.merge!({weight: value[:weight]}) if value[:weight]

            custom_filters << {
              filter: {
                exists: {
                  field: field
                }
              }
            }.merge(script_score)
          end

          if options[:random]
            custom_filters << {:random_score=>{:seed=>DateTime.now.to_i/3600}}
          end
        end

        boost_by = options[:boost_by] || {}
        if boost_by.is_a?(Array)
          boost_by = Hash[ boost_by.map{|f| [f, {factor: 1}] } ]
        end
        if options[:boost]
          boost_by[options[:boost]] = {factor: 1}
        end

        boost_by.each do |field, value|
          script_score =
            if below12
              {script_score: {script: "#{value[:factor].to_f} * log(doc['#{field}'].value + 2.718281828)"}}
            else
              {field_value_factor: {field: field, factor: value[:factor].to_f, modifier: "ln2p"}}
            end

          custom_filters << {
            filter: {
              exists: {
                field: field
              }
            }
          }.merge(script_score)
        end

        boost_where = options[:boost_where] || {}
        if options[:user_id] and personalize_field
          boost_where[personalize_field] = options[:user_id]
        end
        if options[:personalize]
          boost_where.merge!(options[:personalize])
        end
        boost_where.each do |field, value|
          if value.is_a?(Array)
            value.each do |value_factor|
              value, factor = value_factor[:value], value_factor[:factor]
              custom_filters << custom_filter(field, value, factor)
            end
          elsif value.is_a?(Hash)
            value, factor = value[:value], value[:factor]
            custom_filters << custom_filter(field, value, factor)
          else
            factor = 1000
            custom_filters << custom_filter(field, value, factor)
          end
        end

        boost_by_distance = options[:boost_by_distance]
        if boost_by_distance
          boost_by_distance = {function: :gauss, scale: "5mi"}.merge(boost_by_distance)
          if !boost_by_distance[:field] or !boost_by_distance[:origin]
            raise ArgumentError, "boost_by_distance requires :field and :origin"
          end
          function_params = boost_by_distance.select{|k,v| [:origin, :scale, :offset, :decay].include?(k) }
          function_params[:origin] = function_params[:origin].reverse
          custom_filters << {
            boost_by_distance[:function] => {
              boost_by_distance[:field] => function_params
            }
          }
        end

        if custom_filters.any?
          options[:score_mode] ||= "multiply"
          options[:boost_mode] ||= "multiply"
          payload = {
            function_score: {
              functions: custom_filters,
              query: payload,
              score_mode: options[:score_mode],
              boost_mode: options[:boost_mode]
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
        if options[:order]
          order = options[:order].is_a?(Enumerable) ? options[:order] : {options[:order] => :asc}
          # TODO id transformation for arrays
          payload[:sort] = order.is_a?(Array) ? order : Hash[ order.map{|k, v| [k.to_s == "id" ? :_id : k, v] } ]
        end

        # filters
        filters = where_filters(options[:where])
        if filters.any?
          payload[:query] = {
            filtered:{
              query: payload[:query],
              filter:{
                bool: { must: filters }
              }
            }
          }
        end

        # facets
        if options[:facets]
          facets = options[:facets] || {}
          if facets.is_a?(Array) # convert to more advanced syntax
            facets = Hash[ facets.map{|f| [f, {}] } ]
          end

          payload[:facets] = {}
          facets.each do |field, facet_options|
            # ask for extra facets due to
            # https://github.com/elasticsearch/elasticsearch/issues/1305
            size = facet_options[:limit] ? facet_options[:limit] + 150 : 100000

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
                  value_script: below14 ? "doc.score" : "_score",
                  size: size
                }
              }
            else
              payload[:facets][field] = {
                terms: {
                  field: field,
                  size: size
                }
              }
            end

            facet_limits[field] = facet_options[:limit] if facet_options[:limit]

            # offset is not possible
            # http://elasticsearch-users.115913.n3.nabble.com/Is-pagination-possible-in-termsStatsFacet-td3422943.html

            facet_options.deep_merge!(where: options[:where].reject{|k| k == field}) if options[:smart_facets] == true
            facet_filters = where_filters(facet_options[:where])
            if facet_filters.any?
              payload[:facets][field][:facet_filter] = {
                and: {
                  filters: facet_filters
                }
              }
            end
          end
        end

        if options[:aggs]
          aggs = options[:aggs]
          if aggs.is_a?(Array) # convert to more advanced syntax
            aggs = Hash[ aggs.map{|f| [f, {}] } ]
          end

          payload[:aggs] = {}
          aggs.each do |field, agg_options|
            size = agg_options[:limit] ? agg_options[:limit] + 150 : 100000
            payload[:aggs][field] = {
              terms:{
                field:field,
                size:size
              }
            }
          end
        end

        # stats
        if options[:stat_aggs]
          aggs = options[:stat_aggs]
          if aggs.is_a?(Array) # convert to more advanced syntax
            aggs = Hash[ aggs.map{|f| [f, {}] } ]
          end

          payload[:aggs] ||= {}
          options[:stat_aggs].each do |name, field|
            payload[:aggs][name] = {
              stats: {
                field: field
              }
            }
          end
        end

        # suggestions
        if options[:suggest]
          suggest_fields = (searchkick_options[:suggest] || []).map(&:to_s)

          # intersection
          if options[:fields]
            suggest_fields = suggest_fields & options[:fields].map{|v| (v.is_a?(Hash) ? v.keys.first : v).to_s.split("^", 2).first }
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

        # highlight
        if options[:highlight]
          payload[:highlight] = {
            fields: Hash[ fields.map{|f| [f, {}] } ]
          }

          if options[:highlight].is_a?(Hash)
            if tag = options[:highlight][:tag]
              payload[:highlight][:pre_tags] = [tag]
              payload[:highlight][:post_tags] = [tag.to_s.gsub(/\A</, "</")]
            end

            highlight_fields = options[:highlight][:fields]
            if highlight_fields
              payload[:highlight][:fields] = {}

              highlight_fields.each do |name, opts|
                payload[:highlight][:fields]["#{name}.analyzed"] = opts || {}
              end
            end
          end
        end

        # An empty array will cause only the _id and _type for each hit to be returned
        # http://www.elasticsearch.org/guide/reference/api/search/fields/
        if options[:select]
          payload[:fields] = options[:select] if options[:select] != true
        elsif load
          payload[:fields] = []
        end

        if options[:type] or klass != searchkick_klass
          @type = [options[:type] || klass].flatten.map{|v| searchkick_index.klass_document_type(v) }
        end
      end

      @body = payload
      @facet_limits = facet_limits
      @page = page
      @per_page = per_page
      @padding = padding
      @load = load
    end
    def searchkick_index
      klass.searchkick_index
    end

    def searchkick_options
      klass.searchkick_options
    end

    def searchkick_klass
      klass.searchkick_klass
    end

    def params
      params = {
        index: options[:index_name] || searchkick_index.name,
        body: body
      }
      params[:type] = @type if @type
      params[:search_type] = options[:search_type] if options[:search_type].present?
      params[:timeout] = options[:timeout] if options[:timeout].present?

      return params
    end

    def execute
      # wew = params.merge!({explain:true})
      begin
        response = @respond || Searchkick.client.search(params)
        # response = Searchkick.client.search(wew)
      rescue => e # TODO rescue type
        status_code = e.message[1..3].to_i
        if status_code == 404
          raise MissingIndexError, "Index missing - run #{searchkick_klass.name}.reindex"
        elsif status_code == 500 and (
            e.message.include?("IllegalArgumentException[minimumSimilarity >= 1]") or
            e.message.include?("No query registered for [multi_match]") or
            e.message.include?("[match] query does not support [cutoff_frequency]]") or
            e.message.include?("No query registered for [function_score]]")
          )

          raise UnsupportedVersionError, "This version of Searchkick requires Elasticsearch 1.0 or greater"
        elsif status_code == 400
          if e.message.include?("[multi_match] analyzer [searchkick_search] not found")
            raise InvalidQueryError, "Bad mapping - run #{searchkick_klass.name}.reindex"
          else
            raise InvalidQueryError, e.message
          end
        else
          raise e
        end
      end

      # apply facet limit in client due to
      # https://github.com/elasticsearch/elasticsearch/issues/1305
      @facet_limits.each do |field, limit|
        field = field.to_s
        facet = response["facets"][field]
        response["facets"][field]["terms"] = facet["terms"].first(limit)
        response["facets"][field]["other"] = facet["total"] - facet["terms"].sum{|term| term["count"] }
      end

      opts = {
        page: @page,
        per_page: @per_page,
        padding: @padding,
        load: @load,
        includes: options[:include] || options[:includes],
        json: !options[:json].nil?,
        unscoped: @options[:unscoped]
      }
      return Searchkick::Results.new(searchkick_klass, response, opts)
    end

    private

    def where_filters(where)
      filters = []
      (where || {}).each do |field, value|
        field = :_id if field.to_s == "id"

        if field == :or
          value.each do |or_clause|
            filters << {or: or_clause.map{|or_statement| {and: where_filters(or_statement)} }}
          end
        else
          # expand ranges
          if value.is_a?(Range)
            value = {gte: value.first, (value.exclude_end? ? :lt : :lte) => value.last}
          end

          if value.is_a?(Array)
            value = {in: value}
          end

          if value.is_a?(Hash)
            value.each do |op, op_value|
              case op
              when :within, :bottom_right
                # do nothing
              when :near
                filters << {
                  geo_distance: {
                    field => op_value.map(&:to_f).reverse,
                    distance: value[:within] || "50mi"
                  }
                }
              when :top_left
                filters << {
                  geo_bounding_box: {
                    field => {
                      top_left: op_value.map(&:to_f).reverse,
                      bottom_right: value[:bottom_right].map(&:to_f).reverse
                    }
                  }
                }
              when :not # not equal
                filters << {not: term_filters(field, op_value)}
              when :all
                filters << {terms: {field => op_value, execution: "and"}}
              when :in
                filters << term_filters(field, op_value)
              else
                range_query = {op => op_value}
                # issue 132
                if existing = filters.find{ |f| f[:range] && f[:range][field] }
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
        if value.any?
          {or: value.map{|v| term_filters(field, v) }}
        else
          {terms: {field => value}} # match nothing
        end
      elsif value.nil?
        {missing: {"field" => field, existence: true, null_value: true}}
      else
        {term: {field => value}}
      end
    end

    def custom_filter(field, value, factor)
      {
        filter: {
          term: {field => value}
        },
        boost_factor: factor
      }
    end

  end
end
