defmodule Mix.Tasks.Budget.Report do
  use Mix.Task

  alias SymphonyElixir.BudgetGuard

  @shortdoc "Print budget guard usage report (daily and per-issue)"

  @moduledoc """
  Prints budget guard usage from the persisted store.

  Usage:

      mix budget.report
      mix budget.report --date 2026-03-14
      mix budget.report --issue-id <linear_issue_id>
      mix budget.report --date 2026-03-14 --top 50
  """

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [date: :string, issue_id: :string, top: :integer, help: :boolean],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        date = parse_date(opts[:date])
        top_n = normalize_top(opts[:top])

        report =
          BudgetGuard.report(
            date: date,
            issue_id: opts[:issue_id],
            top_n: top_n
          )

        print_report(report)
    end
  end

  defp print_report(report) do
    Mix.shell().info("Budget Report")
    Mix.shell().info("Date: #{report.date}")
    Mix.shell().info("Currency: #{report.currency}")
    Mix.shell().info("")

    print_usage("Daily", report.daily, report.currency)

    case report do
      %{issue_id: issue_id, issue_day: issue_day, issue_total: issue_total, fail: fail} ->
        Mix.shell().info("")
        Mix.shell().info("Issue: #{issue_id}")
        print_usage("Issue (day)", issue_day, report.currency)
        print_usage("Issue (lifetime)", issue_total, report.currency)

        Mix.shell().info("Failure: count=#{fail.count} cooling_until=#{format_datetime(fail.cooling_until)}")

      %{top_issues: issues} ->
        Mix.shell().info("")
        Mix.shell().info("Top issues for day:")

        if issues == [] do
          Mix.shell().info("  (none)")
        else
          Enum.with_index(issues, 1)
          |> Enum.each(fn {row, idx} ->
            Mix.shell().info(
              "  #{idx}. issue_id=#{row.issue_id} " <>
                "usd=#{format_usd(row.usd)} " <>
                "input=#{row.input_tokens} output=#{row.output_tokens} total=#{row.total_tokens}"
            )
          end)
        end
    end
  end

  defp print_usage(label, usage, currency) do
    Mix.shell().info(
      "#{label}: " <>
        "#{currency} #{format_usd(usage.usd)} " <>
        "(input=#{usage.input_tokens} output=#{usage.output_tokens} total=#{usage.total_tokens})"
    )
  end

  defp parse_date(nil), do: Date.utc_today()

  defp parse_date(raw) when is_binary(raw) do
    case Date.from_iso8601(String.trim(raw)) do
      {:ok, date} -> date
      {:error, _reason} -> Mix.raise("Invalid --date value #{inspect(raw)}; expected YYYY-MM-DD")
    end
  end

  defp normalize_top(nil), do: 20
  defp normalize_top(value) when is_integer(value) and value > 0, do: value
  defp normalize_top(value), do: Mix.raise("Invalid --top value #{inspect(value)}; expected positive integer")

  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(_datetime), do: "n/a"

  defp format_usd(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 4)
  defp format_usd(value) when is_integer(value), do: :erlang.float_to_binary(value * 1.0, decimals: 4)
  defp format_usd(_value), do: "0.0000"
end
