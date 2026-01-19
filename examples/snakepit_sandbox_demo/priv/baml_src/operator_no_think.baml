// ============================================================================
// OPERATOR AGENT TOOLS (NO THINK)
// ============================================================================

class Message {
  role string @description("assistant or tool")
  content string @description("JSON content")
}

class SetState {
  intent "set_state"
  state "healthy" | "observing" | "warning" | "critical" @description("New operator state")
  reason string @description("Why you're setting this state")
}

class SendNotification {
  intent "send_notification"
  type string @description("Type of notification (e.g., memory_elevated, scheduler_contention)")
  summary string @description("Brief description of the issue")
  severity "info" | "warning" | "critical" @description("Notification severity")
  snapshot_ids string[] @description("IDs of snapshots to include with notification - required")
}

class GetNotifications {
  intent "get_notifications"
}

class TakeSnapshot {
  intent "take_snapshot"
}

class GetSnapshot {
  intent "get_snapshot"
  id string @description("Snapshot ID to retrieve")
}

class GetSnapshots {
  intent "get_snapshots"
  limit int? @description("Max snapshots to return")
  offset int? @description("Number of snapshots to skip")
}

class Wait {
  intent "wait"
  ms int @description("Milliseconds to sleep before next iteration")
}

class Done {
  intent "done"
}

// ============================================================================
// SHARED PROMPT COMPONENTS
// ============================================================================

template_string OperatorToolDocs(callback_docs: string) #"
## Available Tools

### set_state(state, reason)
Update your state. Use this to reflect your current assessment.
If everything is fine, set state to healthy with a brief reason.

### send_notification(type, summary, severity, snapshot_ids)
Create a notification when you detect an anomaly.
- type: Descriptive name like "memory_elevated", "scheduler_contention"
- summary: Brief human-readable description
- severity: info/warning/critical based on impact
- snapshot_ids: REQUIRED - IDs of snapshots that show the issue (from take_snapshot)

IMPORTANT: You must include snapshot_ids referencing the snapshots that show
the anomaly. Notifications without snapshots will fail.

### get_notifications()
Retrieve previous notifications for correlation. Use this to avoid duplicate
notifications or to understand if an issue is recurring.

### take_snapshot()
Capture current system metrics and store with a unique ID. Returns:
- id: Unique snapshot identifier (use this in send_notification)
- captured_at: Timestamp
- data: Metrics including memory_utilization_pct, process_utilization_pct, etc.

Call this to capture metrics at specific points during your investigation.

### get_snapshot(id)
Retrieve a specific snapshot by its ID. Use this to review a previously
captured snapshot.

### get_snapshots(limit?, offset?)
Retrieve multiple snapshots with optional pagination.
- limit: Maximum number to return
- offset: Number to skip from the beginning
"#

template_string OperatorMessages(messages: Message[]) #"
{% for message in messages %}
{{ _.role(message.role) }}
{{ message.content }}
{% endfor %}
"#

// ============================================================================
// OPERATOR FUNCTION
// ============================================================================

function OperatorRunNoThink(
  messages: Message[],
  system_prompt: string,
  callback_docs: string
) -> SetState | SendNotification | GetNotifications | TakeSnapshot | GetSnapshot | GetSnapshots | Wait | Done {
  client Default
  prompt #"
{{ _.role("system") }}
{{ system_prompt }}

## State Model
You have a state that reflects your current assessment:
- healthy: Everything is normal
- observing: Something looks off, you're gathering more data
- warning: Elevated concern, but not critical
- critical: Active issue requiring immediate attention

{{ OperatorToolDocs(callback_docs) }}

### wait(ms)
Sleep for the specified milliseconds, then continue investigating.
Use this when you need to wait for conditions to change or to pace your investigation.

### done()
Signal that you have completed your analysis. Use this when:
- You've finished investigating the concern
- You've sent any necessary notifications
- You're ready to return results

## Guidelines

Your workflow:
1. Start by calling take_snapshot() to capture current system metrics
2. Review snapshots via get_snapshot/get_snapshots if needed
3. Send notifications for any issues found (include snapshot_ids)
4. Set appropriate state based on your findings
5. Call done() when your analysis is complete

{{ OperatorMessages(messages) }}

What action do you want to take?

{{ ctx.output_format }}
"#
}
