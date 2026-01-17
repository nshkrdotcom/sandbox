# Module Transformation Guide

This guide provides a comprehensive overview of the module transformation system in the Sandbox library. Module transformation is the core mechanism that enables namespace isolation, allowing multiple sandboxes to run identical module definitions without conflicts.

## Table of Contents

1. [Overview](#overview)
2. [Namespace Isolation](#namespace-isolation)
3. [The Transformation Process](#the-transformation-process)
4. [Virtual Code Tables](#virtual-code-tables)
5. [Handling Aliases and Module References](#handling-aliases-and-module-references)
6. [Module Registry](#module-registry)
7. [Limitations and Considerations](#limitations-and-considerations)
8. [Examples](#examples)
9. [API Reference](#api-reference)

---

## Overview

Module transformation is the process of rewriting Elixir module definitions to include sandbox-specific prefixes. This enables complete isolation between sandboxes, where each sandbox operates in its own namespace without affecting modules in other sandboxes or the host application.

The transformation system consists of two primary components:

- **`Sandbox.ModuleTransformer`** - Handles AST-level transformation of source code
- **`Sandbox.VirtualCodeTable`** - Manages ETS-based storage for compiled modules

### Key Benefits

- **Complete Isolation**: Each sandbox has its own module namespace
- **No Global State Pollution**: Sandbox modules do not affect the host BEAM VM
- **Hot Reload Support**: Modules can be reloaded without affecting other sandboxes
- **Dependency Resolution**: Module mappings enable proper inter-module references

---

## Namespace Isolation

When code runs in a sandbox, all user-defined modules are prefixed with a unique namespace identifier. This prevents module name collisions between:

- Different sandboxes running the same code
- Sandbox modules and host application modules
- Multiple versions of the same module in different sandboxes

### Namespace Format

The transformation creates module names using the following format:

```
Sandbox_<SanitizedSandboxId>_<UniqueHash>_<OriginalModuleName>
```

For example, a module `MyApp.User` in sandbox `test-123` becomes:

```elixir
:"Sandbox_Test_123_847291_MyApp.User"
```

### Sandbox ID Sanitization

Sandbox IDs are sanitized to create valid Elixir module identifiers:

```elixir
# Input                    # Output
"test-123"           ->    "Test_123"
"my_complex-id-456"  ->    "My_Complex_Id_456"
"123abc"             ->    "S123abc"  # Prefixed with 'S' if starts with number
```

Sanitization rules:
- Invalid characters are replaced with underscores
- Parts are capitalized (PascalCase segments)
- If the result starts with a number, it is prefixed with 'S'

---

## The Transformation Process

The transformation process consists of several steps that walk the Abstract Syntax Tree (AST) and rewrite module references.

### Step 1: Parse Source Code

Source code is parsed into an AST using `Code.string_to_quoted/1`:

```elixir
{:ok, ast} = Code.string_to_quoted(source_code)
```

### Step 2: AST Walking

The transformer uses `Macro.prewalk/3` to traverse the AST and transform relevant nodes:

```elixir
{transformed_ast, module_mapping} =
  Macro.prewalk(ast, %{}, fn node, mapping ->
    transform_node(node, namespace_prefix, preserve_stdlib, mapping)
  end)
```

### Step 3: Node Transformation

Three types of AST nodes are transformed:

#### Module Definitions (`defmodule`)

```elixir
# Before AST
{:defmodule, meta, [{:__aliases__, _, [:MyModule]}, do_block]}

# After AST
{:defmodule, meta, [{:__aliases__, _, [:"Sandbox_Test_847291_MyModule"]}, do_block]}
```

#### Alias Statements

```elixir
# Before
{:alias, meta, [{:__aliases__, _, [:MyApp, :User]}]}

# After
{:alias, meta, [{:__aliases__, _, [:"Sandbox_Test_847291_MyApp.User"]}]}
```

#### Module Function Calls

```elixir
# Before: MyModule.function()
{{:., meta1, [{:__aliases__, _, [:MyModule]}, :function]}, meta2, args}

# After: Sandbox_Test_847291_MyModule.function()
{{:., meta1, [{:__aliases__, _, [:"Sandbox_Test_847291_MyModule"]}, :function]}, meta2, args}
```

### Step 4: Code Generation

The transformed AST is converted back to source code:

```elixir
transformed_code = Macro.to_string(transformed_ast)
```

### Standard Library Preservation

By default, standard library modules are NOT transformed. This ensures that calls to `Enum`, `String`, `GenServer`, etc. continue to work correctly.

The following module prefixes are preserved:
- `Kernel`, `GenServer`, `Agent`, `Task`, `Supervisor`
- `Process`, `System`, `File`, `Path`
- `String`, `Enum`, `Stream`, `Map`, `List`
- `IO`, `Logger`, `Mix`, `ExUnit`
- And other core Elixir/Erlang modules

---

## Virtual Code Tables

Virtual code tables provide ETS-based storage for compiled BEAM modules within a sandbox. This allows efficient lookup and management of module bytecode.

### Creating a Virtual Code Table

```elixir
{:ok, table_ref} = Sandbox.VirtualCodeTable.create_table("my_sandbox", [
  access: :public,
  read_concurrency: true,
  write_concurrency: false
])
```

### Table Structure

Each entry in the virtual code table contains:

```elixir
{module_name, %{
  beam_data: <<binary>>,           # Compiled BEAM bytecode
  loaded_at: monotonic_timestamp,  # When the module was loaded
  size: byte_size,                 # Size of the bytecode
  checksum: sha256_hash,           # SHA-256 checksum for verification
  metadata: %{                     # Optional extracted metadata
    attributes: %{...},
    exports: [...],
    imports: [...],
    compile_info: %{...}
  }
}}
```

### Loading Modules

```elixir
# Load a compiled module into the table
:ok = Sandbox.VirtualCodeTable.load_module(
  "my_sandbox",
  MyTransformedModule,
  beam_data,
  force_reload: false,
  extract_metadata: true
)
```

### Fetching Modules

```elixir
{:ok, module_info} = Sandbox.VirtualCodeTable.fetch_module("my_sandbox", MyModule)
# module_info.beam_data contains the BEAM bytecode
```

### Listing All Modules

```elixir
{:ok, modules} = Sandbox.VirtualCodeTable.list_modules("my_sandbox",
  include_metadata: true,
  sort_by: :loaded_at
)
```

### Table Statistics

```elixir
{:ok, stats} = Sandbox.VirtualCodeTable.get_table_stats("my_sandbox")
# Returns: %{
#   table_name: :sandbox_virtual_code_my_sandbox,
#   module_count: 5,
#   total_size: 45_000,
#   memory_usage: 52_000,
#   ...
# }
```

---

## Handling Aliases and Module References

The transformer handles various forms of module references in Elixir code.

### Direct Module References

```elixir
# Original
MyModule.hello()

# Transformed
Sandbox_Test_847291_MyModule.hello()
```

### Alias Statements

```elixir
# Original
alias MyApp.Users.Admin

# Transformed
alias Sandbox_Test_847291_MyApp.Users.Admin
```

### Multi-Part Module Names

Nested module names are transformed as a unit:

```elixir
# Original
defmodule MyApp.Web.Controllers.UserController do
  # ...
end

# Transformed
defmodule Sandbox_Test_847291_MyApp.Web.Controllers.UserController do
  # ...
end
```

### Module Attribute References

Module references in attributes are also transformed:

```elixir
# Original
@behaviour MyApp.Behaviour

# Note: Behaviour modules need special handling if they are sandbox-local
```

---

## Module Registry

The module transformer maintains a bidirectional registry mapping between original and transformed module names.

### Creating the Registry

```elixir
table = Sandbox.ModuleTransformer.create_module_registry("my_sandbox")
```

### Registering Mappings

```elixir
Sandbox.ModuleTransformer.register_module_mapping(
  "my_sandbox",
  MyApp.User,                        # Original name
  :"Sandbox_Test_847291_MyApp.User"  # Transformed name
)
```

### Looking Up Mappings

```elixir
# Forward lookup (original -> transformed)
{:ok, transformed} = Sandbox.ModuleTransformer.lookup_module_mapping(
  "my_sandbox",
  MyApp.User
)

# Reverse lookup (transformed -> original)
{:ok, original} = Sandbox.ModuleTransformer.lookup_module_mapping(
  "my_sandbox",
  :"Sandbox_Test_847291_MyApp.User"
)
```

### Reverse Transformation

To get the original module name from a transformed name:

```elixir
original = Sandbox.ModuleTransformer.reverse_transform_module_name(
  :"Sandbox_Test_123_MyModule",
  "test-123"
)
# Returns: :MyModule
```

---

## Limitations and Considerations

### Known Limitations

1. **Macro Expansion Order**: Macros are expanded before transformation. If a macro generates module references, those references may not be transformed correctly.

2. **Dynamic Module Creation**: Modules created dynamically at runtime using `Module.create/3` are not automatically transformed.

3. **External Dependencies**: Modules from external dependencies (Hex packages) are not transformed. They run in the global namespace.

4. **Erlang Modules**: Erlang modules (atoms starting with lowercase) are not transformed.

5. **Protocol Implementations**: Protocol implementations require special handling to ensure the protocol can find the implementation.

### Performance Considerations

- **AST Walking**: Transformation requires parsing and walking the entire AST, which adds compilation overhead.
- **ETS Lookup**: Module lookups from virtual code tables are O(1) but add slight overhead compared to native BEAM code loading.
- **Memory Usage**: Each sandbox maintains its own ETS tables, increasing memory footprint.

### Best Practices

1. **Unique Sandbox IDs**: Always use unique sandbox IDs to prevent namespace collisions.

2. **Clean Up Resources**: Always destroy virtual code tables and module registries when a sandbox is terminated:

```elixir
Sandbox.VirtualCodeTable.destroy_table("my_sandbox")
Sandbox.ModuleTransformer.destroy_module_registry("my_sandbox")
```

3. **Preserve Standard Library**: Keep `preserve_stdlib: true` (the default) to ensure standard library modules work correctly.

4. **Handle Errors**: Always handle transformation errors gracefully:

```elixir
case Sandbox.ModuleTransformer.transform_source(code, sandbox_id) do
  {:ok, transformed, mapping} ->
    # Continue with compilation
  {:error, {:parse_error, line, error, token}} ->
    # Handle syntax error
  {:error, {:transformation_error, error}} ->
    # Handle transformation failure
end
```

---

## Examples

### Complete Transformation Example

**Original Source Code:**

```elixir
defmodule MyApp.Calculator do
  @moduledoc "A simple calculator module"

  alias MyApp.Utils.Math

  def add(a, b) do
    Math.sum(a, b)
  end

  def multiply(a, b) do
    Enum.reduce(1..b, 0, fn _, acc -> add(acc, a) end)
  end
end

defmodule MyApp.Utils.Math do
  def sum(a, b), do: a + b
end
```

**Transformed Source Code (sandbox ID: "calc-sandbox"):**

```elixir
defmodule Sandbox_Calc_Sandbox_847291_MyApp.Calculator do
  @moduledoc "A simple calculator module"

  alias Sandbox_Calc_Sandbox_847291_MyApp.Utils.Math

  def add(a, b) do
    Sandbox_Calc_Sandbox_847291_MyApp.Utils.Math.sum(a, b)
  end

  def multiply(a, b) do
    Enum.reduce(1..b, 0, fn _, acc -> add(acc, a) end)
  end
end

defmodule Sandbox_Calc_Sandbox_847291_MyApp.Utils.Math do
  def sum(a, b), do: a + b
end
```

Note that:
- Both module definitions are prefixed
- The alias is transformed
- The `Math.sum/2` call is transformed
- `Enum.reduce/3` is NOT transformed (standard library)

### Using the Transformation API

```elixir
# Transform source code
source = """
defmodule Counter do
  use GenServer

  def start_link(initial) do
    GenServer.start_link(__MODULE__, initial)
  end

  def init(count), do: {:ok, count}

  def increment(pid) do
    GenServer.call(pid, :increment)
  end

  def handle_call(:increment, _from, count) do
    {:reply, count + 1, count + 1}
  end
end
"""

{:ok, transformed, mapping} = Sandbox.ModuleTransformer.transform_source(
  source,
  "counter-sandbox",
  preserve_stdlib: true
)

# The mapping shows the transformation
IO.inspect(mapping)
# %{Counter => :"Sandbox_Counter_Sandbox_123456_Counter"}

# Transform a single module name
transformed_name = Sandbox.ModuleTransformer.transform_module_name(
  MyModule,
  "test-sandbox"
)
# :"Sandbox_Test_Sandbox_789012_MyModule"
```

### Virtual Code Table Workflow

```elixir
sandbox_id = "my-sandbox"

# 1. Create the virtual code table
{:ok, _table} = Sandbox.VirtualCodeTable.create_table(sandbox_id)

# 2. Transform and compile source code
{:ok, transformed, _mapping} = Sandbox.ModuleTransformer.transform_source(
  source_code,
  sandbox_id
)

# 3. Compile the transformed code (using Elixir compiler)
{:ok, modules, _warnings} = Code.compile_string(transformed)

# 4. Load compiled modules into virtual code table
for {module, beam_data} <- modules do
  :ok = Sandbox.VirtualCodeTable.load_module(sandbox_id, module, beam_data)
end

# 5. Later, fetch modules as needed
{:ok, module_info} = Sandbox.VirtualCodeTable.fetch_module(sandbox_id, transformed_module)

# 6. Get statistics
{:ok, stats} = Sandbox.VirtualCodeTable.get_table_stats(sandbox_id)
IO.puts("Loaded #{stats.module_count} modules, total size: #{stats.total_size} bytes")

# 7. Clean up when done
:ok = Sandbox.VirtualCodeTable.destroy_table(sandbox_id)
```

---

## API Reference

### Sandbox.ModuleTransformer

| Function | Description |
|----------|-------------|
| `transform_source/3` | Transform Elixir source code to use sandbox-specific module names |
| `transform_module_name/3` | Transform a single module name to include sandbox prefix |
| `reverse_transform_module_name/2` | Get the original name from a transformed module name |
| `create_module_registry/2` | Create an ETS-based module mapping registry |
| `register_module_mapping/4` | Register a bidirectional module mapping |
| `lookup_module_mapping/3` | Look up a module mapping |
| `destroy_module_registry/2` | Destroy the module registry for a sandbox |
| `sanitize_sandbox_id/1` | Sanitize a sandbox ID to be a valid Elixir identifier |
| `create_unique_namespace/1` | Create a globally unique namespace prefix |

### Sandbox.VirtualCodeTable

| Function | Description |
|----------|-------------|
| `create_table/2` | Create a virtual code table for a sandbox |
| `load_module/4` | Load a compiled module into the table |
| `fetch_module/3` | Fetch a module from the table |
| `list_modules/2` | List all modules in the table |
| `unload_module/3` | Remove a module from the table |
| `destroy_table/2` | Destroy the virtual code table |
| `get_table_stats/2` | Get statistics about the table |

---

## See Also

- `Sandbox.Manager` - High-level sandbox lifecycle management
- `Sandbox.IsolatedCompiler` - Compilation in isolated environments
- `Sandbox.ProcessIsolator` - Process-level isolation
