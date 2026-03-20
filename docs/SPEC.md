# ContextD — Full Application Specification

> This document fully specifies the ContextD application such that a developer
> could reproduce it from scratch without access to the source code.

_Generated with an LLM, edited by a human._

---

## 1. Overview

**ContextD** is a macOS menu bar application that continuously captures screenshots,
extracts text via OCR, progressively summarizes the captured activity using an LLM,
and provides a prompt enrichment system that injects relevant screen context into
user prompts for AI assistants. It also exposes a local HTTP API for programmatic
access to captured data.

**Core value proposition:** Give AI assistants the context of what you've been doing
on your computer, so they can provide more relevant responses.

### Key Capabilities

1. **Continuous screen capture** — Screenshots every 2 seconds with intelligent
   keyframe/delta compression to minimize redundant OCR work.
2. **Progressive summarization** — Background LLM calls summarize captured activity
   into searchable chunks, indexed with FTS5 full-text search.
3. **Prompt enrichment** — A two-pass LLM retrieval pipeline that finds relevant
   context from your screen history and appends it as footnotes to your prompt.
4. **Local HTTP API** — REST endpoints for searching, browsing, and querying
   captured data programmatically.
5. **All data stays local** — SQLite database in `~/Library/Application Support/ContextD/`.
   The only external calls are to the LLM API (OpenRouter).

### Technology Stack

| Component       | Technology                                           |
|-----------------|------------------------------------------------------|
| Language        | Swift 5.9+                                           |
| Platform        | macOS 14+ (Sonoma)                                   |
| UI Framework    | SwiftUI + AppKit (NSWindow, NSPanel)                 |
| Database        | SQLite via GRDB.swift 6.24+ (WAL mode, FTS5)        |
| HTTP Server     | Hummingbird 2.0+                                     |
| LLM Provider    | OpenRouter (OpenAI-compatible chat completions API)  |
| OCR             | Apple Vision framework (VNRecognizeTextRequest)      |
| Screen Capture  | CoreGraphics (CGDisplayCreateImage)                  |
| Accessibility   | AXUIElement API + CGWindowListCopyWindowInfo          |
| Build System    | Swift Package Manager                                |
| Bundle ID       | `com.contextd.app`                                   |

---

## 2. Project Structure

```
ContextD/
├── Package.swift                # SPM manifest
├── Makefile                     # Build, run, database, and utility targets
├── scripts/                     # Shell scripts for development
│   ├── gen-info-plist.sh        # Generates Info.plist for .app bundle
│   ├── dev.sh                   # Build + run + live log streaming
│   ├── reset-all.sh             # Reset permissions, DB, build artifacts
│   ├── benchmark.sh             # Capture pipeline performance benchmarks
│   └── db-inspect.sh            # Interactive database inspection tool
├── ContextD/                    # All Swift source code
│   ├── App/                     # Application lifecycle and service wiring
│   │   ├── ContextDApp.swift    # @main SwiftUI App entry point
│   │   ├── AppDelegate.swift    # NSApplicationDelegate, window controllers
│   │   └── ServiceContainer.swift # Singleton DI container for all services
│   ├── Capture/                 # Screen capture pipeline
│   │   ├── CaptureEngine.swift  # Orchestrates capture loop
│   │   ├── ScreenCapture.swift  # CGDisplayCreateImage wrapper
│   │   ├── ImageDiffer.swift    # SIMD-accelerated tile-based pixel diff
│   │   ├── OCRProcessor.swift   # Vision framework OCR
│   │   ├── CaptureFrame.swift   # Data models for captures
│   │   └── AccessibilityReader.swift # Frontmost app + window metadata
│   ├── Storage/                 # Database and records
│   │   ├── Database.swift       # GRDB setup, migrations, FTS5
│   │   ├── StorageManager.swift # High-level query/insert operations
│   │   ├── CaptureRecord.swift  # captures table record
│   │   ├── SummaryRecord.swift  # summaries table record
│   │   └── TokenUsageRecord.swift # token_usage table record
│   ├── Summarization/           # Background progressive summarization
│   │   ├── SummarizationEngine.swift # Polling loop + LLM calls
│   │   └── Chunker.swift        # Time + app-boundary chunking
│   ├── Enrichment/              # Prompt enrichment system
│   │   ├── EnrichmentEngine.swift   # Coordinates enrichment
│   │   ├── EnrichmentStrategy.swift # Protocol + result types
│   │   ├── TwoPassLLMStrategy.swift # Two-pass retrieval for UI
│   │   └── CitationStrategy.swift   # Structured JSON citations for API
│   ├── LLMClient/               # LLM API integration
│   │   ├── LLMClient.swift      # Protocol definition
│   │   ├── OpenRouterClient.swift # OpenRouter implementation
│   │   └── KeychainHelper.swift # macOS Keychain wrapper (unused in prod)
│   ├── Server/                  # Embedded HTTP API
│   │   ├── APIServer.swift      # Hummingbird router + endpoints
│   │   ├── APIModels.swift      # Request/response Codable models
│   │   ├── OpenAPISpec.swift    # Static OpenAPI 3.1 JSON spec
│   │   └── ScalarDocsPage.swift # Interactive API docs HTML page
│   ├── UI/                      # User interface
│   │   ├── MenuBarView.swift    # Menu bar dropdown
│   │   ├── SettingsView.swift   # Tabbed settings window
│   │   ├── EnrichmentPanel.swift # Floating prompt enrichment panel
│   │   ├── DebugTimelineView.swift # Database debug/inspection window
│   │   └── HotkeyManager.swift  # Global hotkey (Cmd+Shift+Space)
│   ├── Permissions/             # macOS permission management
│   │   ├── PermissionManager.swift  # Screen Recording + Accessibility checks
│   │   └── OnboardingView.swift     # First-run permission grant flow
│   └── Utilities/               # Shared helpers
│       ├── PromptTemplates.swift # LLM prompt templates with {placeholder} substitution
│       ├── CaptureFormatter.swift # Hierarchical keyframe+delta text formatter
│       ├── TextDiff.swift       # Jaccard similarity for text dedup
│       ├── Extensions.swift     # String SHA256, Date formatting, Array safe subscript
│       └── DualLogger.swift     # Dual os.log + stdout logger
├── Tests/
│   └── ImageDifferTests.swift   # SIMD vs scalar correctness + benchmarks
└── docs/
    └── SPEC.md                  # This file
```

