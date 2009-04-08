#!/usr/bin/env ruby
require 'uri'
require 'open-uri'
require 'rubygems'
require 'json'
require 'active_support'
require 'osx/cocoa'
include OSX
require 'growl'
require 'htmlentities'

class Twitter

  FRIEND_TWEET = :FriendTweet
  SEARCH_TWEET = :SearchTweet
  TWEET = :Tweet
  
  @@cache_path = File.dirname(__FILE__) + '/cache/'
  Dir.mkdir(@@cache_path)  unless File.exist?(@@cache_path)

  def initialize(config)
    @username, @password = config.values_at(:user, :password)
    @searches = config[:searches] || []
    @friends_tweets_url = "#{config[:urls][:twitter]}/statuses/friends_timeline.json"
    @search_tweets_url = "#{config[:urls][:twitter_search]}/search.json?q="
    @user_url = "#{config[:urls][:twitter]}/users/show/"
  end

  def friends_tweets(last_created_at)
    response = request(@friends_tweets_url) { |f| JSON.parse(f.read) }
    return [] if response.empty?
    returning [] do |t|
      response.each do |r|
        created_at = Time.parse(r['created_at'])
        break  if created_at <= last_created_at
        screen_name = r['from_user']
        next   if screen_name == @username
        user_id = r['user']['id']
        t << Tweet.new(:created_at => created_at, :screen_name => r['user']['screen_name'], :text => r['text'], :profile_image_url => r['user']['profile_image_url'], :user_id => user_id, :user => user(user_id), :tweet_type => FRIEND_TWEET)
      end
    end
  end

  def search_tweets(last_created_at)
    returning [] do |t|
      @searches.each do |q|
        u = @search_tweets_url + URI.escape(q, Regexp.new("[^#{URI::PATTERN::UNRESERVED}]"))
        response = request(u) { |f| JSON.parse(f.read) }['results']
        next if response.empty?
        response.each do |r|
          created_at = Time.parse(r['created_at'])
          break  if created_at <= last_created_at
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
        request("#{@user_url}#{id}.json") do |u|
          f.write(u.read)
        end
      end
    end
    open(file) { |f| JSON.parse(f.read) }
  end

  private

  def request(url)
    # puts url
    begin
      open(url, :http_basic_authentication => [ @username, @password ]) do |u|
        yield(u)
      end      
    rescue Exception => e
      # puts e
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

  def plain_text
    HTMLEntities.new.decode(@text)
  end

  attr_accessor :tweet_type, :user, :user_id, :screen_name, :profile_image_url, :created_at

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
  @timer = nil
  
  def initialize
    @config = YAML.load_file(@@config)
    @twitter = Twitter.new @config
    @growler = Growler.new
    @tweets = []
    @last_created_at = @config[:last_created_at] ? Time.parse(@config[:last_created_at]) : 1.year.ago
  end

  def run
    @tweets = (@twitter.friends_tweets(@last_created_at) + @twitter.search_tweets(@last_created_at)).sort
    @last_created_at = @tweets.empty? ? Time.now : @tweets.last.created_at
    save_last_created_at(@last_created_at) 
    @timer = OSX::NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(3.0, self, :growl, nil, true)
  end

  def growl
    if @tweets.empty?
      @timer.invalidate
      if (sleep_time = 10.minutes - (Time.now - @last_created_at)) > 0
        # puts "sleeping for #{sleep_time} seconds"
        OSX::NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(sleep_time.to_i, self, :run, nil, true)       
      else
        run
      end
    else
      t = @tweets.shift
      sticky, priority = sticky?(t) ? [true,1] : [false,0]
      @growler.growl(t.tweet_type, t.screen_name, t.plain_text, t.screen_name, sticky, priority, t.profile_image_url)
    end
  end
  
  private
  def sticky?(tweet)
    keywords = @config[:sticky] || []
    keywords.any? { |k| tweet.plain_text.downcase.include?(k) } || tweet.user['notifications']
  end

  def save_last_created_at(time)
    @config[:last_created_at] = time.strftime("%a %b %d %H:%M:%S %z %Y")
    File.open(@@config, 'w') { |f| f.write(YAML.dump(@config)) }    
  end
end

if $0 == __FILE__
  TwitterGrowl.new.run  
  NSApplication.sharedApplication
  NSApp.run
end