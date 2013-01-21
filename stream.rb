# Show output in foreman logs immediately
$stdout.sync = true

require "rubygems"
require "bundler/setup"
require 'twitter/json_stream'
require 'twilio-ruby'
require 'json'
require 'tinder'
require 'redis'
require 'time'
require 'timeout'

TIME_START = 8 # hour; as in, 8:00, i.e. 8am
TIME_STOP = 21 # hour; as in, 21:00, i.e. 9pm
NOTIFY_USERS_UP_TO = 3 # Campfire Bot is 1, so 3 means notify until after 2 users in room
ISSUE_TRACKER_URL = ENV['ISSUE_TRACKER_URL'] # e.g. "https://github.com/alfajango/some-repo/issues/%s", where "%s" will be replaced with issue ticket number
BOT_USER_ID = ENV['BOT_USER_ID'] # Used to prevent bot from triggering itself when speaking in campfire room
CAMPFIRE_MESSAGE_PATTERNS = [ /#(\d+)/m, /\Aruby run: (.+)\Z/m ] # Message patterns from campfire for which to take action

if ENV['REDISTOGO_URL']
  uri = URI.parse(ENV["REDISTOGO_URL"])
  @redis = Redis.new(:host => uri.host, :port => uri.port, :password => uri.password)
else
  @redis = Redis.new
end

# Set up campfire client to communicate with Campfire REST API
@campfire = Tinder::Campfire.new ENV['CAMPFIRE_SUBDOMAIN'], :token => ENV['CAMPFIRE_TOKEN']

# Set up a client to talk to the Twilio REST API
@twilio = Twilio::REST::Client.new ENV['TWILIO_ACCOUNT_SID'], ENV['TWILIO_ACCOUNT_TOKEN']

def all_users
  # Populate all_users hash from config vars
  @all_users ||= Hash.new.tap do |h|
    10.times do |i|
      name = ENV["USER_#{i}_NAME"]
      h[name] = ENV["USER_#{i}_NUMBER"] if name
    end
  end
end
puts "ALL USERS: #{all_users}"

def room
  @room ||= @campfire.find_room_by_id(ENV['CAMPFIRE_ROOM_ID'])
end

def room_users
  # Don't memoize value, each call should ping Campfire REST API
  @room_users = room.users
end

def memoized_room_users
  @room_users ||= room_users
end

def sms_message(user, room)
  case memoized_room_users.size
  # Campfire Bot is 1, so 2 means there is 1 actual user in the room
  when 2
    "BOT: #{user["name"]} entered campfire room: \"#{room.name}\". It's lonely in there."
  when 3
    "BOT: #{user["name"]} entered campfire room: \"#{room.name}\". Now it's a party. I'll be quiet now."
  else
    "BOT: #{user["name"]} entered campfire room: \"#{room.name}\"."
  end
end

def send_sms(user, room)
  # Send SMS to all users except ones already in Campfire room
  all_users.reject{ |name, number| memoized_room_users.any?{ |u| u["name"] == name } }.each do |name, number|
    puts "Sending sms to: #{name}"
    puts sms_message(user, room)
    @twilio.account.sms.messages.create(
      :from => ENV['SMS_SENDER'],
      :to => number,
      :body => sms_message(user, room)
    )
  end
end

def send_sms_for_event?(item)
  item["type"] == "EnterMessage" && Time.now.hour.between?(TIME_START, TIME_STOP) && !repeat_event(item) && memoized_room_users.size <= NOTIFY_USERS_UP_TO
end

def run_ruby_code!(code_string)
  puts "evaluating ruby code"
  begin
    Timeout.timeout(10) do
      if %w(run_ruby_code! speak send_sms File).any? { |s| code_string.include?(s) }
        raise "Disallowed method"
      end
      eval(code_string).to_s
    end
  rescue Timeout::Error
    "!!-- Code eval not finished in time, killing it with the vengeance of 1000 Erinyes. --!!}"
  rescue LoadError => e
    "!!-- Code eval error: \"#{e}\" --!!"
  rescue => e
    "!!-- Code eval error: \"#{e}\" --!!"
  end
end

def speak_messages(item)
  # Issue tracker auto-link: match e.g. "#795"
  item["body"].scan(CAMPFIRE_MESSAGE_PATTERNS[0]).inject(Array.new) do |array, match|
    array << "##{match[0]}: " + ISSUE_TRACKER_URL % match[0]
  end

  # Ruby runtime: match e.g. "ruby run: Time.now"
  item["body"].scan(CAMPFIRE_MESSAGE_PATTERNS[1]).inject(Array.new) do |array, match|
    array << "#=> " + run_ruby_code!(match[0])
  end
end

def speak(item)
  speak_messages(item).each do |msg|
    puts "speaking: #{msg}"
    room.speak(msg)
  end
end

def item_matches_pattern?(item)
  CAMPFIRE_MESSAGE_PATTERNS.any? { |p| item["body"].match(p) }
end

def speak_for_event?(item)
  item["type"] == "TextMessage" && item["user_id"].to_i != BOT_USER_ID.to_i && item_matches_pattern?(item)
end

def store_event(item, options={})
  puts "storing event"
  @redis.set item["room_id"], options.merge({:occurred_at => Time.now, :event_type => item["type"], :user => item["user_id"], :users_in_room => memoized_room_users}).to_json
end

def last_event(room_id)
  last = @redis.get(room_id)
  last && JSON.parse(last)
end

def repeat_event(item)
  last = last_event(item["room_id"])
  last && last["event_type"] == item["type"] && last["user"] == item["user_id"] && (Time.now - Time.parse(last["occurred_at"])) < (60 * 60 * 2) # Within 2 hours
end

puts "Joining room"
room.join

campfire_stream_options = {
  :path => "/room/#{ENV['CAMPFIRE_ROOM_ID']}/live.json",
  :host => 'streaming.campfirenow.com',
    :auth => "#{ENV['CAMPFIRE_TOKEN']}:x"
}

EventMachine::run do
  puts "Running and waiting for events to happen..."
  stream = Twitter::JSONStream.connect(campfire_stream_options)

  stream.each_item do |item|
    item = JSON.parse(item)
    puts item
    room_users # update memoized_room_users

    if send_sms_for_event?(item)
      user = memoized_room_users.find{ |u| u["id"] == item["user_id"] }
      store_event(item)
      send_sms(user, room)
    end

    if speak_for_event?(item)
      speak(item)
    end
  end

  stream.on_error do |message|
    puts "ERROR:#{message.inspect}"
  end

  stream.on_max_reconnects do |timeout, retries|
    puts "Tried #{retries} times to connect."
    exit
  end

  timer = EventMachine::PeriodicTimer.new(60*30) do
    puts "Keeping alive - #{Time.now}"
    # Ping campfire for users to keep connection alive
    # See: https://groups.google.com/forum/#!topic/37signals-api/IDH-8yzkU-0
    room_users
  end
end