---

## 3. Application Lifecycle

### 3.1 Entry Point

The app uses `@main struct ContextDApp: App` with a `MenuBarExtra` scene (system
tray icon using SF Symbol `eye.circle`) and a `Settings` scene.

An `NSApplicationDelegateAdaptor` connects to `AppDelegate` for lifecycle events
that SwiftUI cannot handle directly.

### 3.2 Activation Policy

On launch, `AppDelegate.applicationDidFinishLaunching` sets
`NSApp.setActivationPolicy(.accessory)`. This keeps the app out of the Dock while
still allowing windows to come to the foreground and receive keyboard input.

### 3.3 First Launch / Onboarding

1. Check `UserDefaults.bool(forKey: "hasCompletedOnboarding")` and
   `PermissionManager.shared.allPermissionsGranted`.
2. If either is false, show the **OnboardingView** in an `NSWindow` (520x420).
3. OnboardingView displays two permission rows (Screen Recording, Accessibility)
   with Grant / Settings / Refresh buttons.
4. The "Continue" button is disabled until both permissions are granted.
5. On completion: set `hasCompletedOnboarding = true`, close the window, and call
   `ServiceContainer.shared.startServices()`.

### 3.4 Normal Launch (Already Onboarded)

Call `ServiceContainer.shared.startServices()` directly from
`applicationDidFinishLaunching`.

### 3.5 Global Hotkey

On init of `ContextDApp`, register a global hotkey (Cmd+Shift+Space, keyCode 49)
via `HotkeyManager.shared`. When pressed, it toggles the enrichment panel:
`ServiceContainer.shared.panelController?.toggle()`.

The hotkey uses the Carbon `RegisterEventHotKey` API with a C callback function.
The signature is `0x43_54_58_44` (ASCII "CTXD"), ID 1.

---

## 4. Service Container (Dependency Injection)

`ServiceContainer` is a `@MainActor` singleton that creates and owns all long-lived
services. It lives outside SwiftUI's struct lifecycle so services survive view
re-renders.

### Initialization Order

```
1. llmClient       = OpenRouterClient()
2. database        = AppDatabase()           // may throw
3. storageManager  = StorageManager(database:)
4. captureEngine   = CaptureEngine(storageManager:)
5. enrichmentEngine = EnrichmentEngine(storageManager:, llmClient:)
6. summarizationEngine = SummarizationEngine(storageManager:, llmClient:)
7. panelController  = EnrichmentPanelController(enrichmentEngine:)
8. debugController  = DebugWindowController(storageManager:)
```

If database initialization fails, all downstream services are set to nil and the
menu bar shows "Failed to initialize."

### startServices()

Called once after permissions are confirmed. Performs:

1. Verify `PermissionManager.shared.allPermissionsGranted` (early return if false).
2. Apply UserDefaults overrides to capture engine settings:
   - `captureInterval` (default 2.0s)
   - `maxKeyframeInterval` (default 60s)
   - `keyframeChangeThreshold` (default 0.50)
3. Start the capture engine: `captureEngine.start()`.
4. Apply UserDefaults overrides to enrichment strategy (TwoPassLLMStrategy).
5. If an API key is present, apply UserDefaults overrides to summarization engine
   settings and start it: `summarizationEngine.start()`.
6. Start the API server if enabled (defaults to enabled on first run):
   - Default port: 21890
   - Binding: `127.0.0.1` only

---

## 5. Capture Pipeline

### 5.1 Architecture

The capture pipeline runs on a configurable timer (default 2s). Each cycle:

```
Screenshot → Pixel Diff → Frame Decision → Selective OCR → Hash Dedup → Store
```

### 5.2 Screenshot Capture (`ScreenCapture`)

- Uses `CGDisplayCreateImage(CGMainDisplayID())` — no ScreenCaptureKit, no
  recording indicator, no app-visible notifications.
- Images wider than 1920px are proportionally downscaled using a `CGContext` with
  `interpolationQuality = .high`.
- Pixel format: 32-bit BGRA (`premultipliedFirst | byteOrder32Little`).

### 5.3 Accessibility Metadata (`AccessibilityReader`)

Read on every capture cycle (on `@MainActor`):

- **Frontmost app:** `NSWorkspace.shared.frontmostApplication` → name + bundleID.
- **Window title:** `AXUIElementCreateApplication` → `kAXFocusedWindowAttribute` →
  `kAXTitleAttribute`. Requires Accessibility permission; returns nil if not trusted.
- **Visible windows:** `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])`
  filtered to layer 0 (normal windows). Captures app name + window title per window.

### 5.4 Image Differencing (`ImageDiffer`)

Tile-based pixel comparison engine. Divides the screen into a 32x32 pixel grid.

**Configuration:**
- `tileSize`: 32 pixels
- `paddingPixels`: 32 pixels (padding around changed regions for OCR)
- `noiseThreshold`: 10.0/255.0 (~4%) — filters cursor blink, sub-pixel rendering
- `significantChangeThreshold`: 0.50 (50% of tiles must change for keyframe)

**Algorithm:**
1. Render both current and previous `CGImage` into 32-bit BGRA pixel buffers via
   `CGContext` with sRGB color space.
2. For each tile, compute the mean per-channel absolute difference (BGR only, alpha
   is skipped).
3. **SIMD path:** Process 4 pixels (16 bytes) per iteration using `SIMD16<UInt8>`.
   Unsigned absolute difference via `max(a,b) - min(a,b)`. Sum BGR channels only
   (skip alpha at indices 3, 7, 11, 15). Supports early exit when a threshold is
   exceeded.
4. **Scalar remainder:** Handle pixels that don't fill a SIMD vector at the end of
   each row.
5. A tile is "changed" if `totalDiff > noiseThreshold * 255 * pixelCount * 3`.

