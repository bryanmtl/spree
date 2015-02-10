require 'spec_helper'

shared_examples_for 'unlimited supply' do
  it 'can_supply? any amount' do
    subject.can_supply?(1).should be true
    subject.can_supply?(101).should be true
    subject.can_supply?(100_001).should be true
  end
end

module Spree
  module Stock
    describe Quantifier do

      before(:all) { Spree::StockLocation.destroy_all } #FIXME leaky database

      let!(:stock_location) { create :stock_location_with_items  }
      let!(:stock_item) { stock_location.stock_items.order(:id).first }

      subject { described_class.new(stock_item.variant) }

      specify { subject.stock_items.should == [stock_item] }


      context 'with a single stock location/item' do
        it 'total_on_hand should match stock_item' do
          subject.total_on_hand.should ==  stock_item.count_on_hand
        end

        context 'when track_inventory_levels is false' do
          before { configure_spree_preferences { |config| config.track_inventory_levels = false } }

          specify { subject.total_on_hand.should == Float::INFINITY }

          it_should_behave_like 'unlimited supply'
        end

        context 'when variant inventory tracking is off' do
          before { stock_item.variant.track_inventory = false }

          specify { subject.total_on_hand.should == Float::INFINITY }

          it_should_behave_like 'unlimited supply'
        end

        context 'when stock item allows backordering' do

          specify { subject.backorderable?.should be true }

          it_should_behave_like 'unlimited supply'
        end

        context 'when stock item prevents backordering' do
          before { stock_item.update_attributes(backorderable: false) }

          specify { subject.backorderable?.should be false }

          it 'can_supply? only upto total_on_hand' do
            subject.can_supply?(1).should be true
            subject.can_supply?(10).should be true
            subject.can_supply?(11).should be false
          end
        end

      end

      context 'with multiple stock locations/items' do
        let!(:stock_location_2) { create :stock_location }
        let!(:stock_location_3) { create :stock_location, active: false }

        before do
          stock_location_2.stock_items.where(variant_id: stock_item.variant).update_all(count_on_hand: 5, backorderable: false)
          stock_location_3.stock_items.where(variant_id: stock_item.variant).update_all(count_on_hand: 5, backorderable: false)
        end

        it 'total_on_hand should total all active stock_items' do
          subject.total_on_hand.should == 15
        end

        context 'when any stock item allows backordering' do
          specify { subject.backorderable?.should be true }

          it_should_behave_like 'unlimited supply'
        end

        context 'when all stock items prevent backordering' do
          before { stock_item.update_attributes(backorderable: false) }

          specify { subject.backorderable?.should be false }

          it 'can_supply? upto total_on_hand' do
            subject.can_supply?(1).should be true
            subject.can_supply?(15).should be true
            subject.can_supply?(16).should be false
          end
        end

      end

      context 'with order stock locations specified' do
        let(:order) { create :order }
        let!(:stock_location_2) { create :stock_location }
        let!(:stock_location_3) { create :stock_location, active: false }
        let!(:order_stock_location_1) { Spree::OrderStockLocation.create!(stock_location: stock_location, variant: stock_item.variant, quantity: 5, order: order) }
        let!(:order_stock_location_2) { Spree::OrderStockLocation.create!(stock_location: stock_location_3, variant: stock_item.variant, quantity: 3, order: order) }

        before do
          stock_location_2.stock_items.where(variant_id: stock_item.variant).update_all(count_on_hand: 5, backorderable: false)
          stock_location_3.stock_items.where(variant_id: stock_item.variant).update_all(count_on_hand: 3, backorderable: false)
        end

         subject { described_class.new(stock_item.variant, Spree::OrderStockLocation.where(order: order, variant: stock_item.variant)) }

        it 'total_on_hand should total all stock_items in configured locations' do
          subject.total_on_hand.should == 13
        end

        context 'when any stock item allows backordering' do
          specify { subject.backorderable?.should be true }

          it_should_behave_like 'unlimited supply'
        end

        context 'when all stock items prevent backordering' do
          before { stock_item.update_attributes(backorderable: false) }

          specify { subject.backorderable?.should be false }

          it 'can_supply? upto total_on_hand' do
            subject.can_supply?(1).should be true
            subject.can_supply?(13).should be true
            subject.can_supply?(15).should be false
          end
        end
      end

    end
  end
end
