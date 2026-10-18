# frozen_string_literal: true

# Public opt-out. The signed token names the tenant and customer; no login.
class EmailUnsubscribesController < ApplicationController
  layout false
  skip_before_action :require_login
  skip_before_action :load_last_sync
  skip_forgery_protection only: :create # RFC 8058 one-click posts come from mail providers

  def show
    @token = params[:token]
    head(:not_found) unless Marketing::EmailUnsubscribe.read(@token)
  end

  def create
    data = Marketing::EmailUnsubscribe.read(params[:token])
    return head(:not_found) unless data

    Marketing::EmailUnsubscribe.apply!(data)
    render :done
  end
end
