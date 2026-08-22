# frozen_string_literal: true

# Pagy config — lightweight pagination for index pages.
require 'pagy'
require 'pagy/extras/overflow'

Pagy::DEFAULT[:items] = 25
Pagy::DEFAULT[:overflow] = :last_page
