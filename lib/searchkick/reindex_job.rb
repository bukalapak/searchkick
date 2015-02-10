module Searchkick
  class ReindexJob

    def initialize(klass, id)
      @klass = klass
      @id = id
    end

    def perform
      model = @klass.constantize
      record = model.unscoped.where(id: @id).first
      index = model.searchkick_index
      index.store record if record
    end

  end
end
