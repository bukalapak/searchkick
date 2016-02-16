module Searchkick
  class ReindexV2Job < ActiveJob::Base
    queue_as :searchkick

    def perform(klass, id)
      model = klass.constantize
      return unless model.superclass == ActiveRecord::Base
      record = model.unscoped.where(id: id).first
      index = model.searchkick_index
      index.store record if record
    end
  end
end
