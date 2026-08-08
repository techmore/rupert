# frozen_string_literal: true

class HomeController < ApplicationController
  def index
    return redirect_to onboarding_path unless OnboardingController.configured?

    render "home/index"
  end
end
