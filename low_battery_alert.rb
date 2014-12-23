module LowBatteryAlert
  require 'lib/lock_state_device/lock_state_api_base'
  @queue = :low_battery_alert

  def self.perform
    all_locks = Lock.all
    api_time_zone = ActiveSupport::TimeZone.new('US/Pacific')

    all_locks.each do |lock|
      if lock.low_battery_alert

        # 5 days cycle
        if lock.running_low
          last_3hb = lock.get_last_heartbeats 3
          unless last_3hb.nil? || last_3hb.empty? || last_3hb.last.nil? || last_3hb.last["battery"].nil?
            unless last_3hb.first == 403
              if lock.battery_low_checkpoint <= Time.now && last_3hb.last["battery"] < 4
                Notifier.send_low_battery_alert(lock.property.account, lock).deliver
                lock.battery_low_checkpoint = Time.now + 5.days
                lock.save

                # Does this need to be translated into UTC?
                last_heartbeat_time = api_time_zone.parse(last_3hb.last["time"].to_s)

                #Send a PubSub event for this
                ApiPartnerNotificationHelper.send_event_notification(lock, LockStateLockApi::EVENT_TYPE_LOW_BATTERY_ALERT, true, last_3hb.last["battery"], last_heartbeat_time)

              else
                reset_alert(lock) if last_3hb.last["battery"] > 4.5
              end
            end
          end
        end

        # First entry
        if lock.battery_low_checkpoint.nil?
          last_3hb = lock.get_last_heartbeats 3

          unless last_3hb.nil? || last_3hb.empty? || last_3hb.last.nil? || last_3hb.last["battery"].nil?
            unless last_3hb.first == 403
              if last_3hb.last["battery"] < 4
                lock.battery_low_checkpoint = Time.now + 24.hours
                lock.save
              end
            end
          end
        else
        # Second entry
          last_3hb = lock.get_last_heartbeats 3
          unless last_3hb.nil? || last_3hb.empty? || last_3hb.last.nil? || last_3hb.last["battery"].nil?
            unless last_3hb.first == 403
              if lock.battery_low_checkpoint <= Time.now && last_3hb.last["battery"] < 4
                Notifier.send_low_battery_alert(lock.property.account, lock).deliver
                lock.running_low = true
                lock.battery_low_checkpoint = Time.now + 5.days
                lock.save

                # Does this need to be translated into UTC?
                last_heartbeat_time = api_time_zone.parse(last_3hb.last["time"].to_s)

                #Send a PubSub event for this
                ApiPartnerNotificationHelper.send_event_notification(lock, LockStateLockApi::EVENT_TYPE_LOW_BATTERY_ALERT, true, last_3hb.last["battery"], last_heartbeat_time)

              else
                reset_alert(lock) if last_3hb.last["battery"] > 4.5
              end
            end
          end
        end

      end
    end
  end

  def self.reset_alert(lock)
    lock.battery_low_checkpoint = nil
    lock.running_low = false
    lock.save
  end

  #def self.calculate_battery_level(battery_level)
  #
  # # Range is 4.0 (0%) to 6 (100%)
  #  min_voltage = 3.5
  #  max_voltage = 6
  #  adjusted_level = battery_level.to_f - min_voltage
  #  adjusted_level = 0 if adjusted_level < 0
  #
  #  battery_percent = (adjusted_level/(max_voltage - min_voltage))*100.ceil
  #  ((battery_percent.to_f)/25.0).ceil.to_i
  #end
end

