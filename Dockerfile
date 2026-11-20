# Build stage: the full image has the compiler that native gems (bigdecimal) need.
FROM ruby:3.4 AS build
WORKDIR /app
ENV BUNDLE_WITHOUT=test
COPY Gemfile Gemfile.lock ./
RUN bundle install

# Runtime stage: slim image with only the installed gems and the app.
FROM ruby:3.4-slim
WORKDIR /app
ENV BUNDLE_WITHOUT=test LEDGER_DB=sqlite:///data/ledger.db
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY . .
RUN useradd --create-home app && mkdir /data && chown app /data
USER app
VOLUME /data
EXPOSE 9292
CMD ["bundle", "exec", "rackup", "--host", "0.0.0.0", "--port", "9292"]
