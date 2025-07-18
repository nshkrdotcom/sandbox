# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2024-01-17

### Added
- Initial release of Sandbox
- Core sandbox management functionality (create, destroy, restart)
- Isolated compilation with `Sandbox.IsolatedCompiler`
- Module version management and hot-reload capabilities
- Support for multiple compiler backends (mix, elixirc, erlc)
- Process state migration during hot-reload
- Version history tracking and rollback
- Resource control during compilation (timeout, validation)
- Comprehensive API documentation
- Example use cases for plugin systems, learning environments, and safe execution