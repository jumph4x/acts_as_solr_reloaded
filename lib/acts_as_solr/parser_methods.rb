module ActsAsSolr #:nodoc:
  module ParserMethods
    protected

    # Method used by mostly all the ClassMethods when doing a search
    def parse_query(query=nil, options={})
      valid_options = [:models, :lazy, :core, :results_format, :sql_options,
        :alternate_query, :boost_functions, :filter_queries, :facets, :sort,
        :scores, :operator, :latitude, :longitude, :radius, :relevance, :highlight,
        :offset, :per_page, :limit, :page,]
      query_options = {}

      return if query.nil?
      raise "Query should be a string" unless query.is_a?(String)
      raise "Invalid parameters: #{(options.keys - valid_options).join(',')}" unless (options.keys - valid_options).empty?
      begin
        Deprecation.validate_query(options)

        if options[:alternate_query]
          query = query.blank? ? '' : sanitize_query(query)
          query = "#{options[:alternate_query]} #{query}"
        else
          query = query.blank? ? '*:*' : sanitize_query(query)
        end

        query = replace_types([*query], ':').first # put types on filtered fields
        query = add_relevance query, options[:relevance]
        query_options[:query] = query

        field_list = options[:models].nil? ? solr_configuration[:primary_key_field] : "id"
        query_options[:field_list] = [field_list, 'score']

        per_page = options[:per_page] || options[:limit] || 30
        offset = options[:offset] || (((options[:page] || 1).to_i - 1) * per_page)
        query_options[:rows] = per_page
        query_options[:start] = offset

        query_options[:operator] = options[:operator]

        query_options[:filter_queries] = [solr_type_condition(options)]
        query_options[:filter_queries] += replace_types([*options[:filter_queries]], '') if options[:filter_queries]

        query_options[:boost_functions] = replace_types([*options[:boost_functions]], '').join(' ') if options[:boost_functions]

        # first steps on the facet parameter processing
        if options[:facets]
          query_options[:facets] = {}
          query_options[:facets][:limit] = -1  # TODO: make this configurable
          query_options[:facets][:sort] = :count if options[:facets][:sort]
          query_options[:facets][:mincount] = 0
          query_options[:facets][:mincount] = 1 if options[:facets][:zeros] == false
          # override the :zeros (it's deprecated anyway) if :mincount exists
          query_options[:facets][:mincount] = options[:facets][:mincount] if options[:facets][:mincount]
          query_options[:facets][:fields] = options[:facets][:fields].map{ |k| "#{k}_facet" } if options[:facets][:fields]
          query_options[:filter_queries] += replace_types([*options[:facets][:browse]]) if options[:facets][:browse]
          query_options[:facets][:queries] = replace_types([*options[:facets][:query]]) if options[:facets][:query]

          if options[:facets][:dates]
            query_options[:date_facets] = {}
            # if options[:facets][:dates][:fields] exists then :start, :end, and :gap must be there
            if options[:facets][:dates][:fields]
              [:start, :end, :gap].each { |k| raise "#{k} must be present in faceted date query" unless options[:facets][:dates].include?(k) }
              query_options[:date_facets][:fields] = []
              options[:facets][:dates][:fields].each { |f|
                if f.kind_of? Hash
                  key = f.keys[0]
                  query_options[:date_facets][:fields] << {"#{key}_d" => f[key]}
                  validate_date_facet_other_options(f[key][:other]) if f[key][:other]
                else
                  query_options[:date_facets][:fields] << "#{f}_d"
                end
              }
            end

            query_options[:date_facets][:start]   = options[:facets][:dates][:start] if options[:facets][:dates][:start]
            query_options[:date_facets][:end]     = options[:facets][:dates][:end] if options[:facets][:dates][:end]
            query_options[:date_facets][:gap]     = options[:facets][:dates][:gap] if options[:facets][:dates][:gap]
            query_options[:date_facets][:hardend] = options[:facets][:dates][:hardend] if options[:facets][:dates][:hardend]
            query_options[:date_facets][:filter]  = replace_types([*options[:facets][:dates][:filter]].collect{|k| "#{k.dup.sub!(/ *:(?!\d) */,"_d:")}"}) if options[:facets][:dates][:filter]

            if options[:facets][:dates][:other]
              validate_date_facet_other_options(options[:facets][:dates][:other])
              query_options[:date_facets][:other] = options[:facets][:dates][:other]
            end

          end
        end

        if options[:highlight]
          query_options[:highlighting] = {}
          query_options[:highlighting][:field_list] = replace_types([*options[:highlight][:fields]], '') if options[:highlight][:fields]
          query_options[:highlighting][:require_field_match] =  options[:highlight][:require_field_match] if options[:highlight][:require_field_match]
          query_options[:highlighting][:max_snippets] = options[:highlight][:max_snippets] if options[:highlight][:max_snippets]
          query_options[:highlighting][:prefix] = options[:highlight][:prefix] if options[:highlight][:prefix]
          query_options[:highlighting][:suffix] = options[:highlight][:suffix] if options[:highlight][:suffix]
        end

        query_options[:sort] = replace_types([*options[:sort]], '')[0] if options[:sort]

        if options[:radius]
          query_options[:radius] = options[:radius]
          query_options[:filter_queries] << '{!geofilt}'
        end
        query_options[:latitude] = options[:latitude]
        query_options[:longitude] = options[:longitude]

        not_dismax = query_options[:operator] == :or
        request = not_dismax ? Solr::Request::Standard.new(query_options) : Solr::Request::Dismax.new(query_options)
        ActsAsSolr::Post.execute(request, options[:core])
      rescue
        raise "#{$query} There was a problem executing your search\n#{query_options.inspect}\n: #{$!} in #{$!.backtrace.first}"
      end
    end

    def solr_type_condition(options = {})
      classes = [self] + (self.subclasses || []) + (options[:models] || [])
      classes.inject([]) do |condition, klass|
        next if klass.name.empty? 
        condition << "#{solr_configuration[:type_field]}:\"#{klass.name}\""
      end.join(' OR ')
    end

    # Parses the data returned from Solr
    def parse_results(solr_data, options = {})
      results = {
        :docs => [],
        :total => 0
      }

      configuration = {
        :format => :objects
      }
      results.update(:spellcheck => solr_data.data['spellcheck']) unless solr_data.nil?
      results.update(:facets => {'facet_fields' => []}) if options[:facets]
      unless solr_data.nil? or solr_data.header['params'].nil?
        header = solr_data.header
        results.update :rows => header['params']['rows']
        results.update :start => header['params']['start']
      end
      return SearchResults.new(results) if (solr_data.nil? || solr_data.total_hits == 0)

      configuration.update(options) if options.is_a?(Hash)

      ids = solr_data.hits.collect {|doc| doc["#{solr_configuration[:primary_key_field]}"]}.flatten

      result = find_objects(ids, options, configuration)

      add_scores(result, solr_data) if configuration[:format] == :objects && options[:scores]

      highlighted = {}
      solr_data.highlighting.map do |x,y|
        e={}
        y1=y.map{|x1,y1| e[x1.gsub(/_[^_]*/,"")]=y1} unless y.nil?
        highlighted[x.gsub(/[^:]*:/,"").to_i]=e
        end unless solr_data.highlighting.nil?

      results.update(:facets => solr_data.data['facet_counts']) if options[:facets]
      results.update({:docs => result, :total => solr_data.total_hits, :max_score => solr_data.max_score, :query_time => solr_data.data['responseHeader']['QTime']})
      results.update({:highlights=>highlighted})
      SearchResults.new(results)
    end


    def find_objects(ids, options, configuration)
      result = if configuration[:lazy] && configuration[:format] != :ids
        ids.collect {|id| ActsAsSolr::LazyDocument.new(id, self)}
      elsif configuration[:format] == :objects
        find_options = options[:sql_options] || {}
        find_options[:conditions] = self.send :merge_conditions, {self.primary_key => ids}, (find_options[:conditions] || [])
        result = self.all(find_options) || []
        result = reorder(result, ids) unless find_options[:order]
        result
      else
        ids
      end

      result
    end

    # Reorders the instances keeping the order returned from Solr
    def reorder(things, ids)
      ordered_things = []
      ids.each do |id|
        thing = things.find{ |t| t.id.to_s == id.to_s }
        ordered_things |= [thing] if thing
      end
      ordered_things
    end

    # Replaces the field types based on the types (if any) specified
    # on the acts_as_solr call
    def replace_types(strings, suffix=':')
      if configuration[:solr_fields]
        configuration[:solr_fields].each do |name, options|
          solr_name = (options[:as] || name).to_s
          solr_type = get_solr_field_type(options[:type])
          field = "#{solr_name}_#{solr_type}#{suffix}"
          strings.each_with_index {|s,i| strings[i] = s.gsub(/\b#{solr_name}\b#{suffix}/,field) }
        end
      end
      if configuration[:solr_includes]
        configuration[:solr_includes].each do |association, options|
          solr_name = options[:as] || association.to_s.singularize
          solr_type = get_solr_field_type(options[:type])
          field = "#{solr_name}_#{solr_type}#{suffix}"
          strings.each_with_index {|s,i| strings[i] = s.gsub(/\b#{solr_name}\b#{suffix}/,field) }
        end
      end
      strings
    end

    # Adds the score to each one of the instances found
    def add_scores(results, solr_data)
      with_score = []
      solr_data.hits.each do |doc|
        with_score.push([doc["score"],
          results.find {|record| scorable_record?(record, doc) }])
      end
      with_score.each do |score, object|
        class << object; attr_accessor :solr_score; end
        object.solr_score = score
      end
    end

    def scorable_record?(record, doc)
      doc_id = doc["#{solr_configuration[:primary_key_field]}"]
      if doc_id.nil?
        doc_id = doc["id"]
        "#{record.class.name}:#{record_id(record)}" == doc_id.first.to_s
      else
        record_id(record).to_s == doc_id.to_s
      end
    end

    def validate_date_facet_other_options(options)
      valid_other_options = [:after, :all, :before, :between, :none]
      options = [options] unless options.kind_of? Array
      bad_options = options.map {|x| x.to_sym} - valid_other_options
      raise "Invalid option#{'s' if bad_options.size > 1} for faceted date's other param: #{bad_options.join(', ')}. May only be one of :after, :all, :before, :between, :none" if bad_options.size > 0
    end
    
    def sanitize_query(query)
      fields = self.configuration[:solr_fields].keys
      fields += DynamicAttribute.all(:select => 'name', :group => 'name').map(&:name) if DynamicAttribute.table_exists?
      Solr::Util::query_parser_escape query, fields
    end

    private

    def add_relevance(query, relevance)
      return query if relevance.nil? or query.include? ':'

      query = [query] + relevance.map do |attribute, value|
        "#{attribute}:(#{query})^#{value}"
      end
      query = query.join(' OR ')

      replace_types([query], '').first
    end

  end
end

