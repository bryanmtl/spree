module Spree
  class RefundReason < ActiveRecord::Base
    include Spree::ReasonType

    RETURN_PROCESSING_REASON = 'Return processing'

    has_many :refunds

    def self.return_processing_reason
      find_by!(name: RETURN_PROCESSING_REASON, mutable: false)
    end
  end
end
