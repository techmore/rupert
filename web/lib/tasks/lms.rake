# frozen_string_literal: true

namespace :lms do
  desc 'Load or update the shipped Learning center courses in every active workspace (safe to re-run)'
  task seed: :environment do
    Tenant.find_each do |tenant|
      courses = Lms::Seeder.sync!(tenant.id)
      puts "#{tenant.id}: #{courses.empty? ? 'up to date' : courses.map(&:slug).join(', ')}"
    end
  end
end
