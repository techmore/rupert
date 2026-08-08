FROM ruby:3.2-alpine

RUN apk add --no-cache build-base sqlite-dev git openssl-dev

ENV RAILS_ENV=production \
    RAILS_LOG_TO_STDOUT=1 \
    RAILS_SERVE_STATIC_FILES=1 \
    SECRET_KEY_BASE=build-time-only

WORKDIR /app

COPY web/Gemfile web/Gemfile.lock ./
RUN bundle install --jobs 4 --retry 3

COPY web .
RUN bin/rails tailwindcss:build && bin/rails assets:precompile

COPY entrypoint.sh /usr/bin/
RUN chmod +x /usr/bin/entrypoint.sh

EXPOSE 3000

ENTRYPOINT ["entrypoint.sh"]

CMD ["bin/rails", "server", "-b", "0.0.0.0"]
