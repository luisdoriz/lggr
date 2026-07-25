# Lggr — Original Product Specification (source of truth)

> This file reproduces the user's original request verbatim in structure and content.
> All design and implementation work must be faithful to it.

## Role

Senior macOS product engineer and product designer with deep expertise in Swift, SwiftUI, AppKit,
Apple Human Interface Guidelines, productivity software, and local-first applications.

## Mandate

Build a polished native macOS application that combines:

- Toggl-style explicit time tracking
- Pomodoro and focus sessions
- Automatic activity tracking
- Daily accomplishment logging
- Weekly productivity insights

The application should help engineering managers, developers, and knowledge workers understand:

- What they intended to work on
- What they actually spent time doing
- How often they changed context
- How much time was planned versus reactive
- What tangible outcomes they produced
- Where their week went

The application must feel extremely practical, lightweight, fast, private, and native to macOS.

## Product principles

1. Starting a focus session must take fewer than five seconds.
2. The app should require minimal manual data entry.
3. Activity tracking should help reconstruct work, not surveil the user.
4. The interface should feel calm and focused, not like enterprise time-tracking software.
5. The user should be able to understand their day at a glance.
6. Every screen should have a clear primary action.
7. Use progressive disclosure instead of showing every option immediately.
8. Prefer keyboard shortcuts and native macOS interactions.
9. Store everything locally by default.
10. Do not include authentication, teams, billing, or cloud sync in the MVP.
11. Avoid unnecessary abstractions and overengineering.
12. Build the smallest polished vertical slice before adding advanced functionality.

## Target platform

- Native macOS application
- Swift
- SwiftUI
- AppKit only where SwiftUI is insufficient
- SwiftData for persistence
- macOS 14 or newer
- Xcode-compatible project
- Menu bar support
- Sandboxed where practical
- Local-first architecture

## Core workflow

1. The user clicks the menu bar icon or uses a global keyboard shortcut.
2. The user selects a project.
3. The user writes a short intended outcome, such as: "Finish the receipt deduplication PR."
4. The user selects a duration: 25 minutes / 50 minutes / Custom / Open-ended.
5. The focus session begins.
6. The timer remains visible in the menu bar.
7. The app automatically tracks the active application and relevant context.
8. When the session finishes, the app asks what happened:
   Completed / Made progress / Blocked / Interrupted / Reprioritized
9. The app generates a suggested session summary.
10. The user can confirm or edit the summary.
11. The result is added to the daily accomplishment log.

## Main product areas

### 1. Menu bar experience

The menu bar is the primary entry point.

When no session is running, show:

- Start Focus Session
- Quick Timer
- Add Accomplishment
- Capture Interruption
- Open Today
- Open Weekly Review

When a session is running, show:

- Current intended outcome
- Remaining or elapsed time
- Current project
- Pause
- Finish
- Capture interruption
- Open full app

The menu bar icon should subtly communicate the timer state without becoming distracting.

Provide a configurable global shortcut for starting a session.
Suggested default: Command + Shift + Space

### 2. Start Focus Session

Create an extremely fast session-starting interface.

Fields: Project, Intended outcome, Duration, Work type, Link to weekly outcome (optional)

Work types: Deep work, Code review, Management, Communication, Planning, Incident, Meeting, Administrative

The intended outcome is required.

Intelligent defaults:

- Remember the last selected project.
- Suggest recent intended outcomes.
- Preselect 50 minutes for deep work.
- Preselect 25 minutes for communication or administrative work.
- Allow starting the session entirely with the keyboard.

Primary button: **Start Focus**
Secondary action: **Start without timer**

### 3. Active focus session

Show: Intended outcome, Project, Timer, Current active application, Number of context switches,
Time spent in potentially distracting applications, Session timeline, Pause and finish controls.

Do not overload the screen. The timer and intended outcome should be visually dominant.

