defmodule Mix.Tasks.Cass.Accounts.CreateAdmin do
  @shortdoc "Grants the :admin role to a CASS account"

  @moduledoc """
  Grants the `:admin` role to an account, registering the account first if it
  does not exist yet.

  This is the bootstrap path for the **first** administrator, so a fresh
  environment has somebody who can use the admin area in later phases. It is a
  CLI task on purpose: there is no HTTP route, no request path, and no way for
  a visitor to reach it. Creating an account is not the same as making it an
  admin, and this task does the two steps explicitly.

  ## Usage

      $ mix cass.accounts.create_admin --email admin@example.com --password "a long passphrase"

  The password can also come from the `CASS_ADMIN_PASSWORD` environment
  variable, which is the better choice on a shared machine: an argument is
  visible in the shell history and in the process list.

      $ CASS_ADMIN_PASSWORD="a long passphrase" mix cass.accounts.create_admin --email admin@example.com

  ## Options

    * `--email` - (required) the account to grant the role to. The account is
      created with this address if it does not exist.
    * `--password` - the password for a newly created account. Required only
      when the account does not exist yet; also read from
      `CASS_ADMIN_PASSWORD`. An existing account's password is never changed.
    * `--force` - required to run with `MIX_ENV=prod`. Without it the task
      refuses to create an admin in production.

  ## Safety

    * The role is only ever applied to the account named by `--email`; nothing
      in the application grants a role to "the first account" or to whoever
      registers next.
    * The task is idempotent: running it again for an address that already has
      the role reports that and changes nothing.
    * The new account is created unconfirmed, which is fine for logging in
      (confirmation only gates the email-change and reset flows). No mail is
      sent.
  """
  use Mix.Task

  alias Cass.Accounts
  alias Cass.Accounts.User

  @requirements ["app.start"]
  @switches [email: :string, password: :string, force: :boolean]
  @aliases [e: :email, p: :password]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv, _invalid} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    with :ok <- ensure_allowed_env(opts),
         {:ok, email} <- fetch_email(opts) do
      grant_admin(email, opts)
    end
  end

  defp grant_admin(email, opts) do
    case Accounts.get_user_by_email(email) do
      %User{} = user ->
        promote(user, "already registered")

      nil ->
        register_and_promote(email, opts)
    end
  end

  defp register_and_promote(email, opts) do
    with {:ok, password} <- fetch_password(opts),
         {:ok, user} <- Accounts.register_user(%{email: email, password: password}) do
      promote(user, "registered (unconfirmed) and")
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        Mix.raise("""
        could not register #{email}:

        #{format_errors(changeset)}
        """)

      {:error, :no_password} ->
        Mix.raise("""
        #{email} does not exist yet, so a password is required to create it.

        Pass --password, or set CASS_ADMIN_PASSWORD. Use at least \
        #{User.password_min_length()} characters.
        """)
    end
  end

  defp promote(user, what) do
    case Accounts.grant_user_role(user, :admin) do
      :ok ->
        Mix.shell().info("#{user.email} (#{what}) now has the :admin role.")
        user

      {:error, %Ecto.Changeset{} = changeset} ->
        Mix.raise(
          "could not grant the :admin role to #{user.email}:\n#{format_errors(changeset)}"
        )
    end
  end

  defp ensure_allowed_env(opts) do
    if Mix.env() == :prod and not Keyword.get(opts, :force, false) do
      Mix.raise("""
      refusing to create an admin with MIX_ENV=prod.

      Re-run with --force once you are sure the address is correct.
      """)
    end

    :ok
  end

  defp fetch_email(opts) do
    case opts[:email] do
      email when is_binary(email) and email != "" -> {:ok, email}
      _email -> Mix.raise("missing required option --email (or -e)")
    end
  end

  defp fetch_password(opts) do
    case opts[:password] || System.get_env("CASS_ADMIN_PASSWORD") do
      password when is_binary(password) and password != "" -> {:ok, password}
      _password -> {:error, :no_password}
    end
  end

  defp format_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
      end)
    end)
    |> Enum.map_join("\n", fn {field, messages} ->
      "  * #{field}: #{Enum.join(messages, ", ")}"
    end)
  end
end
