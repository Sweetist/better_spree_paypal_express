module Spree
  class PaypalExpressCheckout < ActiveRecord::Base
    def actions
      %w[credit]
    end

    # Indicates whether its possible to credit the payment.  Note that most gateways require that the
    # payment be settled first which generally happens within 12-24 hours of the transaction.
    def can_credit?(payment)
      payment.completed? && payment.credit_allowed > 0
    end

    def paypal?
      true
    end
  end
end
