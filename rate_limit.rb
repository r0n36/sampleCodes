class RateLimit

  PER_MINUTE_THROTTLE_TIME_WINDOW = 1*60
  PER_MINUTE_THROTTLE_MAX_REQUESTS = 100

  DAILY_THROTTLE_TIME_WINDOW = 60*60*24
  DAILY_THROTTLE_MAX_REQUESTS = 10000

  def initialize(app)
    @app = app
    @@logger ||= Logger.new("#{Rails.root}/log/threshold.log")
  end

  def call(env)
    req_uri      = env['REQUEST_URI']
    client_ip    = env["REMOTE_ADDR"]

    @@logger.info "#{client_ip} #{req_uri}"

    minute_key   = "minute_count:#{client_ip}"
    minute_count = REDIS.get(minute_key)

    day_key   = "day_count:#{client_ip}"
    day_count = REDIS.get(day_key)

    unless minute_count
      REDIS.set(minute_key, 0)
      REDIS.expire(minute_key, PER_MINUTE_THROTTLE_TIME_WINDOW)
    end

    unless day_count
      REDIS.set(day_key, 0)
      REDIS.expire(day_key, DAILY_THROTTLE_TIME_WINDOW)
    end

    if minute_count.to_i >= PER_MINUTE_THROTTLE_MAX_REQUESTS
      [
          429,
          rate_limit_headers(minute_count, minute_key),
          [minute_message]
      ]
    elsif day_count.to_i >= DAILY_THROTTLE_MAX_REQUESTS
      [
          429,
          rate_limit_headers(day_count, day_key),
          [day_message]
      ]
    else
      REDIS.incr(minute_key)
      status, headers, body = @app.call(env)
      [
          status,
          headers.merge(rate_limit_headers(minute_count.to_i + 1, minute_key)),
          body
      ]

      REDIS.incr(day_key)
      status, headers, body = @app.call(env)
      [
          status,
          headers.merge(rate_limit_headers(day_count.to_i + 1, day_key)),
          body
      ]
    end
  end

  private
  def minute_message
    {
      :message => "You have made too many requests within 1 minute. Please keep requests under 100 per minute."
    }.to_json
  end
  def day_message
    {
      :message => "You have made too many requests in a day. Please keep requests under 10,000 per day."
    }.to_json
  end


  def rate_limit_headers(count, key)
    g_count = PER_MINUTE_THROTTLE_MAX_REQUESTS
    g_count = DAILY_THROTTLE_MAX_REQUESTS unless key.include?("minute")

    ttl = REDIS.ttl(key)
    time = Time.now.to_i
    time_till_reset = (time + ttl.to_i).to_s
    {
        "X-Rate-Limit-Limit" =>  g_count.to_s,
        "X-Rate-Limit-Remaining" => (g_count - count.to_i).to_s,
        "X-Rate-Limit-Reset" => time_till_reset
    }
  end
end
