# frozen_string_literal: true

# Keep all Action Text filters and presentation extensions from the reference.
Dir["#{CampfireBenchmark::REFERENCE}/lib/rails_ext/*.rb"].sort.each { |path| require path }
Time::DATE_FORMATS[:epoch] = ->(time) { (time.to_f * 1000).to_i }
ActiveSupport::Inflector.inflections(:en) { |inflect| inflect.acronym "HTTP" }
Rails.application.config.after_initialize { GlobalID.app = "campfire" }
