# Aurora macOS Client — Codebase Documentation (Snapshot)

**Snapshot source:** `Aurora.zip` (imported into ChatGPT on 2026-01-06).

This document describes what the code currently does, how the pieces fit together, and what technologies are used. It’s written as a “living” architecture + module map for the current stage of the project.

## 1. What this project is

Aurora is a native macOS Telegram client built in **Swift + SwiftUI**, using **TDLib** (Telegram Database Library) via the **td_json** C API. The app keeps a local TDLib database directory, receives TDLib updates as JSON strings, parses them, and maintains an in-memory app state (`TelegramStore`) that drives the SwiftUI UI.

At this snapshot, the app focuses on:
- Showing a chat list with search and unread counts
- Displaying message history for the selected chat (with paging)
- Sending text messages with optimistic UI (pending/failed/sent)
- Handling edits and deletions
- Showing an inspector-style side panel for a selected chat
- Viewing and managing TDLib storage statistics (cache limit, optimization, clear cache)
- Downloading and caching avatars/profile photos


Authentication UI is **not implemented** yet (phone/code/password/QR). The store observes TDLib authorization state and sends TDLib parameters, but it does not present interactive login flows.

## 2. Technology stack

- **Language:** Swift 5
- **UI:** SwiftUI (macOS app), plus AppKit bridges where needed (`NSImage`, materials, etc.)
- **State management:** `ObservableObject` + `@Published` + `@MainActor` (store), Swift Concurrency `Task { @MainActor … }`
- **Concurrency:** `DispatchQueue` for TDLib send/receive isolation; MainActor for UI state
- **Telegram API:** **TDLib JSON interface** via `td_json_client_*` and dynamic library `libtdjson.1.8.59.dylib`
- **Serialization:** `JSONSerialization` (parsing TDLib JSON into `[String: Any]` dictionaries)
- **Caching:** `NSCache` (memory), on-disk thumbnails under Application Support
- **Image processing:** CoreImage (`CIFilter.areaAverage`) for color sampling

## 3. Repository layout

High-level directory map (active code):

- `App/` — SwiftUI app entry point + root view composition
- `Core/`
  - `Config/` — runtime configuration (API id/hash via env vars)
  - `TDLib/` — TDLib client wrapper, store, models, parsing/update logic
- `Features/`
  - `Chat/` — chat list rows, message timeline UI, composer, inspector UI
  - `Settings/` — settings window UI
- `Vendor/TDLib/` — TDLib headers and prebuilt `libtdjson` dylib


Not used by the Xcode project at this snapshot:
- `New Group/` — duplicate SwiftUI starter app + Assets; not referenced in `project.pbxproj`.

## 4. Core runtime architecture

Aurora is intentionally “store-driven”. The main data flow:

**TDLib (C dylib)** → `TDLibClient` receives JSON updates → `TelegramStore.handleUpdate(_:)` parses updates → updates `@Published` state → SwiftUI views re-render.

Requests travel the opposite direction:

SwiftUI UI → calls `TelegramStore` façade methods (`sendText`, `loadMoreHistory`, etc.) → store builds JSON request dictionaries/strings → `TDLibClient.send(_:)` → TDLib.

### 4.1 `TDLibClient` (transport + thread rules)

`Core/TDLib/TDLibClient.swift` is a minimal wrapper around TDLib’s `td_json_client_*` API.
- Maintains a raw TDLib client pointer.
- Runs a **single-threaded receive loop** on a dedicated `DispatchQueue` (TDLib requires `td_receive` to be called from one thread/queue).
- Sends outgoing JSON on a separate queue so receive isn’t starved.
- Exposes `startReceiveLoop(onUpdate:)`, `send(_:)`, `stop()`.

### 4.2 `TelegramStore` (the application brain)

`Core/TDLib/TelegramStore.swift` is the central state container (`@MainActor final class TelegramStore: ObservableObject`).