Include a small interruption capture action. When triggered, let the user type a short note without
ending the current session. Example: "Review Omar's blocked PR." The interruption should be saved to
an inbox for later processing.

### 4. Automatic activity tracking

Track activity locally and privately. Initially capture:

- Frontmost application
- Application bundle identifier
- Application display name
- Start and end timestamps
- Window title when permission is available
- Browser domain when technically and securely possible
- Idle periods
- Application switches
- Session association

Use NSWorkspace and the macOS Accessibility APIs where appropriate.

Do NOT capture: Keystrokes, Passwords, Screenshots, Full document contents, Slack message contents,
Email contents, Clipboard contents.

Privacy controls allowing the user to:

- Disable window title tracking
- Exclude specific applications
- Mark applications as private
- Pause tracking
- Delete activity history
- Define retention duration

When an application is marked private, store only "Private activity". Do not store the title or
bundle information.

### 5. Activity classification

Rule-based classification engine before any AI.

Categories: Coding, Testing, Code review, Communication, Planning, Research, Meeting, Documentation,
Administrative, Distraction, Unknown.

Support user-configurable rules. Examples:

- Xcode → Coding
- Terminal → Coding or Testing
- GitHub → Code review
- Slack → Communication
- Linear → Planning
- Google Meet → Meeting
- YouTube → Distraction, unless manually reclassified
- Claude → Research or Coding, depending on the active project

Rules based on: Application, Window title text, Browser domain, Project, Work type.

The user should be able to correct a classification, and the app should offer to create a reusable rule.

### 6. Session completion review

Compact review sheet. Ask "What happened?" with options:
Completed / Made progress / Blocked / Interrupted / Reprioritized

Display: Total duration, Focused time, Idle time, Number of context switches, Main applications used,
Time by category, Interruption count.

Generate a suggested summary using deterministic rules. Example:

> "Worked primarily in Xcode and Terminal on receipt deduplication. Reviewed one GitHub pull request
> and spent seven minutes in Slack."

Allow the user to edit the summary.

Additional fields: Tangible result, Blocker, Next step. Only the result status should be required.

### 7. Today view

Polished dashboard for the current day. Visual hierarchy:

1. Current or next focus session
2. Daily intended outcomes
3. Accomplishments
4. Time allocation
5. Activity timeline

Show: Total tracked time, Focused time, Reactive time, Meeting time, Communication time, Number of
focus sessions, Context switches, Completed outcomes, Current interruption inbox.

Include a horizontal timeline of the day. Activity blocks should be grouped intelligently rather than
showing one row per application switch. For example:

```
9:00–9:52
Receipt deduplication
Xcode, Terminal, GitHub
Completed
```

Provide a one-click action to add an accomplishment manually.

### 8. Weekly outcomes

At the beginning of each week the user can define: One primary outcome, up to two secondary outcomes,
operational responsibilities.

Each outcome includes: Title, Description, Priority, Status, Progress, Linked projects, Linked focus
sessions, Linked accomplishments.

Avoid encouraging the user to create a large task list. The design should emphasize outcomes, not tasks.

### 9. Weekly review

Answer: What did I accomplish? Where did my time go? How much work was planned versus reactive?
Which outcomes received my best hours? What repeatedly interrupted me? What work remained invisible?
What should I change next week?

Display: Time by project, Time by work type, Time by application category, Planned versus reactive
time, Focus sessions completed, Sessions interrupted, Context switches per day, Main accomplishments,
People or workstreams unblocked, Primary outcome progress, Most common interruption sources.

Generate observations such as:

- "Your longest uninterrupted sessions happened before 11:00 AM."
- "Slack interrupted 42% of deep-work sessions."
- "You spent 5.1 hours reviewing and unblocking other engineers."
- "The primary weekly outcome received only 18% of your tracked time."
- "Tuesday had twice as many context switches as your weekly average."

Recommendations must be neutral and evidence-based. Do not use judgmental language.

### 10. Accomplishment log

