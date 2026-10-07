# frozen_string_literal: true

class Queries::Base
  def self.inherited(subclass)
    super
    subclass.instance_variable_set(:@statements, {})
    subclass.instance_variable_set(:@statement_mutex, Mutex.new)
  end

  class << self
    private
      def fetch_first(key, version: nil, **bindings)
        # SQLite treats binary-encoded HTTP strings as blobs. Preserve the text
        # comparison performed by the preceding literalized queries.
        bindings.each do |name, value|
          if value.is_a?(String) && value.encoding == Encoding::BINARY
            bindings[name] = value.dup.force_encoding(Encoding::UTF_8)
          end
        end
        statement(key, version) { yield }.call(bindings)
      end

      def statement(key, version)
        cached = @statements[key]
        return cached.last if cached && cached.first == version

        # Resolve models and build the dataset outside the mutex: autoloading
        # can read database schemas. Only SQL preparation/registration is locked.
        dataset = yield
        @statement_mutex.synchronize do
          cached = @statements[key]
          return cached.last if cached && cached.first == version

          name = :"queries_#{self.name.delete_prefix('Queries::').underscore.tr('/', '_')}_#{key.to_s.underscore.tr('/', '_')}"
          prepared = dataset.prepare(:first, name)
          @statements[key] = [version, prepared].freeze
          prepared
        end
      end
  end
end