**Tile Merging:**
Changed tiles are merged into rectangular bounding regions via flood fill on the
tile grid (4-connected neighbors). Each connected component produces one bounding
rect, padded by `paddingPixels` on all sides (clamped to image bounds).

**DiffResult:**
```swift
struct DiffResult {
    let tileDiff: TileDiff          // changed tiles + total tiles + changePercentage
    let changedRegions: [ChangedRegion]  // merged rects with cropped images
    let isSignificantChange: Bool   // changePercentage >= threshold
}
```

### 5.5 Frame Type Decision

```
No previous image?         → KEYFRAME (forced)
0% tiles changed?          → SKIP (no storage)
≥50% tiles changed?        → KEYFRAME
App switch detected?       → KEYFRAME
≥60s since last keyframe?  → KEYFRAME (time cap)
Otherwise?                 → DELTA
```

### 5.6 Keyframe Handling

1. Run full-screen OCR on the image (on a detached task with `.userInitiated` priority).
2. Normalize the OCR text: lowercase, collapse whitespace, trim.
3. Compute SHA256 hash of normalized text.
4. **Hash dedup:** If hash matches the last stored hash, skip entirely.
5. Build a `CaptureFrame` with:
   - `ocrText` = full screen text
   - `fullOcrText` = full screen text (same as ocrText for keyframes)
   - `frameType` = `.keyframe`
   - `keyframeId` = nil
6. Insert into database via `StorageManager.insertCapture()`.
7. Update engine state: `currentKeyframeId`, `currentKeyframeText`,
   `currentKeyframeRegions`, `lastKeyframeTime`, `lastKeyframeAppName`,
   `lastTextHash`.

### 5.7 Delta Handling

1. If ≤8 changed regions: run OCR on each cropped region individually, translating
   bounding boxes back to full-image coordinates.
2. If >8 changed regions: fall back to full-screen OCR (faster than many small crops).
3. Delta text = text from changed regions only.
4. `fullOcrText` = `currentKeyframeText + "\n" + deltaText` (simple concatenation).
5. Hash dedup on `fullOcrText`.
6. Build `CaptureFrame` with:
   - `ocrText` = delta text only
   - `fullOcrText` = reconstructed full text
   - `frameType` = `.delta`
   - `keyframeId` = current keyframe's DB ID
7. Insert into database.

### 5.8 OCR Processing (`OCRProcessor`)

- Uses `VNRecognizeTextRequest` with:
  - `recognitionLevel = .accurate`
  - `usesLanguageCorrection = true`
  - `revision = VNRecognizeTextRequestRevision3`
- Results sorted by position: top-to-bottom (descending Y in normalized coords),
  left-to-right (ascending X). "Same line" threshold: `abs(aY - bY) > 0.02`.
- Each observation produces an `OCRRegion` with text, `CodableCGRect` bounding box
  (wrapping `CGRect` for Codable), and confidence score.
- Full text = all region texts joined with `"\n"`.

### 5.9 Continuity Across Restarts

On `CaptureEngine.init`:
- Load `lastTextHash` from the most recent capture in DB.
- Load `captureCount` from DB.
- Load the last keyframe from DB to restore `currentKeyframeId`,
  `currentKeyframeText`, `lastKeyframeTime`, `lastKeyframeAppName`.

---

## 6. Database Schema

### 6.1 Database Setup

- Path: `~/Library/Application Support/ContextD/contextd.sqlite`
- Engine: SQLite via GRDB's `DatabasePool` (WAL mode: concurrent reads, serial writes).
- In `DEBUG` builds: `migrator.eraseDatabaseOnSchemaChange = true`.

### 6.2 Tables

#### `captures`

| Column           | Type    | Constraints                       |
|------------------|---------|-----------------------------------|
| id               | INTEGER | PRIMARY KEY AUTOINCREMENT         |
| timestamp        | DOUBLE  | NOT NULL (Unix epoch)             |
| appName          | TEXT    | NOT NULL                          |
| appBundleID      | TEXT    |                                   |
| windowTitle      | TEXT    |                                   |
| ocrText          | TEXT    | NOT NULL                          |
| fullOcrText      | TEXT    | NOT NULL, DEFAULT ""              |
| visibleWindows   | TEXT    | (JSON array of VisibleWindow)     |
| textHash         | TEXT    | NOT NULL (SHA256 hex)             |
| isSummarized     | BOOLEAN | NOT NULL, DEFAULT false           |
| frameType        | TEXT    | NOT NULL, DEFAULT "keyframe"      |
| keyframeId       | INTEGER | (FK to captures.id, for deltas)   |
| changePercentage | DOUBLE  | NOT NULL, DEFAULT 1.0             |

**Indexes:**
- `idx_captures_timestamp` on `timestamp`
- `idx_captures_app` on `appName`
- `idx_captures_hash` on `textHash`
- `idx_captures_keyframe` on `keyframeId`
- `idx_captures_frametype` on `frameType`

#### `captures_fts` (FTS5 virtual table)

```sql
CREATE VIRTUAL TABLE captures_fts USING fts5(
    ocrText, windowTitle, appName,
    content=captures, content_rowid=id,
    tokenize='porter unicode61'
);
```

**Important:** The FTS column is named `ocrText` for backward compatibility, but
the triggers insert the value of `fullOcrText` (always has complete text for all
frame types).

Sync triggers: `captures_ai` (after insert), `captures_ad` (after delete),
`captures_au` (after update).

#### `summaries`

| Column         | Type    | Constraints               |
|----------------|---------|---------------------------|
| id             | INTEGER | PRIMARY KEY AUTOINCREMENT |
| startTimestamp | DOUBLE  | NOT NULL (Unix epoch)     |
| endTimestamp   | DOUBLE  | NOT NULL (Unix epoch)     |
| appNames       | TEXT    | (JSON array of strings)   |
| summary        | TEXT    | NOT NULL                  |
| keyTopics      | TEXT    | (JSON array of strings)   |
| captureIds     | TEXT    | NOT NULL (JSON array of Int64) |

**Indexes:**
- `idx_summaries_time` on `(startTimestamp, endTimestamp)`

