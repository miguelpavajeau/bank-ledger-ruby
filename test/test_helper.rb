# frozen_string_literal: true

ENV["RACK_ENV"] = "test"

require "minitest/autorun"
require "rack/test"
require_relative "../app"

module LedgerHelpers
  def new_service = Ledger::Service.new("sqlite:/") # fresh in-memory database

  def open_account(service, owner, currency = "USD", funds: 0)
    account = service.create_account(owner: owner, currency: currency)
    service.deposit(account[:id], funds) if funds.positive?
    account
  end
end
