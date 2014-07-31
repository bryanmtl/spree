module Spree
  class Reimbursement < ActiveRecord::Base
    class IncompleteReimbursement < StandardError; end

    belongs_to :order, inverse_of: :reimbursements
    belongs_to :customer_return, inverse_of: :reimbursements

    has_many :refunds, inverse_of: :reimbursement
    has_many :return_items, inverse_of: :reimbursement

    validates :order, presence: true
    validates :customer_return, presence: true
    validate :validate_return_items_belong_to_same_order

    accepts_nested_attributes_for :return_items, allow_destroy: true

    before_create :generate_number

    # The return_item_tax_calculator property should be set to an object that responds to "call"
    # and accepts an array of ReturnItems. Invoking "call" should update the tax fields on the
    # supplied ReturnItems.
    # This allows a store to easily integrate with third party tax services.
    class_attribute :return_item_tax_calculator
    self.return_item_tax_calculator = ReturnItemTaxCalculator
    # A separate attribute here allows you to use a more performant calculator for estimates
    # and a different one (e.g. one that hits a 3rd party API) for the final caluclations.
    class_attribute :return_item_simulator_tax_calculator
    self.return_item_simulator_tax_calculator = ReturnItemTaxCalculator

    # The reimbursement_models property should contain an array of all models that provide
    # reimbursements.
    # This allows a store to incorporate custom reimbursement methods that Spree doesn't know about.
    # Each model must implement a "total_amount_reimbursed_for" method.
    # Example:
    #   Refund.total_amount_reimbursed_for(reimbursement)
    # See the `reimbursement_generator` property regarding the generation of custom reimbursements.
    class_attribute :reimbursement_models
    self.reimbursement_models = [Refund]

    # The reimbursement_performer property should be set to an object that responds to the following methods:
    # - #perform
    # - #simulate
    # see ReimbursementPerformer for details.
    # This allows a store to customize their reimbursement methods and logic.
    class_attribute :reimbursement_performer
    self.reimbursement_performer = ReimbursementPerformer

    # These are called if the call to "reimburse!" succeeds.
    class_attribute :reimbursement_success_hooks
    self.reimbursement_success_hooks = []

    # These are called if the call to "reimburse!" fails.
    class_attribute :reimbursement_failure_hooks
    self.reimbursement_failure_hooks = []

    state_machine :reimbursement_status, initial: :pending do

      event :errored do
        transition to: :errored, from: :pending
      end

      event :reimbursed do
        transition to: :reimbursed, from: [:pending, :errored]
      end

    end

    def display_total
      Spree::Money.new(total, { currency: order.currency })
    end

    def calculated_total
      return_items.to_a.sum(&:total)
    end

    def paid_amount
      reimbursement_models.sum do |model|
        model.total_amount_reimbursed_for(self)
      end
    end

    def unpaid_amount
      total - paid_amount
    end

    def perform!
      return_item_tax_calculator.call(
        return_items.includes(inventory_unit: {line_item: :order}).to_a
      )
      reload
      update!(total: calculated_total)

      reimbursement_performer.perform(self)

      if unpaid_amount.zero?
        reimbursed!
        reimbursement_success_hooks.each { |h| h.call self }
      else
        errored!
        reimbursement_failure_hooks.each { |h| h.call self }
        raise IncompleteReimbursement, Spree.t("validation.unpaid_amount_not_zero", amount: unpaid_amount)
      end
    end

    def simulate
      return_item_simulator_tax_calculator.call(
        return_items.includes(inventory_unit: {line_item: :order}).to_a
      )
      reload
      update!(total: calculated_total)

      reimbursement_performer.simulate(self)
    end

    private

    def generate_number
      self.number ||= loop do
        random = "RI#{Array.new(9){rand(9)}.join}"
        break random unless self.class.exists?(number: random)
      end
    end

    def validate_return_items_belong_to_same_order
      if return_items.any? { |ri| ri.inventory_unit.order_id != order_id }
        errors.add(:base, :return_items_order_id_does_not_match)
      end
    end

  end
end