#### `summaries_fts` (FTS5 virtual table)

```sql
CREATE VIRTUAL TABLE summaries_fts USING fts5(
    summary, keyTopics, appNames,
    content=summaries, content_rowid=id,
    tokenize='porter unicode61'
);
```

Sync triggers: `summaries_ai`, `summaries_ad`, `summaries_au`.

#### `token_usage`

| Column       | Type    | Constraints               |
|--------------|---------|---------------------------|
| id           | INTEGER | PRIMARY KEY AUTOINCREMENT |
| timestamp    | DOUBLE  | NOT NULL (Unix epoch)     |
| caller       | TEXT    | NOT NULL                  |
| model        | TEXT    | NOT NULL                  |
| inputTokens  | INTEGER | NOT NULL                  |
| outputTokens | INTEGER | NOT NULL                  |

**Indexes:**
- `idx_token_usage_timestamp` on `timestamp`
- `idx_token_usage_caller` on `caller`

### 6.3 FTS Query Sanitization

User search queries are sanitized before FTS5 matching: each word is wrapped in
double quotes, then joined with `" OR "`. Example: `auth token` becomes
`"auth" OR "token"`.

---

## 7. Progressive Summarization

### 7.1 Engine (`SummarizationEngine`)

An `actor` that runs a polling loop in the background.

**Configuration (defaults):**
- `pollInterval`: 60 seconds
- `minimumAge`: 300 seconds (5 min) — don't summarize very recent captures
- `chunkDuration`: 300 seconds (5 min) per summarization window
- `minimumChunkDuration`: 15 seconds — merge sub-chunks shorter than this
- `model`: `anthropic/claude-haiku-4-5`
- `maxSamplesPerChunk`: 10
- `maxTokens`: 1024
- `maxDeltasPerKeyframe`: 3
- `maxKeyframeTextLength`: 2000
- `maxDeltaTextLength`: 300

### 7.2 Processing Loop

Every `pollInterval` seconds:

1. Query `unsummarizedCaptures(olderThan: minimumAge, limit: 500)`.
2. If none found, sleep and retry.
3. Chunk captures using `Chunker.chunkHybrid()`.
4. For each chunk, call `summarizeChunk()`.

### 7.3 Chunking (`Chunker`)

**Hybrid chunking** (3-step process):

1. **Time-based split:** Group captures into windows of `chunkDuration` seconds.
   A new window starts when a capture's timestamp exceeds `windowStart + chunkDuration`.
2. **App-switch split:** Within each time window, split at app-switch boundaries
   (whenever `appName` changes).
3. **Short chunk merging:** Sub-chunks shorter than `minimumChunkDuration` (15s)
   are merged into their predecessor to avoid micro-chunks from rapid alt-tabs.

Each `Chunk` contains:
- `captures: [CaptureRecord]`
- `startTime`, `endTime`
- `primaryApp` (most frequent app by count)
- `appNames` (all unique, sorted)
- `primaryWindowTitle` (from most recent capture)
- `captureIds` (all non-nil IDs)

### 7.4 Summarizing a Chunk

1. Format captures as hierarchical keyframe+delta text using `CaptureFormatter.formatHierarchical()`.
2. Render the user prompt template with `{start_time}`, `{end_time}`, `{duration}`,
   `{app_name}`, `{window_title}`, `{ocr_samples}`.
3. Call the LLM via `completeWithUsage()` with the summarization system prompt.
4. Record token usage in `token_usage` table (caller: `"summarizer"`).
5. Parse the JSON response: `{"summary": "...", "key_topics": ["...", ...]}`.
   - Strip markdown code fences (```` ```json ... ``` ````) before parsing.
   - Fallback: use raw response as summary if JSON parsing fails.
6. Insert a `SummaryRecord` with JSON-encoded `appNames`, `captureIds`, `keyTopics`.
7. Mark all chunk captures as `isSummarized = true`.

### 7.5 Capture Formatting (`CaptureFormatter`)

Converts captures into a hierarchical text format for LLM input:

```
--- Keyframe (HH:MM:SS) [AppName — WindowTitle] ---
<full screen OCR text, truncated to maxKeyframeTextLength>

--- Delta (HH:MM:SS) [X% changed] ---
<changed-region text only, truncated to maxDeltaTextLength>
```

**Grouping:** Flat lists of captures are grouped into `KeyframeGroup`s by walking
chronologically — each keyframe starts a new group, subsequent deltas append to it.
Orphaned deltas become standalone groups.

**Sampling:** If there are more keyframe groups than `maxKeyframes`, evenly-spaced
indices are selected. Similarly for deltas within each group.

---

## 8. Prompt Enrichment

### 8.1 Architecture

The enrichment system uses a two-pass LLM retrieval pipeline:

```
                    ┌─── Path A: Summarized Data ──────────────────────┐
                    │                                                    │
User Query ────────>├── Pass 1: FTS search + recency ──> LLM relevance │
                    │   judging ──> relevant summary IDs ──> resolve    │
                    │   to capture IDs ──> fetch captures              │
                    │                                                    │
                    ├─── Path B: Unsummarized Data ─────────────────────┤
                    │   FTS search + recency over unsummarized captures │
                    └───────────────────────────────────────────────────┘
                                         │
                          Merge + Dedup (by capture ID)
                                         │
                          ┌──── Pass 2 ────┐
                          │  LLM synthesizes context footnotes         │
                          │  from merged captures                      │
                          └────────────────────────────────────────────┘
```

Path A and Path B run in parallel (`async let`).

### 8.2 Engine (`EnrichmentEngine`)

`@MainActor ObservableObject` that coordinates enrichment. Exposes:
- `isProcessing: Bool`
- `lastResult: EnrichedResult?`
- `lastError: String?`
- `strategies: [EnrichmentStrategy]`
- `activeStrategyIndex: Int`

Currently has one strategy: `TwoPassLLMStrategy`.

### 8.3 TwoPassLLMStrategy (UI)

