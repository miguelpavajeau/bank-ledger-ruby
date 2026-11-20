FROM ruby:3.4-slim
WORKDIR /app
ENV BUNDLE_WITHOUT=test LEDGER_DB=sqlite:///data/ledger.db
COPY Gemfile Gemfile.lock ./
RUN bundle install
COPY . .
RUN useradd --create-home app && mkdir /data && chown app /data
USER app
VOLUME /data
EXPOSE 9292
CMD ["bundle", "exec", "rackup", "--host", "0.0.0.0", "--port", "9292"]