Dedicated "Done" log. Types: Feature completed, Pull request opened, Pull request reviewed, Decision
made, Person unblocked, Incident resolved, Customer issue resolved, Document written, Risk identified,
Work intentionally deprioritized, Other.

Accomplishments can be: created manually, generated from completed sessions, associated with projects,
associated with weekly outcomes, exported to Markdown.

The user should be able to open the app on Friday and immediately see evidence of what they delivered.

## Data model

SwiftData models for at least:

**Project** — id, name, color identifier, icon identifier, isActive, createdAt, updatedAt

**WeeklyOutcome** — id, title, details, priority, status, progress, weekStartDate, createdAt, updatedAt

**FocusSession** — id, project, weeklyOutcome, intendedOutcome, workType, plannedDuration, startedAt,
endedAt, pausedDuration, resultStatus, resultSummary, blocker, nextStep, isReactive, interruptionCount

**ActivityEvent** — id, focusSession, applicationName, bundleIdentifier, windowTitle, domain, category,
startedAt, endedAt, isIdle, isPrivate, classificationSource

**Interruption** — id, focusSession, description, source, timestamp, status, convertedProject

**Accomplishment** — id, project, weeklyOutcome, focusSession, type, title, details, timestamp

**ClassificationRule** — id, matchType, matchValue, category, project, priority, isEnabled

**UserPreferences** — defaultSessionDuration, globalShortcut, trackWindowTitles, idleThreshold,
excludedApplications, privateApplications, dataRetentionDays, launchAtLogin, showTimerInMenuBar

Use enums where appropriate. Ensure relationships and deletion behavior are safe.

## Design direction

Premium native macOS productivity tool.

Visual references: Things, Raycast, Linear, Craft, Session, Apple Reminders, Apple Calendar, Screen Time.
Do not directly clone any product.

Use: Spacious layouts, strong typography hierarchy, native materials, subtle separators, clear empty
states, rounded cards only where they improve hierarchy, SF Symbols, native toolbars, sheets and
popovers, smooth but restrained animation, excellent dark mode, excellent light mode, full keyboard
navigation, useful hover states, native context menus, accessible contrast, Dynamic Type where applicable.

Avoid: Excessive gradients, oversized cards everywhere, dashboard clutter, gamification, streaks,
red warning-heavy interfaces, productivity scores that shame the user, generic web-app styling,
unnecessary charts, tiny text, modal dialogs for common actions.

The interface should feel calm, premium, and fast.

## Navigation

Native macOS sidebar with: Today, Focus Sessions, Accomplishments, Weekly Review, Projects, Rules, Settings.

Today is selected by default. The menu bar experience must work even when the main window is closed.

## Keyboard experience

- Global shortcut to start a session
- Command + N: New focus session
- Command + Return: Start or confirm
- Command + Shift + I: Capture interruption
- Command + Shift + A: Add accomplishment
- Space: Pause or resume active session when appropriate
- Escape: Close popover or sheet
- Command + 1 through Command + 7: Navigate sidebar sections

The primary workflow must be fully usable without a mouse.

## Notifications

Native notifications for: Session completed, optional halfway reminder, long idle period, planned
session start (if scheduled). Configurable and non-intrusive.

## Architecture

Pragmatic architecture. Prefer: SwiftUI views, SwiftData models, Observation framework, services for
system integrations, small view models only when necessary, dependency injection through the SwiftUI
environment, protocols for services that require mocking.

Suggested services: SessionManager, ActivityTrackingService, IdleDetectionService,
ApplicationMonitoringService, ClassificationService, NotificationService, ExportService,
PermissionsService, MenuBarManager.

Avoid a complicated Clean Architecture implementation unless justified. Keep domain logic testable.

## Permissions

Clear onboarding explaining: why Accessibility permission is requested, what information is collected,
what information is never collected, that all data remains local, how tracking can be paused, how data
can be deleted.

The app must still function with reduced tracking if Accessibility permission is denied.
Never repeatedly nag the user for permissions.

