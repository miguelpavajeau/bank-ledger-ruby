# frozen_string_literal: true

require "sequel"
require "securerandom"
require "digest"
require "time"

# A small double-entry bank ledger on SQLite.
#
# Money is an Integer in minor units (cents), never a Float. Every operation
# runs inside one SQL transaction, so a failed transfer changes nothing.
module Ledger
  class Error < StandardError; end

  class InvalidAmount < Error
    def initialize(msg = "amount must be an integer greater than zero") = super
  end

  class InvalidAccount < Error
    def initialize(msg = "owner and a 3-letter currency are required") = super
  end

  class AccountNotFound < Error
    def initialize(msg = "account not found") = super
  end

  class InsufficientFunds < Error
    def initialize(msg = "insufficient funds") = super
  end

  class CurrencyMismatch < Error
    def initialize(msg = "accounts have different currencies") = super
  end

  class SameAccount < Error
    def initialize(msg = "source and destination accounts must differ") = super
  end

  class IdempotencyConflict < Error
    def initialize(msg = "idempotency key was already used with a different request") = super
  end

  SCHEMA = [
    <<~SQL,
      CREATE TABLE IF NOT EXISTS accounts (
        id         TEXT PRIMARY KEY,
        owner      TEXT NOT NULL,
        currency   TEXT NOT NULL,
        balance    INTEGER NOT NULL DEFAULT 0 CHECK (balance >= 0),
        created_at TEXT NOT NULL
      )
    SQL
    <<~SQL,
      CREATE TABLE IF NOT EXISTS transactions (
        id              TEXT PRIMARY KEY,
        type            TEXT NOT NULL CHECK (type IN ('deposit','withdrawal','transfer')),
        idempotency_key TEXT UNIQUE,
        request_hash    TEXT NOT NULL,
        from_account    TEXT REFERENCES accounts(id),
        to_account      TEXT REFERENCES accounts(id),
        amount          INTEGER NOT NULL CHECK (amount > 0),
        currency        TEXT NOT NULL,
        created_at      TEXT NOT NULL
      )
    SQL
    <<~SQL,
      CREATE TABLE IF NOT EXISTS entries (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        transaction_id TEXT NOT NULL REFERENCES transactions(id),
        account_id     TEXT NOT NULL REFERENCES accounts(id),
        amount         INTEGER NOT NULL
      )
    SQL
    "CREATE INDEX IF NOT EXISTS idx_entries_account ON entries(account_id)"
  ].freeze

  class Service
    # url examples: "sqlite://ledger.db" or "sqlite:/" for in-memory (tests)
    def initialize(url = "sqlite://ledger.db")
      # One connection serialises writers: the simplest correct model for SQLite.
      @db = Sequel.connect(url, max_connections: 1)
      SCHEMA.each { |statement| @db.run(statement) }
    end

    def close = @db.disconnect

    def create_account(owner:, currency:)
      owner = owner.to_s.strip
      currency = currency.to_s.strip.upcase
      raise InvalidAccount if owner.empty? || currency.length != 3

      row = { id: SecureRandom.hex(12), owner: owner, currency: currency,
              balance: 0, created_at: Time.now.utc.iso8601(6) }
      @db[:accounts].insert(row)
      present_account(row)
    end

    def account(id)
      row = @db[:accounts].where(id: id.to_s).first
      raise AccountNotFound unless row

      present_account(row)
    end

    def transactions(account_id)
      account(account_id) # raises AccountNotFound for unknown ids
      ids = @db[:entries].where(account_id: account_id).select(:transaction_id)
      @db[:transactions].where(id: ids).reverse_order(:created_at, Sequel.lit("rowid")).limit(100).map do |row|
        present_transaction(row)
      end
    end

    # Each money operation returns [transaction, replayed]. A non-nil key makes
    # the call idempotent: replaying it returns the original result.
    def deposit(account_id, amount, key: nil)
      apply(key, kind: "deposit", to: account_id, amount: amount)
    end

    def withdraw(account_id, amount, key: nil)
      apply(key, kind: "withdrawal", from: account_id, amount: amount)
    end

    def transfer(from, to, amount, key: nil)
      apply(key, kind: "transfer", from: from, to: to, amount: amount)
    end

    private

    def apply(key, kind:, amount:, from: nil, to: nil)
      raise InvalidAmount unless amount.is_a?(Integer) && amount.positive?
      raise SameAccount if kind == "transfer" && from == to

      hash = Digest::SHA256.hexdigest([kind, from, to, amount].join("|"))

      @db.transaction do
        existing = key && @db[:transactions].where(idempotency_key: key).first
        if existing
          raise IdempotencyConflict unless existing[:request_hash] == hash

          next [present_transaction(existing), true] # replay: change nothing
        end

        currency = move_money(from, to, amount)
        row = { id: SecureRandom.hex(12), type: kind, idempotency_key: key, request_hash: hash,
                from_account: from, to_account: to, amount: amount, currency: currency,
                created_at: Time.now.utc.iso8601(6) }
        @db[:transactions].insert(row)
        @db[:entries].insert(transaction_id: row[:id], account_id: from, amount: -amount) if from
        @db[:entries].insert(transaction_id: row[:id], account_id: to, amount: amount) if to
        [present_transaction(row), false]
      end
    end

    def move_money(from, to, amount)
      from_currency = from && currency_of(from)
      to_currency = to && currency_of(to)
      raise CurrencyMismatch if from_currency && to_currency && from_currency != to_currency

      if from
        # The balance >= amount guard makes overdrafts impossible, even under concurrency.
        updated = @db[:accounts].where(id: from).where(Sequel[:balance] >= amount)
                                .update(balance: Sequel[:balance] - amount)
        raise InsufficientFunds if updated.zero?
      end
      @db[:accounts].where(id: to).update(balance: Sequel[:balance] + amount) if to
      from_currency || to_currency
    end

    def currency_of(account_id)
      @db[:accounts].where(id: account_id.to_s).get(:currency) || raise(AccountNotFound)
    end

    def present_account(row)
      { id: row[:id], owner: row[:owner], currency: row[:currency],
        balance_minor: row[:balance], created_at: row[:created_at] }
    end

    def present_transaction(row)
      { id: row[:id], type: row[:type], from_account: row[:from_account],
        to_account: row[:to_account], amount_minor: row[:amount],
        currency: row[:currency], created_at: row[:created_at] }.compact
    end
  end
end