**Configuration (defaults):**
- `pass1Model`: `anthropic/claude-haiku-4-5`
- `pass2Model`: `anthropic/claude-sonnet-4-6`
- `maxSummariesForPass1`: 30
- `maxCapturesForPass2`: 50
- `pass1MaxTokens`: 1024
- `pass2MaxTokens`: 2048
- `maxKeyframes`: 10, `maxDeltasPerKeyframe`: 5
- `maxKeyframeTextLength`: 3000, `maxDeltaTextLength`: 500

**Pass 1 — Relevance Judging:**
1. Gather summaries: FTS search (limit: maxSummaries/2) + recent summaries in
   time range (limit: maxSummaries/2). Dedup by ID.
2. Format summaries as numbered list: `[<id>]: <start> - <end>\nApps: ...\nTopics: ...\nSummary: ...`
3. Call the LLM (cheap model) with the enrichment Pass 1 system/user prompts.
4. Parse response as JSON array: `[{"id": <summary_id>, "reason": "..."}]`.
   Strip code fences first. Extract IDs, validate against known summary IDs.

**Path A — Resolve Summaries to Captures:**
1. Take relevant summary IDs from Pass 1.
2. Fetch all summaries, find matching ones, extract their `captureIds` JSON arrays.
3. Fetch those captures by ID from the database.

**Path B — Unsummarized Captures:**
1. FTS search over all captures, filtered to `!isSummarized` (limit: maxCaptures/2).
2. Recent unsummarized captures in time range (limit: maxCaptures/2).
3. Merge and dedup by ID.

**Merge:**
Summary-path captures first, then unsummarized captures. Dedup by ID. Sort by
timestamp descending. Limit to `maxCapturesForPass2`.

**Pass 2 — Context Synthesis:**
1. Format merged captures as hierarchical keyframe+delta text.
2. Call the LLM (capable model) with the enrichment Pass 2 system/user prompts.
3. The LLM outputs markdown footnotes: `[^1]: (2 min ago, VS Code) description...`

**Final Output:**
```
<original prompt>

---
## Context References

[^1]: (time, app) relevant context...
[^2]: ...
```

If no relevant context found:
```
<original prompt>

_(No relevant context found from recent activity.)_
```

### 8.4 CitationStrategy (API)

Identical two-pass retrieval pipeline as `TwoPassLLMStrategy`, but Pass 2 outputs
structured JSON citations instead of markdown footnotes:

```json
[
  {
    "timestamp": "2026-03-12T10:23:45Z",
    "app_name": "Google Chrome",
    "window_title": "Pull Request #482 - GitHub",
    "relevant_text": "...",
    "relevance_explanation": "...",
    "source": "capture"
  }
]
```

Has its own Pass 2 system prompt that explicitly requests JSON output.

### 8.5 Time Ranges

The `TimeRange` struct provides `.last(minutes:)` and `.last(hours:)` factories.
UI options: 5 min, 15 min, 30 min (default), 1 hour, 2 hours.

---

## 9. LLM Client

### 9.1 Protocol

```swift
protocol LLMClient: Sendable {
    func complete(messages:, model:, maxTokens:, systemPrompt:, temperature:) async throws -> String
    func completeWithUsage(messages:, model:, maxTokens:, systemPrompt:, temperature:) async throws -> LLMResponse
}
```

### 9.2 OpenRouter Implementation

- Endpoint: `https://openrouter.ai/api/v1/chat/completions`
- Auth: `Authorization: Bearer <api_key>`
- Format: OpenAI-compatible chat completions (system message as role `"system"`).
- Timeout: 120 seconds.
- Retry: up to 3 attempts for rate limits (429) and server errors (5xx).
  - Rate limited: use `retry-after` header or exponential backoff (2^attempt seconds).
  - Server error: exponential backoff.

### 9.3 API Key Storage

Stored as a **plain text file** at
`~/Library/Application Support/ContextD/api_key`.

- `OpenRouterClient.readAPIKey()` — read + trim whitespace.
- `OpenRouterClient.saveAPIKey(_:)` — create directory, write atomically.
- `OpenRouterClient.hasAPIKey()` — check existence + non-empty.

Note: A `KeychainHelper` exists in the codebase using `SecItemAdd`/`SecItemCopyMatching`
with service `com.contextd.app`, but it is not currently used for API key storage.

### 9.4 Response Parsing

Parse OpenAI-format response:
```json
{"choices": [{"message": {"content": "..."}}], "usage": {"prompt_tokens": N, "completion_tokens": M}}
```

Token usage extracted from `usage.prompt_tokens` → `inputTokens`,
`usage.completion_tokens` → `outputTokens`.

---

## 10. LLM Prompt Templates

All templates use simple `{placeholder}` substitution via
`PromptTemplates.render(template, values:)`.

Templates can be overridden via UserDefaults (Settings > Prompts tab). If the
custom value is empty, the default is used.

### 10.1 Summarization System Prompt

Role: computer activity summarizer. Instructed to:
- Summarize what the user was doing (reading, coding, browsing, chatting, etc.).
- Note specific content, key information (names, code, URLs, errors).
- Extract key topics for later retrieval.
- Respond in JSON: `{"summary": "...", "key_topics": ["...", ...]}`.
- Understands keyframe/delta format.

### 10.2 Summarization User Prompt

Template variables: `{start_time}`, `{end_time}`, `{duration}`, `{app_name}`,
`{window_title}`, `{ocr_samples}`.

### 10.3 Enrichment Pass 1 System Prompt

Role: relevance judge. Instructed to:
- Identify which activity summaries are relevant to the user's prompt.
- Respond in JSON: `[{"id": <summary_id>, "reason": "..."}]`.
- Return empty array if nothing relevant.

### 10.4 Enrichment Pass 1 User Prompt

Template variables: `{query}`, `{summaries}`.

### 10.5 Enrichment Pass 2 System Prompt

Role: context enrichment assistant. Instructed to:
- Produce markdown footnotes: `[^1]: (time, app) description`.
- Only include genuinely relevant information.
- Be concise but specific (exact names, values, code snippets).
- Maximum 10 references, ordered by relevance.

### 10.6 Enrichment Pass 2 User Prompt

