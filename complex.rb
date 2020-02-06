class SaleCancelRefund
  class << self
    def proceed(sale)
      self.new(sale).cancel
    end
  end

  def initialize(sale)
    @sale = sale
    @buyer = sale.buyer
  end

  def cancel
    return false if @sale.buyer.wallet.balance_cents <= 0

    ActiveRecord::Base.transaction do
      revert_line_items_attributes
      revert_sale_attributes
      generate_items_from_payment_events
    end

    true
  end
  
  private

  def generate_items_from_payment_events
    payment_events.each do |event|
      if event.due_on.present?
        create_recurring_payments(event)
      else
        create_wallet_items(event)
        make_payment_event_visible_to_user(event)
      end
    end
  end

  def removeble_type(type)
    {
      'AppWallet': :walletable,
      'WalletItem': :accountable
    }[type.to_sym]
  end

  def create_wallet_items(event)
    wallet = event.wallet_type.constantize.new

    params = {
      wallet_id: event.user.wallet.id,
      amount_cents: event.amount_cents,
      memo: event.name,
      walletable: @sale,
      accountable: @sale
    }
    params.delete(removeble_type(event.wallet_type))

    wallet.attributes = params
    wallet.save
  end

  def create_recurring_payments(event)
    RecurringPayment.create(
      payable: @sale.order,
      wallet_id: event.user.wallet.id,
      amount_cents: event.amount_cents,
      due_on: event.due_on
    )
    
    PaymentEvent.create(
      payment_eventable: @sale.order,
      name: event.name,
      amount_cents: event.amount_cents,
      user_id: event.user_id
    )
  end

  def make_payment_event_visible_to_user(event)
    if event.wallet_type == 'WalletItem'
      new_event = event.dup
      new_event.visible = true
      new_event.save
    end
  end

  def revert_line_items_attributes
    @sale.line_items.where(status: 'refunded').update_all(status: 'accepted',
                                                          rejected_at: nil,
                                                          litigation_status: 'none')
  end

  def revert_sale_attributes
    @sale.canceled_by = nil
    @sale.canceled_at = nil
    @sale.paused_at = nil
    @sale.buyer_refunded_amount_cents = 0
    @sale.seller_refunded_amount_cents = 0
    @sale.save
    @sale.reindex
  end

  def payment_events
    payment_events = PaymentEvent.where(payment_eventable: @sale, visible: false)
                                 .order(refund_count: :desc)
    payment_events = payment_events.where(refund_count: payment_events&.last&.refund_count)
    payment_events
  end
end
