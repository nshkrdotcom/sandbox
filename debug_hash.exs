#!/usr/bin/env elixir

# Debug script to understand file hashing issue

defmodule DebugHash do
  def test_file_reading do
    # Create a test file
    test_file = "/tmp/test_file.ex"
    content = """
    defmodule TestModule do
      def test_func, do: :test
    end
    """
    
    File.write!(test_file, content)
    
    # Try to read it back
    read_content = File.read!(test_file)
    
    IO.puts("Original content:")
    IO.inspect(content)
    IO.puts("\nRead content:")
    IO.inspect(read_content)
    IO.puts("\nContent type: #{inspect(is_binary(read_content))}")
    
    # Try hashing
    try do
      hash = :crypto.hash(:sha256, read_content) |> Base.encode16(case: :lower)
      IO.puts("\nHash: #{hash}")
    rescue
      error ->
        IO.puts("\nHash error: #{inspect(error)}")
    end
    
    # Clean up
    File.rm!(test_file)
  end
end

DebugHash.test_file_reading()