Template variables: `{query}`, `{captures}`.

### 10.7 UserDefaults Keys for Custom Templates

| Key                               | Default Template           |
|-----------------------------------|----------------------------|
| `prompt_summarization_system`     | summarizationSystem        |
| `prompt_summarization_user`       | summarizationUser          |
| `prompt_enrichment_pass1_system`  | enrichmentPass1System      |
| `prompt_enrichment_pass1_user`    | enrichmentPass1User        |
| `prompt_enrichment_pass2_system`  | enrichmentPass2System      |
| `prompt_enrichment_pass2_user`    | enrichmentPass2User        |

---

## 11. HTTP API Server

### 11.1 Server Setup

- Framework: Hummingbird 2.0
- Binding: `127.0.0.1:<port>` (localhost only)
- Default port: 21890
- CORS: Allow all origins (`CORSMiddleware(allowOrigin: .all)`)
- Managed via a background `Task`, cancelable via `stop()`.

### 11.2 Endpoints

#### `GET /health`

Returns database statistics.

**Response:**
```json
{
  "status": "ok",
  "capture_count": 1234,
  "summary_count": 56
}
```

#### `POST /v1/search`

Full-text search over activity summaries using FTS5. No LLM calls.

**Request body:**
```json
{
  "text": "auth token OAuth",
  "time_range_minutes": 1440,  // optional, default 1440 (24h)
  "limit": 20                  // optional, default 20, max 100
}
```

**Response:**
```json
{
  "citations": [
    {
      "timestamp": "2026-03-12T10:23:45Z",
      "app_name": "Google Chrome",
      "window_title": null,
      "relevant_text": "<summary text>",
      "relevance_explanation": "FTS match — topics: ...",
      "source": "summary"
    }
  ],
  "metadata": {
    "query": "auth token OAuth",
    "time_range_minutes": 1440,
    "processing_time_ms": 12,
    "captures_examined": 0,
    "summaries_searched": 15
  }
}
```

**Logic:** FTS5 search over summaries → filter by time range → convert each
matching summary to a `Citation` with `source: "summary"`.

#### `GET /v1/summaries?minutes=60&limit=50`

List activity summaries within a time range.

**Parameters:**
- `minutes` — how far back to look (default 60, max 1440)
- `limit` — max results (default 50, max 200)

**Response:**
```json
{
  "summaries": [
    {
      "start_timestamp": "2026-03-12T10:00:00Z",
      "end_timestamp": "2026-03-12T10:05:00Z",
      "app_names": ["VS Code", "Terminal"],
      "summary": "User was editing...",
      "key_topics": ["auth", "OAuth"]
    }
  ],
  "time_range_minutes": 60,
  "total": 12
}
```

#### `GET /v1/activity?timestamp=ISO8601&window_minutes=5&kind=captures&limit=100`

Browse activity near a timestamp.

**Parameters:**
- `timestamp` — ISO 8601 center point (default: now). Supports fractional seconds.
- `window_minutes` — total window size centered on timestamp (default 5, max 1440)
- `kind` — `"captures"` or `"summaries"` (default: `"captures"`)
- `limit` — max results (default 100, max 500)

**Response:**
```json
{
  "activities": [
    {
      "timestamp": "2026-03-12T10:23:45Z",
      "app_name": "VS Code",
      "window_title": "parser.ts",
      "text": "<full OCR text>",
      "kind": "capture",
      "frame_type": "keyframe",
      "change_percentage": 1.0
    }
  ],
  "center_timestamp": "2026-03-12T10:25:00Z",
  "window_minutes": 5,
  "kind": "captures",
  "total": 42
}
```

#### `GET /openapi.json`

Returns the static OpenAPI 3.1 specification as JSON.

#### `GET /docs`

Returns an HTML page that loads Scalar API docs from CDN
(`https://cdn.jsdelivr.net/npm/@scalar/api-reference`), pointing at the local
`/openapi.json` endpoint.

### 11.3 Error Responses

All errors return:
```json
{
  "error": "error_code",
  "detail": "Human-readable description"
}
```

Error codes: `invalid_request`, `search_error`, `summaries_error`, `activity_error`,
`configuration_error`.

---

## 12. macOS Permissions

### 12.1 Required Permissions

1. **Screen Recording** — For `CGDisplayCreateImage()` and `CGWindowListCopyWindowInfo`
   (window titles).
   - Check: `CGPreflightScreenCaptureAccess()`
   - Request: `CGRequestScreenCaptureAccess()`
2. **Accessibility** — For `AXUIElementCopyAttributeValue` (focused window titles).
   - Check: `AXIsProcessTrusted()`
   - Request: `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`

### 12.2 PermissionManager

`@MainActor` singleton `ObservableObject` with `@Published` booleans for each
permission. `allPermissionsGranted` = both true.

### 12.3 System Settings Deep Links

- Screen Recording: `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`
- Accessibility: `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`

---

## 13. User Interface

### 13.1 Menu Bar (`MenuBarExtra`)

Icon: SF Symbol `eye.circle`. Dropdown contains:

1. **Status section:** Capture count, last capture time, errors, 24h token usage.
2. **Controls section:** Pause/Resume Capture, Enrich Prompt... (Cmd+Shift+Space).
3. **Navigation section:** API Docs link (copies URL to clipboard), Settings (Cmd+,),
   Database Debug (Cmd+Option+D), Quit (Cmd+Q).

Token usage refreshes every 30 seconds via a `Timer`.

### 13.2 Settings Window (Tabbed)

**5 tabs:**

1. **General** — API key (SecureField + Save), capture interval (1-10s slider),
   keyframe interval (30-300s slider), keyframe threshold (20-80% slider), API
   server toggle + port + restart button.
2. **Models** — Summarization model, enrichment Pass 1 model, enrichment Pass 2 model.
3. **Limits** — Steppers for all numeric limits (max response tokens, context
   retrieval sizes, formatting limits). Reset All to Defaults button.
4. **Prompts** — TextEditors for custom system prompts (summarization, Pass 1, Pass 2).
   Each has a "Reset to Default" button.
