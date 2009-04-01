#!/usr/bin/env ruby

require 'uri'
require 'open-uri'
require 'rubygems'
require 'json'
require 'active_support'
require 'osx/cocoa'
include OSX
require 'growl'

class Twitter

  FRIEND_TWEET = :FriendTweet
  SEARCH_TWEET = :SearchTweet
  TWEET = :Tweet
  
  @@cache_path = File.dirname(__FILE__) + '/cache/'
  Dir.mkdir(@@cache_path)  unless File.exist?(@@cache_path)

  @@friends_tweets_url = 'http://twitter.com/statuses/friends_timeline.json'
  @@search_tweets_url = 'http://search.twitter.com/search.json?q='
  @@user_url = 'http://twitter.com/users/show/'

  def initialize(config)
    @username, @password = config.values_at(:user, :password)
    @last_created_at = config[:last_created_at] ? Time.parse(config[:last_created_at]) : 1.year.ago
    @searches = config[:searches] || []
  end
  
  def friends_tweets
    response = request(@@friends_tweets_url) { |f| JSON.parse(f.read) }
    return [] if response.empty?
    returning [] do |t|
      response.each do |r|
        created_at = Time.parse(r['created_at'])
        break  if created_at <= @last_created_at
        screen_name = r['from_user']
        next   if screen_name == @username
        user_id = r['user']['id']
        t << Tweet.new(:created_at => created_at, :screen_name => r['user']['screen_name'], :text => r['text'], :profile_image_url => r['user']['profile_image_url'], :user_id => user_id, :user => user(user_id), :tweet_type => FRIEND_TWEET)
      end
    end
  end

  def search_tweets
    returning [] do |t|
      @searches.each do |q|
        u = @@search_tweets_url + URI.escape(q, Regexp.new("[^#{URI::PATTERN::UNRESERVED}]"))
        response = request(u) { |f| JSON.parse(f.read) }['results']
        next if response.empty?
        response.each do |r|
          created_at = Time.parse(r['created_at'])
          break  if created_at <= @last_created_at
          screen_name = r['from_user']
          next   if screen_name == @username
          t << Tweet.new(:created_at => created_at, :screen_name => screen_name, :text => r['text'], :profile_image_url => r['profile_image_url'], :user_id => nil, :user => user(screen_name), :tweet_type => SEARCH_TWEET)
        end
      end
    end
  end

  def user(id)
    file = "#{@@cache_path}#{id}.json"
    unless File.exists?(file) && !File.zero?(file)
      open(file, 'w') do |f|
        request("#{@@user_url}#{id}.json") do |u|
          f.write(u.read)
        end
      end
    end
    open(file) { |f| JSON.parse(f.read) }
  end

  private

  def request(url)
    puts url
    open(url, :http_basic_authentication => [ @username, @password ]) do |u|
      yield(u)
    end
  end  

end

class Tweet

  def initialize(options)
    @text = options[:text]
    @user_id = options[:user_id]
    @screen_name = options[:screen_name]
    @profile_image_url = options[:profile_image_url]
    @created_at = options[:created_at]
    @user = options[:user]
    @tweet_type = options[:tweet_type]
  end

  attr_accessor :tweet_type, :text, :user, :user_id, :screen_name, :profile_image_url, :created_at

  def <=>(t) 
    return self.created_at <=> t.created_at
  end

end

class Growler
  def initialize
    @notifier = Growl::Notifier.sharedInstance
    @notifier.delegate = self
    @notifier.register('TwitterGrowl', [Twitter::FRIEND_TWEET,Twitter::SEARCH_TWEET], Twitter::TWEET)
  end

  def growl(notification_name, title, description, context, sticky, priority, image_url)
    @notifier.notify(notification_name, title, description, :click_context => context,
      :sticky => sticky, :priority => priority, :icon => image(image_url))
  end

  def growlNotifierClicked_context(sender, context)
    `open #{'http://twitter.com/' + context}`
  end
  
  private
  
  def image(url)
    NSImage.alloc.initByReferencingURL(NSURL.alloc.initWithString(url))
  end
end

class TwitterGrowl
  @@config = File.dirname(__FILE__) + '/config.yml'

  def initialize
    @config = YAML.load_file(@@config)
    @twitter = Twitter.new @config
    @growler = Growler.new
    @tweets = []
  end

  def run
    @tweets = (@twitter.friends_tweets + @twitter.search_tweets).sort

    mark_time(@tweets.last.created_at) unless @tweets.empty?
    
    @timer = OSX::NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(3.0, self, :growl, nil, true)
  end

  def growl
    if @tweets.empty?
      @timer = OSX::NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(15.0, self, :exit, nil, false)
    else
      t = @tweets.shift
      puts 'growl: '  + t.text
      sticky, priority = sticky?(t) ? [true,1] : [false,0]
      @growler.growl(t.tweet_type, t.screen_name, t.text, t.screen_name, sticky, priority, t.profile_image_url)
    end
  end
  
  def exit
    exit!
  end

  private
  def sticky?(tweet)
    keywords = @config[:sticky] || []
    keywords.any? { |k| tweet.text.downcase.include?(k) } || tweet.user['notifications']
  end
  def mark_time(time)
    @config[:last_created_at] = time.strftime("%a %b %d %H:%M:%S %z %Y")
    File.open(@@config, 'w') { |f| f.write(YAML.dump(@config)) }    
  end
end

if $0 == __FILE__
  TwitterGrowl.new.run  
  NSApplication.sharedApplication
  NSApp.run
end