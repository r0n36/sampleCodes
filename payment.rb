class Payment < ActiveRecord::Base
  require "stripe"

  belongs_to :account
  attr_accessible :stripe_token, :last_4_digits, :subscription_type
  attr_accessible :address_line_1, :address_line_2, :city, :state, :zip, :country, :exp_month, :exp_year, :credit_card_number, :plan_id
  attr_accessor :stripe_token, :plan_id, :row1, :row2, :row3, :row4, :row5

  before_save :update_stripe

  validates :last_4_digits, :presence => true

  #def plan_id=(p_id)
  #  self.plan_id = p_id
  #end

  # ALERT_COST = {
  #     "1-#{self.account.store.store_pricing.alerts_max_devices} Devices Included" => self.account.store.store_pricing.alerts_price,
  #     "#{self.account.store.store_pricing.alerts_max_devices+1}-#{self.account.store.store_pricing.alerts_max_devices *2} Devices Included" => self.account.store.store_pricing.alerts_price*2,
  #     "#{self.account.store.store_pricing.alerts_max_devices*2 +1}-#{self.account.store.store_pricing.alerts_max_devices *3} Devices Included" => self.account.store.store_pricing.alerts_price*3
  # }

  FEATURE_NAME_MODIFIER = {
      "device_count" => "Device Included",
      "cost_additional_device" => "Additional Device Cost",
      "history_interval" => "History Interval",
      "rule_access" => "Rule Access",
      "scene_access" => "Scene Access",
      "individual_rule_access" => "Individual Rule Access",
      "remote_device_control" => "Remote Device Control",
      "schedules" => "Schedules",
      "history" => "History",
      "text_alerts" => "Text Alerts",
      "email_alerts" => "Email Alerts",
      "rules" => "Rules"
  }.freeze

  def calculate_all_total_charge(device_count, alert_pack, rule_pack, history_pack, cam_history_pack, checked_arr)
    store_pricing = self.account.store.store_pricing
    alert_pack = alert_pack / store_pricing.alerts_price unless alert_pack.blank?
    rule_pack = rule_pack / store_pricing.rules_price unless rule_pack.blank?

    history_pack = history_pack.split('_').last unless history_pack.nil?
    cam_history_pack = cam_history_pack.split('_').last unless cam_history_pack.nil?

    # Paid device
    row_1 = 0
    row_1 = self.charge_calculator(device_count) unless device_count.blank?

    # Alert charge
    row_2 = 0
    row_2 = store_pricing.alerts_price * alert_pack unless alert_pack.blank?

    # Rule charge
    row_3 = 0
    row_3 = store_pricing.rules_price * rule_pack unless rule_pack.blank?

    # Device History charge
    unless history_pack.blank?
      max = eval("store_pricing.history_tier_#{history_pack}_max_devices")
      cost = eval("store_pricing.history_tier_#{history_pack}_price")
      obj = self.all_history_charge(max, cost, device_count)
      row_4 = obj[0]
    else
      obj = Array.new(2,0)
      obj[1] = 0
      row_4 = 0
    end

    # Camera History charge
    c_obj = 0
    unless cam_history_pack.blank?
      c_max = eval("store_pricing.camera_history_tier_#{cam_history_pack}_max_devices")
      c_cost = eval("store_pricing.camera_history_tier_#{cam_history_pack}_price")
      c_obj = self.all_history_charge(c_max, c_cost, device_count)
      row_5 = c_obj[0]
    else
      c_obj = Array.new(2,0)
      c_obj[1] = 0
      row_5 = 0
    end

    row_1 = 0 if checked_arr[0] == 'false' || checked_arr[0].nil?
    row_2 = 0 if checked_arr[1] == 'false' || checked_arr[1].nil?
    row_3 = 0 if checked_arr[2] == 'false' || checked_arr[2].nil?
    row_4 = 0 if checked_arr[3] == 'false' || checked_arr[3].nil?
    row_5 = 0 if checked_arr[4] == 'false' || checked_arr[4].nil?

    grand_monthly_total = row_1 + row_2 + row_3 + row_4 +row_5
    grand_yearly_total = (grand_monthly_total * 12) - (grand_monthly_total * 12 * 0.1)

    return grand_monthly_total, grand_yearly_total, obj[1], c_obj[1]
  end

  def all_history_charge(max_device, cost, total_devices)
    calc_total = 0
    tier_count = 0
    if total_devices % max_device == 0
      calc_total = (total_devices / max_device).to_i * cost
      tier_count = (total_devices / max_device).to_i
    else
      calc_total = ((total_devices / max_device).to_i + 1) * cost
      tier_count = ((total_devices / max_device).to_i + 1)
    end
    return calc_total, tier_count
  end
  def charge_calculator(device_count)
    payment = self
    total = device_count
    threshold = []
    (1..7).each do |x|
      max_device = eval("payment.account.store.store_pricing.devices_tier_#{x}_max_devices")
      threshold << max_device unless max_device.blank?
    end
    result = []
    threshold.each do |max|
      if max <= total
        total -= max
        result << max
      else
        result << total
        break
      end
    end
    total_charge = 0
    result.each_with_index do |z, index|
      price = eval("payment.account.store.store_pricing.devices_tier_#{index + 1}_price")
      total_charge += (z * price)
    end

    return total_charge
  end

  def update_metadata(store, account)
    customer = Stripe::Customer.retrieve(self.stripe_id)
    customer.metadata[:store_name] = store.name
    customer.metadata[:store_id] = store.id
    customer.metadata[:stripe_plan_name] = account.plan_tier.external_plan_code
    customer.metadata[:store_plan_name] = account.plan.name
    customer.save
  end

  def self.pull_stripe_meta_data
    # Since we have duplicate checking we can overlap pulls
    latest_charge = StripeCharge.order('event_time desc').first
    time_from = latest_charge.event_time - 1.day
    has_more = true
    max_loops = 100
    starting_after = nil

    while has_more && max_loops > 0
      search_params = {:created => {gte: time_from.to_i }, :starting_after => starting_after, :limit=>100}

      all_charges = Stripe::Charge.all(search_params)


      all_charges.each do |charge|
        exists = StripeCharge.where(:invoice_id => charge[:invoice])
        if exists.blank?
          puts "Processing: " + charge[:invoice]
          stripe_charge = StripeCharge.new
          stripe_charge.event_time = Time.at charge[:created]
          stripe_charge.customer_id = charge[:customer]
          stripe_charge.invoice_id = charge[:invoice]
          stripe_charge.card_id = charge[:card][:id]
          stripe_charge.amount = charge[:amount]
          stripe_charge.currency = charge[:currency]

          customer = Stripe::Customer.retrieve(charge[:customer])

          unless customer[:metadata].blank? || customer[:metadata][:store_id].blank?
            stripe_charge.store_id = customer[:metadata][:store_id]
            stripe_charge.stripe_plan_name = customer[:metadata][:stripe_plan_name]
            stripe_charge.store_plan_name = customer[:metadata][:store_plan_name]
          else
            payment = Payment.where(:stripe_id => charge[:customer]).first
            unless payment.blank?
              charge_store = payment.account.store unless payment.account.blank?
              charge_plan = payment.account.plan unless payment.account.blank?

              stripe_charge.store_id = charge_store.id unless charge_store.blank?
              stripe_charge.stripe_plan_name = payment.subscription_type
              stripe_charge.store_plan_name = charge_plan.name unless charge_plan.blank?
            end
          end
          stripe_charge.save
        else
          puts "Exists: #{charge[:invoice]}"
        end

        starting_after = charge[:id]
      end
      has_more = all_charges.has_more
      max_loops -= 1

      puts "STILL going: #{has_more.inspect()} #{max_loops}"
    end
  end

  def update_stripe

    if stripe_token.present?
      if stripe_id.nil?
        customer = Stripe::Customer.create(
            :description => self.account.email,
            :card => {
                :number => self.credit_card_number,
                :address_line1 => self.address_line_1,
                :address_line2 => self.address_line_2,
                :address_zip => self.zip,
                :address_state => self.state,
                :address_country => self.country,
                :exp_month => self.exp_month.to_i,
                :exp_year => self.exp_year.to_i,
                :name => self.name,
                :city => self.city
            },
            :metadata => {
                :store_name => self.account.store.name,
                :store_id => self.account.store.id,
                :stripe_plan_name => (self.account.plan_tier.blank?? '': self.account.plan_tier.external_plan_code),
                :store_plan_name => (self.account.plan.blank?? '': self.account.plan.name)
            }
        )
        self.last_4_digits = customer.active_card.last4
        response = customer.update_subscription({:plan => self.subscription_type})
      else
        customer = Stripe::Customer.retrieve(stripe_id)
        customer.description = "Customer for #{self.account.email}"
        customer.card = stripe_token
        customer.active_card.address_line_1 = self.address_line_1
        customer.active_card.address_line_2 = self.address_line_2
        customer.active_card.address_zip = self.zip
        customer.active_card.address_state = self.state
        customer.active_card.address_county = self.country
        customer.active_card.exp_month = self.exp_month
        customer.active_card.exp_year = self.exp_year
        customer.save

        unless self.subscription_type.nil?
          Rails.logger.warn("Updating Stripe ##{stripe_id} to #{self.subscription_type}")
          customer.update_subscription({:plan =>self.subscription_type, :prorate => true})
        else
          Rails.logger.warn("Could not update Stripe ##{stripe_id} (blank subscription_type)")
        end

        self.last_4_digits = customer.active_card.last4
      end

      self.account.update_attribute(:subscribed, true)
      self.stripe_id = customer.id
      self.stripe_token = nil
    elsif last_4_digits_changed?
      self.last_4_digits = last_4_digits_was
    end
  end

  def self.annual_cost(plan)
    #plan = Plan.find_by_id(current_user.account.plan_id)
    if plan.interval == 'month'
      annual_cost = (plan.amount.to_f * 12).round(2)
    else
      annual_cost = plan.amount.to_f
    end

    return (annual_cost / 100).round(2) #for cent to dollar conversion
  end

  def charge_of_paid_devices(device_count, store_id)
    store = Store.find store_id
    total = device_count
    threshold = []
    (1..7).each do |x|
      max_device = eval("store.store_pricing.devices_tier_#{x}_max_devices")
      threshold << max_device unless max_device.blank?
    end
    result = []
    threshold.each do |max|
      if max <= total
        total -= max
        result << max
      else
        result << total
        break
      end
    end
    total_charge = 0
    result.each_with_index do |z, index|
      price = eval("store.store_pricing.devices_tier_#{index + 1}_price")
      total_charge += (z * price)
    end

    return total_charge
  end

  def charge_calculator_for_existing_users(current_store, device_count)
    store = current_store
    total = device_count
    threshold = []
    (1..7).each do |x|
      max_device = eval("store.store_pricing.devices_tier_#{x}_max_devices")
      threshold << max_device unless max_device.blank?
    end
    result = []
    threshold.each do |max|
      if max <= total
        total -= max
        result << max
      else
        result << total
        break
      end
    end
    total_charge = 0
    result.each_with_index do |z, index|
      price = eval("store.store_pricing.devices_tier_#{index + 1}_price")
      total_charge += (z * price)
    end

    return total_charge
  end
end
