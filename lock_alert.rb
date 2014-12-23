module LockAlert
  require 'lib/lock_state_device/lock_state_api_base'
  @queue = :lock_alert


  def self.send_alert(lock, access_code, status, username_list, access_time)

    # Is this a user with one property or many?  If many, include the property name with the lock name
    lock_desc = lock.name
    lock_desc = "#{lock.property.name} - #{lock_desc}" if lock.property.account.properties.count > 1

    if username_list.blank?
      sms_message = "From: LockState Connect " + "\n" + lock_desc + " was unlocked at " + access_time.to_s
      email_message = lock_desc + " was unlocked at " + access_time.to_s
    else
      sms_message = "From: LockState Connect " + "\n" + lock_desc + " was unlocked by " + username_list.to_s + " at " + access_time.to_s
      email_message = lock_desc + " was unlocked by " + username_list.to_s + " at " + access_time.to_s
    end

    if status.to_s == lock.api.event_status_success
      if access_code.alert_contact_1
        Notifier.send_lock_access_alert(email_message, "#{lock_desc} - Unlocked", access_code.alert_contact_1.email_address).deliver
      end
      if access_code.alert_contact_2
        Notifier.send_lock_access_alert(email_message, "#{lock_desc} - Unlocked", access_code.alert_contact_2.email_address).deliver
      end
    end
  end

  # Merged in from the lock_events_pull_job
  def self.save_history_record(access_history, lock, user)
    event = LockEventHistory.new
    event.lock_id = lock.id
    event.remote_lock_id = lock.remote_lock_id
    event.user_id = user.id
    event.mac = lock.mac
    event.event_id = access_history['id']
    event.event_type = access_history['type']
    event.event_status = access_history['status']
    event.event_time = access_history['time']

    # If there is information in the data, it
    # represents a code created / deleted on the lock itself
    if !access_history['data'].blank?
      event.event_code = access_history['data']    
      event.event_data = access_history['code']
    else
      event.event_code = access_history['code']    
      event.event_data = access_history['data']
    end
    
    event.event_last_api_call = Time.now
    
    if !access_history['code'].blank?
	    if access_history['code'][-1, 1] == 'a'
	      access_code = access_history['code'][0...-1]
	else
	      access_code = access_history['code']
	end

	if access_history['code'].include?("<")
		  all_possible_codes = self.calculate_permutations(access_history['code'])
	    event.lock_user_name = self.get_user_name_with_array(all_possible_codes, lock.id)
    else
      event.lock_user_name = self.get_user_name(access_code, lock.id)
    end
  end

  event.save

  # Send a notification to a 3rd party if necessary
  ApiPartnerNotificationHelper.send_event_notification(lock, lock.api.lockstate_event_type(event.event_type), event.event_status.to_s == lock.api.event_status_success, access_code, event.event_time)

