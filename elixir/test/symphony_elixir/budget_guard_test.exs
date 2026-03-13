defmodule SymphonyElixir.BudgetGuardTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.BudgetGuard
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue

  setup do
    Application.put_env(
      :symphony_elixir,
      :budget_guard_store_path,
      Path.join(System.tmp_dir!(), "symphony-budget-guard-test-#{System.unique_integer([:positive])}.dets")
    )

    :persistent_term.erase({BudgetGuard, :storage_mode})

    case :ets.whereis(:symphony_budget_guard) do
      :undefined -> :ok
      table -> :ets.delete(table)
    end

    case :dets.info(:symphony_budget_guard_dets) do
      :undefined -> :ok
      _ -> close_dets_if_possible()
    end

    on_exit(fn ->
      case :dets.info(:symphony_budget_guard_dets) do
        :undefined -> :ok
        _ -> close_dets_if_possible()
      end

      Application.delete_env(:symphony_elixir, :budget_guard_store_path)
      :persistent_term.erase({BudgetGuard, :storage_mode})
    end)

    :ok
  end

  test "budget guard blocks when daily usd limit is reached" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}

    budget = %Schema.Budget{
      daily_usd_limit: 0.0001,
      usd_per_1m_input: 1.0,
      usd_per_1m_output: 1.0,
      on_limit: %Schema.BudgetOnLimit{}
    }

    assert :ok = BudgetGuard.record_usage(issue, %{input_tokens: 150, output_tokens: 0}, budget)
    assert {:blocked, snapshot} = BudgetGuard.check_issue(issue, budget)
    assert snapshot.reason == :daily_usd_limit
  end

  test "budget guard tracks consecutive failures and enters cooldown" do
    issue = %Issue{id: "issue-2", identifier: "MT-2", state: "In Progress"}

    budget = %Schema.Budget{
      consecutive_fail_limit: 2,
      fail_cooldown_minutes: 10,
      on_limit: %Schema.BudgetOnLimit{}
    }

    assert :ok = BudgetGuard.record_failure(issue, budget)
    assert {:blocked, snapshot} = BudgetGuard.record_failure(issue, budget)
    assert snapshot.reason == :consecutive_fail_limit

    assert {:blocked, cooldown_snapshot} = BudgetGuard.check_issue(issue, budget)
    assert cooldown_snapshot.reason == :fail_cooldown
  end

  test "reset_failures clears failure counter" do
    issue = %Issue{id: "issue-3", identifier: "MT-3", state: "In Progress"}

    budget = %Schema.Budget{
      consecutive_fail_limit: 2,
      fail_cooldown_minutes: 0,
      on_limit: %Schema.BudgetOnLimit{}
    }

    assert :ok = BudgetGuard.record_failure(issue, budget)
    assert :ok = BudgetGuard.reset_failures(issue)
    assert :ok = BudgetGuard.check_issue(issue, budget)
  end

  test "check_issue does not hard-block on consecutive failures without cooldown" do
    issue = %Issue{id: "issue-4", identifier: "MT-4", state: "In Progress"}

    budget = %Schema.Budget{
      consecutive_fail_limit: 2,
      fail_cooldown_minutes: 0,
      on_limit: %Schema.BudgetOnLimit{}
    }

    assert :ok = BudgetGuard.record_failure(issue, budget)
    assert {:blocked, _snapshot} = BudgetGuard.record_failure(issue, budget)
    assert :ok = BudgetGuard.check_issue(issue, budget)
  end

  test "block notifications are idempotent for the same day and reason" do
    issue = %Issue{id: "issue-5", identifier: "MT-5", state: "In Progress"}

    assert :new = BudgetGuard.mark_block_notified(issue, :daily_usd_limit)
    assert :seen = BudgetGuard.mark_block_notified(issue, :daily_usd_limit)
    assert :new = BudgetGuard.mark_block_notified(issue, :per_issue_usd_limit)
  end

  defp close_dets_if_possible do
    case :dets.close(:symphony_budget_guard_dets) do
      :ok -> :ok
      {:error, :not_owner} -> :ok
      {:error, :not_open} -> :ok
      _ -> :ok
    end
  end
end
