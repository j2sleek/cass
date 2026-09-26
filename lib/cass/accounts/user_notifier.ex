defmodule Cass.Accounts.UserNotifier do
  @moduledoc """
  Transactional account emails, delivered through `Cass.Mailer` (Swoosh).

  No external email provider is wired up yet: development uses Swoosh's local
  adapter (browse `/dev/mailbox`) and tests use the test adapter. Selecting a
  real provider in production is a deployment concern and is documented as
  deferred in `docs/security.md`. Bodies are plain text and never contain
  anything but the recipient's own address and the single-use link.
  """
  import Swoosh.Email

  alias Cass.Accounts.User
  alias Cass.Mailer

  @from_name "CASS Marketplace"
  @from_email "no-reply@example.com"

  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({@from_name, @from_email})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc "Delivers instructions to confirm a newly registered account."
  def deliver_confirmation_instructions(%User{} = user, url) do
    deliver(user.email, "Confirm your CASS account", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    This link can be used once and expires in a few days. If you did not create
    an account with us, you can ignore this email.

    ==============================
    """)
  end

  @doc "Delivers instructions to confirm a new email address."
  def deliver_update_email_instructions(%User{} = user, url) do
    deliver(user.email, "Confirm your new CASS email address", """

    ==============================

    Hi #{user.email},

    You can confirm the new email address for your account by visiting the URL
    below:

    #{url}

    If you did not request this change, please ignore this email.

    ==============================
    """)
  end

  @doc "Delivers instructions to reset a forgotten password."
  def deliver_reset_password_instructions(%User{} = user, url) do
    deliver(user.email, "Reset your CASS password", """

    ==============================

    Hi #{user.email},

    You can reset your password by visiting the URL below:

    #{url}

    This link can be used once and expires in #{Cass.Accounts.UserToken.reset_password_validity_in_hours()} hour. If you did not
    request a password reset, you can ignore this email — your password has not
    changed.

    ==============================
    """)
  end
end