Key responsibilities:
- Owns the TDLib client (`let td = TDLibClient()`).
- Starts the TDLib receive loop during initialization and forwards updates to `handleUpdate` on the MainActor.
- Holds the entire “UI-ready” model state (`@Published` dictionaries for chats/users/messages).
- Provides high-level actions used by the UI (send, retry, delete, edit, paging, read receipts, storage management).
- Implements optimistic-sending and history-job bookkeeping data structures.

Key published state:
- `authState: String`
- `chatsById: [Int64: TGChat]`
- `usersById: [Int64: TGUser]`
- `messagesByChatId: [Int64: [TGMessage]]`
- `selectedChatId: Int64?`
- `storageByFileType`, `storageTotalBytes`, `cacheLimitBytes`, etc.
- `chatAvatarPathByChatId: [Int64: String]`

### 4.3 TDLib update handling pipeline

Update handling is split into focused extensions:
- `TelegramStore+UpdateHandling.swift`: orchestrates handling for each incoming update.
- `TelegramStore+Parsing.swift.swift`: JSON helpers + parsers for specific TDLib update/response shapes.
- Specialized modules apply changes:
  - `+Timeline` (message list mutation)
  - `+OptimisticSending` (send/ack/fail reconciliation)
  - `+EditsAndDeletes` (edit/delete updates)
  - `+Avatars` (avatar download + path updates)
  - `+Storage` (storage stats parsing + actions)
  - `+ChatState` (chat read state + last message fields)

`handleUpdate(_:)` typically follows this pattern:
1) Parse a specific update shape (by checking `@type`).
2) Apply the change to the in-memory state.
3) Trigger follow-up requests when needed (e.g., `getUser` on demand, `getChats` on first ready).

## 5. Data model layer (`TelegramModels.swift`)

`Core/TDLib/TelegramModels.swift` defines lightweight UI models extracted from TDLib JSON:

- `TGChatKind`: categorizes chats (`privateChat`, `basicGroup`, `supergroup`, `secret`, `unknown`).
- `TGChat`: `Identifiable` + `Hashable` representation with fields like `id`, `title`, `order`, `unreadCount`, `lastMessagePreview`, `lastMessageId`, `lastReadInboxMessageId`, etc.
- `TGUser`: minimal user model with a `displayName` convenience.
- `TGMessageSendState`: state machine for outgoing messages: `.pending(sendingId:)`, `.failed(error:)`, `.sent`.
- `TGMessage`: UI-ready message with `id`, `chatId`, `date`, `isOutgoing`, `senderUserId`, `text`, plus optimistic bookkeeping (`localId`, `sendingId`, `sendState`).

## 6. Chat list: from TDLib to the sidebar

Chat list state lives in `TelegramStore.chatsById` and is displayed in `ContentView`.
- `ContentView` uses `NavigationSplitView` with a sidebar `List(selection: $store.selectedChatId)`.
- Chats are sorted via `TelegramStore.sortedChats` using TDLib-provided `order` (descending).
- `searchText` filters chats by title and last message preview.
- Row UI lives in `Features/Chat/ChatRow.swift` and includes avatar, title, preview, and unread count badge.

TDLib updates that keep the sidebar correct:
- `updateChatPosition` (ordering)
- `updateChatTitle`
- `updateChatLastMessage` (preview and last message metadata)
- `updateChatReadInbox` (unread count)
- Chat photo/file updates for avatars.

## 7. Message timeline: history loading, paging, grouping

### 7.1 Local timeline storage

The store maintains `messagesByChatId: [Int64: [TGMessage]]`. Each chat’s messages are kept sorted chronologically.

`TelegramStore+Timeline.swift` provides:
- `sortChronological(_:)`
- `appendMessage(_:, chatId:)`
- `replaceMessage(_:, chatId:)`
- `updateChatLastFromLocalTimeline(chatId:)` (keeps chat preview consistent with the local last message, including optimistic states)
- `keepOptimisticChatPreviewIfNeeded(chatId:)` (prevents incoming TDLib updates from overwriting a “sending…” preview prematurely)

### 7.2 Loading history (`getChatHistory`) and job tracking

