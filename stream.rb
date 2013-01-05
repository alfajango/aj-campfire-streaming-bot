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

end

def room
  @room ||= @campfire.find_room_by_id(ENV['CAMPFIRE_ROOM_ID'])
end

def users
  # Don't memoize value, each call should ping Campfire REST API
  room.users
end

def send_sms(message)
  @twilio.account.sms.messages.create(
    :from => ENV['SMS_SENDER'],
    :to => ENV['SMS_RECIPIENT'],
    :body => message
  )
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
      puts "Sending sms"
      user = users.find{ |u| u["id"] == item["user_id"] }
      send_sms("#{user["name"]} entered campfire room #{room.name}.")
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