## Export

Support exporting: Daily summary as Markdown, Weekly review as Markdown, Accomplishment log as
Markdown, Raw sessions as CSV.

Example Markdown output:

```markdown
# Weekly Work Review

## Primary outcome

Improve receipt ingestion reliability

- 7 focus sessions
- 8.4 hours invested
- 2 pull requests opened
- 3 pull requests reviewed
- Status: Made significant progress

## Time allocation

- SOR engineering: 31%
- Code review: 22%
- Communication: 19%
- Incidents: 14%
- Planning: 9%
- Other: 5%

## Accomplishments

- Opened the receipt deduplication PR
- Resolved duplicate commission ingestion
- Reviewed three blocking pull requests
- Unblocked two engineers
- Documented the new ingestion architecture

## Observations

- The primary outcome received 31% of tracked time.
- Most deep-work sessions occurred before 11:00 AM.
- Four sessions were interrupted by Slack.
- Code review and team support represented 5.2 hours of otherwise invisible work.
```

## Testing requirements

Unit tests for: Timer behavior, pause and resume calculations, session completion, activity
aggregation, context switch calculation, planned versus reactive calculation, rule matching,
private application handling, weekly summary generation, Markdown export.

Add preview data for all major views. Ensure previews work in light and dark mode.

## Implementation order

### Phase 1: Product and technical design

1. Summarize the product in one paragraph.
2. Define the MVP boundary.
3. Identify technical and privacy risks.
4. Propose the architecture.
5. Define the SwiftData models.
6. Define the navigation structure.
7. Describe the key user flows.
8. Create an implementation checklist.

### Phase 2: Smallest working vertical slice

1. Create a project.
2. Start a focus session.
3. Display the timer in the main window.
4. Display the timer in the menu bar.
5. Pause and resume.
6. Finish the session.
7. Select the result status.
8. Save the session using SwiftData.
9. Display the completed session in Today.
10. Add an accomplishment from the completed session.

**This phase must compile and work before continuing.**

### Phase 3: Automatic application tracking

1. Detect the frontmost application. 2. Store activity intervals. 3. Detect idle periods.
4. Associate activity with the current focus session. 5. Show a session timeline.
6. Calculate application switches. 7. Add privacy exclusions.

### Phase 4: Daily experience

1. Today dashboard. 2. Daily timeline. 3. Accomplishment log. 4. Interruption inbox.
5. Daily summary export.

### Phase 5: Weekly review

1. Weekly outcomes. 2. Weekly aggregation. 3. Planned versus reactive analysis.
4. Context-switch insights. 5. Accomplishment summary. 6. Markdown export.

### Phase 6: Product polish

1. Onboarding. 2. Permissions flow. 3. Global shortcuts. 4. Notifications. 5. Settings.
6. Empty states. 7. Error states. 8. Accessibility improvements. 9. Keyboard navigation.
10. Light and dark mode refinement.

## Coding expectations

- Produce compiling Swift code.
- Do not use pseudocode for core functionality.
- Keep files reasonably small and focused.
- Use clear naming.
- Add comments only where intent is not obvious.
- Handle errors explicitly.
- Avoid force unwraps.
- Avoid unnecessary third-party dependencies.
- Prefer Apple frameworks.
- Explain any required entitlement or system permission.
- Preserve existing working functionality while iterating.
- Run the build after meaningful implementation steps.
- Fix compilation errors before continuing.
- Do not leave placeholder buttons that do nothing.
- Use sample data only in previews and development fixtures.
- Keep user-facing copy concise and natural.

## Initial deliverable

1. A concise product definition
2. The exact MVP scope
3. The architecture and folder structure
4. The SwiftData model definitions
5. A description of the main screens
6. The permissions strategy
7. A phased execution checklist

Then scaffold and implement the Phase 2 vertical slice.

Do not implement advanced analytics or AI summaries until the core tracking workflow is functional,
polished, persistent, and tested.
