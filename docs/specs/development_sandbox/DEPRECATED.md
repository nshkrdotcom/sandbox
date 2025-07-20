# DEPRECATED: Development Sandbox Platform as Separate Project

## Status: DEPRECATED

**Date**: January 20, 2025  
**Decision**: Merge into unified Apex Development Platform  
**Superseded By**: Unified Apex Development Platform Architecture

## Deprecation Notice

The Development Sandbox Platform specification (documents 01-06 in this directory) has been deprecated in favor of a unified architecture that combines both the security-focused Apex Sandbox and the developer-focused Development Sandbox into a single, modular platform.

## Background

This specification suite was created to design a comprehensive development acceleration system that would extend the existing Apex Sandbox infrastructure. The original vision was to create a separate project focused on developer productivity features such as:

- Real-time code experimentation
- Time-travel debugging
- Live state manipulation
- Distributed debugging
- Team collaboration features

## Reason for Deprecation

After holistic analysis of both the existing Apex Sandbox and the proposed Development Sandbox Platform, several critical insights emerged:

### 1. Significant Overlap

Both systems require:
- Module loading and management infrastructure
- State handling and synchronization
- Process monitoring and orchestration
- Hot-code reloading capabilities
- Resource monitoring

Maintaining two separate implementations would lead to:
- Code duplication
- Inconsistent behaviors
- Doubled maintenance burden
- Missed optimization opportunities

### 2. Complementary Strengths

Rather than competing approaches, the two systems are highly complementary:
- **Apex Sandbox** provides the secure execution foundation
- **Development Sandbox** adds the developer experience layer
- Together they create a more powerful unified platform

### 3. User Confusion

Having two separate sandbox projects in the Elixir ecosystem would create confusion:
- Which sandbox should I use?
- Can they work together?
- Do I need both?
- Which is actively maintained?

### 4. Architectural Compatibility

The core architectures are compatible and can be unified through a mode-based system:
```elixir
# Unified API with mode selection
Apex.create("sandbox", MyModule, mode: :isolation)    # Security-focused
Apex.attach(MyApp, mode: :development)                # Developer-focused
Apex.create("workspace", MyApp, mode: :hybrid)        # Combined features
```

## Migration to Unified Platform

### New Architecture

The unified Apex Development Platform will support three operational modes:

1. **Isolation Mode** (Current Apex Sandbox)
   - Security-first design
   - Resource limits and monitoring
   - Module transformation for isolation
   - Audit logging

2. **Development Mode** (Development Sandbox Features)
   - Debugging and profiling tools
   - Time-travel capabilities
   - State manipulation
   - No isolation overhead

3. **Hybrid Mode** (Best of Both)
   - Selective feature enablement
   - Security with debugging
   - Configurable trade-offs
   - Permission-based access

### What Changes

1. **Single Codebase**: All features in one platform
2. **Unified Configuration**: Mode-based behavior configuration
3. **Shared Infrastructure**: Common components for all modes
4. **Progressive Enhancement**: Start secure, add features as needed

### What Remains

All features described in this specification will be implemented, but as part of the unified platform rather than a separate project:

- ✅ Time-travel debugging
- ✅ Live state manipulation
- ✅ Code experimentation engine
- ✅ Distributed debugging
- ✅ Performance profiling
- ✅ Collaborative features
- ✅ Phoenix/LiveView integration

## Benefits of Deprecation

1. **Stronger Platform**: Combined efforts create a more robust solution
2. **Better Maintenance**: Single codebase is easier to maintain
3. **Larger Community**: One project attracts more contributors
4. **Clear Value Proposition**: One platform for all sandbox needs
5. **Future-Proof**: Easier to add new features to unified architecture

## Documentation Status

These documents remain valuable as they:
- Define important developer-focused features
- Provide detailed design specifications
- Outline implementation strategies
- Serve as reference for unified platform development

However, they should be read with the understanding that implementation will occur within the unified Apex Development Platform rather than as a standalone project.

## References

- Original Apex Sandbox: `/lib/sandbox/`
- Unified Platform Specification: [To be created]
- Migration Guide: [To be created]

## Contact

For questions about this deprecation or the unified platform architecture, please refer to the main Apex project documentation.