end


  def self.get_user_name_with_array(history_codes, lock_id)
    username = []
    history_codes.each do |code|
      usernames = AccessCode.select("first_name").where(:access_code => code.gsub(/a/, ''), :lock_id => lock_id)
      usernames.each do |uname|
        username << uname.first_name
      end
    end

    return username.uniq.join(', ')
  end

  # Merged in from the lock_events_pull_job
  def self.get_user_name(history_code, lock_id)
    username = []
    usernames = AccessCode.select("first_name").where(:access_code => history_code.gsub(/a/, ''), :lock_id => lock_id)
    usernames.each do |uname|
      username << uname.first_name
    end
    return username.uniq.join(', ')
  end


  def self.perform #(queue_number)
    #Although from resque_schedule.yml no argument is passing

    puts '---- Inside lock alert job ----'

    users = User.parent_users
    current_time = Time.now
    errors = Array.new

    users.each do |user|
      puts '---- Inside users loop ----'
      user.account.properties.each do |property|
        puts '---- Inside properties loop ----'
        property.locks.each do |lock|
          puts '---- Inside locks loop ----'
          #next unless lock.id.to_s[-1] == queue_number.to_s

          begin
            #puts "Q: #{queue_number} Calling OHS For #{lock.remote_lock_id}"
            puts "Q: Calling OHS For #{lock.remote_lock_id}"
            access_histories, usernames, response_code = lock.api.get_lock_access_histories_for_lock_alert(user, lock, source="lock_alert background job for access history")

            puts "---- What is response code? A. :#{response_code} ----"
            next if access_histories.nil?
            puts '---- After next block ----'
            process_lock_access_histories(user, property, lock, access_histories, usernames)

          rescue
            errors << "Lock ID: #{lock.id} Error: #{$!}"
          end
        end
      end
    end

    unless errors.empty?
      Notifier.application_error("Errors running OHS Lock Alert:\n#{errors.join('\n')}").deliver
    end

  end

  def self.process_lock_access_histories(user, property, lock, access_histories, usernames)

      access_histories.each do |access_history|
        next if access_history.nil?

        self.save_history_record(access_history, lock, user)

        puts "Q. What type of event is that? A. #{access_history['type']}"
        #Operation based on lock history coming from OHS
        response = lock.api.operation_based_on_lock_history(access_history['type'], access_history, user, lock.remote_lock_id, source="lock_alert background job for Lock history")
        
        # The key peice of information is in the data field for any operations coming in from the lock
        lock.operation_on_lock(access_history['type'], access_history['data'], user, lock.remote_lock_id)

        access_time = DateTime.parse(access_history['time'][0...-1])
        access_time = Time.now if !access_time.nil? && (access_time.to_i - Time.now.to_i) > 86400

        # For alerts, we only look for codes ending in a
        next unless !access_history['code'].blank? && access_history['code'][-1, 1] == 'a'
        access_code = access_history['code'][0...-1]

        status = (access_history['status'] || '-1').to_i

        if access_history['code'].include?("<")
          all_possible_codes = self.calculate_permutations(access_history['code'])

          all_possible_codes.each do |code|
            username_list = Array.new
            unless usernames[code.to_i].nil? || usernames[code.to_i].empty?
              usernames[code.to_i].each do |username|
                username_list << username.first_name
              end
            end
          end

        else
          username_list = Array.new
          usernames[access_history['code'].to_i].each do |username|
            username_list << username.first_name
          end
        end
        access_time = access_time.in_time_zone(property.time_zone).strftime("%D %I:%M %p")

        lock_access_infos = AccessCode.where(["lock_id = :lock_id AND access_code = :access_code AND (is_deleted = 0 or type !='Guestcode')", {:lock_id => lock.id, :access_code => access_code}])
        lock_access_infos.each do |lock_access_info|
          if lock_access_info.send_alert
            if lock_access_info.type == "Guestcode"
              if lock_access_info.alert_type == "first_access"
                lock_access_info.update_attributes(:send_alert => false)
                lock_access_info.save!
                self.send_alert(lock, lock_access_info, status, username_list.join(', '), access_time)
              else
                self.send_alert(lock, lock_access_info, status, username_list.join(', '), access_time)
              end
            else
              self.send_alert(lock, lock_access_info, status, username_list.join(', '), access_time)
            end
          end
        end
      end

      # Are there any rules to run for this lock?
      conditions = Condition.enabled.where({:category => 'Lock', :device_id => lock.id}).includes(:rule)
      rules = conditions.uniq { |c| c.rule_id }.collect { |c| c.rule }

      rules.each do |rule|
        rule.execute unless rule.nil?
      end    
  end

  def self.calculate_permutations(code)
    number_of_occurrence = code.scan(/</).count
    length_of_code = code.length

    all_possible_codes = Array.new

    bugged_code = code.to_s
    tmp = code.to_s

    a = [4, 8]

    b = a.repeated_permutation(number_of_occurrence).to_a

    b.each do |x|
      x.each do |y|
        puts y
        bugged_code = bugged_code.sub '<', y.to_s
        puts bugged_code
      end
      all_possible_codes << bugged_code
      bugged_code = tmp
    end

    return all_possible_codes
  end
end
