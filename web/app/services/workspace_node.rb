# frozen_string_literal: true

require 'net/http'
require 'json'

class WorkspaceNode
  def self.isolated?
    ENV['RUPERT_NODE_MODE'] == 'workspace'
  end

  def self.provisioning?
    !isolated? && ENV['RUPERT_PROVISION_WORKSPACES'] == 'true'
  end

  def self.control_origin
    value = ENV.fetch('RUPERT_CONTROL_PLANE_ORIGIN', '').to_s
    raise RupertBilling::Error, 'The workspace control plane is not configured.' unless value.match?(%r{\Ahttps://[a-z0-9.-]+\z}i)
    value
  end

  def self.exchange(code)
    control_request('exchange', { 'code' => code })
  end

  def self.check_support(grant_id, user_id, resource)
    control_request('support', { 'grant_id' => grant_id, 'user_id' => user_id, 'resource' => resource })
  end

  ENTITLEMENT_CACHE_KEY = 'rupert:workspace-entitlement'
  ENTITLEMENT_OPEN = { 'state' => 'exempt', 'access' => 'full' }.freeze

  # What the control plane says this workspace's subscription allows (SelfService, off by default).
  # Asked at most once every five minutes. It fails open: when the control plane cannot be reached,
  # has the switch off, or has never answered, the last answer inside a week is used, and with no
  # answer at all the workspace has full access. An outage never locks a workspace.
  def self.entitlement
    fresh = Rails.cache.read("#{ENTITLEMENT_CACHE_KEY}:fresh")
    return fresh if fresh

    answer = begin
      control_request('entitlement', {})
    rescue RupertBilling::Error
      nil
    end
    if answer.is_a?(Hash) && answer['access'].present?
      Rails.cache.write("#{ENTITLEMENT_CACHE_KEY}:last", answer, expires_in: 7.days)
    else
      answer = Rails.cache.read("#{ENTITLEMENT_CACHE_KEY}:last") || ENTITLEMENT_OPEN
    end
    Rails.cache.write("#{ENTITLEMENT_CACHE_KEY}:fresh", answer, expires_in: 5.minutes)
    answer
  end

  def self.control_request(action, fields)
    uri = URI("#{control_origin}/internal/workspaces/#{ENV.fetch('RUPERT_WORKSPACE_ID')}/#{action}")
    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = "Bearer #{ENV.fetch('RUPERT_INSTANCE_SECRET')}"
    request['Content-Type'] = 'application/json'
    request.body = JSON.generate(fields)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 8) { |http| http.request(request) }
    raise RupertBilling::Error, 'Workspace sign-in or support authorization could not be verified.' unless response.is_a?(Net::HTTPSuccess)
    JSON.parse(response.body)
  rescue Timeout::Error, SocketError, IOError, JSON::ParserError, SystemCallError
    raise RupertBilling::Error, 'The control plane is temporarily unavailable.'
  end
end
