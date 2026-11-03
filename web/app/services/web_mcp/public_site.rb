# frozen_string_literal: true

module WebMcp
  # Public facts about Rupert for AI assistants: the read-only tools the public
  # landing page registers with WebMCP, and /llms.txt and /llms-full.txt. One
  # source, so a price or address changes in one place (a test checks the landing
  # page still shows the same prices).
  #
  # Only public marketing facts belong here: nothing about any store, customer,
  # processor or account. The only contact address is the owner's.
  module PublicSite
    SITE = 'https://rupertpos.com'
    CONTACT_EMAIL = 'sdolbec@rupertpos.com'
    GUIDES = 'https://techmore.github.io/rupert/overview.html'
    ROADMAP = 'https://techmore.github.io/rupert/roadmap.html'

    BUSINESS = {
      name: 'Rupert',
      summary: 'Rupert is a point of sale and back office for shops: ring up sales, keep stock right across stores, ' \
               'close the day and keep the books, in one workspace.',
      audience: 'Independent shops and small multi-store retailers that sell at a counter and online.',
      jobs: [
        { name: 'Sell', detail: 'A register for the counter: search or scan, cash or card tenders, tips and receipts. Counter and online orders land in one list.' },
        { name: 'Stock', detail: 'Inventory by location with how fresh each count is; physical counts, transfers, stock alerts, purchase orders, vendors and bulk recipes.' },
        { name: 'Books', detail: 'Cash flow, statements, sales tax and forecasts; day close and daily reconciliation; general ledger, expenses and bank reconciliation.' },
        { name: 'Team', detail: 'Time clock, timesheets and shifts; leave, PTO and pay runs; team chat and training progress.' }
      ],
      day: ['Open the register and count the drawer.', 'Ring up sales; counter and connected-store sales land in one list.',
            'Each sale moves the stock count; low items are flagged.', 'Close the day: the register is checked against cash and card deposits.',
            'Closed days post to the ledger for the bookkeeper to review and approve.'],
      connections: ['Shopify', 'Square', 'C-Trax', 'SwipeSimple', 'QuickBooks import', 'Google Drive copies'],
      connection_note: 'Each connection is set up and authorized separately inside a workspace; signing in to Rupert never connects anything on its own. ' \
                       'Available features and provider readiness vary.',
      ai: 'Signed-in workspaces include Ask Rupert (an in-app help assistant), an MCP server for AI assistants (bearer token, read-only apart from tasks and feedback) ' \
          'and WebMCP tools in the browser that act only as the signed-in person.',
      links: { home: "#{SITE}/", product_guides: GUIDES, roadmap: ROADMAP, source: 'https://github.com/techmore/rupert' }
    }.freeze

    PRICING = {
      currency: 'USD',
      plans: [
        { name: 'Free account', price: '$0', detail: 'Google sign-in and your own workspace. Connect providers when you are ready; provider credentials and setup may be required.', link: "#{SITE}/start" },
        { name: 'Monthly', price: '$499 per month', detail: 'Recurring subscription billed monthly through Stripe. Taxes may apply.', link: "#{SITE}/billing" },
        { name: 'Referral', price: '$249.50 per month for 12 months', detail: '50% off for the first 12 months with an eligible customer referral code and a 12-month commitment ($2,994 before tax), then $499 per month.', link: "#{SITE}/billing" }
      ],
      notes: ['No card is needed to create an account.', 'Paid checkout is a separate step inside the workspace.']
    }.freeze

    CONTACT = {
      email: CONTACT_EMAIL,
      support_page: 'https://pos.rupertpos.com/support',
      privacy_policy: 'https://pos.rupertpos.com/privacy',
      sign_in: "#{SITE}/login",
      create_account: "#{SITE}/start",
      note: "Email #{CONTACT_EMAIL} for questions, demos and partnerships."
    }.freeze

    DEMO = {
      fastest: 'Create a free account and look around your own workspace: no card needed.',
      create_account: "#{SITE}/start",
      request_by_email: "mailto:#{CONTACT_EMAIL}?subject=#{ERB::Util.url_encode('Rupert demo request')}",
      email: CONTACT_EMAIL,
      what_to_include: ['Your shop and how many stores', 'What you use today (register, online store, timesheets, books)', 'A few times that suit you'],
      note: 'The assistant should give the person this link to send the email themselves; nothing is booked or sent automatically.'
    }.freeze

    TOOLS = [
      { name: 'get_business_info', title: 'About Rupert',
        description: 'What Rupert is, who it is for, what it does (sell, stock, books, team), how a day runs, which systems it connects to, and links to the product guides.',
        result: BUSINESS },
      { name: 'get_pricing', title: 'Rupert pricing',
        description: 'Rupert plans and prices in USD: free account, monthly subscription and the referral discount, with sign-up links.',
        result: PRICING },
      { name: 'get_contact', title: 'Contact Rupert',
        description: 'How to reach the Rupert team (email), plus the support, privacy, sign-in and create-account pages.',
        result: CONTACT },
      { name: 'request_demo_link', title: 'Get a demo of Rupert',
        description: 'How to see Rupert: a free-account link, and a ready-made email link to request a demo. Read-only: it returns links for the person to open; nothing is sent or booked.',
        result: DEMO }
    ].freeze

    module_function

    # What the landing page embeds for lib/webmcp.js. Static results: nothing is fetched or sent.
    def manifest
      {
        mode: 'public',
        tools: TOOLS.map do |tool|
          tool.slice(:name, :title, :description).merge(
            inputSchema: { type: 'object', properties: {}, additionalProperties: false },
            annotations: { readOnlyHint: true, consequentialHint: false, untrustedContentHint: false },
            result: tool[:result]
          )
        end
      }
    end

    # https://llmstxt.org — a short Markdown map of the public site.
    def llms_txt
      <<~MD
        # Rupert

        > #{BUSINESS[:summary]} Free to start; $499/month subscription. Contact: #{CONTACT_EMAIL}.

        Rupert is built for #{BUSINESS[:audience].sub(/\A./, &:downcase).delete_suffix('.')}. #{BUSINESS[:connection_note]}

        ## Product

        - [Home](#{SITE}/): what Rupert does, how a day runs, pricing and FAQ
        - [Product guides](#{GUIDES}): feature overview, operator and developer guides
        - [Roadmap](#{ROADMAP}): implemented, partial and planned features

        ## Get started

        - [Create a free account](#{SITE}/start): Google sign-in, no card needed
        - [Sign in](#{SITE}/login)
        - [Request a demo](#{DEMO[:request_by_email]}): email #{CONTACT_EMAIL}

        ## Support and policies

        - [Support](#{CONTACT[:support_page]})
        - [Privacy policy](#{CONTACT[:privacy_policy]})

        ## For AI assistants

        - The home page registers read-only WebMCP tools (`document.modelContext`): #{TOOLS.map { |tool| "`#{tool[:name]}`" }.join(', ')}.
        - Signed-in workspaces register tools that act only as the signed-in person; any change needs their on-screen confirmation.
        - [Full text for AI assistants](#{SITE}/llms-full.txt)

        ## Optional

        - [Source code](https://github.com/techmore/rupert)
      MD
    end

    # The same facts written out in full, for assistants that want one document.
    def llms_full_txt
      jobs = BUSINESS[:jobs].map { |job| "- **#{job[:name]}**: #{job[:detail]}" }.join("\n")
      day = BUSINESS[:day].each_with_index.map { |step, index| "#{index + 1}. #{step}" }.join("\n")
      plans = PRICING[:plans].map { |plan| "- **#{plan[:name]}** — #{plan[:price]}. #{plan[:detail]} #{plan[:link]}" }.join("\n")
      tools = TOOLS.map { |tool| "- `#{tool[:name]}` — #{tool[:description]}" }.join("\n")
      <<~MD
        #{llms_txt.strip}

        ---

        # Rupert in full

        #{BUSINESS[:summary]}

        Who it is for: #{BUSINESS[:audience]}

        ## What it does

        #{jobs}

        ## How a day runs

        #{day}

        ## Connections

        #{BUSINESS[:connections].join(', ')}. #{BUSINESS[:connection_note]}

        ## AI features

        #{BUSINESS[:ai]}

        ## Pricing (#{PRICING[:currency]})

        #{plans}

        #{PRICING[:notes].join(' ')}

        ## Contact and demos

        - Email: #{CONTACT_EMAIL}
        - Demo: #{DEMO[:fastest]} Or email #{CONTACT_EMAIL} with the subject "Rupert demo request" and include: #{DEMO[:what_to_include].join('; ').downcase}.
        - Support: #{CONTACT[:support_page]}
        - Privacy: #{CONTACT[:privacy_policy]}

        ## WebMCP tools on the public site

        #{tools}
      MD
    end
  end
end
