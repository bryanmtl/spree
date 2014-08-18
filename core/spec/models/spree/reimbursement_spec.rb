require 'spec_helper'

describe Spree::Reimbursement do

  describe ".before_create" do
    describe "#generate_number" do
      context "number is assigned" do
        let(:number)        { '123' }
        let(:reimbursement) { Spree::Reimbursement.new(number: number) }

        it "should return the assigned number" do
          reimbursement.save
          expect(reimbursement.number).to eq number
        end
      end

      context "number is not assigned" do
        let(:reimbursement) { Spree::Reimbursement.new(number: nil) }

        before do
          reimbursement.stub(valid?: true)
        end

        it "should assign number with random RI number" do
          reimbursement.save
          expect(reimbursement.number).to be =~ /RI\d{9}/
        end
      end
    end
  end

  describe "#display_total" do
    let(:total)         { 100.50 }
    let(:currency)      { "USD" }
    let(:order)         { Spree::Order.new(currency: currency) }
    let(:reimbursement) { Spree::Reimbursement.new(total: total, order: order) }

    subject { reimbursement.display_total }

    it "returns the value as a Spree::Money instance" do
      expect(subject).to eq Spree::Money.new(total)
    end

    it "uses the order's currency" do
      expect(subject.money.currency.to_s).to eq currency
    end
  end

  describe "#perform!" do
    let!(:adjustments)            { [] } # placeholder to ensure it gets run prior the "before" at this level

    let!(:tax_rate)               { nil }
    let!(:tax_zone)               { create(:zone, default_tax: true) }

    let(:order)                   { create(:order_with_line_items, state: 'payment', line_items_count: 1, line_items_price: line_items_price, shipment_cost: 0) }
    let(:line_items_price)        { BigDecimal.new(10) }
    let(:line_item)               { order.line_items.first }
    let(:inventory_unit)          { line_item.inventory_units.first }
    let(:payment)                 { build(:payment, amount: payment_amount, order: order) }
    let(:payment_amount)          { order.total }
    let(:reimbursement_item)      { build(:reimbursement_item, pre_tax_amount: inventory_unit.pre_tax_amount, inventory_unit: inventory_unit) }

    let!(:default_refund_reason) { Spree::RefundReason.find_or_create_by!(name: Spree::RefundReason::RETURN_PROCESSING_REASON, mutable: false) }

    let(:reimbursement) { create(:reimbursement, order: order, reimbursement_items: [reimbursement_item]) }

    subject { reimbursement.perform! }

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
        payment.state = 'completed'
        payment.save!
      end
    end

    it "refunds the total amount" do
      subject
      expect(reimbursement.unpaid_amount).to eq 0
    end

    it "creates a refund" do
      expect {
        subject
      }.to change{ Spree::Refund.count }.by(1)
      Spree::Refund.last.amount.should eq order.total
    end

    context 'with additional tax' do
      let!(:tax_rate) { create(:tax_rate, name: "Sales Tax", amount: 0.10, included_in_price: false, zone: tax_zone) }

      it 'saves the additional tax and refunds the total' do
        expect {
          subject
        }.to change { Spree::Refund.count }.by(1)
        reimbursement_item.reload
        expect(reimbursement_item.additional_tax_total).to be > 0
        expect(reimbursement_item.additional_tax_total).to eq line_item.additional_tax_total
        expect(reimbursement.total).to eq line_item.pre_tax_amount + line_item.additional_tax_total
        expect(Spree::Refund.last.amount).to eq line_item.pre_tax_amount + line_item.additional_tax_total
      end
    end

    context 'with included tax' do
      let!(:tax_rate) { create(:tax_rate, name: "VAT Tax", amount: 0.1, included_in_price: true, zone: tax_zone) }

      it 'saves the additional tax and refunds the total' do
        expect {
          subject
        }.to change { Spree::Refund.count }.by(1)
        reimbursement_item.reload
        expect(reimbursement_item.included_tax_total).to be < 0
        expect(reimbursement_item.included_tax_total).to eq line_item.included_tax_total
        expect(reimbursement.total).to eq line_item.pre_tax_amount.round(2, :down)
        expect(Spree::Refund.last.amount).to eq line_item.pre_tax_amount.round(2, :down)
      end
    end

    context 'when reimbursement cannot be fully performed' do
      let!(:non_return_refund) { create(:refund, amount: 1, payment: payment) }

      it 'raises IncompleteReimbursement error' do
        expect { subject }.to raise_error(Spree::Reimbursement::IncompleteReimbursement)
      end
    end

    context "when exchange is required" do
      let(:exchange_variant) { build(:variant) }
      before { reimbursement_item.exchange_variant = exchange_variant }
      it "generates an exchange shipment for the order for the exchange items" do
        expect { subject }.to change { order.reload.shipments.count }.by 1
        expect(order.shipments.last.inventory_units.first.variant).to eq exchange_variant
      end
    end

  end

  describe "#reimbursement_items_requiring_exchange" do
    it "returns only the return items that require an exchange" do
      reimbursement_items = [double(exchange_required?: true), double(exchange_required?: true), double(exchange_required?: false)]
      subject.stub(:reimbursement_items) { reimbursement_items }
      expect(subject.reimbursement_items_requiring_exchange).to eq reimbursement_items.take(2)
    end
  end

  describe "#calculated_total" do
    context 'with reimbursement item amounts that would round up' do
      let(:reimbursement) { Spree::Reimbursement.new }

      subject { reimbursement.calculated_total }

      before do
        reimbursement.reimbursement_items << Spree::ReimbursementItem.new(pre_tax_amount: 10.003)
        reimbursement.reimbursement_items << Spree::ReimbursementItem.new(pre_tax_amount: 10.003)
      end

      it 'rounds down' do
        expect(subject).to eq 20
      end
    end
  end
end
