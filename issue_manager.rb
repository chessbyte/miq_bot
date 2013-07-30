#!/usr/bin/env ruby
require 'bundler/setup'
require 'octokit'
require 'yaml'
require 'time'
SLEEPTIME = 5
YAML_FILE = File.join(File.dirname(__FILE__), '/issue_manager.yml')

class IssueManager

  COMMANDS = {
    "add_label"    => :add_labels_to_an_issue,
    "rm_label"     => :remove_labels_from_issue,
    "remove_label" => :remove_labels_from_issue,
    "assign"       => :assign_to_issue,
  }


  def initialize
    @client = Octokit::Client.new(:login => "xxxxxx", :password => "xxxxxx", :auto_traversal => true)
    @timestamps = load_yaml_file
    if !@timestamps
      @timestamps = Hash.new(0)
    end
    @permitted_labels = {}
    load_permitted_labels("MANAGEIQ/sandbox")
  end


  def load_permitted_labels(repo)
    labels = @client.labels(repo)
    labels.each do |label|
      @permitted_labels[label.name] = 0
    end
  end

  def print_issue(issue)
    puts "Title:\t #{issue.title}"
    puts "Body:\t #{issue.body}"
    puts "Number:\t #{issue.number}"
    puts "State:\t #{issue.state}"
  end


  def add_label(issue_id, labels)
    @client.add_labels_to_an_issue("ManageIQ/sandbox", issue_id, labels)
  end

  def remove_label(issue_id, label)
    @client.remove_label("ManageIQ/sandbox", issueID, label)
  end

  def get_issue_comments(issue_id)
    @client.issue_comments("ManageIQ/sandbox", issue_id)
  end

  def find_issue(repository, issue_id)
    @client.issue("ManageIQ/#{repository}", issue_id)
  end

  def print_notification(notification)
    puts "Notification repo: #{notification.repository.name}"
    puts "Notification subject title: #{notification.subject.title}"
    puts "#{notification.subject.url}"
    puts "#{notification.subject.latest_comment_url}"
  end

  def print_comment(comment)
    puts "\tComment body: #{comment.body}"
    puts "\tComment added at: #{comment.updated_at}\n"
  end

  def get_notifications
    notifications = @client.repository_notifications("ManageIQ/sandbox", "all" => false)
    notifications.each do |notification|
      process_notification(notification)
    end
  end

  def extract_comment_id(notification)
    notification.subject.latest_comment_url.match(/[0-9]+\Z/)
  end

  def extract_issue_id(notification)
    notification.subject.url.match(/[0-9]+\Z/)
  end

  def extract_thread_id(notification)
    notification.url.match(/[0-9]+\Z/)
  end

  def make_repo_name(notification)
    "ManageIQ/#{notification.repository.name}"
  end

  def process_notification(notification)
    #print_notification(notification)
    repo        = make_repo_name(notification)
    thread_id   = extract_thread_id(notification)
    issue_id    = extract_issue_id(notification)
    issue       = @client.issue(repo, issue_id)   
    comments    = @client.issue_comments(repo, issue_id)
    comments.each do |comment|
      process_comment(comment, issue, repo) 
    end
    mark_thread_as_read(thread_id)
  end

    # comment: The goal is to find the comments that have not been processed by the BOT. 
    # As each comment is processed it overwrites the entry in the hash @timestamps for this
    # issue ID. Then the hash @timestamps is written to a yaml file.
    # When a new comment is made it will be processed if its timestamp is more recent
    # than the one in the hash/yaml for this issue 

  def process_comment(comment, issue, repo)
    last_comment_timestamp = @timestamps[issue.number] || 0   
    if last_comment_timestamp != 0 && last_comment_timestamp >= comment.updated_at
      return
    end

    # bot command or not, we need to update the yaml file so next time we 
    # pull in the comments we can skip this one.

    add_and_yaml_timestamps(issue.number, comment.updated_at)       

    match = parse_command_value(comment)
    return if !match 
    

    command = match[0].match(/@cfme-bot\s/).post_match
    command.strip!
    command_value = match.post_match

    method_name = COMMANDS[command]
    if method_name.nil?

      # How to distinguish between the a typo in a command that needs reported back
      # to the user and just a regular comment that starts with @cfme-bot...?
      # @client.add_comment(repo, issue.id, "invalid command #{command}, ignoring.")

      return
    else
      self.send(method_name, repo, issue, command_value)
    end
    add_and_yaml_timestamps(issue.number, comment.updated_at)       
  end


  def parse_command_value(comment)
    return comment.body.match(/@cfme-bot\s[@a-z\-\_]+\s/)
  end

  def assign_to_issue(repo, issue, assign_to_user)
    assign_to_user = assign_to_user.delete('@').rstrip
  
    # We cannot rely on rescuing the error Octokit::UnprocessableEntity
    # because assignee names unknown to manageiq might be valid in the 
    # global community, so we just check the company name of each
    # assignee and ignore it if it is not set to redhat.
    
    begin
      user = @client.user(assign_to_user)
    rescue Octokit::NotFound
       add_assignee_comment(repo, issue, assign_to_user)
       return
    end
 
    if user.login.nil? || user.company.nil? 
      add_assignee_comment(repo, issue, assign_to_user)
      return
    end

    if user.company.downcase.delete(' ') != "redhat"
      add_assignee_comment(repo, issue, assign_to_user)
      return
    end
    @client.update_issue(repo, issue.number, issue.title, issue.body, "assignee" => assign_to_user)
  end

