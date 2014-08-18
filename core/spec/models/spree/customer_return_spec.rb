require 'spec_helper'

describe Spree::CustomerReturn do
  before do
    Spree::Order.any_instance.stub(return!: true)
  end

  describe ".validation" do
    describe "#return_items_belong_to_same_order" do
      let(:customer_return)       { build(:customer_return) }

      let(:first_inventory_unit)  { build(:inventory_unit) }
      let(:first_return_item)     { build(:return_item, inventory_unit: first_inventory_unit) }

      let(:second_inventory_unit) { build(:inventory_unit, order: second_order) }
      let(:second_return_item)    { build(:return_item, inventory_unit: second_inventory_unit) }

      subject { customer_return.valid? }

      before do
        customer_return.return_items << first_return_item
        customer_return.return_items << second_return_item
      end

      context "return items are part of different orders" do
        let(:second_order) { create(:order) }

        it "is not valid" do
          expect(subject).to eq false
        end

        it "adds an error message" do
          subject
          expect(customer_return.errors.full_messages).to include(Spree.t(:return_items_cannot_be_associated_with_multiple_orders))
        end

      end

      context "return items are part of the same order" do
        let(:second_order) { first_inventory_unit.order }

        it "is valid" do
          expect(subject).to eq true
        end
      end
    end
  end

  describe ".before_create" do
    describe "#generate_number" do
      context "number is assigned" do
        let(:customer_return) { Spree::CustomerReturn.new(number: '123') }

        it "should return the assigned number" do
          customer_return.save
          customer_return.number.should == '123'
        end
      end

      context "number is not assigned" do
        let(:customer_return) { Spree::CustomerReturn.new(number: nil) }

        before do
          customer_return.stub(valid?: true, process_return!: true)
        end

        it "should assign number with random CR number" do
          customer_return.save
          customer_return.number.should =~ /CR\d{9}/
        end
      end
    end
  end

  describe "#pre_tax_total" do
    let(:pre_tax_amount)  { 15.0 }
    let(:customer_return) { create(:customer_return_with_return_items) }

    before do
      Spree::ReturnItem.where(customer_return_id: customer_return.id).update_all(pre_tax_amount: pre_tax_amount)
    end

    subject { customer_return.pre_tax_total }

    it "returns the sum of the return item's pre_tax_amount" do
      expect(subject).to eq (pre_tax_amount * 2)
    end
  end

  describe "#display_pre_tax_total" do
    let(:customer_return) { Spree::CustomerReturn.new }

    it "returns a Spree::Money" do
      customer_return.stub(pre_tax_total: 21.22)
      customer_return.display_pre_tax_total.should == Spree::Money.new(21.22)
    end
  end

  describe "#order" do
    let(:return_item) { create(:return_item) }
    let(:customer_return) { build(:customer_return, return_items: [return_item]) }

    subject { customer_return.order }

    it "returns the order associated with the return item's inventory unit" do
      expect(subject).to eq return_item.inventory_unit.order
    end
  end

  describe "#order_id" do
    subject { customer_return.order_id }

    context "return item is not associated yet" do
      let(:customer_return) { build(:customer_return) }

      it "is nil" do
        expect(subject).to be_nil
      end
    end

    context "has an associated return item" do
      let(:return_item) { create(:return_item) }
      let(:customer_return) { build(:customer_return, return_items: [return_item]) }

      it "is the return item's inventory unit's order id" do
        expect(subject).to eq return_item.inventory_unit.order.id
      end
    end
  end

  context ".after_save" do
    let(:inventory_unit)  { create(:inventory_unit, state: 'shipped') }
    let(:return_item)     { create(:return_item, inventory_unit: inventory_unit) }

    context "to the initial stock location" do

      it "should mark all inventory units are returned" do
        create(:customer_return, return_items: [return_item], stock_location_id: inventory_unit.shipment.stock_location_id)
        expect(inventory_unit.reload.state).to eq 'returned'
      end

      it "should update the stock item counts in the stock location" do
        expect do
          create(:customer_return, return_items: [return_item], stock_location_id: inventory_unit.shipment.stock_location_id)
        end.to change { inventory_unit.find_stock_item.count_on_hand }.by(1)
      end

      context 'with Config.track_inventory_levels == false' do
        before do
          Spree::Config.track_inventory_levels = false
          expect(Spree::StockItem).not_to receive(:find_by)
          expect(Spree::StockMovement).not_to receive(:create!)
        end

        it "should NOT update the stock item counts in the stock location" do
          count_on_hand = inventory_unit.find_stock_item.count_on_hand
          create(:customer_return, return_items: [return_item], stock_location_id: inventory_unit.shipment.stock_location_id)
          expect(inventory_unit.find_stock_item.count_on_hand).to eql count_on_hand
        end
      end
    end

    context "to a different stock location" do
      let(:new_stock_location) { create(:stock_location, :name => "other") }

      it "should update the stock item counts in new stock location" do
        expect {
          create(:customer_return, return_items: [return_item], stock_location_id: new_stock_location.id)
        }.to change {
          Spree::StockItem.where(variant_id: inventory_unit.variant_id, stock_location_id: new_stock_location.id).first.count_on_hand
        }.by(1)
      end

      it "should NOT raise an error when no stock item exists in the stock location" do
        inventory_unit.find_stock_item.destroy
        expect { create(:customer_return, return_items: [return_item], stock_location_id: new_stock_location.id) }.not_to raise_error
      end

      it "should not update the stock item counts in the original stock location" do
        count_on_hand = inventory_unit.find_stock_item.count_on_hand
        create(:customer_return, return_items: [return_item], stock_location_id: new_stock_location.id)
        inventory_unit.find_stock_item.count_on_hand.should == count_on_hand
      end
    end
  end

  context "refund" do
    let(:customer_return_refunds) { [] }
    let!(:adjustments)            { [] } # placeholder to ensure it gets run prior the "before" at this level

    let!(:tax_rate)               { nil }
    let!(:tax_zone)               { create(:zone, default_tax: true) }

    let(:order)                   { create(:order_with_line_items, state: 'payment', line_items_count: 1, line_items_price: line_items_price, shipment_cost: 0) }
    let(:line_items_price)        { BigDecimal.new(10) }
    let(:line_item)               { order.line_items.first }
    let(:inventory_unit)          { line_item.inventory_units.first }
    let(:payment)                 { build(:payment, amount: payment_amount, order: order) }
    let(:payment_amount)          { order.total }
    let(:customer_return)         { build(:customer_return, refunds: customer_return_refunds) }
    let(:return_item)             { build(:return_item, pre_tax_amount: inventory_unit.pre_tax_amount, customer_return: customer_return, inventory_unit: inventory_unit) }

    let!(:default_refund_reason) { Spree::RefundReason.find_or_create_by!(name: Spree::RefundReason::RETURN_PROCESSING_REASON, mutable: false) }

    subject do
      customer_return.refund
    end

    before do
      order.shipments.each do |shipment|
        shipment.inventory_units.update_all state: 'shipped'
        shipment.update_column('state', 'shipped')
      end
      order.reload
      order.update!
      if payment
        payment.save!
        order.next! # confirm
      end
      order.next! # completed
      if payment
        payment.state = "completed"
        payment.save!
      end
      customer_return.return_items << return_item
      customer_return.save!
    end

    context "the order has completed payments" do

      context 'with additional tax' do
        let!(:tax_rate) { create(:tax_rate, name: "Sales Tax", amount: 0.10, included_in_price: false, zone: tax_zone) }

        describe 'return_item_tax_calculator' do
          it 'sets the return item tax fields correctly' do
            subject
            return_item.reload
            expect(return_item.additional_tax_total).to be > 0
            expect(return_item.additional_tax_total).to eq line_item.additional_tax_total
          end
        end
      end

      context 'with included tax', focus: true do
        let!(:tax_rate) { create(:tax_rate, name: "VAT Tax", amount: 0.1, included_in_price: true, zone: tax_zone) }

        describe 'return_item_tax_calculator' do
          it 'sets the return item tax fields correctly' do
            subject
            return_item.reload
            expect(return_item.included_tax_total).to be < 0
            expect(return_item.included_tax_total).to eq line_item.included_tax_total
          end
        end
      end

      context "payment amount is enough to refund customer" do
        context "customer has already been refunded for the total amount of the customer return" do
          let!(:customer_return_refunds) { [create(:refund, amount: order.total, payment: payment)] }

          it "should refund the total amount" do
            subject
            expect(customer_return).to be_refunded
          end
        end

        context "customer has not received any refund for the customer return" do
          it "should refund the total amount" do
            subject
            expect(customer_return).to be_refunded
          end

          it "should create a refund" do
            expect { subject }.to change{ Spree::Refund.count }.by(1)
          end

          it "should create a refund with the amount of the customer return" do
            subject
            refund = customer_return.reload.refunds.first
            refund.amount.should eq order.total
          end
        end

        context "customer has been partially refunded for the total amount of the customer return" do
          let(:refunded_amount) { order.total - 1.0 }
          let!(:customer_return_refunds) { [create(:refund, amount: refunded_amount, payment: payment)] }

          it "should refund the total amount" do
            subject
            expect(customer_return).to be_refunded
          end

          it "should create a refund" do
            expect { subject }.to change{ Spree::Refund.count }.by(1)
          end

          it "should create a refund with the remaining amount required to refund the total amount of the customer return" do
            subject
            refund = customer_return.reload.refunds.last # first refund is the partial refund
            refund.amount.should eq (order.total - refunded_amount)
          end
        end
      end

      context "payment amount is not enough to refund customer" do
        # for example, if a standalone refund had already been issued against the payment
        let(:previous_refund_amount) { 1.0 }
        let!(:previous_refund) { create(:refund, payment: payment, amount: previous_refund_amount) }

        it "should return false" do
          expect(subject).to eq false
        end

        it "should add an error message" do
          subject
          expect(customer_return.errors.full_messages).to include(Spree.t("validation.amount_due_greater_than_zero"))
        end

        it "should create a refund" do
          expect{ subject }.to change{ Spree::Refund.count }.by(1)
          customer_return.reload.refunds.last.amount.should eq (payment_amount - previous_refund_amount)
        end
      end

      context "too much was already refunded" do
        let!(:customer_return_refunds) { [create(:refund, amount: order.total+1)] }

        it "should return false" do
          expect(subject).to eq false
        end

        it "should add an error message" do
          subject
          expect(customer_return.errors.full_messages).to include(Spree.t("validation.amount_due_less_than_zero"))
        end
      end
    end

    context "the order doesn't have any completed payments" do
      let(:line_items_price) { 0 }
      let(:payment) { nil }

      it "should refund the total amount" do
        subject
        expect(customer_return).to be_refunded
      end
    end

    context "customer return amount is zero" do
      it "should refund the total amount" do
        subject
        expect(customer_return).to be_refunded
      end
    end
  end
end
