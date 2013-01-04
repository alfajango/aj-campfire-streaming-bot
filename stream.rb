require "rubygems"
require "bundler/setup"
require 'twitter/json_stream'
require 'twilio-ruby'
require 'json'

# Campfire config
token = ENV['CAMPFIRE_TOKEN'] # your API token
room_id = ENV['CAMPFIRE_ROOM_ID'] # the ID of the room you want to stream

# Twilio config
account_sid = ENV['TWILIO_ACCOUNT_SID']
auth_token = ENV['TWILIO_ACCOUNT_TOKEN']

@sms_recipient = ENV['SMS_RECIPIENT'] # e.g. '+16105557069'
@sms_sender = ENV['SMS_SENDER'] # e.g. '+14159341234'

# set up a client to talk to the Twilio REST API
@client = Twilio::REST::Client.new account_sid, auth_token

options = {
  :path => "/room/#{room_id}/live.json",
  :host => 'streaming.campfirenow.com',
    :auth => "#{token}:x"
}

def send_sms(message)
  @client.account.sms.messages.create(
    :from => @sms_sender,
    :to => @sms_recipient,
    :body => message
  )
end

EventMachine::run do
  puts "Running and waiting for events to happen..."
  stream = Twitter::JSONStream.connect(options)

  stream.each_item do |item|
    item = JSON.parse(item)
    puts item
    if item["type"] == "EnterMessage"
      puts "Sending sms"
      send_sms("#{item["user_id"]} entered campfire room #{item["room_id"]}.")
    else
      puts "False alarm"
    end
  end

  stream.on_error do |message|
    puts "ERROR:#{message.inspect}"
  end

  stream.on_max_reconnects do |timeout, retries|
    puts "Tried #{retries} times to connect."
    exit
  end
end
