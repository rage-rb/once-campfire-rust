# frozen_string_literal: true

class Queries::Record < Queries::Base
  def self.fetch_by_id(model, id)
    types = model.sti_key_array if model.respond_to?(:sti_key_array)
    types = Sequel.synchronize { types.dup.freeze } if types
    fetch_first(model, version: types, id: id) do
      scope = model.dataset
      if types
        # Sequel's STI filter is delayed, which prepared statements reject.
        # Refresh the snapshot if another subclass is loaded after the first read.
        scope = model.sti_dataset.with_row_proc(scope.row_proc)
          .where(Sequel[model.table_name][model.sti_key] => types)
      end
      scope.where(Sequel[model.table_name][model.primary_key] => :$id)
    end
  end
end