5. **Storage** — Retention days (1-90), chunk duration (1-15 min), poll interval
   (10-300s), minimum age before summarizing (1-10 min).

### 13.3 Enrichment Panel

A floating `NSPanel` (`.floating` level, `.utilityWindow` style) at 600x500.
`becomesKeyOnlyIfNeeded = false` so it accepts keyboard input.
`hidesOnDeactivate = false` so it persists when the app loses focus.

Components:
- Time range picker (5 min, 15 min, 30 min, 1 hour, 2 hours)
- Prompt text editor (monospaced, 80-150pt height)
- Enrich button (Cmd+Return) with progress indicator
- Error display
- Result display (monospaced, scrollable, text-selectable, 100-300pt height)
  with metadata bar (summaries searched, captures examined, processing time)
- Copy button (Cmd+Shift+C)

### 13.4 Debug Timeline Window

`NSWindow` (850x600, resizable, autosave name "DebugWindow") with 4 tabs:

1. **Captures** — HSplitView: left side is a list of captures (badge K/D, app name,
   window, timestamp, text preview, char counts, summarized status). Right side is
   a detail pane showing all fields + full OCR text + delta text.
2. **Summaries** — List of summaries with app names, time range, summary preview,
   key topic pills, capture count.
3. **Search** — FTS5 search bar with live results.
4. **Stats** — Overview (counts, DB size, time range), top apps with progress bars,
   frame types (keyframes, deltas, avg change, compression ratio), summarization
   progress.

Auto-refreshes every 3 seconds (toggle-able).

### 13.5 Onboarding Window

`NSWindow` (520x420, titled + closable). Shows:
- Eye circle icon + "Welcome to ContextD" title
- Explanation text
- Two `PermissionRow`s (Screen Recording, Accessibility) with grant/settings buttons
  and green/red status indicators
- Refresh Status + Continue buttons (Continue disabled until all granted)
- Warning text if permissions missing

---

## 14. Utilities

### 14.1 DualLogger

Writes every log message to both:
- Apple's Unified Logging (`os.log.Logger`) with `.public` privacy
- stdout with format: `[HH:mm:ss.SSS] [LEVEL] [category] message`

Subsystem: `com.contextd.app`. Levels: debug, info, notice, warning, error.

### 14.2 String Extensions

- `sha256Hash` — SHA256 via CryptoKit, returned as lowercase hex string.
- `normalizedForDedup` — lowercase, split on whitespace, filter empties, rejoin
  with single spaces.

### 14.3 Date Extensions

- `relativeString` — `RelativeDateTimeFormatter` with `.abbreviated` units.
- `shortTimestamp` — formatted as `HH:mm:ss`.

### 14.4 Array Extension

- `subscript(safe:)` — bounds-checked subscript returning `Optional`.

### 14.5 TextDiff

- `jaccardSimilarity(_:_:)` — Word-set Jaccard similarity (0.0-1.0).
- `isDuplicate(_:_:threshold:)` — Fast path: SHA256 hash match. Fallback: Jaccard
  similarity >= 0.9.

---

## 15. App Bundle

For proper macOS permission prompts, the binary is packaged into a `.app` bundle
via `make bundle`:

```
.build/ContextD.app/
├── Contents/
│   ├── MacOS/ContextD     (copied from .build/debug/ContextD)
│   ├── Resources/
│   └── Info.plist         (generated by scripts/gen-info-plist.sh)
```

### Info.plist Key Values

| Key                                       | Value                                |
|-------------------------------------------|--------------------------------------|
| CFBundleIdentifier                        | com.contextd.app                     |
| CFBundleExecutable                        | ContextD                             |
| CFBundleShortVersionString                | 0.1.0                                |
| LSMinimumSystemVersion                    | 14.0                                 |
| LSUIElement                               | true (no Dock icon)                  |
| NSScreenCaptureUsageDescription           | ContextD captures screenshots to...  |
| NSHighResolutionCapable                   | true                                 |
| NSSupportsAutomaticGraphicsSwitching      | true                                 |

---

## 16. UserDefaults Keys

All configurable settings with their defaults:

| Key                                  | Type   | Default |
|--------------------------------------|--------|---------|
| `hasCompletedOnboarding`             | Bool   | false   |
| `captureInterval`                    | Double | 2.0     |
| `maxKeyframeInterval`                | Double | 60      |
| `keyframeChangeThreshold`            | Double | 0.50    |
| `apiServerEnabled`                   | Bool   | true*   |
| `apiServerPort`                      | Int    | 21890   |
| `retentionDays`                      | Int    | 7       |
| `summarizationChunkDuration`         | Double | 300     |
| `summarizationPollInterval`          | Double | 60      |
| `summarizationMinAge`                | Double | 300     |
| `summarizationMaxTokens`             | Int    | 1024    |
| `maxSamplesPerChunk`                 | Int    | 10      |
| `maxSummariesForPass1`               | Int    | 30      |
| `maxCapturesForPass2`                | Int    | 50      |
| `enrichmentPass1MaxTokens`           | Int    | 1024    |
| `enrichmentPass2MaxTokens`           | Int    | 2048    |
| `enrichmentMaxKeyframes`             | Int    | 10      |
| `enrichmentMaxDeltasPerKeyframe`     | Int    | 5       |
| `enrichmentMaxKeyframeTextLength`    | Int    | 3000    |
| `enrichmentMaxDeltaTextLength`       | Int    | 500     |
| `summarizationMaxDeltasPerKeyframe`  | Int    | 3       |
| `summarizationMaxKeyframeTextLength` | Int    | 2000    |
| `summarizationMaxDeltaTextLength`    | Int    | 300     |
| `prompt_summarization_system`        | String | ""      |
| `prompt_summarization_user`          | String | ""      |
| `prompt_enrichment_pass1_system`     | String | ""      |
| `prompt_enrichment_pass1_user`       | String | ""      |
| `prompt_enrichment_pass2_system`     | String | ""      |
| `prompt_enrichment_pass2_user`       | String | ""      |

*`apiServerEnabled` defaults to enabled if the key has never been set (checked via
`UserDefaults.object(forKey:) != nil`).

