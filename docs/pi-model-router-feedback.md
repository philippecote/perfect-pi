# Pi Model-Router Feedback Extension

## Context

The model router delegates subtasks according to routing metadata such as task difficulty. A correctly routed subtask prompt begins with a structured HTML comment containing that metadata.

After the subtask finishes, the more capable parent model that dispatched it should perform a few cursory checks—for example, reading relevant files, inspecting a diff, or running a focused test—and submit an evaluation through the router's MCP rating tool. This feedback improves the router; it is useful but must not become a hard dependency of normal client-side work.

Prompt instructions and skills alone are not completely reliable. The parent model may omit the routing header, skip the checks, or forget the MCP rating call. A Pi extension can improve compliance while remaining advisory and failure-tolerant.

## Design goal

Build a client-side **soft protocol assistant**, not a strict enforcement gate.

The extension should:

- Remind the parent model to dispatch subtasks with the routing header.
- Preserve the requirement that the parent model—not the extension or subtask model—performs the evaluation.
- Prompt the parent to inspect relevant evidence before rating.
- Remember unsubmitted feedback and remind the model occasionally.
- Never block the primary task because the MCP server is unavailable, credentials are missing, permissions are incorrect, or feedback submission fails.
- Avoid unnecessary expensive-model turns and excessive reminder tokens.

## Proposed behavior

### 1. Stable protocol hint

Use Pi's `before_agent_start` event to add a short, stable guideline to the parent model's system prompt:

> When delegating through the model router, include the required routing metadata header. After inspecting a completed subtask, submit feedback with the router rating MCP tool when practical. Feedback must not block the primary task.

Keep this instruction concise and stable so that provider prompt caching remains effective.

### 2. Observe subtask dispatches

Use the `tool_call` event to identify model-router or subtask tool calls by exact tool name.

For each dispatch:

- Detect whether the required HTML routing header is present and valid.
- Record the parent provider, model, and thinking level.
- Record the subtask tool-call ID and a small task summary or hash.
- If all routing metadata already exists elsewhere in the tool arguments, the extension may normalize or prepend the header.
- If semantic metadata such as difficulty is unavailable, allow the dispatch and remember that the header was missing. The extension must not invent routing judgments.

The default policy should be advisory. A missing header should not prevent the subtask from running.

Optional policies may be supported later:

- `hint`: allow the call and remind later.
- `retry-once`: reject one malformed attempt so the parent can correct it, then fail open.
- `strict`: always reject malformed dispatches.

The recommended default is `hint`.

### 3. Create a pending feedback item

When `tool_result` fires for a completed subtask, create a pending feedback record and append a short note to the result shown to the parent model:

```text
[Router feedback pending: rf_123]
Inspect relevant files or outputs, then call the router rating tool when convenient.
Feedback is optional and must not block the main task.
```

This is the best reminder point because Pi will normally invoke the parent model again to process the subtask result. It does not require a separate model turn.

A pending record could contain:

```ts
interface PendingFeedback {
  id: string;
  subtaskToolCallId: string;
  dispatchedBy: {
    provider?: string;
    model?: string;
    thinkingLevel?: string;
  };
  headerPresent: boolean;
  createdAtTurn: number;
  lastRemindedTurn: number;
  attempts: number;
  observedChecks: number;
  state: "pending" | "failed" | "submitted" | "dismissed";
}
```

### 4. Let the parent model evaluate

The extension should observe, but not judge, post-result verification activity. Relevant actions may include:

- Opening or rereading files.
- Inspecting a diff.
- Searching for related definitions or callers.
- Running focused tests or diagnostics.
- Comparing the result against the delegated request.

These observations can make reminders more useful, but they must not become rigid admission criteria. The extension cannot determine mechanically whether the parent's reasoning or checks are sufficient.

The evaluation content and rating must be produced by the parent model that dispatched the subtask.

### 5. Observe the MCP rating call

Use `tool_call` and `tool_result` for the router's MCP rating tool:

- On `tool_call`, mark that submission was attempted.
- On a successful `tool_result`, mark the corresponding feedback item as `submitted`.
- On an error, timeout, permission failure, or unavailable server, leave it pending and snooze reminders.

A failed MCP call must never stop the parent task or cause an immediate retry loop.

Where practical, associate a rating with a stable feedback ID. If the MCP schema cannot accept that ID, correlate it using the pending subtask and tool-call state maintained by the extension.

### 6. Remind opportunistically

Do not automatically trigger a new expensive-model turn solely to obtain feedback.

Instead, remind during naturally occurring parent turns. A turn-based backoff could be:

1. Immediate note in the subtask result.
2. Reminder on the next natural parent turn if still pending.
3. Later reminders after 2, 4, and 8 additional turns.
4. Stop after a configurable maximum, such as three or four reminders.

Use the `context` event to inject a compact reminder only when it is due. Cap the number of listed feedback IDs and summarize any remainder:

```text
Router feedback pending: rf_123, rf_124 (+2 more). Submit ratings when practical; do not block current work.
```

If the MCP tool recently failed, wait several turns before mentioning the item again.

### 7. Use token-free UI status

Expose pending state in the Pi UI without adding model context:

```text
router feedback: 2 pending, 1 retry later
```

Useful commands could include:

- `/router-feedback` — list pending feedback.
- `/router-feedback snooze` — suppress reminders temporarily.
- `/router-feedback dismiss <id>` — discard an item.
- `/router-feedback remind` — schedule a reminder for the next natural turn.

### 8. Persist state without model-context cost

Use `pi.appendEntry()` for state transitions. Custom entries survive reload and session resume but do not participate in LLM context. Reconstruct active pending state from the current session branch during `session_start`.

Persist only compact metadata. Do not store complete subtask outputs redundantly.

## Suggested Pi events

```ts
pi.on("session_start", restorePendingFeedback);
pi.on("before_agent_start", addStableProtocolHint);
pi.on("tool_call", observeDispatchChecksAndRatingAttempts);
pi.on("tool_result", handleSubtaskAndRatingResults);
pi.on("context", injectReminderOnlyWhenDue);
pi.on("turn_end", advanceTurnBasedBackoff);
```

`agent_end` should generally record state or update the UI, not trigger another model turn. This keeps optional feedback from creating unnecessary cost.

## Configuration sketch

```json
{
  "dispatchPolicy": "hint",
  "feedbackPolicy": "remind",
  "maxReminders": 3,
  "reminderBackoffTurns": [1, 2, 4, 8],
  "snoozeAfterMcpFailureTurns": 4,
  "showStatus": true
}
```

Tool names and task-argument paths should also be configurable so the extension can recognize the installed subtask and MCP rating tools without coupling itself to one router implementation.

## Expected flow

```text
Parent model prepares a routed subtask
    ↓
Extension observes whether the routing header is present
    ↓
Subtask executes normally
    ↓
Extension records pending feedback and annotates the result
    ↓
Parent model reads files, inspects evidence, and reasons
    ↓
Parent calls the MCP rating tool when ready
    ↓
Success clears the pending item
    ↓
Failure leaves it pending and snoozed; primary work continues
    ↓
A later natural turn may receive a compact reminder
```

## Guiding principle

Make correct routing and feedback behavior easy and salient, remember omissions, and retry opportunistically—but never let optional router feedback obstruct the user's actual work.
