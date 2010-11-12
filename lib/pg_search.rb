require "active_record"

module PgSearch
  def self.included(base)
    base.send(:extend, ClassMethods)
  end

  module ClassMethods
    def pg_search_scope(name, options)
      options_proc = case options
        when Proc
          options
        when Hash
          lambda { |query|
            options.reverse_merge(
              :query => query
            )
          }
        else
          raise ArgumentError, "#{__method__} expects a Proc or Hash for its options"
      end

      scope_method = if self.respond_to?(:scope) && !protected_methods.include?('scope')
                       :scope
                     else
                       :named_scope
                     end

      send(scope_method, name, lambda { |*args|
        options = options_proc.call(*args).reverse_merge(:using => :tsearch)
        query = options[:query]
        normalizing = Array.wrap(options[:normalizing])
        dictionary = options[:with_dictionary]

        raise ArgumentError, "the search scope #{name} must have :against in its options" unless options[:against]

        against = options[:against]
        against = Array.wrap(against) unless against.is_a?(Hash)

        columns_with_weights = against.map do |column_name, weight|
          ["coalesce(#{quoted_table_name}.#{connection.quote_column_name(column_name)}, '')",
           weight]
        end

        document = columns_with_weights.map { |column, *| column }.join(" || ' ' || ")

        normalized = lambda do |string|
          string = "unaccent(#{string})" if normalizing.include?(:diacritics)
          string
        end

        tsquery = query.split(" ").compact.map do |term|
          term = "'#{term}'"
          term = "#{term}:*" if normalizing.include?(:prefixes)
          "to_tsquery(#{normalized[connection.quote(term)]})"
        end.join(" && ")

        tsdocument = columns_with_weights.map do |column, weight|
          tsvector = if dictionary
            "to_tsvector(:dictionary, #{normalized[column]})"
          else
            "to_tsvector(#{normalized[column]})"
          end

          if weight
            "setweight(#{tsvector}, #{connection.quote(weight)})"
          else
            tsvector
          end
        end.join(" || ")

        conditions_hash = {
          :tsearch => "(#{tsdocument}) @@ (#{tsquery})",
          :trigram => "(#{normalized[document]}) % #{normalized[":query"]}"
        }

        conditions = Array.wrap(options[:using]).map do |feature|
          "(#{conditions_hash[feature]})"
        end.join(" OR ")

        interpolations = {
          :query => query,
          :dictionary => dictionary.to_s
        }

        rank_select = sanitize_sql_array(["ts_rank((#{tsdocument}), (#{tsquery}))", interpolations])

        {
          :select => "#{quoted_table_name}.*, (#{rank_select})::float AS rank",
          :conditions => [conditions, interpolations],
          :order => "rank DESC, #{quoted_table_name}.#{connection.quote_column_name(primary_key)} ASC"
        }
      })
    end
  end
end
