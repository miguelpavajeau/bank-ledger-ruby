# frozen_string_literal: true

require "sinatra/base"
require "json"
require_relative "lib/ledger"

# Reads the request body once and keeps it. Rack 3 inputs are not guaranteed to be
# rewindable, and Sinatra consumes form-encoded bodies while building params, which
# is what clients like `curl -d` send even for JSON.
class RawBody
  def initialize(app) = @app = app

  def call(env)
    raw = env["rack.input"]&.read.to_s
    env["ledger.raw_body"] = raw
    env["rack.input"] = StringIO.new(raw)
    @app.call(env)
  end
end

# HTTP/JSON API over Ledger::Service.
class LedgerApp < Sinatra::Base
  use RawBody
  set :show_exceptions, false
  set :raise_errors, false
  set :ledger, nil # injected by config.ru and by the tests

  ERROR_STATUS = {
    Ledger::AccountNotFound => 404,
    Ledger::InvalidAmount => 400,
    Ledger::InvalidAccount => 400,
    Ledger::SameAccount => 400,
    Ledger::InsufficientFunds => 422,
    Ledger::CurrencyMismatch => 422,
    Ledger::IdempotencyConflict => 409
  }.freeze

  before { content_type :json }

  get "/healthz" do
    json(status: "ok")
  end

  post "/accounts" do
    body = payload
    json(ledger.create_account(owner: body["owner"], currency: body["currency"]), 201)
  end

  get "/accounts/:id" do
    json ledger.account(params[:id])
  end

  get "/accounts/:id/transactions" do
    json ledger.transactions(params[:id])
  end

  post "/accounts/:id/deposits" do
    respond_with(*ledger.deposit(params[:id], amount_from(payload), key: idempotency_key))
  end

  post "/accounts/:id/withdrawals" do
    respond_with(*ledger.withdraw(params[:id], amount_from(payload), key: idempotency_key))
  end

  post "/transfers" do
    body = payload
    respond_with(*ledger.transfer(body["from_account"], body["to_account"],
                                  amount_from(body), key: idempotency_key))
  end

  error Ledger::Error do
    err = env["sinatra.error"]
    json({ error: err.message }, ERROR_STATUS.fetch(err.class, 400))
  end

  error JSON::ParserError do
    json({ error: "invalid JSON body" }, 400)
  end

  error do
    err = env["sinatra.error"]
    logger_io = env["rack.errors"] || $stderr
    logger_io.puts("#{err.class}: #{err.message}", *Array(err.backtrace).first(8))
    json({ error: "internal error" }, 500) # never leak internals to clients
  end

  not_found do
    json({ error: "not found" }, 404)
  end

  private

  def ledger = settings.ledger

  def json(data, status_code = 200)
    status status_code
    JSON.generate(data)
  end

  def payload
    raw = env.fetch("ledger.raw_body", "")
    raw.empty? ? {} : JSON.parse(raw).tap { |parsed| raise JSON::ParserError unless parsed.is_a?(Hash) }
  end

  def amount_from(body) = body["amount_minor"]

  def idempotency_key
    key = request.env["HTTP_IDEMPOTENCY_KEY"].to_s
    key.empty? ? nil : key
  end

  def respond_with(transaction, replayed)
    headers "Idempotent-Replayed" => "true" if replayed
    json(transaction, replayed ? 200 : 201)
  end
end
