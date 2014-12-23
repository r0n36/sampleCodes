module InternetConnectionAlert
  require 'lib/lock_state_device/lock_state_api_base'
  @queue = :internet_connection_alert

  def self.perform
    #Internet connection checking for LOCKS
    locks = Lock.all

    locks.each do |lock|
      check_connection_alert_and_send(lock) if lock.lost_connection_alert && lock.enable_access_event_alert
    end

    #Internet connection checking for PLUGS
    plugs = PowerPlug.all

    plugs.each do |plug|
      check_connection_alert_and_send(plug) if plug.lost_connection_alert && plug.enable_access_event_alert
    end

    # Internet connection checking for THERMOSTATS
    thermostats = Thermostat.all

    thermostats.each do |thermostat|
      check_connection_alert_and_send(thermostat) if thermostat.lost_connection_alert && thermostat.enable_access_event_alert
    end
  end

  def self.check_connection_alert_and_send(device)
    unless device.connection_dead
      api_time_zone = ActiveSupport::TimeZone.new('US/Pacific')
      puts "::::#{device.class}- #{device.id}::: After 6hours Second Entry: First Part"
      last_3hb = device.get_last_heartbeats 3
      puts ":::::Got Blank" if last_3hb.blank?

      unless last_3hb.blank?
        puts ":::::Got 403" if last_3hb.first == 403
        unless last_3hb.first == 403
          puts "::::: #{last_3hb} ::::"
          time_zone = ActiveSupport::TimeZone.new(device.property.time_zone)
          last_hb_time = api_time_zone.parse(last_3hb.last["time"].to_s).in_time_zone(time_zone)
          time_difference = (Time.now.in_time_zone(time_zone) - last_hb_time).to_i

          if time_difference >= 6.hours && time_difference < 14.hours
            puts "::::#{device.class}- #{device.id}::: After 6hours Second Entry: Second Part"
            Notifier.send_internet_connection_alert(AlertContact.find(device.alert_contact_1_id).address, device).deliver
            # device.internet_connection_checkpoint = Time.now + 6.hours
            # device.save

            #Send a PubSub event for this
            ApiPartnerNotificationHelper.send_event_notification(device, LockStateLockApi::EVENT_TYPE_LOST_CONNECTION_ALERT, true, time_difference, api_time_zone.parse(last_3hb.last["time"].to_s))

          elsif time_difference >= 14.hours
            puts "::::#{device.class}- #{device.id}::: After 6hours Second Entry: Killing Forever Part"
            device.connection_dead = true    # Killing Alert forever
            device.save
          end
        end
      end
    end
  end

end