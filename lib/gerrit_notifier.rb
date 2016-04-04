require 'slack'
class GerritNotifier
  extend Alias

  @@buffer = {}
  @@channel_config = nil
  @@semaphore = Mutex.new

  BR = "\r\n>"

  def self.start!
    @@channel_config = ChannelConfig.new
    start_buffer_daemon
    listen_for_updates
  end

  def self.psa!(msg)
    notify @@channel_config.all_channels, msg
  end

  def self.notify(channels, msg, emoji = '')
    channels.each do |channel|
      slack_channel = "##{channel}"
      add_to_buffer slack_channel, @@channel_config.format_message(channel, msg, emoji)
    end
  end

  def self.notify_user(user, msg)
    channel = "@#{slack_name_for user}"
    add_to_buffer channel, msg
  end

  def self.add_to_buffer(channel, msg)
    @@semaphore.synchronize do
      @@buffer[channel] ||= []
      @@buffer[channel] << msg
    end
  end

  def self.start_buffer_daemon
    # post every X seconds rather than truly in real-time to group messages
    # to conserve slack-log
    Thread.new do
      while true
        @@semaphore.synchronize do
          if @@buffer == {}
            puts "[#{Time.now}] Buffer is empty"
          else
            puts "[#{Time.now}] Current buffer:"
            ap @@buffer
          end

          if @@buffer.size > 0 #&& !ENV['DEVELOPMENT']
            @@buffer.each do |channel, messages|
              messages.each do |message|

                next if ignore? message

                Slack.configure do |config|
                  config.token = slack_config['token']
                end
                Slack.chat_postMessage text:message, username:slack_config['username'], icon_emoji:slack_config['icon_emoji'], channel: channel
                sleep 1
              end
            end
          end

          @@buffer = {}
        end

        sleep 15
      end
    end
  end

  def self.listen_for_updates
    stream = YAML.load(File.read('config/gerrit.yml'))['gerrit']['stream']
    puts "Listening to stream via #{stream}"

    IO.popen(stream).each do |line|
      update = Update.new(line)
      process_update(update)
    end

    puts "Connection to Gerrit server failed, trying to reconnect."
    sleep 3
    listen_for_updates
  end

  def self.process_update(update)
    if ENV['DEVELOPMENT']
      ap update.json
      puts update.raw_json
    end

    channels = @@channel_config.channels_to_notify(update.project, update.owner)

    return if channels.size == 0

    # Patch Set Created
    if update.patchset_created?
      notify channels, "#{slack_config['icon_patchset']} patchset created. #{BR}#{update.commit} #{BR}#{update.patchset}"      
    # Code review +2
    elsif update.code_review_approved?
      notify channels, "#{slack_config['icon_plus']} #{update.author_slack_name} has +2 #{BR}#{update.commit} #{BR}#{update.patchset}"
    # Code review +1
    elsif update.code_review_tentatively_approved?
      notify channels, "#{slack_config['icon_plus']} #{update.author_slack_name} has +1 #{BR}#{update.commit} #{BR}#{update.patchset}"
    # Any minuses (Code/Product/QA)
    elsif update.minus_1ed? || update.minus_2ed?
      verb = update.minus_1ed? ? "-1" : "-2"
      notify channels, "#{slack_config['icon_minus']} #{update.author_slack_name} has #{verb} #{BR}#{update.commit} #{BR}#{update.patchset}"
    # No Score
    elsif update.comment_added? && update.human? && update.approvals.nil? && update.comment == ''
      notify channels, "#{slack_config['icon_noscore']} #{update.author_slack_name} has no score #{BR}#{update.commit} #{BR}#{update.patchset}"
    end

    # New comment added
    if update.comment_added? && update.human? && update.comment != ''
      comment = update.comment.gsub(/(\r\n|\r|\n)/, BR)
      notify channels, "#{slack_config['icon_comment']} #{update.author_slack_name} has left comments on #{BR}#{update.commit} #{BR}#{update.patchset} #{BR}#{comment}"
    end

    # Merged
    if update.merged?
      notify channels, "#{update.commit} was merged! #{slack_config['icon_merge']}"
    end
  end

  def self.slack_config
    @slack_config ||= YAML.load(File.read('config/slack.yml'))['slack']
  end

  def self.ignore?(message)
    ignore_words = slack_config['ignore_words']
    if ignore_words.nil? || ignore_words.empty?
      false
    else
      ignore_words.reduce(false) { |boolean, word|
        boolean || message.include?(word)
      }
    end
  end
end