History loading is implemented in `TelegramStore+History.swift` and correlated using TDLib’s `@extra` field.

Key mechanisms:
- Each request uses a unique extra string: `history:<chatId>:<latest|older>:<uuid>`.
- The store keeps `historyJobs: [String: HistoryJob]` keyed by that extra.
- `HistoryJob` stores an accumulator (`accById`) so the final array is de-duplicated and stable.
- `reachedHistoryStart: Set<Int64>` prevents repeat paging once TDLib reports there is no more history.

Entry points:
- `loadLatestHistory(chatId:)` resets the timeline and requests an initial page.
- `loadMoreHistory(chatId:pageSize:)` requests older pages using the oldest server message id in the current timeline.

### 7.3 Timeline UI (`MessagesPane`)

`Features/Chat/MessagesPane.swift` renders the message list and drives paging.
- Groups messages by day.
- Tracks scroll position and requests older history when the user approaches the top (when paging is enabled and not already in flight).
- Delegates message layout to `MessageGroupView` + `MessageBubble`.

`ChatScreen.swift` composes the timeline with the bottom composer using `safeAreaInset`.

## 8. Sending messages (optimistic UI)

Sending is implemented in `TelegramStore+OptimisticSending.swift`.

### 8.1 Placeholder insertion
- When the user sends text, the store creates a placeholder `TGMessage` with a local temporary id (negative), `sendState = .pending`, and inserts it into the timeline immediately.
- A `sending_id` (Int32) is generated and inserted into `messageSendOptions`.
- The request uses `@extra = send:<localUUID>` so responses can be correlated.

### 8.2 Reconciliation
- When TDLib emits `updateMessageSendSucceeded` or `updateMessageSendFailed`, the store matches by `sending_id` and converts the placeholder into a real message (or marks it failed).
- Retrying a failed send reuses the content while generating a new `sending_id`.

### 8.3 Keeping chat previews truthful
While a message is pending, the chat list preview is kept in a “You: (sending…) …” state and protected from being overwritten by stale TDLib last-message updates.

## 9. Edits and deletions

Implemented in `TelegramStore+EditsAndDeletes.swift`.
- Parses TDLib updates:
  - `updateMessageEdited`
  - `updateMessageContent`
  - `updateDeleteMessages`
- Applies changes into `messagesByChatId`.
- Updates chat previews via `renderPreviewTextFromContent(_:)` for non-text content types (e.g., sticker previews).
- Cleans up optimistic bookkeeping if a pending placeholder is deleted.

## 10. Read states and viewed messages

Read/view logic:
- `viewMessages(chatId:messageIds:forceRead:)` sends TDLib `viewMessages`.
- `markChatAsReadToLatestIfNeeded(chatId:)` marks the latest message as read when there are unread messages.
- `TelegramStore+ChatState.swift` applies `updateChatReadInbox` updates to keep unread counts correct.

## 11. Avatars, profile photos, thumbnails, and caching

Avatar handling is implemented in `TelegramStore+Avatars.swift`.

Key behaviors:
- Chat objects and updates provide TDLib `file_id`s for avatar images.
- The store registers file ids per chat and downloads the small avatar automatically (big avatar is not automatically downloaded).
- When TDLib sends `updateFile` (or similar file-path updates), the store maps the file id back to the chat id and publishes a usable file path in `chatAvatarPathByChatId`.

Caching:
- `imageMemCache: NSCache<NSString, NSImage>` inside the store caches decoded images.
- Thumbnails are stored under Application Support: `~/Library/Application Support/Aurora/thumbs`.
- `Features/Chat/ChatRow.swift` also defines a shared `DiskImageCache` to avoid repeated `NSImage(contentsOfFile:)` decode thrash.

## 12. Storage statistics and cache management

Implemented in `TelegramStore+Storage.swift`.

Features:
- Refresh storage stats from TDLib and publish them to the UI.
- Maintain a persistent cache size limit (`cacheLimitBytes`) stored in `UserDefaults` under key `aurora.cache_limit_bytes`.
- Clear all cache via TDLib.
- Run TDLib storage optimization (`optimizeStorage`) across many file types and then refresh stats.

