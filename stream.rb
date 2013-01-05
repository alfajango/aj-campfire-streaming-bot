# Show output in foreman logs immediately
$stdout.sync = true

require "rubygems"
require "bundler/setup"
require 'twitter/json_stream'
require 'twilio-ruby'
require 'json'
require 'tinder'

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

def users
  # Don't memoize value, each call should ping Campfire REST API
  room.users
end

def sms_message(user, room)
  "BOT: #{user["name"]} entered campfire room: \"#{room.name}\". Go say something nice."
end

def send_sms(user, room)
  # Send SMS to all users except ones already in Campfire room
  all_users.reject{ |name, number| users.any?{ |u| u["name"] == name } }.each do |name, number|
    puts "Sending sms to: #{name}"
    puts sms_message(user, room)
    @twilio.account.sms.messages.create(
      :from => ENV['SMS_SENDER'],
      :to => number,
      :body => sms_message(user, room)
    )
  end
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
    if item["type"] == "EnterMessage"
      user = users.find{ |u| u["id"] == item["user_id"] }
      send_sms(user, room)
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
    users
  end
end
