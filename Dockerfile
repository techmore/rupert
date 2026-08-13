FROM ruby:4.0.6-alpine

RUN apk add --no-cache build-base postgresql-dev git openssl-dev

ENV RAILS_ENV=production \
    RAILS_LOG_TO_STDOUT=1 \
    RAILS_SERVE_STATIC_FILES=1

WORKDIR /app

COPY web/Gemfile web/Gemfile.lock ./
RUN bundle install --jobs 4 --retry 3

COPY web .

# Precompile with a throwaway secret; the real SECRET_KEY_BASE comes from the
# runtime .env. Nothing is baked into the image.
RUN SECRET_KEY_BASE=build-time-only bin/rails tailwindcss:build \
    && SECRET_KEY_BASE=build-time-only bin/rails assets:precompile

COPY entrypoint.sh /usr/bin/
RUN chmod +x /usr/bin/entrypoint.sh

# Run as a non-root user so a compromise of the app can't root the container
# or the mounted storage volume.
RUN addgroup -S app && adduser -S app -G app \
    && chown -R app:app /app /usr/bin/entrypoint.sh

USER app

EXPOSE 3000

ENTRYPOINT ["entrypoint.sh"]

CMD ["bin/rails", "server", "-b", "0.0.0.0"]