def remove_labels_from_issue(repo, issue, command_value)
    message             = "Cannot remove the following label(s) because they are not recognized: "
    invalid_labels_bool = false
    valid_labels        = Array.new
    labels_array        = split(command_value)

    labels_array.each do |label|
      label.rstrip!
      label.lstrip!
      begin
        label = @client.label(repo, label)
      rescue Octokit::NotFound
        message << " " << label << ","
        invalid_labels_bool = true    
        next
      end
      valid_labels.push(label)
    end

    if invalid_labels_bool
      @client.add_comment(repo, issue.number, message.chomp(','))
    end

    valid_labels.each do |valid_label|
      @client.remove_label(repo, issue.number, valid_label.name)  
    end
end



  # def remove_labels_from_issue(repo, issue, command_value)
  #   labels_array = split(command_value)
  #   labels_array.each do |label|
  #     begin
  #       label = @client.label(repo, label).name
  #     rescue Octokit::NotFound
  #       message = "Cannot find label #{label}"
  #       @client.add_comment(repo, issue.number, message)
  #       next
  #     end
  #     @client.remove_label(repo, issue.number, label)
  #   end
  # end

  def add_assignee_comment(repo, issue, assign_to_user)
    message = "Assignee #{assign_to_user} is an invalid user."
    @client.add_comment(repo, issue.number, message)
  end


  def check_user_organization()
    members_array = @client.organization_members("ManageIQ")
      members_array.each do |members_hash|
        members_hash.each do |member|
          puts "HASH: #{member[1]}"
        end
      end
  end

  def add_labels_to_an_issue(repo, issue, command_value)
    message = "Applying the following label(s) is not permitted:"

    new_labels        = split(command_value)
    puts "new labels #{new_labels}"
    new_labels_length = new_labels.length
    allowed_labels    = Array.new

    new_labels.each do |new_label|
      if !@permitted_labels[new_label]
        message << " " << new_label << ","
        next
      else
        allowed_labels.push(new_label)
      end
    end

    if new_labels.length - allowed_labels.length > 0
      @client.add_comment(repo, issue.number, message.chomp(','))
    end

    if !allowed_labels.empty?
      @client.add_labels_to_an_issue(repo, issue.number, allowed_labels)
    end
  end

  def mark_thread_as_read(thread_id)
    @client.mark_thread_as_read(thread_id, "read" => false )

  end


  def split(labels)
    labels.split(", ")
  end

  def add_and_yaml_timestamps(key, updated_at)
    @timestamps[key]=updated_at
    File.open("issue_manager.yml", 'w+') do |f| 
      YAML.dump(@timestamps, f) 
    end
  end

  def load_yaml_file
    begin
      @timestamps = YAML.load_file(YAML_FILE)
    rescue Errno::ENOENT
      puts "#{Time.now} #{YAML_FILE} was missing, recreating it..."
      File.open(YAML_FILE, 'w+')
      retry       
    end 
  end
end
 
issue_manager = IssueManager.new
loop {
  begin
    issue_manager.get_notifications
  rescue =>err
    puts "ERROR: #{err.message} \n #{err.backtrace} \n"
  end
  sleep(SLEEPTIME)
}