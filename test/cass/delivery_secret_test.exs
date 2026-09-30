defmodule Cass.DeliverySecretTest do
  @moduledoc """
  The signing secret behind the digital access code.

  These tests live in their own **serial** module because they are the only
  place in the suite that rewrites `:cass, Cass.Delivery` — the signing secret
  is application-wide state, so running them beside anything else that derives
  a code would race them into reading a half-rotated configuration. ExUnit
  cannot tag a single test serial, and making the whole `Cass.DeliveryTest`
  module serial would slow down tests that never touch the configuration, so
  the two concerns are split instead.
  """
  use Cass.DataCase, async: false

  import Cass.AccountsFixtures
  import Cass.CommerceFixtures

  alias Cass.Accounts.Scope
  alias Cass.Delivery

  setup do
    buyer = Scope.for_user(user_fixture())
    granted = granted_entitlement_fixture(buyer, category_fixture())

    # Captured once, because a rotation deletes the key: reading the live
    # environment on each rotation would try to restore a configuration that
    # the previous rotation had already replaced.
    config = Application.fetch_env!(:cass, Cass.Delivery)
    on_exit(fn -> Application.put_env(:cass, Cass.Delivery, config) end)

    %{buyer: buyer, entitlement: granted.entitlement, config: config}
  end

  test "rotating the server secret rotates the access code", %{
    buyer: buyer,
    entitlement: entitlement,
    config: config
  } do
    assert {:ok, original} = Delivery.authorize_access(buyer, entitlement.id)

    rotate_access_secret(config, String.duplicate("z", 43))

    assert {:ok, rotated} = Delivery.authorize_access(buyer, entitlement.id)

    # This is what makes a code unforgeable without the secret: the code is a
    # function of the server's secret as much as of the purchase, so it cannot
    # be reproduced or predicted off-server.
    assert rotated.access_code != original.access_code

    # The same purchase still derives one stable code under the new secret.
    assert {:ok, again} = Delivery.authorize_access(buyer, entitlement.id)
    assert again.access_code == rotated.access_code
  end

  test "a missing or short secret fails loudly instead of issuing a credential", %{
    buyer: buyer,
    entitlement: entitlement,
    config: config
  } do
    for bad_secret <- [nil, "", "too-short"] do
      rotate_access_secret(config, bad_secret)

      assert_raise RuntimeError, ~r/not configured/, fn ->
        Delivery.authorize_access(buyer, entitlement.id)
      end
    end

    # With the real secret back, the same purchase issues normally — proving the
    # failures above were the missing configuration, not a broken purchase. (The
    # suite-wide restore is `on_exit`; this restores within the test so the
    # property is asserted here rather than assumed.)
    rotate_access_secret(config, Keyword.fetch!(config, :access_secret))

    assert {:ok, restored} = Delivery.authorize_access(buyer, entitlement.id)
    assert restored.access_code =~ ~r/^[0-9A-HJKMNP-TV-Z]{4}-/
  end

  defp rotate_access_secret(_config, nil), do: Application.delete_env(:cass, Cass.Delivery)

  defp rotate_access_secret(config, secret) do
    Application.put_env(:cass, Cass.Delivery, Keyword.put(config, :access_secret, secret))
  end
end
