require 'delayed_job'
require File.join(Rails.root, 'lib/workers/issue_trackers_to_backend_job.rb')

class UpdateIssueTrackersInBackend < ActiveRecord::Migration

  def self.up
    Delayed::Job.enqueue IssueTrackersToBackendJob.new
  end

  def self.down
  end

end