---

## 17. Build & Development

### 17.1 Package.swift

```swift
// swift-tools-version: 5.9
platforms: [.macOS(.v14)]
dependencies:
  - GRDB.swift 6.24+
  - hummingbird 2.0+
targets:
  - executableTarget "ContextD" (path: "ContextD", excludes: "Assets.xcassets")
  - testTarget "ContextDTests" (path: "Tests")
```

### 17.2 Key Makefile Targets

| Target              | Description                                  |
|---------------------|----------------------------------------------|
| `make build`        | Debug build                                  |
| `make release`      | Optimized release build                      |
| `make run`          | Build + run (debug)                          |
| `make bundle`       | Create .app bundle for proper permissions    |
| `make run-bundle`   | Build + bundle + launch via `open`           |
| `make test`         | Run unit tests                               |
| `make benchmark`    | Run ImageDiffer SIMD vs scalar benchmarks    |
| `make db-shell`     | Open SQLite shell on the database            |
| `make db-stats`     | Database statistics (counts, sizes, apps)    |
| `make db-search Q=` | FTS5 search captures                         |
| `make db-recent`    | Show 10 most recent captures                 |
| `make logs`         | Stream unified logs live                     |
| `make install`      | Install release binary to /usr/local/bin     |
| `make clean`        | Remove build artifacts                       |
| `make watch`        | Rebuild on file changes (requires fswatch)   |

### 17.3 Tests

`ImageDifferTests` — 8 test methods:
1. `testIdenticalBuffers` — zero diff from identical data
2. `testMaxDiff` — maximum diff from 0 vs 255
3. `testAlphaIgnored` — alpha channel differences produce zero diff
4. `testSinglePixelChange` — single pixel B=10 G=20 R=30 → diff=60
5. `testTileOffset` — tile at non-zero offset in larger image
6. `testNonAlignedTileWidth` — 7x5 tile (exercises scalar remainder)
7. `testRandomData` — SIMD matches scalar for pseudo-random data across multiple
   tile sizes and offsets
8. `testBenchmarkScalar/SIMD/SIMDEarlyExit` — Performance measurement on a
   2560x1440 full-display simulation

---

## 18. Data Flow Summary

```
┌──────────────────────────────────────────────────────────────┐
│                     Every 2 seconds                          │
│                                                              │
│  ScreenCapture ──> ImageDiffer ──> OCR ──> StorageManager    │
│  (CGImage)       (tile diff)    (Vision)   (SQLite/GRDB)     │
│                                                              │
│  AccessibilityReader ──────────────────┘                     │
│  (app name, window title, visible windows)                   │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│                    Every 60 seconds                           │
│                                                              │
│  SummarizationEngine                                         │
│    ├── Query unsummarized captures (≥5 min old)              │
│    ├── Chunk by time (5 min) + app boundaries                │
│    ├── Format as keyframe+delta text                         │
│    ├── LLM call (Claude Haiku) → JSON {summary, key_topics} │
│    └── Store in summaries table, mark captures summarized    │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│                    On user request                            │
│                                                              │
│  EnrichmentEngine (Cmd+Shift+Space)                          │
│    ├── Pass 1: FTS search + recency → LLM relevance judge   │
│    │   (Claude Haiku → relevant summary IDs)                 │
│    ├── Resolve summary IDs → capture IDs → fetch captures    │
│    ├── Parallel: fetch unsummarized captures (FTS + recency) │
│    ├── Merge + dedup captures                                │
│    ├── Pass 2: LLM context synthesis (Claude Sonnet)         │
│    │   → markdown footnotes                                  │
│    └── Append footnotes to user's prompt                     │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│                    Always running                             │
│                                                              │
│  APIServer (http://127.0.0.1:21890)                          │
│    ├── POST /v1/search     (FTS5 search summaries)           │
│    ├── GET  /v1/summaries  (list by time range)              │
│    ├── GET  /v1/activity   (browse captures/summaries)       │
│    ├── GET  /health        (status + counts)                 │
│    ├── GET  /openapi.json  (OpenAPI 3.1 spec)                │
│    └── GET  /docs          (Scalar interactive docs)         │
└──────────────────────────────────────────────────────────────┘
```

---

## 19. Security Considerations

1. **All data local** — SQLite database never leaves the machine. No telemetry.
2. **API key in plaintext** — Stored at `~/Library/Application Support/ContextD/api_key`.
   Not in Keychain (a `KeychainHelper` exists but is unused for this purpose).
3. **API server localhost-only** — Binds to `127.0.0.1`, not `0.0.0.0`.
4. **CORS allow-all** — The API server permits all origins (for browser-based docs).
5. **No images stored** — Screenshots are processed in memory for OCR and diffing,
   then discarded. Only extracted text is persisted.
6. **FTS query sanitization** — User input is quoted to prevent FTS5 syntax injection.
7. **DEBUG erasure** — In debug builds, the database is erased on schema change
   (`eraseDatabaseOnSchemaChange = true`).

---

## 20. Performance Design

1. **SIMD pixel diffing** — 4 pixels per iteration via `SIMD16<UInt8>` with early
   exit threshold. ~4x faster than scalar on Apple Silicon.
2. **Selective OCR** — Only changed screen regions are OCR'd for delta frames
   (with fallback to full-screen OCR if >8 separate regions).
3. **Hash deduplication** — SHA256 of normalized text prevents storing identical
   captures. Checked before every database insert.
4. **Image downscaling** — Screenshots wider than 1920px are proportionally
   downscaled before OCR (preserves aspect ratio).
5. **Background processing** — OCR runs on detached tasks with `.userInitiated`
   priority. Summarization runs as an actor with its own background task.
6. **WAL mode** — GRDB DatabasePool uses SQLite WAL for concurrent reads during
   writes.
7. **FTS5 indexing** — Porter-stemmed Unicode-aware full-text search for fast
   retrieval without scanning all rows.
8. **Evenly-spaced sampling** — When there are too many keyframes or deltas for an
   LLM context window, evenly-spaced indices are selected to maintain temporal
   coverage.
