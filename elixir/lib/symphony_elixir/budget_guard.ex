defmodule SymphonyElixir.BudgetGuard do
  @moduledoc false

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @table :symphony_budget_guard
  @dets_table :symphony_budget_guard_dets
  @storage_mode_key {__MODULE__, :storage_mode}

  @micros_per_usd 1_000_000
  @tokens_per_million 1_000_000

  @spec enabled?() :: boolean()
  def enabled? do
    enabled?(Config.settings!().budget)
  end

  @spec enabled?(term()) :: boolean()
  def enabled?(budget) when is_map(budget) do
    positive?(Map.get(budget, :daily_usd_limit)) or
      positive?(Map.get(budget, :daily_input_tokens_limit)) or
      positive?(Map.get(budget, :daily_output_tokens_limit)) or
      positive?(Map.get(budget, :per_issue_usd_limit)) or
      positive?(Map.get(budget, :per_issue_input_tokens_limit)) or
      positive?(Map.get(budget, :per_issue_output_tokens_limit)) or
      positive?(Map.get(budget, :consecutive_fail_limit))
  end

  def enabled?(_budget), do: false

  @spec check_issue(Issue.t(), term()) :: :ok | {:blocked, map()}
  def check_issue(%Issue{id: issue_id} = issue, budget) when is_binary(issue_id) do
    ensure_storage!()
    date = Date.utc_today()
    now = DateTime.utc_now()

    issue_day = read_usage({:issue_day, date, issue_id})
    issue_total = read_usage({:issue_total, issue_id})
    day_total = read_usage({:day, date})
    fail = read_fail(issue_id)

    with :ok <- check_fail_cooldown(fail, budget, now),
         :ok <- check_daily_limits(day_total, budget),
         :ok <- check_issue_limits(issue_day, issue_total, budget) do
      :ok
    else
      {:blocked, reason, extra} ->
        {:blocked,
         %{
           reason: reason,
           issue_id: issue_id,
           issue_identifier: issue.identifier,
           daily: day_total,
           issue_day: issue_day,
           issue_total: issue_total,
           details: extra,
           checked_at: now,
           next_reset_at: next_daily_reset(now),
           currency: normalize_currency(Map.get(budget, :currency)),
           limits: limits_snapshot(budget)
         }}
    end
  end

  def check_issue(_issue, _budget), do: :ok

  @spec record_usage(Issue.t(), map(), term()) :: :ok
  def record_usage(%Issue{id: issue_id}, token_delta, budget)
      when is_binary(issue_id) and is_map(token_delta) do
    ensure_storage!()
    date = Date.utc_today()

    input_tokens = non_negative_int(Map.get(token_delta, :input_tokens))
    output_tokens = non_negative_int(Map.get(token_delta, :output_tokens))

    if input_tokens > 0 or output_tokens > 0 do
      usage = %{
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        usd_micros: estimate_usd_micros(input_tokens, output_tokens, budget)
      }

      bump_usage({:day, date}, usage)
      bump_usage({:issue_day, date, issue_id}, usage)
      bump_usage({:issue_total, issue_id}, usage)
    end

    :ok
  end

  def record_usage(_issue, _token_delta, _budget), do: :ok

  @spec record_failure(Issue.t(), term()) :: :ok | {:blocked, map()}
  def record_failure(%Issue{id: issue_id} = issue, budget) when is_binary(issue_id) do
    ensure_storage!()

    case positive_int(Map.get(budget, :consecutive_fail_limit)) do
      nil ->
        :ok

      fail_limit ->
        now = DateTime.utc_now()
        fail = read_fail(issue_id)
        count = max(Map.get(fail, :count, 0), 0) + 1
        cooldown_minutes = non_negative_int(Map.get(budget, :fail_cooldown_minutes))

        cooling_until =
          if count >= fail_limit and cooldown_minutes > 0 do
            DateTime.add(now, cooldown_minutes * 60, :second)
          else
            nil
          end

        write_fail(issue_id, count, cooling_until)

        if count >= fail_limit do
          {:blocked,
           %{
             reason: :consecutive_fail_limit,
             issue_id: issue_id,
             issue_identifier: issue.identifier,
             checked_at: now,
             next_reset_at: next_daily_reset(now),
             details: %{
               fail_count: count,
               fail_limit: fail_limit,
               cooling_until: cooling_until
             },
             limits: limits_snapshot(budget),
             currency: normalize_currency(Map.get(budget, :currency)),
             daily: read_usage({:day, Date.utc_today()}),
             issue_day: read_usage({:issue_day, Date.utc_today(), issue_id}),
             issue_total: read_usage({:issue_total, issue_id})
           }}
        else
          :ok
        end
    end
  end

  def record_failure(_issue, _budget), do: :ok

  @spec reset_failures(Issue.t() | String.t() | nil) :: :ok
  def reset_failures(%Issue{id: issue_id}), do: reset_failures(issue_id)

  def reset_failures(issue_id) when is_binary(issue_id) do
    ensure_storage!()
    delete_record({:fail, issue_id})
    :ok
  end

  def reset_failures(_issue_id), do: :ok

  @spec mark_block_notified(Issue.t() | String.t(), atom()) :: :new | :seen
  def mark_block_notified(%Issue{id: issue_id}, reason) when is_binary(issue_id),
    do: mark_block_notified(issue_id, reason)

  def mark_block_notified(issue_id, reason) when is_binary(issue_id) and is_atom(reason) do
    ensure_storage!()
    key = {:block_notice, Date.utc_today(), issue_id, reason}

    case :ets.lookup(@table, key) do
      [] ->
        put_record({key, DateTime.utc_now() |> DateTime.to_iso8601()})
        :new

      _ ->
        :seen
    end
  end

  def mark_block_notified(_issue_id, _reason), do: :new

  @spec block_comment(Issue.t(), map(), term()) :: String.t()
  def block_comment(%Issue{} = issue, snapshot, budget) do
    prefix = comment_prefix(budget)
    move_state = move_state(budget)
    currency = Map.get(snapshot, :currency, normalize_currency(Map.get(budget, :currency)))
    reason = snapshot[:reason]

    """
    #{prefix} limit reached: #{human_reason(snapshot[:reason])}

    - Issue: #{issue.identifier || issue.id || "n/a"}
    - Daily spend: #{format_usd(snapshot[:daily], currency)} / #{format_limit(Map.get(snapshot[:limits], :daily_usd_limit), currency)}
    - Issue spend (lifetime): #{format_usd(snapshot[:issue_total], currency)} / #{format_limit(Map.get(snapshot[:limits], :per_issue_usd_limit), currency)}
    - Daily input/output tokens: #{format_token_pair(snapshot[:daily])}
    - Issue input/output tokens: #{format_token_pair(snapshot[:issue_total])}
    - Block reason: #{human_reason(snapshot[:reason])}
    - Next daily reset (UTC): #{format_datetime(snapshot[:next_reset_at])}
    - Target state: #{move_state}

    #{resume_guidance(reason)}
    """
    |> String.trim()
  end

  defp resume_guidance(reason)

  defp resume_guidance(reason) when reason in [:consecutive_fail_limit, :fail_cooldown] do
    """
    Resume options:
    1) Wait for fail cooldown to expire, then move issue back to an active state (`Todo` or `In Progress`)
    2) Update `budget.fail_cooldown_minutes` or `budget.consecutive_fail_limit` in `WORKFLOW.md`, reload config, then resume

    Note: daily/per-issue budget limits still apply after cooldown.
    """
    |> String.trim()
  end

  defp resume_guidance(reason)
       when reason in [:per_issue_usd_limit, :per_issue_input_tokens_limit, :per_issue_output_tokens_limit] do
    """
    Resume options:
    1) Increase the matching `budget.per_issue_*` limit in `WORKFLOW.md`, reload config, then resume
    2) If this issue should remain capped, keep it in review state for manual handling

    Note: daily budget limits and failure circuit breaker still apply after resume.
    """
    |> String.trim()
  end

  defp resume_guidance(reason)
       when reason in [:daily_usd_limit, :daily_input_tokens_limit, :daily_output_tokens_limit] do
    """
    Resume options:
    1) Wait for daily reset and move issue back to an active state (`Todo` or `In Progress`)
    2) Increase the matching `budget.daily_*` limit in `WORKFLOW.md`, reload config, then resume

    Note: `per_issue_*` limits and failure circuit breaker still apply after daily reset.
    """
    |> String.trim()
  end

  defp resume_guidance(_reason) do
    """
    Resume options:
    1) Wait for daily reset and move issue back to an active state (`Todo` or `In Progress`)
    2) Increase `budget.daily_usd_limit` in `WORKFLOW.md`, reload config, then resume

    Note: `per_issue_*` limits and failure circuit breaker still apply after daily reset.
    """
    |> String.trim()
  end

  defp check_daily_limits(day_total, budget) do
    cond do
      exceeds_float?(Map.get(day_total, :usd_micros), Map.get(budget, :daily_usd_limit), @micros_per_usd) ->
        {:blocked, :daily_usd_limit, %{}}

      exceeds_int?(Map.get(day_total, :input_tokens), Map.get(budget, :daily_input_tokens_limit)) ->
        {:blocked, :daily_input_tokens_limit, %{}}

      exceeds_int?(Map.get(day_total, :output_tokens), Map.get(budget, :daily_output_tokens_limit)) ->
        {:blocked, :daily_output_tokens_limit, %{}}

      true ->
        :ok
    end
  end

  defp check_issue_limits(issue_day, issue_total, budget) do
    cond do
      exceeds_float?(Map.get(issue_total, :usd_micros), Map.get(budget, :per_issue_usd_limit), @micros_per_usd) ->
        {:blocked, :per_issue_usd_limit, %{}}

      exceeds_int?(Map.get(issue_total, :input_tokens), Map.get(budget, :per_issue_input_tokens_limit)) ->
        {:blocked, :per_issue_input_tokens_limit, %{}}

      exceeds_int?(Map.get(issue_total, :output_tokens), Map.get(budget, :per_issue_output_tokens_limit)) ->
        {:blocked, :per_issue_output_tokens_limit, %{}}

      exceeds_float?(Map.get(issue_day, :usd_micros), Map.get(budget, :per_issue_usd_limit), @micros_per_usd) ->
        {:blocked, :per_issue_usd_limit, %{}}

      true ->
        :ok
    end
  end

  defp check_fail_cooldown(fail, budget, now) do
    fail_limit = positive_int(Map.get(budget, :consecutive_fail_limit))
    count = Map.get(fail, :count, 0)
    cooling_until = Map.get(fail, :cooling_until)

    cond do
      is_nil(fail_limit) ->
        :ok

      is_struct(cooling_until, DateTime) and DateTime.compare(cooling_until, now) == :gt ->
        {:blocked, :fail_cooldown, %{cooling_until: cooling_until, fail_count: count, fail_limit: fail_limit}}

      true ->
        :ok
    end
  end

  defp limits_snapshot(budget) do
    %{
      daily_usd_limit: Map.get(budget, :daily_usd_limit),
      daily_input_tokens_limit: Map.get(budget, :daily_input_tokens_limit),
      daily_output_tokens_limit: Map.get(budget, :daily_output_tokens_limit),
      per_issue_usd_limit: Map.get(budget, :per_issue_usd_limit),
      per_issue_input_tokens_limit: Map.get(budget, :per_issue_input_tokens_limit),
      per_issue_output_tokens_limit: Map.get(budget, :per_issue_output_tokens_limit),
      consecutive_fail_limit: Map.get(budget, :consecutive_fail_limit),
      fail_cooldown_minutes: Map.get(budget, :fail_cooldown_minutes)
    }
  end

  defp bump_usage(key, usage) do
    current = read_usage(key)

    updated = %{
      input_tokens: current.input_tokens + Map.get(usage, :input_tokens, 0),
      output_tokens: current.output_tokens + Map.get(usage, :output_tokens, 0),
      usd_micros: current.usd_micros + Map.get(usage, :usd_micros, 0)
    }

    put_record({key, updated.input_tokens, updated.output_tokens, updated.usd_micros})
    :ok
  end

  defp read_usage(key) do
    case :ets.lookup(@table, key) do
      [{^key, input_tokens, output_tokens, usd_micros}] ->
        %{
          input_tokens: non_negative_int(input_tokens),
          output_tokens: non_negative_int(output_tokens),
          usd_micros: non_negative_int(usd_micros)
        }

      _ ->
        %{input_tokens: 0, output_tokens: 0, usd_micros: 0}
    end
  end

  defp read_fail(issue_id) when is_binary(issue_id) do
    key = {:fail, issue_id}

    case :ets.lookup(@table, key) do
      [{^key, count, cooling_until_iso}] ->
        %{
          count: non_negative_int(count),
          cooling_until: parse_datetime(cooling_until_iso)
        }

      _ ->
        %{count: 0, cooling_until: nil}
    end
  end

  defp write_fail(issue_id, count, cooling_until) when is_binary(issue_id) do
    key = {:fail, issue_id}
    cooling_until_iso = if is_struct(cooling_until, DateTime), do: DateTime.to_iso8601(cooling_until), else: nil
    put_record({key, non_negative_int(count), cooling_until_iso})
    :ok
  end

  defp estimate_usd_micros(input_tokens, output_tokens, budget) do
    input_price = float_or_default(Map.get(budget, :usd_per_1m_input), 0.0)
    output_price = float_or_default(Map.get(budget, :usd_per_1m_output), 0.0)

    input_usd = input_tokens * input_price / @tokens_per_million
    output_usd = output_tokens * output_price / @tokens_per_million
    round((input_usd + output_usd) * @micros_per_usd)
  end

  defp ensure_storage! do
    ensure_ets!()

    case :persistent_term.get(@storage_mode_key, :unset) do
      :unset ->
        initialize_storage_mode()

      _ ->
        :ok
    end
  end

  defp ensure_ets! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :named_table, :public, read_concurrency: true, write_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end

  defp initialize_storage_mode do
    case open_and_load_dets() do
      :ok ->
        :persistent_term.put(@storage_mode_key, :dets)

      {:error, reason} ->
        Logger.warning("Budget guard persistence unavailable; falling back to ETS only: #{inspect(reason)}")
        :persistent_term.put(@storage_mode_key, :ets_only)
    end
  end

  defp open_and_load_dets do
    path = dets_store_path()
    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(@dets_table, type: :set, file: String.to_charlist(path), auto_save: 5_000) do
      {:ok, @dets_table} ->
        :dets.foldl(
          fn record, :ok ->
            :ets.insert(@table, record)
            :ok
          end,
          :ok,
          @dets_table
        )

        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      {:error, error}
  end

  defp dets_store_path do
    workflow_budget_path =
      try do
        Config.settings!().budget
        |> Map.get(:store_path)
      rescue
        _ -> nil
      end

    env_path = Application.get_env(:symphony_elixir, :budget_guard_store_path)

    cond do
      is_binary(workflow_budget_path) and String.trim(workflow_budget_path) != "" ->
        Path.expand(workflow_budget_path)

      is_binary(env_path) and String.trim(env_path) != "" ->
        Path.expand(env_path)

      true ->
        Path.join(System.tmp_dir!(), "symphony_budget_guard.dets")
    end
  end

  defp put_record(tuple) when is_tuple(tuple) do
    :ets.insert(@table, tuple)

    if :persistent_term.get(@storage_mode_key, :unset) == :dets do
      _ = safe_dets_write(:insert, tuple)
    end

    :ok
  end

  defp delete_record(key) do
    :ets.delete(@table, key)

    if :persistent_term.get(@storage_mode_key, :unset) == :dets do
      _ = safe_dets_write(:delete, key)
    end

    :ok
  end

  defp safe_dets_write(:insert, tuple) do
    :dets.insert(@dets_table, tuple)
  rescue
    ArgumentError ->
      :persistent_term.put(@storage_mode_key, :ets_only)
      :ok
  end

  defp safe_dets_write(:delete, key) do
    :dets.delete(@dets_table, key)
  rescue
    ArgumentError ->
      :persistent_term.put(@storage_mode_key, :ets_only)
      :ok
  end

  defp format_usd(usage, currency) when is_map(usage) do
    usd = Map.get(usage, :usd_micros, 0) / @micros_per_usd
    "#{currency} #{:erlang.float_to_binary(max(usd, 0.0), decimals: 4)}"
  end

  defp format_usd(_usage, currency), do: "#{currency} 0.0000"

  defp format_limit(nil, _currency), do: "n/a"

  defp format_limit(limit, currency) do
    "#{currency} #{:erlang.float_to_binary(float_or_default(limit, 0.0), decimals: 4)}"
  end

  defp format_token_pair(usage) when is_map(usage) do
    "#{Map.get(usage, :input_tokens, 0)} in / #{Map.get(usage, :output_tokens, 0)} out"
  end

  defp format_token_pair(_usage), do: "0 in / 0 out"

  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(_datetime), do: "n/a"

  defp human_reason(reason) do
    case reason do
      :daily_usd_limit -> "daily USD limit"
      :daily_input_tokens_limit -> "daily input token limit"
      :daily_output_tokens_limit -> "daily output token limit"
      :per_issue_usd_limit -> "per-issue USD limit"
      :per_issue_input_tokens_limit -> "per-issue input token limit"
      :per_issue_output_tokens_limit -> "per-issue output token limit"
      :consecutive_fail_limit -> "consecutive failure limit"
      :fail_cooldown -> "failure cooldown active"
      _ -> "budget limit"
    end
  end

  defp next_daily_reset(%DateTime{} = now) do
    now
    |> DateTime.to_date()
    |> Date.add(1)
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp move_state(budget) do
    budget
    |> Map.get(:on_limit, %{})
    |> Map.get(:move_state, "Human Review")
    |> normalize_non_empty("Human Review")
  end

  defp comment_prefix(budget) do
    budget
    |> Map.get(:on_limit, %{})
    |> Map.get(:comment_prefix, "[Budget Guard]")
    |> normalize_non_empty("[Budget Guard]")
  end

  defp normalize_currency(nil), do: "USD"

  defp normalize_currency(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.upcase()
    |> normalize_non_empty("USD")
  end

  defp normalize_non_empty(value, default) do
    trimmed = value |> to_string() |> String.trim()
    if trimmed == "", do: default, else: trimmed
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp exceeds_int?(_current, nil), do: false

  defp exceeds_int?(current, limit) do
    case positive_int(limit) do
      nil -> false
      normalized_limit -> current >= normalized_limit
    end
  end

  defp exceeds_float?(_current_micros, nil, _factor), do: false

  defp exceeds_float?(current_micros, limit, factor) do
    current_micros >= round(float_or_default(limit, 0.0) * factor)
  end

  defp positive?(value) when is_integer(value), do: value > 0
  defp positive?(value) when is_float(value), do: value > 0
  defp positive?(_value), do: false

  defp positive_int(value) when is_integer(value) and value > 0, do: value
  defp positive_int(_value), do: nil

  defp non_negative_int(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value), do: 0

  defp float_or_default(value, _default) when is_float(value), do: value
  defp float_or_default(value, _default) when is_integer(value), do: value * 1.0
  defp float_or_default(_value, default), do: default
end