The code uses `@extra` correlation strings for storage operations and keeps a `storageExtrasInFlight` set to filter responses.

## 13. UI layer

### 13.1 App entry and scenes
- `App/AuroraApp.swift` creates a single `TelegramStore` and injects it into:
  - Main window: `ContentView(store:)`
  - Settings window: `SettingsRootView(store:)`
- Adds SwiftUI’s built-in `InspectorCommands()` to expose inspector menu commands.

### 13.2 Root navigation (`ContentView`)

`App/ContentView.swift` is the UI composition root:
- `NavigationSplitView` with chat sidebar + detail.
- When a chat is selected, shows `ChatScreen(store:chat:)`.
- When no chat is selected, shows a `ContentUnavailableView` placeholder.
- Toolbar: the chat title button toggles an inspector side panel.

### 13.3 Chat screen and composer

`ChatScreen.swift` shows the timeline and the composer:
- Timeline: `MessagesPane`
- Composer: `GlassComposerBar` in `ComposerBar.swift` with `.glassEffect` styling.

### 13.4 Message rendering

- `MessageBubble.swift` implements bubble layout and a trackpad interaction to reveal timestamps. It also provides a context menu for outgoing messages (retry/delete).
- `MessageGroupView.swift` groups and lays out bubbles.
- `BottomScrim.swift` provides visual scrims/fades.

### 13.5 Inspector UI

`ChatInspectorView.swift` implements a scroll-driven inspector with pinned header + blur/dissolve effects.
It uses geometry measurements and CoreImage helpers (see `CoreImage.swift`).

### 13.6 Settings UI

`SettingsRootView.swift` provides a multi-section settings window.
Note: at this snapshot, section titles are in Russian (e.g., “Общие”), while the documentation for the project is expected to be English.

## 14. Build & runtime notes

- Xcode project is configured to generate its Info.plist (`GENERATE_INFOPLIST_FILE = YES`).
- Swift/Obj-C bridging header: `Core/TDLib/TDLibBridge.h`.
- TDLib dylib bundled: `Vendor/TDLib/lib/libtdjson.1.8.59.dylib`.
- The project’s `MACOSX_DEPLOYMENT_TARGET` is set to `26.1` in `project.pbxproj` (verify this matches your intended macOS target / toolchain).

### Running locally
1) In Xcode, set environment variables for the scheme:
   - `TELEGRAM_API_ID`
   - `TELEGRAM_API_HASH`
2) Build and run.
3) On first run, TDLib parameters are sent automatically once TDLib enters `authorizationStateWaitTdlibParameters`.

## 15. File-by-file responsibility map (active code)

