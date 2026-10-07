# frozen_string_literal: true

# A shared Sequel base, with only the interfaces needed by reference ERB/GlobalID.
ApplicationRecord = Class.new(Sequel::Model)
class ApplicationRecord
  plugin :active_model
  plugin :validation_helpers
  plugin :dirty
  plugin :defaults_setter
  include GlobalID::Identification
  unrestrict_primary_key

  class << self
    private
      # Sequel also uses this hook for many-to-one association reads. Keep its
      # association caching and callbacks while reusing the native statement.
      def primary_key_lookup(pk)
        Queries::Record.fetch_by_id(self, pk)
      end
  end

  def self.find(id)
    return with_pk!(id.to_s.to_i) unless id.is_a?(Array)

    ids = id.map { |value| value.to_s.to_i }.uniq
    records = where(id: ids).all.index_by(&:id)
    ids.map { |value| records.fetch(value) { raise Sequel::NoMatchingRow } }
  end

  def new_record? = new?
  # Message overrides to_key for DOM ids, but URLs still use its database id.
  def to_param = id&.to_s

  def cache_key
    new? ? "#{model_name.cache_key}/new" : "#{model_name.cache_key}/#{id}-#{updated_at.utc.strftime('%Y%m%d%H%M%S%6N')}"
  end
  alias cache_key_with_version cache_key

  def before_validation
    now = Time.current
    self.created_at ||= now if new?
    self.updated_at = now
    super
  end

  def touch(column = :updated_at)
    now = Time.current
    attributes = { column => now, updated_at: now }
    model.where(id: id).update(attributes)
    set(attributes)
    self
  end
end
