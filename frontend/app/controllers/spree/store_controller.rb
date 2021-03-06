module Spree
  class StoreController < Spree::BaseController
    include Spree::Core::ControllerHelpers::Order

    def unauthorized
      render 'spree/shared/unauthorized', :layout => Spree::Config[:layout], :status => 401
    end

    def cart_link
      render :partial => 'spree/shared/link_to_cart'
      fresh_when(simple_current_order)
    end

    protected
      # This method is placed here so that the CheckoutController
      # and OrdersController can both reference it (or any other controller
      # which needs it)
      def apply_coupon_code
        if params[:order] && params[:order][:coupon_code]
          handler = @order.contents.apply_coupon_code(params[:order][:coupon_code])

          if handler.error.present?
            flash.now[:error] = handler.error
            respond_with(@order) { |format| format.html { render :edit } } and return
          elsif handler.success
            flash[:success] = handler.success
          end
        end
      end

      def config_locale
        Spree::Frontend::Config[:locale]
      end

      def lock_order
        OrderMutex.with_lock!(@order) { yield }
      rescue Spree::OrderMutex::LockFailed => e
        flash[:error] = Spree.t(:order_mutex_error)
        redirect_to spree.cart_path
      end
  end
end

