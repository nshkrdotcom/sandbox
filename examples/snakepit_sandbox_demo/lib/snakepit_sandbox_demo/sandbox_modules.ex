defmodule SnakepitSandboxDemo.SandboxModules do
  @moduledoc "Resolves sandbox-transformed module names."

  def resolve_module(sandbox_id, module) when is_binary(sandbox_id) and is_atom(module) do
    module_name = module_name_without_elixir(module)

    case lookup_mapping(sandbox_id, [module, module_name]) do
      {:ok, mapped} ->
        {:ok, normalize_module_atom(mapped)}

      :not_found ->
        case Sandbox.Manager.get_hot_reload_context(sandbox_id) do
          {:ok, %{module_namespace_prefix: prefix}} when is_binary(prefix) ->
            mapped = :"#{prefix}_#{module_name}"
            {:ok, normalize_module_atom(mapped)}

          _ ->
            {:error, :module_mapping_not_found}
        end
    end
  end

  defp lookup_mapping(sandbox_id, modules) do
    Enum.find_value(modules, :not_found, fn candidate ->
      case Sandbox.ModuleTransformer.lookup_module_mapping(sandbox_id, candidate) do
        {:ok, mapped} -> {:ok, mapped}
        :not_found -> nil
      end
    end)
  end

  defp module_name_without_elixir(module) do
    module
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
    |> String.to_atom()
  end

  defp normalize_module_atom(module) do
    module_str = Atom.to_string(module)

    if String.starts_with?(module_str, "Elixir.") do
      module
    else
      String.to_atom("Elixir." <> module_str)
    end
  end
end
