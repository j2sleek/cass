defmodule Cass.AnalyticsTest do
  use Cass.DataCase, async: true

  alias Cass.Analytics

  # In the test environment the async writer is disabled, so `track/2` writes
  # synchronously inside the sandbox and is observable immediately.
  defp track(name, attrs \\ %{}) do
    assert :ok = Analytics.track(name, attrs)
  end

  describe "track/2" do
    test "records an event and normalizes metadata keys and values" do
      track("search", %{
        visitor_id: "visitor-1",
        path: "/catalog",
        metadata: %{query: "widget", result_count: 0, missing: nil}
      })

      assert [event] = Analytics.list_events(name: "search")
      assert event.name == "search"
      assert event.visitor_id == "visitor-1"
      assert event.path == "/catalog"
      assert event.metadata == %{"query" => "widget", "result_count" => 0}
      assert %DateTime{} = event.occurred_at
    end

    test "stringifies subject ids and drops unusable values from metadata" do
      track("product_view", %{
        subject_type: "product",
        subject_id: 42,
        metadata: %{status: :ok, blob: self()}
      })

      assert [event] = Analytics.list_events(name: "product_view")
      assert event.subject_id == "42"
      assert event.metadata["status"] == "ok"
      assert is_binary(event.metadata["blob"])
    end

    test "never raises into the caller" do
      assert :ok = Analytics.track("weird", %{metadata: %{anything: self()}})
      assert [event] = Analytics.list_events(name: "weird")
      assert is_binary(event.metadata["anything"])
    end
  end

  describe "summary/1" do
    test "counts each event name and distinct visitors inside the window" do
      track("page_view", %{visitor_id: "a"})
      track("page_view", %{visitor_id: "b"})
      track("page_view", %{visitor_id: "b"})
      track("product_view")
      track("order_created")
      track("order_paid")
      track("ai_run")

      summary = Analytics.summary(days: 7)

      assert summary.page_views == 3
      assert summary.unique_visitors == 2
      assert summary.product_views == 1
      assert summary.orders_created == 1
      assert summary.orders_paid == 1
      assert summary.ai_runs == 1
    end

    test "respects the window" do
      track("page_view", %{occurred_at: DateTime.add(DateTime.utc_now(), -10, :day)})

      assert Analytics.summary(days: 7).page_views == 0
      assert Analytics.summary(days: 30).page_views == 1
    end
  end

  describe "read queries" do
    test "top_paths and page_views_over_time" do
      track("page_view", %{path: "/catalog"})
      track("page_view", %{path: "/catalog"})
      track("page_view", %{path: "/"})

      assert Analytics.top_paths(days: 7) == [{"/catalog", 2}, {"/", 1}]

      assert [{day, 3}] = Analytics.page_views_over_time(days: 7)
      assert %NaiveDateTime{} = day
    end

    test "top_products groups by subject and keeps the title" do
      track("product_view", %{subject_id: 10, metadata: %{title: "Alpha"}})
      track("product_view", %{subject_id: 10, metadata: %{title: "Alpha"}})
      track("product_view", %{subject_id: 11, metadata: %{title: "Beta"}})

      assert Analytics.top_products(days: 7) == [{"10", "Alpha", 2}, {"11", "Beta", 1}]
    end

    test "top_searches and searches_without_results" do
      track("search", %{metadata: %{query: "ai", result_count: 3}})
      track("search", %{metadata: %{query: "ai", result_count: 3}})
      track("search", %{metadata: %{query: "nft art", result_count: 0}})

      assert Analytics.top_searches(days: 7) == [{"ai", 2}, {"nft art", 1}]
      assert Analytics.searches_without_results(days: 7) == [{"nft art", 1}]
    end

    test "list_events filters by name and visitor" do
      track("page_view", %{visitor_id: "a"})
      track("search", %{visitor_id: "a"})
      track("page_view", %{visitor_id: "b"})

      assert length(Analytics.list_events()) == 3
      assert length(Analytics.list_events(name: "page_view")) == 2
      assert [event] = Analytics.list_events(visitor_id: "b")
      assert event.visitor_id == "b"
    end
  end
end
