require "rubygems"
require "bundler/setup"
require 'twitter/json_stream'
require 'twilio-ruby'
require 'json'
require 'tinder'

# Campfire config
token = ENV['CAMPFIRE_TOKEN'] # your API token
@room_id = ENV['CAMPFIRE_ROOM_ID'].to_i # the ID of the room you want to stream
subdomain = ENV['CAMPFIRE_SUBDOMAIN']

@campfire = Tinder::Campfire.new subdomain, :token => token

# Twilio config
account_sid = ENV['TWILIO_ACCOUNT_SID']
auth_token = ENV['TWILIO_ACCOUNT_TOKEN']

@sms_recipient = ENV['SMS_RECIPIENT'] # e.g. '+16105557069'
@sms_sender = ENV['SMS_SENDER'] # e.g. '+14159341234'

# set up a client to talk to the Twilio REST API
@client = Twilio::REST::Client.new account_sid, auth_token

def send_sms(message)
  @client.account.sms.messages.create(
    :from => @sms_sender,
    :to => @sms_recipient,
    :body => message
  )
end

def room
  @room ||= @campfire.find_room_by_id(@room_id)
end

def users
  room.users
end

room.join

options = {
  :path => "/room/#{@room_id}/live.json",
  :host => 'streaming.campfirenow.com',
    :auth => "#{token}:x"
}

EventMachine::run do
  puts "Running and waiting for events to happen..."
  stream = Twitter::JSONStream.connect(options)

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
end
