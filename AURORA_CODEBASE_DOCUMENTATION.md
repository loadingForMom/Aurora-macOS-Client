# Aurora macOS Client — Codebase Documentation

## Table of Contents
0. [Executive Summary](#0-executive-summary)
1. [Repo Map (directory overview)](#1-repo-map-directory-overview)
2. [Build & Run](#2-build--run)
   - [Requirements (Xcode/macOS target, TDLib dylib, env vars)](#requirements-xcodemacos-target-tdlib-dylib-env-vars)
   - [How to run locally (step-by-step)](#how-to-run-locally-step-by-step)
   - [Common build pitfalls](#common-build-pitfalls)
3. [Architecture Overview (Data Flow)](#3-architecture-overview-data-flow)
   - [TDLib → Store → SwiftUI](#tdlib--store--swiftui)
   - [UI → Store → TDLib requests](#ui--store--tdlib-requests)
   - [Threading/queues/MainActor rules](#threadingqueuesmainactor-rules)
4. [Core Components](#4-core-components)
   - [4.1 TDLibClient](#41-tdlibclient)
   - [4.2 TelegramStore (and each extension file summarized)](#42-telegramstore-and-each-extension-file-summarized)
   - [4.3 Database (GRDB/AppDatabase/AppDatabaseRepository)](#43-database-grdbappdatabaseappdatabaserepository)
5. [Data Models](#5-data-models)
   - [TGChat/TGUser/TGMessage and supporting types](#tgchattgusertgmessage-and-supporting-types)
   - [Message identity strategy (stable keys, local/server ids)](#message-identity-strategy-stable-keys-localserver-ids)
   - [Send state model](#send-state-model)
6. [Message Timeline & Correctness Invariants](#6-message-timeline--correctness-invariants)
   - [How history is loaded (getChatHistory), how responses are correlated (@extra)](#how-history-is-loaded-getchathistory-how-responses-are-correlated-extra)
   - [History job tracking (generation/token gating if present)](#history-job-tracking-generationtoken-gating-if-present)
   - [Merge rules vs replace rules (how disappearing messages are prevented)](#merge-rules-vs-replace-rules-how-disappearing-messages-are-prevented)
   - [Optimistic sending reconciliation (placeholder → server message)](#optimistic-sending-reconciliation-placeholder--server-message)
   - [Edits/deletes handling](#editsdeletes-handling)
   - [Read/viewMessages pipeline](#readviewmessages-pipeline)
   - [Any debug logging / assertions related to timeline](#any-debug-logging--assertions-related-to-timeline)
7. [UI: Chat List](#7-ui-chat-list)
   - [Chat sorting, searching, selection handling](#chat-sorting-searching-selection-handling)
   - [Row rendering, unread badges, preview text](#row-rendering-unread-badges-preview-text)
8. [UI: Chat Screen](#8-ui-chat-screen)
   - [Header/toolbar/inspector toggle](#headertoolbarinspector-toggle)
   - [MessagesPane: grouping, scrolling, paging triggers, geometry/preference keys](#messagespane-grouping-scrolling-paging-triggers-geometrypreference-keys)
   - [MessageGroupView: layout rules](#messagegroupview-layout-rules)
   - [MessageBubble: bubble styling, timestamp reveal, context menu actions](#messagebubble-bubble-styling-timestamp-reveal-context-menu-actions)
   - [Text rendering pipeline: entities → AttributedString, caching strategy, UTF-16 range handling](#text-rendering-pipeline-entities--attributedstring-caching-strategy-utf-16-range-handling)
9. [Avatars & Images](#9-avatars--images)
   - [Where avatars come from (TDLib file ids → paths)](#where-avatars-come-from-tdlib-file-ids--paths)
   - [Caching layers (disk cache, memory cache)](#caching-layers-disk-cache-memory-cache)
   - [Identity-keyed loading & cancellation patterns](#identity-keyed-loading--cancellation-patterns)
10. [Storage Management](#10-storage-management)
   - [Storage stats refresh](#storage-stats-refresh)
   - [Cache limit](#cache-limit)
   - [optimizeStorage request shape and supported file types](#optimizestorage-request-shape-and-supported-file-types)
11. [Settings UI](#11-settings-ui)
12. [Logging & Debugging](#12-logging--debugging)
13. [Known Gaps / Not Implemented](#13-known-gaps--not-implemented)
14. [“How to Change Things Safely”](#14-how-to-change-things-safely)
15. [Appendix](#15-appendix)
   - [Important enums/update types handled](#important-enumsupdate-types-handled)
   - [Important file list (with 1-line descriptions)](#important-file-list-with-1-line-descriptions)
   - [Glossary](#glossary)

---

## 0. Executive Summary
Aurora is a macOS SwiftUI client for Telegram that integrates TDLib through the `td_json_client` C API and renders chats with a custom, timeline-stable message view. The architecture centers on a single `TelegramStore` (`@MainActor`) that owns TDLib communication, local persistence via GRDB, in-memory timeline state, and SwiftUI-bound state. The UI is built around a `NavigationSplitView` (chat list + detail), a richly instrumented `MessagesPane` that handles paging and visibility tracking, and a settings window that exposes storage controls and placeholders for future features.

Key correctness goals visible in the current code:
- Avoid replacing the visible message window on history loads; instead **merge** updates and gate responses by generation tokens.
- Use stable message keys based on either server IDs or local UUIDs to keep optimistic messages and TDLib-confirmed messages from flickering or disappearing.
- Explicitly coalesce visibility updates and read receipts to avoid SwiftUI re-entrancy warnings and to reduce request churn.

---

## 1. Repo Map (directory overview)
Top-level directories and their roles:
- `App/`: Application entrypoint (`AuroraApp`) and main container view (`ContentView`) for the split-view UI.
- `Core/`: Core infrastructure, including TDLib bridge + state store, GRDB database code, and configuration.
  - `Core/TDLib/`: TDLib bridge, models, and store logic with multiple extensions.
  - `Core/Database/`: GRDB database initialization and repository helpers.
  - `Core/Config/`: Environment-based configuration for TDLib parameters.
- `Features/`: UI features for chat and settings.
  - `Features/Chat/`: Chat list rows, chat screen, message pipeline, inspector, composer, and imaging utilities.
  - `Features/Settings/`: Settings window hierarchy and storage controls.
- `Vendor/TDLib/`: Prebuilt TDLib dylib and headers required at build/runtime.
- `Aurora.xcodeproj/`: Xcode project configuration, build settings, and SwiftPM dependency pins (GRDB).
- `New Group/`: A duplicated set of app files and assets not referenced in the Xcode project (see “Known Gaps / Not Implemented”).

---

## 2. Build & Run

### Requirements (Xcode/macOS target, TDLib dylib, env vars)
- **Xcode / macOS target**: The project’s deployment target is macOS 26.1, with Swift 5.0 configured in project build settings. (See `MACOSX_DEPLOYMENT_TARGET` and `SWIFT_VERSION` in the project file.)
- **TDLib dylib**: The app links and embeds `Vendor/TDLib/lib/libtdjson.1.8.59.dylib` and uses the headers under `Vendor/TDLib/include`. The project adds the header search path and library search path, and copies the dylib into the app bundle.
- **Environment variables**: The `Config` type reads `TELEGRAM_API_ID` and `TELEGRAM_API_HASH` from the environment. The shared Xcode scheme includes these as launch environment variables, but they must be valid for runtime authorization.

### How to run locally (step-by-step)
1. Open `Aurora.xcodeproj` in Xcode.
2. Confirm TDLib headers and dylib exist under `Vendor/TDLib/` (they are referenced directly by the build settings).
3. Ensure `TELEGRAM_API_ID` and `TELEGRAM_API_HASH` are provided. You can set them in:
   - Xcode scheme → Run → Arguments → Environment Variables, or
   - Your shell environment before launching.
4. Build the `Aurora` target and run.
5. On first launch, the app will request TDLib parameters, initialize TDLib database folders in `Application Support/Aurora/`, then display the login flow.

### Common build pitfalls
- **Missing TDLib**: If the dylib or headers are missing, the build will fail due to `HEADER_SEARCH_PATHS` or link errors.
- **Wrong macOS target**: macOS 26.1 is specified; using older macOS versions will not meet the deployment target.
- **Missing API credentials**: `Config.apiId` and `Config.apiHash` must be non-empty, or TDLib parameter setup will log an error and authorization cannot proceed.

---

## 3. Architecture Overview (Data Flow)

### TDLib → Store → SwiftUI
1. **TDLib client** (`TDLibClient`) is initialized in `TelegramStore` and starts a receive loop on its own queue.
2. Incoming JSON messages are classified into **updates** vs **responses** (`update*` vs others).
3. `TelegramStore.handleUpdate(_:)` and `TelegramStore.handleResponse(_:)` parse JSON into `TGChat`, `TGUser`, and `TGMessage` models, update `@Published` state, and persist via `AppDatabaseRepository`.
4. SwiftUI views observe `TelegramStore` and read `@Published` fields such as `chatsById`, `messagesByChatId`, and `selectedChatId`. These drive UI updates in the chat list and message views.

### UI → Store → TDLib requests
1. UI invokes public methods on the store (e.g., `sendText`, `viewMessages`, `loadMoreHistory`, `refreshStorageStatistics`).
2. These methods build TDLib JSON requests and send them through `TDLibClient.send`.
3. Responses update store state, which in turn re-renders SwiftUI views.

### Threading/queues/MainActor rules
- `TelegramStore` is annotated with `@MainActor` and owns all `@Published` state, ensuring UI updates are serialized on the main actor.
- `TDLibClient` runs a **receive loop** on a dedicated serial queue (`tdlib.receive.queue`) and sends requests on a separate serial queue (`tdlib.send.queue`).
- Updates/responses are re-dispatched into `Task { @MainActor in ... }`, so parsing and state mutation occurs on the main actor.

---

## 4. Core Components

### 4.1 TDLibClient
**Location**: `Core/TDLib/TDLibClient.swift`

Responsibilities:
- Wraps `td_json_client_create`, `td_json_client_send`, and `td_json_client_receive`.
- Runs a single-threaded receive loop to comply with TDLib’s requirement that `td_receive` be called from one thread/queue.
- Uses two serial queues:
  - `receiveQueue` for polling TDLib.
  - `sendQueue` for dispatching outgoing JSON without blocking the receive loop.
- Distinguishes update vs response by inspecting the `@type` field and checking for the `update` prefix.

Small excerpt (classification of update vs response):
```
if self.isUpdate(json) { onUpdate(json) } else { onResponse(json) }
```

### 4.2 TelegramStore (and each extension file summarized)
**Location**: `Core/TDLib/TelegramStore.swift` + `Core/TDLib/ExtensionsTGS/*.swift`

#### Base store (`TelegramStore.swift`)
Primary responsibilities and state:
- TDLib client lifecycle and event loop.
- Core `@Published` state: `authState`, `chatsById`, `usersById`, `messagesByChatId`, selection state, and UI logging state.
- Database references and cached storage stats.
- Avatar path tracking and thumbnail caches.
- History-job tracking and optimistic-sending bookkeeping.
- Public API methods used by SwiftUI (send, edit, delete, history, storage, avatars).

The store initializes the database first, then starts the TDLib event loop and sends initial requests (e.g., `getOption` for version).

#### `TelegramStore+TDLibParameters.swift`
- Builds and sends `setTdlibParameters` with persistent directories under `~/Library/Application Support/Aurora/`:
  - `database_directory`: `.../Aurora/tdlib`
  - `files_directory`: `.../Aurora/tdlib-files`
  - Enables local message + chat metadata databases (`use_message_database=true`, `use_chat_info_database=true`), keeps the file database off (`use_file_database=false`), and disables secret chats (`use_secret_chats=false`).
  - Enables TDLib’s storage optimizer (`enable_storage_optimizer=true`).
- Persists a stable 32‑byte `database_encryption_key` at `~/Library/Application Support/Aurora/tdlib.key` (written atomically; permissions `0600`) and passes it to TDLib as Base64.
- **Concurrency**: TDLib initialization is on the main actor; the key file read/write is currently synchronous—consider moving it off the main thread to avoid UI hitching on cold start.

#### `TelegramStore+Parsing.swift.swift`
- JSON parsing helpers and caching to avoid repeated JSON decoding for identical strings.
- Parser entry points for:
  - Auth state updates (`updateAuthorizationState`).
  - Chat list and chat objects (`chats`, `chat`).
  - User objects and profile photos (`user`, `updateUser`).
  - File updates for avatars and profile photos (`updateFile`).
  - Message objects and history responses (`messages`, `updateNewMessage`).
  - Text entities and their type mapping to `TGTextEntityType`.
- Produces `TGMessage` with parsed `contentType`, `rawText`, `entities`, `sendState`, `sendingId`, and `editedAt`.

#### `TelegramStore+UpdateHandling.swift`
- Central update/response orchestration:
  - Applies authorization state changes and kicks off initial `getMe`/`getChats`/storage stats.
  - Applies chat updates (last message, title, order, read state).
  - Updates users and avatar paths.
  - Handles send lifecycle updates (`updateMessageSendSucceeded`, `updateMessageSendFailed`).
  - Handles edits/deletes, new messages, and history responses.
- Ties history responses to `HistoryJob` entries and performs generation gating to discard stale windows.

#### `TelegramStore+Timeline.swift`
- Timeline utilities for adding or merging message lists.
- `mergeMessages` builds a `MessageKey → TGMessage` map so incoming history updates do **not** overwrite newer messages or optimistic placeholders.
- `updateChatLastFromLocalTimeline` and `keepOptimisticChatPreviewIfNeeded` ensure chat previews reflect pending/failed outgoing messages.

#### `TelegramStore+History.swift`
- Issues `getChatHistory` requests for initial local window, then follows with remote history.
- Tracks `HistoryJob` records keyed by `@extra`, including generation IDs.
- Enforces window limits and prevents paging past the beginning or past the maximum window size.

#### `TelegramStore+OptimisticSending.swift`
- Creates local placeholders with **negative IDs** and **UUID local IDs**, and uses TDLib `sending_id` to reconcile later.
- Sends `sendMessage` with `messageSendOptions` that includes `sending_id` and `@extra` containing the local UUID.
- Reconciles placeholder with server message based on `sending_id` from TDLib updates or response payloads.

#### `TelegramStore+EditsAndDeletes.swift`
- Applies `updateMessageEdited`, `updateMessageContent`, and `updateDeleteMessages` to the in-memory timeline.
- Re-renders previews using `renderPreviewTextFromContent` and re-parses entities for edited content.
- Ensures deleted messages are removed from pending tracking maps.

#### `TelegramStore+ChatState.swift`
- Applies changes to chat-level state (last message, unread counts, read state).
- Performs user lookups if a sender is missing locally (`getUser`).

#### `TelegramStore+Storage.swift`
- Requests storage statistics (`getStorageStatistics`) and runs `optimizeStorage` with configured file types.
- Maintains `storageExtrasInFlight` so only expected stats are applied.
- Builds UI-ready aggregates (`storageBuckets`) for Settings UI.

#### `TelegramStore+Avatars.swift`
- Resolves chat/user avatar paths, downloads files when needed, and generates cached thumbnails.
- Uses `AuroraImageThumb.ensureThumbnail` for disk-backed, resize-aware caching.
- Stores thumbnails in `Application Support/Aurora/thumbs`.

#### `ThumbHash.swift`
- Provides a stable fallback file ID when a TDLib file ID isn’t known, using an FNV-1a hash.

### 4.3 Database (GRDB/AppDatabase/AppDatabaseRepository)
**Locations**: `Core/Database/AppDatabase.swift`, `Core/Database/AppDatabaseRepository.swift`

Key features:
- Uses GRDB to create a local SQLite database under `Application Support/Aurora/app-db/aurora.sqlite`.
- Tables:
  - `chats` for chat metadata.
  - `users` for user profiles.
  - `messages` for message timeline data (including send state, edited_at, and sending_id).
  - `chat_last_message` for quick last-message lookups.
- Provides upsert operations and fetch routines for latest/older message windows.
- Enforces invariants in debug builds (e.g., single row per `(chat_id, message_id)`).

---

## 5. Data Models

### TGChat/TGUser/TGMessage and supporting types
- `TGChat`: chat metadata including title, kind, order, last message preview/date, unread counts, and read markers.
- `TGUser`: user identifiers and display name logic (first/last/username fallback).
- `TGMessage`: message payload including IDs, chat linkage, timestamps, direction, sender, preview text, and rendering-specific fields (raw text, entities).
- Supporting types:
  - `TGChatKind` enum with `.label` and `.isGroup` helpers.
  - `TGMessageSendState` with `.sent`, `.pending`, `.failed(errorText)`.
  - `TGTextEntity` and `TGTextEntityType` for formatted text ranges.

### Message identity strategy (stable keys, local/server ids)
- `TGMessage.messageKey` uses a `MessageKey` composed of `(chatId, stableId)`.
- `stableId` is derived as:
  - `.server(id)` if `id > 0` (server message id),
  - `.local(UUID)` if a local ID exists (optimistic placeholder).
- This allows merging history and live updates without losing optimistic rows.

### Send state model
- Send states are captured both in memory and persisted to the database via `send_state` and `send_state_error` columns.
- `TGMessage.canRetry` is set from TDLib send-failure updates or message state.

---

## 6. Message Timeline & Correctness Invariants

### How history is loaded (getChatHistory), how responses are correlated (@extra)
- History requests are sent with a custom `@extra` string such as:
  - `history:<chatId>:initial:local:<uuid>`
  - `history:<chatId>:initial:remote:<uuid>`
  - `history:<chatId>:older:<uuid>`
- The response parser (`parseMessagesResponse`) only accepts results where `@extra` begins with `history:`.

### History job tracking (generation/token gating if present)
- Each history request is tracked in `historyJobs` keyed by its `@extra` string.
- A `generation` counter is stored per chat (`historyGenerationByChatId`) and increments each time initial history is loaded.
- When a history response arrives, its generation must match the current generation, or it is discarded to prevent stale history windows from overwriting newer ones.

### Merge rules vs replace rules (how disappearing messages are prevented)
- The timeline prefers **merge** over replace for history windows:
  - `mergeMessages` builds a dictionary keyed by `MessageKey` and reuses existing local IDs/sending IDs where possible.
  - This avoids dropping optimistic placeholders or newer messages that arrived after a history response was requested.
- `appendMessage` and `replaceMessage` are used for real-time updates (new messages, send success/fail) rather than bulk history windows.

### Optimistic sending reconciliation (placeholder → server message)
- On send:
  - A placeholder message is created with a negative `message_id` and a new `localId` UUID.
  - A `sending_id` is generated and added to the TDLib `messageSendOptions`.
- Reconciliation:
  - When TDLib returns a message with a matching `sending_id`, the placeholder is replaced.
  - The mapping `localIdBySendingId` and `localIdByTempMessageId` ensures the placeholder is found even if IDs change.
- Send success/failure updates (`updateMessageSendSucceeded`/`updateMessageSendFailed`) also reconcile with placeholders and update chat previews.

### Edits/deletes handling
- Edits:
  - `updateMessageEdited` updates `editedAt` on the message.
  - `updateMessageContent` rebuilds the text payload and entities, then refreshes chat previews.
- Deletions:
  - `updateDeleteMessages` removes messages from in-memory arrays and purges database rows.
  - It also clears optimistic tracking mappings for any deleted placeholder IDs.

### Read/viewMessages pipeline
- `MessagesPane` tracks visible message IDs via geometry preferences.
- Visible IDs are debounced using `ViewMessagesDebouncer` (0.2s) before calling `store.viewMessages(...)`.
- The store’s `viewMessages` sends TDLib `viewMessages` requests with `force_read: false` by default.

### Any debug logging / assertions related to timeline
- Debug-only assertions verify chat/message IDs in parsed history responses.
- `debugLogMessageEvent` prints labels for incoming updates and history operations.
- In `MessagesPane`, a debug assertion checks for duplicate `MessageKey` values in the visible window.

---

## 7. UI: Chat List

### Chat sorting, searching, selection handling
- **Sorting**: `TelegramStore.sortedChats` sorts by `order` (descending), then `lastMessageDate`, then title.
- **Search**: `ContentView` filters chats by a lowercase match on the chat title or last message preview, **without** referencing message arrays to prevent sidebar re-render churn.
- **Selection**:
  - `List(selection: $store.selectedChatId)` binds selection to the store.
  - `store.selectChat` loads initial history if needed.
  - A `.task` and `.onChange` in `ContentView` ensure the selected chat is loaded and re-selected on changes.

### Row rendering, unread badges, preview text
- `ChatRow` renders:
  - Avatar via `AvatarCircle` (using `store.chatAvatarNSImage` and disk fallback).
  - Chat title and preview text.
  - Relative time for the last message date.
- There is no explicit unread badge rendering in the current `ChatRow` implementation; only text/time are shown.

---

## 8. UI: Chat Screen

### Header/toolbar/inspector toggle
- The detail view uses `ChatScreen` with a toolbar title button (`ChatTitleButtonInline`) that toggles the inspector panel.
- Inspector panel is shown via `.inspector(isPresented:)` and renders `ChatInspectorView` for the selected chat.

### MessagesPane: grouping, scrolling, paging triggers, geometry/preference keys
**Core responsibilities**:
- Holds a **windowed** message list from the database to avoid constant recomputation on every update.
- Groups messages into day headers, time separators, and bubble groups (`MessageGroup`).

**Paging triggers**:
- Paging is enabled only after the initial jump to bottom.
- When the first visible group appears and the user is not at the bottom, `requestOlderHistory` is called to fetch older messages.
- The `pagingInFlight` and `lastPagingAnchor` state prevent double-triggering.

**Coalescing/debouncing**:
- Visible group frames are updated via preference keys. These updates are **coalesced** using a `Task` that sleeps 16ms to avoid SwiftUI “publishing during update” warnings.
- `ViewMessagesDebouncer` debounces read receipts by 0.2s.

**State breakdown**:
- `@State` in `MessagesPane` includes UI-only values such as paging flags, scrolling anchors, cached rows, and view visibility state. These are kept local to avoid churning `@Published` store state.
- Store state is read only as a source of truth (`store.messagesByChatId[chat.id]`, `store.databaseRepository`, `store.isLoadingHistory`).

**Geometry/preference keys**:
- `ScrollOffsetKey`: tracks scroll offsets for the jelly effect.
- `GroupFrameKey`: stores a mapping of group IDs to visible frames for visibility/reading state.

### MessageGroupView: layout rules
- Groups are aligned to the left or right based on `group.isOutgoing`.
- In group chats, sender names appear above incoming groups.
- Each message in the group is rendered using `MessageBubble`, with optional jelly effect based on scroll velocity.

### MessageBubble: bubble styling, timestamp reveal, context menu actions
- Two bubble styles exist in the repo:
  - `Features/Chat/MessageBubble.swift` (active in project): supports trackpad horizontal drag to reveal timestamps and uses an outgoing “Messages blue” bubble.
  - `Features/Chat/MessageBubble 2.swift` (not referenced in project file): a simpler material-based bubble without timestamp reveal.
- Context menu actions exist for outgoing messages: `Retry` (if failed and canRetry) and `Delete`.
- The visible timestamp is hidden during “reveal” gestures; the precise time slides in from the right.

### Text rendering pipeline: entities → AttributedString, caching strategy, UTF-16 range handling
- `MessageTextPipeline.render` returns an `AttributedString` cached by `(chatId, messageId, style)`.
- Entities are applied by converting TDLib UTF-16 offsets/lengths to Swift string indices:
  - Validates ranges against the UTF-16 length of the raw text.
  - Maps to `AttributedString.Index` ranges and applies formatting attributes.
- Supported entity types (and their mappings):
  - `.bold` → `.inlinePresentationIntent = .stronglyEmphasized`
  - `.italic` → `.inlinePresentationIntent = .emphasized`
  - `.underline` → `underlineStyle = .single`
  - `.strikethrough` → `strikethroughStyle = .single`
  - `.code`, `.pre`, `.preCode` → monospaced font
  - `.textUrl(url)` → `link` attribute
  - `.unknown` → ignored

---

## 9. Avatars & Images

### Where avatars come from (TDLib file ids → paths)
- TDLib updates (`updateChatPhoto`, `updateFile`, `updateUser`) provide file IDs and local paths.
- The store keeps a mapping from `chatId → ChatAvatarMeta`, including small/big file IDs and paths.
- When a file path is available and downloaded, it is used for avatar rendering and thumbnail generation.

### Caching layers (disk cache, memory cache)
- **Disk thumb cache**: `AuroraImageThumb.ensureThumbnail` writes JPEG thumbnails to `Application Support/Aurora/thumbs` using a filename that includes file ID, kind, max pixel size, and the source file’s modification time.
- **In-memory thumb cache**: `TelegramStore.imageMemCache` caches thumbnails keyed by `sourcePath|kind|maxPixel`.
- **Sidebar disk image cache**: `DiskImageCache` caches `NSImage` loaded from disk paths.
- **Avatar image cache**: `AvatarImageCache` caches `NSImage` keyed by an `AvatarCacheKey` (kind/id/size/scale).

### Identity-keyed loading & cancellation patterns
- `AvatarCircle` uses `identityKey` to load images asynchronously and drop results if the key changes.
- The asynchronous load uses `Task.detached` and checks `Task.isCancelled`, plus an explicit identity check to avoid stale images.

---

## 10. Storage Management

### Storage stats refresh
- `refreshStorageStatistics` sends `getStorageStatistics` with an `@extra` tagged as `storage:full:<uuid>`.
- Storage responses are validated against `storageExtrasInFlight`, so only in-flight requests update the UI.
- `applyStorageStatistics` updates `storageByFileType`, `storageTotalBytes`, and `storageLastRefreshedAt`.

### Cache limit
- Cache limit is stored in `UserDefaults` (`aurora.cache_limit_bytes`) and defaults to 2 GB.
- Updating the cache limit triggers `optimizeStorage(maxBytes:)` and then refreshes stats.
- The Settings UI exposes a slider (256 MB → 16384 MB) and applies changes after a short debounce.

### optimizeStorage request shape and supported file types
- `optimizeStorage` is sent with:
  - `size`, `ttl`, `count`, and `immunity_delay` parameters.
  - `file_types` including photos, videos, animations, documents, audio, voice notes, video notes, stickers, wallpapers, profile photos, thumbnails, and unknown.
- After optimization, storage stats are refreshed twice (after 1s and 3s) to reflect changes.

---


### Local TDLib database size (why it grows)

Once `use_message_database` and `use_chat_info_database` are enabled, TDLib stores more than “just messages”. It’s normal for the on-disk footprint to jump during the first sync (and sometimes after large chat list refreshes):

- **SQLite tables + indexes**: enabling message + chat-info databases adds tables and indices that simply didn’t exist when those flags were off.
- **WAL files**: SQLite may create `*.db-wal` / `*.db-shm` next to the main DB; these can temporarily make the folder look ~2× larger until a checkpoint runs.
- **Chat metadata caching**: titles, photo references, pinned message metadata, message search structures, etc., contribute even with `use_file_database=false`.

So seeing the local DB grow from ~30 MB to ~60 MB after turning those DBs on is expected. To verify where space is going, use TDLib `getStorageStatistics` and break it down by database vs files (Aurora surfaces this in the storage views).

## 11. Settings UI
- A dedicated Settings window is provided via `SettingsRootView` in `AuroraApp`.
- The settings UI uses a `NavigationSplitView` with a sidebar and detail panes.
- Implemented panes include:
  - **General**: account actions (logout/switch account), toggles for energy saving and spellcheck, and interface style selection.
  - **Notifications**: toggle settings stored with `@AppStorage`.
  - **Data & Storage**: storage statistics, cache size slider, and debug database stats (debug-only).
  - **Appearance**: text size slider and night theme toggle.
- Many sections are placeholders, indicating planned but unimplemented functionality.

---

## 12. Logging & Debugging

##### Troubleshooting: “messages don’t load” / `dropped … messages not in chat …`

If you see logs like `dropped N messages not in chat <chatId>` during initial sync, Aurora is receiving `updateNewMessage` for a chat that hasn’t been materialized in the in-memory chat registry yet (the chat object wasn’t loaded when the message arrived). Dropping those updates will make the timeline look “stuck”.

Recommended approach:
- When a message/update arrives for an unknown `chat_id`, request the chat (`getChat`) and buffer the message until the chat exists, instead of discarding it.
- Use `getChatHistory(..., only_local=true)` only as a fast warm-cache pass; always follow up with a remote `getChatHistory(..., only_local=false)` to backfill.
- The SwiftUI warning “Publishing changes from within view updates…” usually means `@Published` state is being mutated while SwiftUI is rendering. Funnel TDLib updates through a main-actor queue (`Task { @MainActor … }`) to avoid undefined behavior.

- `TelegramStore.pushLog` keeps a rolling in-memory log of TDLib JSON updates/responses (up to 250 entries).
- A debug mode in `MessagesPane` can render these logs inline in the chat view.
- Debug logging includes:
  - `[TDLib]` logs for message events (send success/fail, new messages, history responses).
  - `[HistoryMerge]` logs for merges and discarded history responses.
  - `[DB]` debug assertions for duplicate/mismatched message rows.
- TDLib JSON requests are printed using `[TD->]` logs in `sendJSON`.

---

## 13. Known Gaps / Not Implemented
- **Duplicate files not referenced by Xcode**:
  - `Features/Chat/MessageBubble 2.swift` defines a second `MessageBubble` but is not included in the Xcode project; only `MessageBubble.swift` is referenced.
  - `New Group/Aurora/*` contains an extra `AuroraApp.swift`, `ContentView.swift`, and asset catalogs but is not referenced by the project file.
- **UI stubs**:
  - Chat header actions (new chat, video call) are TODOs.
  - Inspector actions and many settings items are placeholders.
  - Several cards in the inspector are labeled as “stub” or “Placeholder.”

If any of these are actually compiled or wired at runtime, that is uncertain; the project file does not show them as part of the build.

---

## 14. “How to Change Things Safely”
Rules inferred from the current invariants and state management patterns:
1. **Preserve stable message keys**: Always keep `MessageKey(chatId, stableId)` consistent. If you add new message types, ensure `stableId` remains consistent across optimistic + server updates.
2. **Avoid replacing the timeline**: Use `mergeMessages` rather than overwriting `messagesByChatId`, especially for history paging or DB window refreshes.
3. **Respect history generations**: If you add new history loading paths, bump `historyGenerationByChatId` and only apply matching responses to avoid stale overwrites.
4. **Do not mutate `@Published` from non-main threads**: The store is `@MainActor`; keep all state mutations on the main actor.
5. **Debounce UI-driven TDLib requests**: The current pipeline debounces visibility and read receipts; adding new live UI signals should follow the same pattern.
6. **Keep optimistic send state in sync with chat previews**: After any send/replace, call `updateChatLastFromLocalTimeline` or `keepOptimisticChatPreviewIfNeeded` to maintain accurate sidebar previews.

---

## 15. Appendix

### Important enums/update types handled
- TDLib update types parsed in `TelegramStore`:
  - `updateAuthorizationState`
  - `updateChatLastMessage`
  - `updateChatReadInbox`
  - `updateChatTitle`
  - `updateChatPosition`
  - `updateChatPhoto`
  - `updateUser`
  - `updateFile`
  - `updateMessageSendSucceeded`
  - `updateMessageSendFailed`
  - `updateMessageEdited`
  - `updateMessageContent`
  - `updateDeleteMessages`
  - `updateNewMessage`
- Response types parsed:
  - `chats`, `chat`, `user`, `messages`, `storageStatistics`, `storageStatisticsFast`, and `error`.

### Important file list (with 1-line descriptions)
- `App/AuroraApp.swift`: Application entry point; sets up store, window group, and settings window.
- `App/ContentView.swift`: Main UI split view; handles chat list and chat detail + login overlay.
- `Core/TDLib/TDLibClient.swift`: TDLib JSON client wrapper and event loop.
- `Core/TDLib/TelegramStore.swift`: Main `@MainActor` state store for chats/users/messages and TDLib interactions.
- `Core/TDLib/ExtensionsTGS/TelegramStore+Parsing.swift.swift`: JSON parsing for updates/responses and message/entity extraction.
- `Core/TDLib/ExtensionsTGS/TelegramStore+Timeline.swift`: Merge/append logic for message timelines.
- `Core/TDLib/ExtensionsTGS/TelegramStore+History.swift`: History paging and window management.
- `Core/TDLib/ExtensionsTGS/TelegramStore+OptimisticSending.swift`: Local message placeholder creation and reconciliation logic.
- `Core/TDLib/ExtensionsTGS/TelegramStore+EditsAndDeletes.swift`: Edit/delete update handling and preview updates.
- `Core/Database/AppDatabase.swift`: GRDB database initialization and migrations.
- `Core/Database/AppDatabaseRepository.swift`: DB read/write methods for chats/users/messages.
- `Features/Chat/MessagesPane.swift`: Message window, grouping, paging, visibility tracking, and scroll behavior.
- `Features/Chat/MessageTextPipeline.swift`: Text entity → `AttributedString` rendering and caching.
- `Features/Chat/MessageBubble.swift`: Bubble rendering and timestamp reveal.
- `Features/Chat/ChatRow.swift`: Sidebar row rendering and avatar caching.
- `Features/Chat/ChatInspectorView.swift`: Rich inspector UI with poster image and pinned header transitions.
- `Features/Settings/SettingsRootView.swift`: Settings window with storage controls and placeholder sections.
- `Aurora.xcodeproj/project.pbxproj`: Build settings, TDLib linkage, SwiftPM dependencies.

### Glossary
- **TDLib**: Telegram Database Library, used for communication with Telegram servers.
- **@extra**: TDLib request metadata used to correlate responses with client requests.
- **History window**: The bounded subset of messages loaded into memory (up to ~800).
- **Optimistic message**: A locally created placeholder for an outgoing message that has not yet been confirmed by the server.
- **MessageKey**: A stable identifier for UI lists, based on server ID or local UUID.
- **Jelly effect**: A visual scroll effect that stretches bubbles based on scroll velocity.
- **Pinned chrome**: The inspector’s pinned header UI that appears after scrolling past the hero section.
