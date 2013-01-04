require "rubygems"
require "bundler/setup"
require 'twitter/json_stream'

token = ENV['CAMPFIRE_TOKEN'] # your API token
room_id = ENV['CAMPFIRE_ROOM_ID'] # the ID of the room you want to stream

options = {
  :path => "/room/#{room_id}/live.json",
  :host => 'streaming.campfirenow.com',
    :auth => "#{token}:x"
}

EventMachine::run do
  puts "Running and waiting for events to happen..."
  stream = Twitter::JSONStream.connect(options)

  stream.each_item do |item|
    puts item
  end

  stream.on_error do |message|
    puts "ERROR:#{message.inspect}"
  end

  stream.on_max_reconnects do |timeout, retries|
    puts "Tried #{retries} times to connect."
    exit
  end
end
