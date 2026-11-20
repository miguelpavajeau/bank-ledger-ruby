# frozen_string_literal: true

require_relative "test_helper"

class ApiTest < Minitest::Test
  include Rack::Test::Methods
  include LedgerHelpers

  def app = LedgerApp

  def setup
    LedgerApp.set :ledger, new_service
  end

  def post_json(path, body, headers = {})
    headers.each { |name, value| header(name, value) }
    post path, JSON.generate(body), "CONTENT_TYPE" => "application/json"
  end

  def parsed = JSON.parse(last_response.body)

  def new_account(owner)
    post_json "/accounts", { owner: owner, currency: "USD" }
    assert_equal 201, last_response.status
    parsed["id"]
  end

  def test_health
    get "/healthz"
    assert_equal 200, last_response.status
  end

  def test_deposit_then_transfer
    ana = new_account("ana")
    beto = new_account("beto")

    post_json "/accounts/#{ana}/deposits", { amount_minor: 1_000 }
    assert_equal 201, last_response.status
    post_json "/transfers", { from_account: ana, to_account: beto, amount_minor: 300 }
    assert_equal 201, last_response.status

    get "/accounts/#{beto}"
    assert_equal 300, parsed["balance_minor"]
  end

  def test_error_mapping
    ana = new_account("ana")
    beto = new_account("beto")

    post_json "/transfers", { from_account: ana, to_account: beto, amount_minor: 5 }
    assert_equal 422, last_response.status

    post_json "/accounts/#{ana}/deposits", { amount_minor: 0 }
    assert_equal 400, last_response.status

    post_json "/accounts/nope/deposits", { amount_minor: 5 }
    assert_equal 404, last_response.status

    post "/accounts", "{not json", "CONTENT_TYPE" => "application/json"
    assert_equal 400, last_response.status
  end

  def test_idempotent_deposit
    ana = new_account("ana")
    path = "/accounts/#{ana}/deposits"

    post_json path, { amount_minor: 700 }, "Idempotency-Key" => "k1"
    assert_equal 201, last_response.status
    post_json path, { amount_minor: 700 }, "Idempotency-Key" => "k1"
    assert_equal 200, last_response.status
    assert_equal "true", last_response.headers["Idempotent-Replayed"]
    post_json path, { amount_minor: 701 }, "Idempotency-Key" => "k1"
    assert_equal 409, last_response.status

    get "/accounts/#{ana}"
    assert_equal 700, parsed["balance_minor"]
  end
end
