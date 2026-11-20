# frozen_string_literal: true

require_relative "app"

LedgerApp.set :ledger, Ledger::Service.new(ENV.fetch("LEDGER_DB", "sqlite://ledger.db"))
run LedgerApp