- `App/AuroraApp.swift` — SwiftUI entry point; creates TelegramStore; sets up main window + Settings scene; adds InspectorCommands.
- `App/ContentView.swift` — Root UI composition: NavigationSplitView chat sidebar + detail; search; toggles inspector; shows ChatScreen.
- `Core/Config/Config.swift` — Reads TELEGRAM_API_ID and TELEGRAM_API_HASH from process environment.
- `Core/TDLib/TDLibBridge.h` — Obj-C bridging header importing TDLib C headers for td_json client + logging.
- `Core/TDLib/TDLibClient.swift` — Thin transport wrapper for td_json_client; dedicated receive queue + send queue; emits JSON updates as strings.
- `Core/TDLib/TelegramModels.swift` — UI-friendly chat/user/message models and send state enum.
- `Core/TDLib/TelegramStore.swift` — MainActor ObservableObject store: published state, TDLib loop bootstrap, façade API for UI, optimistic infra and history job structs.
- `Core/TDLib/ExtensionsTGS/TelegramStore+UpdateHandling.swift` — Single entry point for each TDLib update; calls parsers and applies side effects across modules.
- `Core/TDLib/ExtensionsTGS/TelegramStore+Parsing.swift.swift` — JSON helpers + parsers for TDLib objects/updates/responses (auth, chats, users, messages, files).
- `Core/TDLib/ExtensionsTGS/TelegramStore+TDLibParameters.swift` — Builds and sends `setTdlibParameters` when auth state requires it.
- `Core/TDLib/ExtensionsTGS/TelegramStore+ChatState.swift` — Applies chat last message + read updates; requests user objects on demand.
- `Core/TDLib/ExtensionsTGS/TelegramStore+Timeline.swift` — Timeline mutation helpers; keeps chat preview consistent with local timeline/optimistic states.
- `Core/TDLib/ExtensionsTGS/TelegramStore+History.swift` — Chat history loading + paging; job tracking via @extra; reached-start detection.
- `Core/TDLib/ExtensionsTGS/TelegramStore+OptimisticSending.swift` — Send text message with optimistic placeholder; reconcile succeeded/failed sends; retry/edit/delete APIs.
- `Core/TDLib/ExtensionsTGS/TelegramStore+EditsAndDeletes.swift` — Handles message edits/content changes/deletions and updates previews accordingly.
- `Core/TDLib/ExtensionsTGS/TelegramStore+Avatars.swift` — Chat avatars + profile photo downloads; mem/disk cache; publishes avatar paths for UI.
- `Core/TDLib/ExtensionsTGS/TelegramStore+Storage.swift` — Storage statistics parsing + publishing; cache limit controls; clear cache; optimize storage.
- `Core/TDLib/ExtensionsTGS/ThumbHash.swift` — Small hashing helper to generate stable fallback ids for thumbnails.
- `Features/Chat/ChatRow.swift` — Sidebar chat row UI; avatar circle; shared disk NSImage cache to avoid decoding thrash.
- `Features/Chat/ChatTitleButton.swift` — Inline title+avatar button used in the toolbar for toggling inspector.
- `Features/Chat/ChatScreen.swift` — Chat detail screen: message timeline + composer.
- `Features/Chat/MessagesPane.swift` — Scroll-driven timeline view; day grouping; triggers paging.
- `Features/Chat/MessageGroupView.swift` — Groups and lays out message bubbles (per-day, per-sender grouping).
- `Features/Chat/MessageBubble.swift` — Bubble styling; trackpad time reveal; outgoing context menu (retry/delete).
- `Features/Chat/ComposerBar.swift` — Glass-effect message composer bar with send button.
- `Features/Chat/BottomScrim.swift` — Bottom fade/scrim visuals supporting the chat UI.
- `Features/Chat/ChatInspectorView.swift` — Inspector panel with pinned header and blur/dissolve effects; scroll-geometry driven.
- `Features/Chat/ChatHeader.swift` — Reusable header row (avatar + title/subtitle) including inspector toggle.
- `Features/Chat/CoreImage.swift` — NSImage helpers using CoreImage to compute average color, etc.
- `Features/Settings/SettingsRootView.swift` — Settings window UI; section sidebar; ties into store’s storage/caching controls.

## 16. Non-active / leftover folders

- `New Group/…` appears to be an earlier SwiftUI starter folder (including an Assets catalog). It is not referenced by the active Xcode project at this snapshot.
- Several `.DS_Store` files are present and can be removed from version control.

## 17. Snapshot constraints / known gaps

- No interactive authentication/login UI.
- Parsing currently does multiple `JSONSerialization` passes per update in several paths; this is correct-but-inefficient and could become a performance bottleneck with high update volume.
- No integrated Assets catalog in the active build.

## 18. Glossary

- **TDLib:** Telegram Database Library (official Telegram client library).
- **td_json:** TDLib’s JSON interface.
- **Update:** Asynchronous event from TDLib (new message, chat title changed, etc.).
- **Function response:** Response to a client-initiated TDLib request (e.g., `getMe`, `getChatHistory`).
- **@extra:** Client-provided correlation string echoed back by TDLib.
- **Optimistic UI:** Inserting a placeholder UI state before the server confirms the action.
- **MainActor:** Swift concurrency “main thread” isolation used for UI correctness.
