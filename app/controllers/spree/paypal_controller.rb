module Spree
  class PaypalController < StoreController
    include Spree::Backend::Callbacks
    def express
      order = current_spree_user.company.purchase_orders.friendly.find(params[:order_id])
      pp_request = provider.build_set_express_checkout(express_checkout_request_details(order))

      begin
        pp_response = provider.set_express_checkout(pp_request)
        if pp_response.success?
          respond_to do |format|
            format.js { render js: "window.location = '#{provider.express_checkout_url(pp_response, :useraction => 'commit')}';" }
          end
        else
          flash[:errors] = Spree.t('flash.generic_error', :scope => 'paypal', :reasons => pp_response.errors.map(&:long_message).join(" "))
          respond_to do |format|
            format.js { render js: "window.location = '#{edit_order_path(order)}';" }
          end
        end
      rescue SocketError
        flash[:errors] = Spree.t('flash.connection_failed', :scope => 'paypal')
        respond_to do |format|
          format.js { render js: "window.location = '#{edit_order_path(order)}';" }
        end
      end
    end

    def confirm
      invoke_callbacks(:create, :before)
      @order = current_spree_user.company.purchase_orders.friendly.find(params[:order_id])
      @account_payment ||= @order.account_payments.new(
        source: Spree::PaypalExpressCheckout.create(
          token: params[:token],
          payer_id: params[:PayerID]
        ),
        amount: params[:amount],
        payment_method: payment_method
      )
      @account_payment.account = @order.account
      @account_payment.customer = @order.customer
      @account_payment.vendor = @order.vendor
      @account_payment.last_ip_address = current_spree_user.try(:current_sign_in_ip)
      @account_payment.orders_amount_sum = orders_amount_sum
      if @order.final_payments_pending?
        flash.now[:errors] = ['Payments are already pending for this order.']
        respond_to do |format|
          format.html { render :new and return }
          format.js { render :create and return }
        end
      end

      if @order.paid?
        flash.now[:errors] = ['This order is already paid.']
        respond_to do |format|
          format.html { render :new and return }
          format.js { render :create and return }
        end
      end

      begin
        @account_payment.save
        if @account_payment.errors.any? \
          || !@order.valid_for_customer_submit?({skip_payment: true})
          invoke_callbacks(:create, :fails)
          flash.now[:errors] = @account_payment.errors.full_messages + @order.errors_including_line_items
          respond_to do |format|
            format.html { redirect_to edit_order_path(@order) }
            format.js { render js: 'window.location.reload();' }
          end
        else
          invoke_callbacks(:create, :after)
          @order.channel = Spree::Company::B2B_PORTAL_CHANNEL if @order.state == 'cart'
          ActiveRecord::Base.transaction do
            while States[@order.state] < States['complete'] && @order.next; end
            @account_payment.process_and_capture if @order.completed? && @account_payment.checkout?
            add_payments({async: false})
          end
          @order.update_columns(user_id: current_spree_user.try(:id)) if @order.user_id.nil?
          flash[:success] = 'Payment created'
          @order.reload
          if params[:commit] == Spree.t(:submit_order)
            respond_to do |format|
              format.html { redirect_to success_order_path(@order) }
              format.js { render js: "window.location.href = '" + success_order_path(@order) + "'" }
            end
          else
            respond_to do |format|
              format.html { redirect_to edit_order_path(@order) }
              format.js { render js: 'window.location.reload();' }
            end
          end
        end
      rescue Spree::Core::GatewayError => e
        invoke_callbacks(:create, :fails)
        @account_payment.destroy!
        error_message = e.message == 'Internal Error' ? 'Unable to reach PayPal servers. Please contact help@getsweet.com for additional information.' : e.message
        flash[:errors] = [error_message]
        redirect_to edit_order_path(@order)
      end
    end

    def cancel
      flash[:notice] = Spree.t('flash.cancel', :scope => 'paypal')
      order = current_spree_user.company.purchase_orders.friendly.find(params[:order_id])
      redirect_to edit_order_path(order)
    end

    private

    def express_checkout_request_details(order)
      { SetExpressCheckoutRequestDetails: {
        InvoiceID: order.number + '_' + (order.payments.count + 1).to_s,
        BuyerEmail: order.valid_emails.first.to_s,
        ReturnURL: confirm_paypal_url(
          payment_method_id: params[:payment_method_id],
          utm_nooverride: 1,
          order_id: order.id,
          amount: params[:amount],
          commit: params[:commit]
        ),
        CancelURL:  cancel_paypal_url(order_id: order.id),
        SolutionType: payment_method.preferred_solution.present? ? payment_method.preferred_solution : 'Mark',
        LandingPage: payment_method.preferred_landing_page.present? ? payment_method.preferred_landing_page : 'Billing',
        cppheaderimage: payment_method.preferred_logourl.present? ? payment_method.preferred_logourl : '',
        NoShipping: 1,
        PaymentDetails: [payment_details]
      } }
    end

    def payment_method
      Spree::PaymentMethod.find(params[:payment_method_id])
    end

    def provider
      payment_method.provider
    end

    def payment_details
      order = current_spree_user.company.purchase_orders.friendly.find(params[:order_id])
      payment_amount = params[:amount]
      # This retrieves the cost of shipping after promotions are applied
      # For example, if shippng costs $10, and is free with a promotion, shipment_sum is now $10
      shipment_sum = 0

      # This calculates the item sum based upon what is in the order total, but not for shipping
      # or tax.  This is the easiest way to determine what the items should cost, as that
      # functionality doesn't currently exist in Spree core
      item_sum = order.total - shipment_sum - order.additional_tax_total

      if item_sum.zero?
        # Paypal does not support no items or a zero dollar ItemTotal
        # This results in the order summary being simply "Current purchase"
        {
          OrderTotal: {
            currencyID: order.currency,
            value: payment_amount
          }
        }
      else
        {
          OrderTotal: {
            currencyID: order.currency,
            value: payment_amount
          },
          ItemTotal: {
            currencyID: order.currency,
            value: payment_amount
          },
          ShippingTotal: {
            currencyID: order.currency,
            value: shipment_sum
          },
          TaxTotal: {
            currencyID: order.currency,
            value: 0
          },
          ShipToAddress: address_options,
          ShippingMethod: 'Shipping Method Name Goes Here',
          PaymentAction: 'Sale'
        }
      end
    end

    def address_options
      order = current_spree_user.company.purchase_orders.friendly.find(params[:order_id])
      return {} unless address_required?

      {
        Name: order.bill_address.try(:full_name),
        Street1: order.bill_address.try(:address1),
        Street2: order.bill_address.try(:address2),
        CityName: order.bill_address.try(:city),
        Phone: order.bill_address.try(:phone),
        StateOrProvince: order.bill_address.try(:state_text),
        Country: order.bill_address.try(:country).try(:iso),
        PostalCode: order.bill_address.try(:zipcode)
      }
    end

    # uses for add child payments in Sidekiq when create
    # to resolve timeout issues
    def add_payments(options = {})
      opts = { async: true }
      opts.merge!(options)
      return unless payments_attributes && @account_payment
      @account_payment.reload
      if Rails.env.test? || opts[:async]
        @account_payment.add_and_process_child_payments(payments_attributes)
      else
        AccountPaymentProcessWorker
          .perform_async(@account_payment.id, payments_attributes)
      end
    end

    def orders_amount_sum
      return 0 unless payments_attributes

      payments_attributes.inject(0) { |sum, pa| sum + pa['amount'].to_d }
    end

    def payments_attributes
      [{ 'order_id' => @order.id, 'amount' => @account_payment.amount }]
    end

    def completion_route(order)
      order_path(order)
    end

    def address_required?
      payment_method.preferred_solution.eql?('Sole')
    end
  end
end
