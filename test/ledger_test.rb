# frozen_string_literal: true

require_relative "test_helper"

class LedgerTest < Minitest::Test
  include LedgerHelpers

  def setup
    @svc = new_service
  end

  def teardown = @svc.close

  def balance(account) = @svc.account(account[:id])[:balance_minor]

  def test_deposit_and_withdraw
    ana = open_account(@svc, "ana", "cop", funds: 10_000)
    @svc.withdraw(ana[:id], 2_500)
    assert_equal 7_500, balance(ana)

    assert_raises(Ledger::InsufficientFunds) { @svc.withdraw(ana[:id], 8_000) }
    assert_equal 7_500, balance(ana), "a failed withdrawal must not change the balance"
  end

  def test_invalid_inputs
    ana = open_account(@svc, "ana", funds: 100)
    assert_raises(Ledger::InvalidAmount) { @svc.deposit(ana[:id], 0) }
    assert_raises(Ledger::InvalidAmount) { @svc.deposit(ana[:id], 10.5) }
    assert_raises(Ledger::AccountNotFound) { @svc.deposit("missing", 5) }
    assert_raises(Ledger::SameAccount) { @svc.transfer(ana[:id], ana[:id], 5) }
    assert_raises(Ledger::InvalidAccount) { @svc.create_account(owner: "", currency: "USD") }
  end

  def test_transfer_moves_money_and_records_history
    ana = open_account(@svc, "ana", funds: 1_000)
    beto = open_account(@svc, "beto")

    @svc.transfer(ana[:id], beto[:id], 400)

    assert_equal 600, balance(ana)
    assert_equal 400, balance(beto)
    history = @svc.transactions(beto[:id])
    assert_equal ["transfer"], history.map { |t| t[:type] }
  end

  def test_failed_transfer_changes_nothing
    ana = open_account(@svc, "ana", funds: 100)
    beto = open_account(@svc, "beto", funds: 50)
    eva = open_account(@svc, "eva", "EUR")

    assert_raises(Ledger::InsufficientFunds) { @svc.transfer(ana[:id], beto[:id], 101) }
    assert_raises(Ledger::CurrencyMismatch) { @svc.transfer(ana[:id], eva[:id], 10) }
    assert_raises(Ledger::AccountNotFound) { @svc.transfer(ana[:id], "ghost", 10) }

    assert_equal [100, 50, 0], [balance(ana), balance(beto), balance(eva)]
  end

  def test_idempotency_replay_and_conflict
    ana = open_account(@svc, "ana")

    first, replayed = @svc.deposit(ana[:id], 500, key: "key-1")
    refute replayed
    second, replayed = @svc.deposit(ana[:id], 500, key: "key-1")
    assert replayed
    assert_equal first[:id], second[:id]
    assert_equal 500, balance(ana), "a replayed deposit must not apply twice"

    assert_raises(Ledger::IdempotencyConflict) { @svc.deposit(ana[:id], 999, key: "key-1") }
  end

  # Money must be conserved and no account may go negative, whatever the interleaving.
  def test_concurrent_transfers_conserve_money
    accounts = %w[a b c].map { |owner| open_account(@svc, owner, funds: 1_000) }

    threads = Array.new(60) do |i|
      Thread.new do
        from = accounts[i % 3]
        to = accounts[(i + 1) % 3]
        begin
          @svc.transfer(from[:id], to[:id], 50 + i)
        rescue Ledger::InsufficientFunds
          nil # expected sometimes; corruption is not
        end
      end
    end
    threads.each(&:join)

    balances = accounts.map { |a| balance(a) }
    assert balances.all? { |b| b >= 0 }, "an account went negative: #{balances}"
    assert_equal 3_000, balances.sum
  end
end
