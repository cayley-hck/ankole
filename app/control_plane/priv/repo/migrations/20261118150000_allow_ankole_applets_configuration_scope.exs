defmodule Ankole.Repo.Migrations.AllowAnkoleAppletsConfigurationScope do
  use Ecto.Migration

  # The ankole_applets system Principal joined the registry without its
  # system:<uid> configuration scope, so its model profile overrides failed this check.
  def up,
    do: replace_scope_check("'system:system', 'system:ankole_brain', 'system:ankole_applets'")

  def down, do: replace_scope_check("'system:system', 'system:ankole_brain'")

  defp replace_scope_check(system_scopes) do
    drop constraint(:app_configurations, :app_configurations_scope_check)

    create constraint(:app_configurations, :app_configurations_scope_check,
             check:
               "scope = 'tenant:' || tenant_id::text OR scope ~ '^agent:.+' OR scope IN (#{system_scopes})"
           )
  end
end
