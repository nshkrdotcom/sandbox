# Sandbox Compilation Guide

This guide provides comprehensive documentation for the Sandbox library's compilation system, covering compilation backends, incremental compilation, caching strategies, configuration options, error handling, performance optimization, and security considerations.

## Table of Contents

1. [Overview](#overview)
2. [Compilation Backends](#compilation-backends)
3. [Incremental Compilation and Caching](#incremental-compilation-and-caching)
4. [Compile-time Options and Configuration](#compile-time-options-and-configuration)
5. [Handling Compilation Errors](#handling-compilation-errors)
6. [Performance Considerations](#performance-considerations)
7. [Security Considerations](#security-considerations)
8. [Examples](#examples)

---

## Overview

The Sandbox compilation system provides isolated, secure compilation of Elixir code with support for multiple compilation backends, incremental compilation, and comprehensive resource management. The system is designed to prevent sandbox compilation failures from affecting the host system or other sandboxes.

### Key Components

The compilation system consists of two primary modules:

- **`Sandbox.IsolatedCompiler`**: The main compilation orchestrator that handles isolated compilation with resource limits, timeout controls, security scanning, and caching.
- **`Sandbox.InProcessCompiler`**: An alternative compilation strategy that compiles Elixir code in-process without spawning external executables.

### Architecture Overview

<svg viewBox="0 0 480 300" xmlns="http://www.w3.org/2000/svg" style="max-width: 480px; font-family: system-ui, -apple-system, sans-serif;">
  <defs>
    <marker id="comp-arrow" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto">
      <polygon points="0 0, 10 3.5, 0 7" fill="#64748b"/>
    </marker>
  </defs>

  <!-- Sandbox.compile_* -->
  <rect x="140" y="16" width="200" height="44" rx="6" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="240" y="44" text-anchor="middle" font-size="12" font-weight="600" fill="#1e40af">Sandbox.compile_*</text>

  <!-- Arrow down -->
  <line x1="240" y1="60" x2="240" y2="88" stroke="#64748b" stroke-width="1.5" marker-end="url(#comp-arrow)"/>

  <!-- IsolatedCompiler -->
  <rect x="100" y="96" width="280" height="88" rx="6" fill="#f8fafc" stroke="#e2e8f0" stroke-width="1.5"/>
  <text x="240" y="120" text-anchor="middle" font-size="12" font-weight="600" fill="#334155">IsolatedCompiler</text>
  <line x1="120" y1="132" x2="360" y2="132" stroke="#e2e8f0" stroke-width="1"/>
  <text x="240" y="150" text-anchor="middle" font-size="10" fill="#64748b">• Resource monitoring</text>
  <text x="240" y="166" text-anchor="middle" font-size="10" fill="#64748b">• Security scanning  •  Cache management</text>

  <!-- Arrow down splitting -->
  <line x1="240" y1="184" x2="240" y2="208" stroke="#64748b" stroke-width="1.5"/>

  <!-- Horizontal connector -->
  <line x1="100" y1="208" x2="380" y2="208" stroke="#64748b" stroke-width="1.5"/>

  <!-- Vertical connectors to backends -->
  <line x1="100" y1="208" x2="100" y2="228" stroke="#64748b" stroke-width="1.5" marker-end="url(#comp-arrow)"/>
  <line x1="240" y1="208" x2="240" y2="228" stroke="#64748b" stroke-width="1.5" marker-end="url(#comp-arrow)"/>
  <line x1="380" y1="208" x2="380" y2="228" stroke="#64748b" stroke-width="1.5" marker-end="url(#comp-arrow)"/>

  <!-- Backend boxes -->
  <rect x="48" y="236" width="104" height="44" rx="6" fill="#f0fdf4" stroke="#10b981" stroke-width="1.5"/>
  <text x="100" y="264" text-anchor="middle" font-size="11" font-weight="500" fill="#047857">:mix</text>

  <rect x="188" y="236" width="104" height="44" rx="6" fill="#fef3c7" stroke="#f59e0b" stroke-width="1.5"/>
  <text x="240" y="264" text-anchor="middle" font-size="11" font-weight="500" fill="#b45309">:elixirc</text>

  <rect x="328" y="236" width="104" height="44" rx="6" fill="#fce7f3" stroke="#ec4899" stroke-width="1.5"/>
  <text x="380" y="264" text-anchor="middle" font-size="11" font-weight="500" fill="#be185d">:in_process</text>
</svg>

---

## Compilation Backends

The Sandbox library supports three compilation backends, each suited for different use cases.

### Mix Backend (`:mix`)

The default backend that uses the Mix build tool for compilation. This is the most feature-complete option, supporting all Mix project features including dependencies, configuration, and compilation options.

```elixir
# Default compilation using Mix
{:ok, compile_info} = Sandbox.IsolatedCompiler.compile_sandbox("/path/to/sandbox")

# Explicitly specifying Mix backend
{:ok, compile_info} = Sandbox.IsolatedCompiler.compile_sandbox("/path/to/sandbox",
  compiler: :mix
)
```

**Characteristics:**
- Full Mix project support
- Dependency resolution
- Application configuration
- Spawns external process for isolation
- Best for complete Mix projects

**Build Environment:**
The Mix backend sets up an isolated build environment:

```elixir
%{
  "MIX_BUILD_PATH" => temp_dir,
  "MIX_ARCHIVES" => "",
  "MIX_DEPS_PATH" => Path.join(temp_dir, "deps"),
  "HOME" => temp_dir,
  "TMPDIR" => temp_dir,
  "MIX_INSTALL_FORCE" => "false",
  "MIX_INSTALL_DIR" => temp_dir
}
```

### Elixirc Backend (`:elixirc`)

Uses the `elixirc` compiler directly for simpler compilation scenarios. This is faster than Mix for projects without complex dependencies.

```elixir
# Compile using elixirc
{:ok, compile_info} = Sandbox.IsolatedCompiler.compile_sandbox("/path/to/sandbox",
  compiler: :elixirc
)

# Compile specific files
{:ok, compile_info} = Sandbox.IsolatedCompiler.compile_sandbox("/path/to/sandbox",
  compiler: :elixirc,
  source_files: ["lib/my_module.ex", "lib/another_module.ex"]
)
```

**Characteristics:**
- Faster startup than Mix
- No dependency resolution
- Direct compilation to BEAM files
- Suitable for single-file or simple multi-file compilations

### In-Process Backend (`:in_process`)

Compiles code within the same Erlang VM using Elixir's compiler APIs. This eliminates the overhead of spawning external processes and is ideal for frequent, small compilations.

```elixir
# Explicit in-process compilation
{:ok, compile_info} = Sandbox.IsolatedCompiler.compile_sandbox("/path/to/sandbox",
  in_process: true
)

# Using InProcessCompiler directly
alias Sandbox.InProcessCompiler

{:ok, result} = InProcessCompiler.compile_in_process(
  "/path/to/source",
  "/path/to/output"
)
```

**Characteristics:**
- No process spawn overhead
- Uses global compile lock for thread safety
- Supports parallel compilation option
- Best for hot-reload scenarios

#### In-Process Compilation Options

```elixir
InProcessCompiler.compile_in_process(source_path, output_path,
  debug_info: true,           # Include debug information in BEAM files
  parallel: true,             # Enable parallel compilation
  source_files: ["file.ex"]   # Specific files to compile
)
```

#### Compiling from String

The `InProcessCompiler` can compile code directly from a string:

```elixir
source_code = """
defmodule MyModule do
  def hello, do: :world
end
"""

{:ok, modules} = InProcessCompiler.compile_string(source_code, "my_module.ex", "/output/path")
# => {:ok, [MyModule]}
```

#### Loading BEAM Files

After compilation, BEAM files can be loaded into the VM:

```elixir
{:ok, loaded_modules} = InProcessCompiler.load_beam_files([
  "/path/to/MyModule.beam",
  "/path/to/AnotherModule.beam"
])
```

---

## Incremental Compilation and Caching

The Sandbox compiler supports incremental compilation to minimize recompilation time when only a subset of files have changed.

### Enabling Incremental Compilation

```elixir
# Enable incremental compilation
{:ok, compile_info} = Sandbox.IsolatedCompiler.compile_sandbox("/path/to/sandbox",
  incremental: true,
  cache_enabled: true
)

# Use the dedicated incremental_compile function
{:ok, compile_info} = Sandbox.IsolatedCompiler.incremental_compile("/path/to/sandbox")
```

### How Incremental Compilation Works

1. **File Hash Tracking**: The compiler maintains SHA-256 hashes of both file content and function-level structure.

2. **Change Detection**: On subsequent compilations, the compiler compares current file hashes against cached values.

3. **Dependency Analysis**: When changes are detected, the compiler analyzes module dependencies to determine the full compilation scope.

4. **Compilation Strategy Selection**: Based on the analysis, the compiler chooses between:
   - `:cache_hit` - No changes detected, return cached result
   - `:incremental` - Compile only changed files and dependents
   - `:full` - Full recompilation required

### Cache Structure

The compilation cache is stored in a `.sandbox_cache` directory within the sandbox:

```
/path/to/sandbox/
  .sandbox_cache/
    file_hashes.json       # File content and function hashes
    last_compilation.json  # Previous compilation result
    dependency_graph.json  # Module dependency analysis
    cache_stats.json       # Cache performance statistics
```

### Cache Management

```elixir
# Get cache statistics
{:ok, stats} = Sandbox.IsolatedCompiler.get_cache_statistics("/path/to/sandbox")
# => %{
#      total_compilations: 15,
#      incremental_compilations: 12,
#      cache_hits: 8,
#      cache_hit_rate: 0.53,
#      incremental_rate: 0.8,
#      average_compilation_time: 450
#    }

# Clear the compilation cache
:ok = Sandbox.IsolatedCompiler.clear_compilation_cache("/path/to/sandbox")
```

### Compilation Scope Expansion

When a file changes, the compiler analyzes dependencies to determine all affected files:

```elixir
# Example: If ModuleA changes and ModuleB imports ModuleA,
# both will be included in the compilation scope

# Automatic dependency analysis
{:ok, result} = Sandbox.IsolatedCompiler.incremental_compile("/path/to/sandbox",
  [],
  dependency_analysis: true
)

# The result shows which files were compiled
result.changed_files        # Files that changed
result.original_changed_files  # Original changed files before scope expansion
result.compilation_strategy    # :incremental or :full
```

### Function-Level Change Detection

The compiler performs AST analysis to detect function-level changes, enabling more precise incremental compilation:

```elixir
# Only function bodies changed - enables optimized compilation
# Structure changes (new functions, changed signatures) trigger broader recompilation
```

---

## Compile-time Options and Configuration

### Core Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:timeout` | integer | 30,000 | Maximum compilation time in milliseconds |
| `:memory_limit` | integer | 256MB | Memory limit in bytes |
| `:temp_dir` | string | auto | Custom temporary directory for build artifacts |
| `:validate_beams` | boolean | true | Validate BEAM files after compilation |
| `:compiler` | atom | `:mix` | Compiler backend (`:mix`, `:elixirc`, `:in_process`) |
| `:env` | map | `%{}` | Environment variables for compilation |

### Incremental Compilation Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:incremental` | boolean | false | Enable incremental compilation mode |
| `:force_recompile` | boolean | false | Force full recompilation, bypassing cache |
| `:cache_enabled` | boolean | true | Enable compilation caching |
| `:skip_cache` | boolean | false | Skip cache lookup but still update cache |
| `:dependency_analysis` | boolean | true | Analyze dependencies for scope expansion |

### Resource Limit Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:cpu_limit` | float | 80.0 | CPU usage limit percentage |
| `:max_processes` | integer | 100 | Maximum spawned processes |

### Security Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:security_scan` | boolean | true | Enable pre-compilation security scanning |
| `:restricted_modules` | list | see below | Modules that are not allowed |
| `:allowed_operations` | list | `[]` | Whitelist of allowed operations |

### Complete Configuration Example

```elixir
{:ok, compile_info} = Sandbox.IsolatedCompiler.compile_sandbox("/path/to/sandbox",
  # Core options
  timeout: 60_000,
  memory_limit: 512 * 1024 * 1024,
  compiler: :mix,
  validate_beams: true,

  # Incremental compilation
  incremental: true,
  cache_enabled: true,
  dependency_analysis: true,

  # Resource limits
  cpu_limit: 50.0,
  max_processes: 50,

  # Security
  security_scan: true,
  restricted_modules: [:os, :file, System, Code],

  # Environment
  env: %{
    "MIX_ENV" => "prod",
    "CUSTOM_VAR" => "value"
  }
)
```

---

## Handling Compilation Errors

The compilation system provides detailed error information through structured error tuples.

### Error Types

```elixir
@type compile_error ::
  {:compilation_failed, exit_code :: non_neg_integer(), output :: String.t()}
  | {:compilation_timeout, timeout :: non_neg_integer()}
  | {:compiler_crash, kind :: atom(), error :: any()}
  | {:compiler_crash, kind :: atom(), error :: any(), context :: map()}
  | {:invalid_sandbox_path, path :: String.t()}
  | {:beam_validation_failed, reason :: String.t()}
  | {:resource_limit_exceeded, limit_type :: atom(), details :: map()}
  | {:resource_monitor_failed, reason :: any()}
  | {:security_threats_detected, threats :: list()}
  | {:security_scan_failed, reason :: any()}
```

### Error Handling Examples

```elixir
case Sandbox.IsolatedCompiler.compile_sandbox("/path/to/sandbox") do
  {:ok, compile_info} ->
    IO.puts("Compiled #{length(compile_info.beam_files)} files in #{compile_info.compilation_time}ms")

  {:error, {:compilation_failed, exit_code, output}} ->
    IO.puts("Compilation failed with exit code #{exit_code}")
    IO.puts("Output: #{output}")

  {:error, {:compilation_timeout, timeout}} ->
    IO.puts("Compilation timed out after #{timeout}ms")

  {:error, {:invalid_sandbox_path, path}} ->
    IO.puts("Invalid sandbox path: #{path}")

  {:error, {:security_threats_detected, threats}} ->
    IO.puts("Security threats detected:")
    Enum.each(threats, fn threat ->
      IO.puts("  - #{threat.file}:#{threat.line} - #{threat.message}")
    end)

  {:error, {:resource_limit_exceeded, :memory_limit, details}} ->
    IO.puts("Memory limit exceeded: #{details.current} > #{details.limit}")

  {:error, reason} ->
    IO.puts("Compilation failed: #{inspect(reason)}")
end
```

### Compilation Reports

Generate structured reports from compilation results:

```elixir
result = Sandbox.IsolatedCompiler.compile_sandbox("/path/to/sandbox")
report = Sandbox.IsolatedCompiler.compilation_report(result)

# Success report
%{
  status: :success,
  summary: "Compilation successful (1234ms)",
  details: "...",
  metrics: %{
    compilation_time: 1234,
    beam_files_count: 5,
    output_size: 2048
  }
}

# Failure report
%{
  status: :failure,
  summary: "Compilation failed: Exit code 1",
  details: "** (CompileError) lib/my_module.ex:10: undefined function foo/0",
  metrics: %{compilation_time: 0, beam_files_count: 0}
}
```

### Handling Warnings

Compilation warnings are captured and returned in the compile result:

```elixir
{:ok, compile_info} = Sandbox.IsolatedCompiler.compile_sandbox("/path/to/sandbox")

Enum.each(compile_info.warnings, fn warning ->
  IO.puts("Warning in #{warning.file}:#{warning.line}")
  IO.puts("  #{warning.message}")
end)
```

---

## Performance Considerations

### Choosing the Right Backend

| Scenario | Recommended Backend | Rationale |
|----------|-------------------|-----------|
| Full Mix project | `:mix` | Complete feature support |
| Simple modules | `:elixirc` | Faster startup |
| Hot reload | `:in_process` | No spawn overhead |
| Frequent small changes | `:in_process` | Minimal latency |
| Untrusted code | `:mix` or `:elixirc` | Better isolation |

### Optimizing Incremental Compilation

1. **Enable caching for repeated compilations:**

```elixir
Sandbox.IsolatedCompiler.compile_sandbox(path,
  incremental: true,
  cache_enabled: true
)
```

2. **Use dependency analysis wisely:**

```elixir
# For isolated modules without dependencies
Sandbox.IsolatedCompiler.incremental_compile(path, [],
  dependency_analysis: false
)

# For interconnected modules
Sandbox.IsolatedCompiler.incremental_compile(path, [],
  dependency_analysis: true
)
```

3. **Specify changed files when known:**

```elixir
# Skip change detection when you know what changed
Sandbox.IsolatedCompiler.incremental_compile(path,
  ["lib/changed_module.ex"],
  dependency_analysis: true
)
```

### Resource Monitoring

The compilation system monitors resources in real-time:

```elixir
# Configure resource limits
Sandbox.IsolatedCompiler.compile_sandbox(path,
  memory_limit: 256 * 1024 * 1024,  # 256MB
  cpu_limit: 50.0,                   # 50% CPU
  max_processes: 100,                # Max 100 processes
  timeout: 30_000                    # 30 second timeout
)
```

Resource monitoring provides early warning before limits are exceeded:
- Warning at 80% of memory limit
- Warning at 80% of CPU limit
- Violation notification after 3 consecutive warnings

### Parallel Compilation

For in-process compilation with multiple files:

```elixir
Sandbox.InProcessCompiler.compile_in_process(source_path, output_path,
  parallel: true  # Uses Kernel.ParallelCompiler
)
```

Note: Parallel compilation is automatically disabled for single files or when fewer than 2 files are being compiled.

### Cleanup

Always clean up temporary artifacts after compilation:

```elixir
{:ok, compile_info} = Sandbox.IsolatedCompiler.compile_sandbox(path)

# Use the compiled artifacts...

# Then clean up
Sandbox.IsolatedCompiler.cleanup_temp_artifacts(compile_info.temp_dir)
```

---

## Security Considerations

### Pre-Compilation Security Scanning

The compiler performs security scans before compilation to detect potentially dangerous code patterns.

```elixir
# Scan code for security issues
{:ok, scan_result} = Sandbox.IsolatedCompiler.scan_code_security("/path/to/sandbox",
  restricted_modules: [:os, :file, System, Code],
  allowed_operations: [:file_read],  # Whitelist mode
  scan_depth: 3
)

# Check results
if scan_result.threats != [] do
  IO.puts("Security threats detected:")
  Enum.each(scan_result.threats, &IO.inspect/1)
end

if scan_result.warnings != [] do
  IO.puts("Security warnings:")
  Enum.each(scan_result.warnings, &IO.inspect/1)
end
```

### Default Restricted Modules

The following modules are restricted by default:

```elixir
[
  :os,       # Erlang OS module
  :file,     # Erlang file module
  :code,     # Erlang code loading
  :erlang,   # Low-level Erlang functions
  System,    # Elixir system functions
  File,      # Elixir file operations
  Code,      # Elixir code evaluation
  Port       # External port communication
]
```

### Dangerous Operations Detection

The security scanner detects various dangerous patterns:

**High Risk Operations:**
- System command execution (`System.cmd`, `System.shell`, `:os.cmd`)
- Code evaluation (`Code.eval_*`)
- File deletion (`File.rm_rf!`)
- System halt (`:erlang.halt`, `:init.stop`)

**Medium Risk Operations:**
- File writing (`File.write`)
- Network access (`:gen_tcp`, `:gen_udp`, HTTP clients)
- Process spawning (`spawn`, `Task.start`)
- Database operations

**Low Risk Operations:**
- File reading
- Path operations
- Process introspection

### Security Severity Levels

```elixir
# Scan results include severity levels
%{
  type: :dangerous_operation,
  severity: :high,  # :critical, :high, :medium, :low
  operation: :system_command,
  file: "lib/dangerous.ex",
  line: 15,
  message: "System command execution detected [HIGH RISK]",
  context: %{surrounding_code: "...", matched_text: "System.cmd"}
}
```

### BEAM File Validation

After compilation, BEAM files are validated for integrity:

```elixir
# Validate compiled BEAM files
:ok = Sandbox.IsolatedCompiler.validate_compilation(compile_info.beam_files)

# Or validate specific files
:ok = Sandbox.IsolatedCompiler.validate_beam_files([
  "/path/to/Module1.beam",
  "/path/to/Module2.beam"
])
```

### Isolated Compilation Environment

The compiler sets up isolated directories and restricted PATH:

```elixir
# Isolated directories created:
# - temp_dir/home
# - temp_dir/tmp
# - temp_dir/cache

# Restricted PATH includes only:
# - /usr/bin
# - /bin
# - Elixir/Erlang executable paths
```

### Path Safety Validation

The compiler validates sandbox paths to prevent directory traversal:

```elixir
# Dangerous patterns are blocked:
# - ".." (parent directory traversal)
# - "/etc", "/usr", "/bin", "/sbin", "/root" (system directories)

# Safe paths typically include:
# - Paths within System.tmp_dir!()
# - Paths containing "sandbox" or "test"
```

### Post-Compilation Security Checks

After compilation, the system checks for suspicious artifacts:

```elixir
# Suspicious patterns detected:
# - *.sh (shell scripts)
# - *.bat (batch files)
# - *.exe (executables)
# - Files in tmp/ or cache/ directories
```

---

## Examples

### Example 1: Basic Compilation

```elixir
defmodule MyApp.CodeCompiler do
  alias Sandbox.IsolatedCompiler

  def compile_user_code(source_path) do
    case IsolatedCompiler.compile_sandbox(source_path,
      timeout: 30_000,
      validate_beams: true
    ) do
      {:ok, compile_info} ->
        IO.puts("Compiled successfully in #{compile_info.compilation_time}ms")
        IO.puts("Generated #{length(compile_info.beam_files)} BEAM files")
        {:ok, compile_info}

      {:error, reason} ->
        IO.puts("Compilation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
```

### Example 2: Incremental Compilation with Hot Reload

```elixir
defmodule MyApp.HotReloader do
  alias Sandbox.IsolatedCompiler
  alias Sandbox.InProcessCompiler

  def reload_changed_modules(sandbox_path, sandbox_id) do
    # Perform incremental compilation
    case IsolatedCompiler.incremental_compile(sandbox_path) do
      {:ok, %{cache_hit: true}} ->
        IO.puts("No changes detected")
        :ok

      {:ok, compile_info} ->
        IO.puts("Compiled #{length(compile_info.changed_files)} changed files")

        # Load the new BEAM files
        Enum.each(compile_info.beam_files, fn beam_file ->
          case InProcessCompiler.load_beam_files([beam_file]) do
            {:ok, [module]} ->
              IO.puts("Reloaded module: #{module}")

            {:error, reason} ->
              IO.puts("Failed to load #{beam_file}: #{inspect(reason)}")
          end
        end)

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

### Example 3: In-Process Compilation for Fast Iteration

```elixir
defmodule MyApp.REPLCompiler do
  alias Sandbox.InProcessCompiler

  def compile_and_run(code_string) do
    # Compile the code in-process
    case InProcessCompiler.compile_string(code_string, "repl_input.ex") do
      {:ok, [module | _]} ->
        # The module is already loaded, execute it
        if function_exported?(module, :run, 0) do
          {:ok, module.run()}
        else
          {:ok, module}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def compile_file_fast(source_path, output_path) do
    # Use in-process compilation for speed
    case InProcessCompiler.compile_in_process(source_path, output_path,
      debug_info: true,
      parallel: true
    ) do
      {:ok, %{modules: modules, warnings: warnings}} ->
        unless Enum.empty?(warnings) do
          IO.puts("Warnings:")
          Enum.each(warnings, &IO.puts("  #{&1.message}"))
        end
        {:ok, modules}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

### Example 4: Secure Compilation with Full Security Scanning

```elixir
defmodule MyApp.SecureCompiler do
  alias Sandbox.IsolatedCompiler

  @restricted_modules [
    :os, :file, :code, :erlang,
    System, File, Code, Port,
    :gen_tcp, :gen_udp, :ssl
  ]

  def compile_untrusted(source_path) do
    # First, scan for security issues
    case IsolatedCompiler.scan_code_security(source_path,
      restricted_modules: @restricted_modules,
      scan_depth: 5
    ) do
      {:ok, %{threats: []}} ->
        # No threats, proceed with compilation
        compile_with_limits(source_path)

      {:ok, %{threats: threats}} ->
        IO.puts("Security threats detected:")
        Enum.each(threats, fn threat ->
          IO.puts("  [#{threat.severity}] #{threat.file}:#{threat.line}")
          IO.puts("    #{threat.message}")
        end)
        {:error, {:security_threats, threats}}

      {:error, reason} ->
        {:error, {:security_scan_failed, reason}}
    end
  end

  defp compile_with_limits(source_path) do
    IsolatedCompiler.compile_sandbox(source_path,
      timeout: 10_000,                      # 10 second timeout
      memory_limit: 100 * 1024 * 1024,     # 100MB memory limit
      cpu_limit: 25.0,                      # 25% CPU limit
      max_processes: 20,                    # Max 20 processes
      security_scan: true,
      restricted_modules: @restricted_modules,
      validate_beams: true
    )
  end
end
```

### Example 5: Compilation with Custom Environment

```elixir
defmodule MyApp.EnvironmentCompiler do
  alias Sandbox.IsolatedCompiler

  def compile_for_production(source_path, app_config) do
    IsolatedCompiler.compile_sandbox(source_path,
      compiler: :mix,
      env: %{
        "MIX_ENV" => "prod",
        "SECRET_KEY_BASE" => app_config.secret_key,
        "DATABASE_URL" => app_config.database_url,
        "APP_VERSION" => app_config.version
      },
      timeout: 120_000,  # 2 minutes for production builds
      incremental: false, # Full build for production
      validate_beams: true
    )
  end

  def compile_for_development(source_path) do
    IsolatedCompiler.compile_sandbox(source_path,
      compiler: :elixirc,  # Faster for development
      env: %{
        "MIX_ENV" => "dev"
      },
      incremental: true,
      cache_enabled: true,
      validate_beams: false  # Skip validation for speed
    )
  end
end
```

### Example 6: Batch Compilation with Progress Tracking

```elixir
defmodule MyApp.BatchCompiler do
  alias Sandbox.IsolatedCompiler

  def compile_multiple_sandboxes(sandbox_paths) do
    total = length(sandbox_paths)

    results = sandbox_paths
    |> Enum.with_index(1)
    |> Enum.map(fn {path, index} ->
      IO.puts("[#{index}/#{total}] Compiling #{Path.basename(path)}...")

      start_time = System.monotonic_time(:millisecond)

      result = IsolatedCompiler.compile_sandbox(path,
        incremental: true,
        cache_enabled: true
      )

      elapsed = System.monotonic_time(:millisecond) - start_time

      case result do
        {:ok, compile_info} ->
          status = if compile_info.cache_hit, do: "cached", else: "compiled"
          IO.puts("  [#{status}] #{elapsed}ms")
          {:ok, path, compile_info}

        {:error, reason} ->
          IO.puts("  [FAILED] #{inspect(reason)}")
          {:error, path, reason}
      end
    end)

    # Summary
    successful = Enum.count(results, &match?({:ok, _, _}, &1))
    failed = Enum.count(results, &match?({:error, _, _}, &1))

    IO.puts("\nSummary: #{successful} successful, #{failed} failed")

    results
  end
end
```

### Example 7: Compilation Cache Management

```elixir
defmodule MyApp.CacheManager do
  alias Sandbox.IsolatedCompiler

  def show_cache_stats(sandbox_path) do
    case IsolatedCompiler.get_cache_statistics(sandbox_path) do
      {:ok, stats} ->
        IO.puts("Cache Statistics for #{Path.basename(sandbox_path)}")
        IO.puts("=" |> String.duplicate(50))
        IO.puts("Total compilations:      #{stats.total_compilations}")
        IO.puts("Incremental compilations: #{stats.incremental_compilations}")
        IO.puts("Cache hits:              #{stats.cache_hits}")
        IO.puts("Cache hit rate:          #{Float.round(stats.cache_hit_rate * 100, 1)}%")
        IO.puts("Incremental rate:        #{Float.round(stats.incremental_rate * 100, 1)}%")
        IO.puts("Average compile time:    #{stats.average_compilation_time}ms")

      {:error, reason} ->
        IO.puts("Failed to get cache stats: #{inspect(reason)}")
    end
  end

  def clear_all_caches(sandbox_paths) do
    Enum.each(sandbox_paths, fn path ->
      case IsolatedCompiler.clear_compilation_cache(path) do
        :ok ->
          IO.puts("Cleared cache for #{Path.basename(path)}")

        {:error, reason} ->
          IO.puts("Failed to clear cache for #{Path.basename(path)}: #{inspect(reason)}")
      end
    end)
  end

  def warm_up_cache(sandbox_path) do
    IO.puts("Warming up cache for #{Path.basename(sandbox_path)}...")

    # Force a full compilation to populate cache
    case IsolatedCompiler.compile_sandbox(sandbox_path,
      cache_enabled: true,
      force_recompile: true
    ) do
      {:ok, compile_info} ->
        IO.puts("Cache warmed up in #{compile_info.compilation_time}ms")
        :ok

      {:error, reason} ->
        IO.puts("Cache warm-up failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
```

---

## Summary

The Sandbox compilation system provides a robust, secure, and performant way to compile Elixir code in isolation. Key takeaways:

1. **Choose the right backend**: Use `:mix` for full projects, `:elixirc` for simple compilations, and `:in_process` for hot reload scenarios.

2. **Leverage incremental compilation**: Enable caching and incremental compilation for repeated build cycles to significantly improve performance.

3. **Configure resource limits**: Set appropriate timeouts, memory limits, and CPU constraints to prevent runaway compilations.

4. **Enable security scanning**: For untrusted code, always enable security scanning and configure restricted modules appropriately.

5. **Handle errors gracefully**: Use the structured error types to provide meaningful feedback to users.

6. **Clean up artifacts**: Always clean up temporary compilation artifacts when done.

For more information, see the [Sandbox README](../README.md) and the module documentation for `Sandbox.IsolatedCompiler` and `Sandbox.InProcessCompiler`.
