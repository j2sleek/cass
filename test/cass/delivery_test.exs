defmodule Cass.DeliveryTest do
  @moduledoc """
  Domain tests for the Delivery & Access boundary.

  Every test starts from a real purchase — a real order, transitioned by the
  same `Cass.Orders.mark_order_paid/1` call a verified payment makes — and then
  drives the real delivery and grant transitions. Nothing fabricates a half
  built chain or hands a status to a struct, so a test that says "this buyer
  holds a grant" is standing on exactly the state production creates.

  They are organised around the three questions the boundary answers, and then
  around the property that makes the boundary worth having: **who can exercise a
  purchase, and what can they learn about everyone else's.**
  """
  use Cass.DataCase, async: true

  import Cass.AccountsFixtures
  import Cass.CommerceFixtures

  alias Cass.Accounts.Scope
  alias Cass.Delivery
  alias Cass.Delivery.Access
  alias Cass.Entitlements
  alias Cass.Entitlements.Entitlement
  alias Cass.Fulfillment
  alias Cass.Orders
  alias Cass.Repo

  @refused "this purchase cannot be accessed"

  # Four groups of four symbols from a Crockford-style alphabet: no I, L, O, or
  # U, so a code read aloud is not misread.
  @code_format ~r/^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/

  setup do
    # Scopes, not raw users: the fixtures and the context both take the same
    # server-resolved identity the session would produce.
    %{
      category: category_fixture(),
      buyer: Scope.for_user(user_fixture()),
      stranger: Scope.for_user(user_fixture())
    }
  end

  describe "the vocabulary" do
    test "delivery kinds are the fulfillment taxonomy, not a second one" do
      assert Delivery.kinds() == Fulfillment.kinds()

      assert Delivery.kind_for(:digital) == :digital
      assert Delivery.kind_for(:smm) == :smm
      assert Delivery.kind_for(:ai) == :ai
      # A service is delivered by a human, and that mapping is owned by
      # Fulfillment rather than restated here.
      assert Delivery.kind_for(:service) == :manual
    end

    test "a kind is not a mechanism: only digital is exercisable today" do
      assert Delivery.mechanism_for(:digital) == :access_code

      # Resolved, and therefore known, but not yet handable. They refuse rather
      # than inventing a placeholder capability.
      assert Delivery.mechanism_for(:smm) == nil
      assert Delivery.mechanism_for(:ai) == nil
      assert Delivery.mechanism_for(:manual) == nil
      assert Delivery.mechanism_for(:nonsense) == nil
    end
  end

  describe "authorize_access/2 for the buyer" do
    setup %{category: category, buyer: buyer} do
      %{granted: granted_entitlement_fixture(buyer, category)}
    end

    test "a paid, delivered purchase is exercisable", %{buyer: buyer, granted: granted} do
      assert {:ok, access} =
               Delivery.authorize_access(buyer, granted.entitlement.id)

      assert access.entitlement_id == granted.entitlement.id
      assert access.mechanism == :access_code
      assert access.kind == :digital
      assert access.product_type == :digital
      assert access.product_name == granted.entitlement.product_name
      assert access.variant_name == granted.entitlement.variant_name
      assert access.sku == granted.entitlement.sku
      assert access.quantity == granted.entitlement.quantity
      assert %DateTime{} = access.granted_at
      assert access.expires_at == granted.entitlement.expires_at
    end

    test "the capability carries a code in the documented shape", %{
      buyer: buyer,
      granted: granted
    } do
      assert {:ok, %Access{access_code: code}} =
               Delivery.authorize_access(buyer, granted.entitlement.id)

      assert code =~ @code_format
    end

    test "the code is stable across repeated and independent reads", %{
      buyer: buyer,
      granted: granted
    } do
      scope = buyer

      codes =
        for _attempt <- 1..3 do
          {:ok, access} = Delivery.authorize_access(scope, granted.entitlement.id)
          access.access_code
        end

      assert codes |> Enum.uniq() |> length() == 1
    end

    test "each purchased line gets its own code", %{category: category, buyer: buyer} do
      first = granted_entitlement_fixture(buyer, category)
      second = granted_entitlement_fixture(buyer, category)

      assert {:ok, one} = Delivery.authorize_access(buyer, first.entitlement.id)
      assert {:ok, two} = Delivery.authorize_access(buyer, second.entitlement.id)

      assert one.access_code != two.access_code
    end

    test "the code never appears when the capability is inspected", %{
      buyer: buyer,
      granted: granted
    } do
      assert {:ok, access} =
               Delivery.authorize_access(buyer, granted.entitlement.id)

      # An accidental `IO.inspect(access)` in a log line must not leak the
      # credential the buyer would use.
      refute inspect(access) =~ access.access_code
      refute inspect(access, structs: true) =~ access.access_code
    end
  end

  describe "authorize_access/2 refuses everything else" do
    test "somebody else's purchase", %{category: category, buyer: buyer, stranger: stranger} do
      granted = granted_entitlement_fixture(buyer, category)

      assert {:error, changeset} =
               Delivery.authorize_access(stranger, granted.entitlement.id)

      assert @refused in errors_on(changeset).base
    end

    test "a guest", %{category: category, buyer: buyer} do
      granted = granted_entitlement_fixture(buyer, category)

      assert {:error, changeset} =
               Delivery.authorize_access(Scope.for_user(nil), granted.entitlement.id)

      assert @refused in errors_on(changeset).base
    end

    test "an id that does not exist", %{buyer: buyer} do
      assert {:error, changeset} = Delivery.authorize_access(buyer, 0)

      assert @refused in errors_on(changeset).base
    end

    test "a revoked grant", %{category: category, buyer: buyer} do
      granted =
        buyer
        |> granted_entitlement_fixture(category)
        |> revoke_fixture()

      assert {:error, changeset} =
               Delivery.authorize_access(buyer, granted.entitlement.id)

      assert @refused in errors_on(changeset).base
    end

    test "a grant whose expiry has elapsed", %{category: category, buyer: buyer} do
      granted = granted_entitlement_fixture(buyer, category)

      # Elapsed is decided by the centralized `active?/1` predicate, so no status
      # write is needed: a lapsed subscription is refused the same way.
      expire!(granted.entitlement)

      assert {:error, changeset} =
               Delivery.authorize_access(buyer, granted.entitlement.id)

      assert @refused in errors_on(changeset).base
    end

    test "a delivery kind with no mechanism yet", %{category: category, buyer: buyer} do
      for product_type <- [:smm, :ai, :service] do
        granted = granted_entitlement_fixture(buyer, category, product_type: product_type)

        assert {:error, changeset} =
                 Delivery.authorize_access(buyer, granted.entitlement.id)

        assert @refused in errors_on(changeset).base
      end
    end

    test "a delivery that is not fulfilled yet grants nothing", %{
      category: category,
      buyer: buyer
    } do
      {_product, variant} = published_variant_fixture(category)
      order = paid_order_fixture(buyer, variant)
      {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order.id)

      # A pending delivery owes the work but has granted no right, so there is
      # nothing to exercise and nothing a caller could name.
      assert fulfillment.status == :pending
      assert Repo.preload(fulfillment, :entitlement).entitlement == nil
      assert Entitlements.list_for_order(buyer, order.id) == []

      assert {:ok, delivered} = Fulfillment.mark_processing(fulfillment)
      assert {:ok, fulfilled} = Fulfillment.mark_fulfilled(delivered)

      entitlement = Repo.preload(fulfilled, :entitlement).entitlement
      assert {:ok, access} = Delivery.authorize_access(buyer, entitlement.id)
      assert access.access_code =~ @code_format
    end

    test "a malformed scope or id is refused, not raised on" do
      assert {:error, _changeset} = Delivery.authorize_access(nil, 1)
      assert {:error, _changeset} = Delivery.authorize_access("admin", 1)
      assert {:error, _changeset} = Delivery.authorize_access(%Scope{}, 1)
    end
  end

  describe "what a refusal reveals" do
    test "unknown, foreign, revoked, elapsed, unsupported, and guest all look alike", %{
      category: category,
      buyer: buyer,
      stranger: stranger
    } do
      granted = granted_entitlement_fixture(buyer, category)
      revoked = buyer |> granted_entitlement_fixture(category) |> revoke_fixture()
      unsupported = granted_entitlement_fixture(buyer, category, product_type: :smm)
      elapsed = granted_entitlement_fixture(buyer, category)
      expire!(elapsed.entitlement)

      refusals =
        for {scope, id} <- [
              {stranger, granted.entitlement.id},
              {Scope.for_user(nil), granted.entitlement.id},
              {buyer, revoked.entitlement.id},
              {buyer, elapsed.entitlement.id},
              {buyer, unsupported.entitlement.id},
              {buyer, 999_999_999}
            ] do
          {:error, changeset} = Delivery.authorize_access(scope, id)
          errors_on(changeset)
        end

      assert length(Enum.uniq(refusals)) == 1
    end
  end

  describe "what the capability reveals" do
    test "no vendor-authored purchase metadata leaks into it", %{
      category: category,
      buyer: buyer
    } do
      granted =
        granted_entitlement_fixture(buyer, category,
          config: %{
            "download_url" => "https://vendor.invalid/secret-file.zip",
            "api_key" => "sk_live_vendor_secret_value",
            "access_token" => "vendor-token-abcdefghijklmnop",
            "license_pool" => %{"pool" => "internal-pool-1"}
          }
        )

      assert {:ok, access} =
               Delivery.authorize_access(buyer, granted.entitlement.id)

      rendered = inspect(access) <> inspect(access, structs: true, limit: :infinity)

      # The typed representation has no metadata field at all, so there is no
      # filter here to forget later.
      refute Map.has_key?(access, :metadata)

      for leak <- [
            "secret-file",
            "sk_live_vendor_secret_value",
            "vendor-token-",
            "internal-pool-1"
          ] do
        refute rendered =~ leak
      end
    end

    test "the signing secret never appears in the capability", %{
      category: category,
      buyer: buyer
    } do
      granted = granted_entitlement_fixture(buyer, category)
      secret = Application.fetch_env!(:cass, Cass.Delivery) |> Keyword.fetch!(:access_secret)

      assert {:ok, access} =
               Delivery.authorize_access(buyer, granted.entitlement.id)

      refute inspect(access) =~ String.slice(secret, 0, 16)
      refute access.access_code =~ String.slice(secret, 0, 8)
    end
  end

  describe "the full chain" do
    test "an unpaid order owes no delivery and grants no access", %{
      category: category,
      buyer: buyer
    } do
      {_product, variant} = published_variant_fixture(category)
      order = order_fixture(buyer, variant)
      scope = buyer

      # Not paid: the payment boundary has not happened, so there is nothing to
      # deliver and nothing to access.
      assert {:error, changeset} = Fulfillment.create_for_paid_order(order.id)
      assert "the order has not been paid" in errors_on(changeset).base
      assert Fulfillment.list_for_order(scope, order.id) == []
      assert Entitlements.list_for_order(scope, order.id) == []

      # Paying creates the delivery; it is completing the delivery — not paying —
      # that grants the right, and only then does access work.
      {:ok, paid} = Orders.mark_order_paid(order.id)
      [fulfillment] = fulfill_order!(paid)

      assert fetched = Fulfillment.get_fulfillment(scope, fulfillment.id)
      assert fetched.id == fulfillment.id

      entitlement = Repo.preload(fulfillment, :entitlement).entitlement
      assert {:ok, access} = Delivery.authorize_access(scope, entitlement.id)
      assert access.access_code =~ @code_format
    end

    test "a delivered purchase is reachable from the buyer's entitlement list", %{
      category: category,
      buyer: buyer
    } do
      granted = granted_entitlement_fixture(buyer, category)

      entitlements = Entitlements.list_for_customer(buyer)

      assert Enum.map(entitlements, & &1.id) == [granted.entitlement.id]

      # The read the web layer leans on already carries the delivery, so
      # authorizing access is a single query rather than a second lookup.
      assert [entitlement] = entitlements
      assert entitlement.fulfillment.id == granted.fulfillment.id

      assert {:ok, %{kind: :digital}} =
               Delivery.authorize_access(buyer, entitlement.id)
    end
  end

  # An elapsed grant is refused by the centralized `Entitlement.active?/1`
  # without any status write, so the expiry is set the way reality sets it: on
  # the row, before anything labels it `:expired`.
  defp expire!(%Entitlement{} = entitlement) do
    entitlement
    |> Ecto.Changeset.change(
      expires_at: DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
    )
    |> Repo.update!()
  end
end
