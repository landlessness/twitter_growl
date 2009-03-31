#!/usr/bin/env ruby

require 'uri'
require 'open-uri'
require 'rubygems'
require 'json'
require 'active_support'

class Tweet
  def initialize(options)
    @text = options[:text]
    @user_id = options[:user_id]
    @screen_name = options[:screen_name]
    @profile_image_url = options[:profile_image_url]
    @created_at = options[:created_at]
  end
  attr_accessor :text, :user_id, :screen_name, :profile_image_url, :created_at
  def <=>(t) 
    return self.created_at <=> t.created_at
  end
end

class TwitterGrowl
  @@friends_tweets_url = 'http://twitter.com/statuses/friends_timeline.json'
  @@search_tweets_url = 'http://search.twitter.com/search.json?q='
  @@config = File.dirname(__FILE__) + '/config.yml'
  @@cache_path = File.dirname(__FILE__) + '/cache/'

  def initialize
    @config = YAML.load_file(@@config)
    Dir.mkdir(@@cache_path)  unless File.exist?(@@cache_path)
  end

  # TODO use since= param
  def url
    if since = @config[:last_created_at]
      @@url + '?since=' + URI.encode(since)
    else
      @@url
    end
  end

  def image(url)
    returning(@@cache_path + url.gsub(/[\W]+/, '_')) do |file|
      open(file, 'w') do |f|
        open(url) do |h|
          f.write(h.read)
        end
      end  unless File.exists?(file)
    end
  end

  def user(tweet)
    # HACK: the current search api does not return an accurate user id
    # so using screen name in those cases
    # cf. http://code.google.com/p/twitter-api/issues/detail?id=214
    user_id = tweet.user_id.nil? ? tweet.screen_name : tweet.user_id
    file = "#{@@cache_path}#{user_id}.json"
    unless File.exists?(file) && !File.zero?(file)
      open(file, 'w') do |f|
        request("http://twitter.com/users/show/#{user_id}.json") do |u|
          f.write(u.read)
        end
      end
    end

    open(file) { |f| JSON.parse(f.read) }
  end

  def growl(tweet)
    options = "--image #{image(tweet.profile_image_url)}"
    options += " --sticky"  if sticky?(tweet)
    open("|growlnotify #{options} #{tweet.screen_name} 2>/dev/null", 'w') do |g|
      g.write(tweet.text)
    end
  end

  def friends_tweets
    response = request(@@friends_tweets_url) { |f| JSON.parse(f.read) }
    last_created_at = Time.parse(@config[:last_created_at] || response.last['created_at'])
    returning [] do |t|
      response.each do |r|
        created_at = Time.parse(r['created_at'])
        break  if created_at <= last_created_at
        screen_name = r['from_user']
        next   if screen_name == @config[:user]
        t << Tweet.new(:created_at => created_at, :screen_name => r['user']['screen_name'], :text => r['text'], :profile_image_url => r['user']['profile_image_url'], :user_id => r['user']['id'])
      end
    end
  end

  def search_tweets
    returning [] do |t|
      @config[:searches].each do |q|
        u = @@search_tweets_url + URI.escape(q, Regexp.new("[^#{URI::PATTERN::UNRESERVED}]"))
        response = request(u) { |f| JSON.parse(f.read) }['results']
        last_created_at = Time.parse(@config[:last_created_at] || response.last['created_at'])
        response.each do |r|
          created_at = Time.parse(r['created_at'])
          break  if created_at <= last_created_at
          screen_name = r['from_user']
          next   if screen_name == @config[:user]
          t << Tweet.new(:created_at => created_at, :screen_name => screen_name, :text => r['text'], :profile_image_url => r['profile_image_url'], :user_id => nil)
        end
      end
    end
  end

  def run
    tweets = (friends_tweets + search_tweets).sort

    @config[:last_created_at] = tweets.last.created_at.strftime("%a %b %d %H:%M:%S %z %Y")
    File.open(@@config, 'w') { |f| f.write(YAML.dump(@config)) }

    tweets.each do |t|
      growl(t)
    end
  end

  private
    def request(url)
      user, password = @config.values_at(:user, :password)
      puts 'url ' + url
      open(url, :http_basic_authentication => [ user, password ]) do |u|
        yield(u)
      end
    end

    def sticky?(tweet)
      keywords = @config[:sticky] || []
      keywords.any? { |k| tweet.text.include?(k) } ||
        user(tweet)['notifications']
    end
end

TwitterGrowl.new.run  if $0 == __FILE__
