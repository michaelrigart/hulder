# Apple's Own Menu Bar Items Implementation Plan

**Status:** Implemented ([PR #3](https://github.com/michaelrigart/hulder/pull/3)). Task 8 Step 2 passed live with Michael on 2026-11-03. Completed; do not run it again.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Battery, Wi-Fi, Clock, Control Center, Siri and the Input menu the app items' functionality (sections, hiding, reordering, Tidy) within macOS 27.2's limits. Nothing changes for an Apple item until the user assigns it.

**Architecture:**
- The core gains:
  - an assignable unit: an app, or a system item named by its module;
  - a layout map from module name to section, holding entries only once the user assigns them;
  - an allowlist field naming the modules to hide.
- The platform:
  - maps menu-extra identifiers to modules and system item numbers;
  - keys drawn modules by identity;
  - reports hidden modules;
  - turns hidden modules into the numbers to keep.
- Siri and the Input menu ride the existing app path once their owners stop counting as "managed by macOS".

**Tech Stack:** Swift 6.4, Swift Testing, SwiftPM packages HulderCore and HulderPlatform27, SwiftUI app target, XcodeGen through mise.

**Spec:** `docs/superpowers/specs/2026-11-03-hulder-system-items-design.md`, which builds on `docs/superpowers/specs/2026-10-31-hulder-design.md` (v1). Read both.

## Global Constraints

- **Location:** this repository's harness worktree `.claude/worktrees/hulder-system-items`, branch `feat/hulder-system-items`. Commit each task on its own, imperative mood, no agent attribution. Never push to `main`.
- **Commands:** `swift test --package-path Packages/HulderCore`, `swift test --package-path Packages/HulderPlatform27`, `mise exec -- xcodegen generate` and `xcodebuild -project Hulder.xcodeproj -scheme Hulder -configuration Debug|Release -derivedDataPath build -quiet build`. All run outside the agent sandbox with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, from the worktree. The build folder is the worktree's own `build/`.
- **Package boundary:** HulderCore imports only Foundation and Observation. System item numbers and menu-extra identifiers live only in HulderPlatform27.
- **The macOS 27 table** (identifier → module name → number):
  - `com.apple.menuextra.battery` → `Battery` → 0;
  - `com.apple.menuextra.clock` → `Clock` → 2;
  - `com.apple.menuextra.wifi` → `WiFi` → 6;
  - `com.apple.menuextra.controlcenter` → `BentoBox` → 8.
- **Apple's owners:** `com.apple.systemuiserver`, `com.apple.TextInputMenuAgent`, `com.apple.MenuBarAgent`, `com.apple.controlcenter`.
  - Assignable as apps: the first two only.
  - Never off the allowlist: the last two.
- **v1's assertion arguments** with nothing assigned and default section Visible: every app as before, and system items `Array(0...127)`.
- **Labels:** v1's rules. Apple's items show their own name ("Wi-Fi", "Siri", "Input Menu"); a tooltip adds ", part of macOS".

## Review Focus

1. **An unassigned Apple item sitting left of Hulder's icon** → no misplaced marker, Tidy leaves it alone. (Task 5.)
2. **Default section Hidden, Apple items never assigned** → Siri and the Input menu stay visible; v1 hid them. (Task 3.)
3. **Wi-Fi drawn with its identifier but no `module:WiFi` entry** → it can be assigned and hidden, but not moved; Battery's entry is never written for it. (Tasks 4 and 5.)
4. **Revealed state with only a module assigned Hidden** → the assertion stays, the module shows, and nothing reflows. (Task 3.)
5. **A state file written by v1** → loads with no module assignments; one written by this build loads in v1 without failing. (Task 1.)

---

### Task 1: Core model: assignable units and stored module sections

**Depends on:** none

**Files:**
- Create: `Packages/HulderCore/Sources/HulderCore/Model/SystemItem.swift`
- Modify: `Packages/HulderCore/Sources/HulderCore/Model/Layout.swift`, `Model/MenuBarItem.swift`
- Test: `Packages/HulderCore/Tests/HulderCoreTests/LayoutTests.swift`, `StateStoreTests.swift`

**Interfaces:**
- Produces:
  - `public struct SystemItemID: Hashable, Codable, Sendable, Comparable { public let moduleName: String }`;
  - `public enum AssignableUnit: Hashable, Sendable { case app(AppID); case systemItem(SystemItemID) }`;
  - `public enum AppleOwners { public static let assignable: Set<AppID>; public static let all: Set<AppID> }` (values from Global Constraints);
  - `MenuBarItem.systemItem: SystemItemID?` (a new stored property, init parameter defaulting to nil);
  - `MenuBarItem.unit: AssignableUnit?`: `.systemItem` when `systemItem` is set, else `.app` when not managed by macOS and the owner has an app ID, else nil;
  - `MenuBarItem.isAppleItem: Bool`: the owner's app is in `AppleOwners.all`;
  - `Layout.systemItems: [SystemItemID: Section]` (`private(set)`);
  - `Layout.assign(_ item: SystemItemID, to: Section)`;
  - `Layout.section(of item: SystemItemID) -> Section?`.

- [ ] **Step 1: Write the failing tests.**
  - A `Layout` with `assign(SystemItemID(moduleName: "WiFi"), to: .hidden)` round-trips through `StateCodec` and keeps the assignment.
  - JSON written by v1, without a `systemItems` key, decodes with an empty map, and the state version is unchanged.
  - **v1 can read what this build writes.** The test target holds a frozen copy of v1's decoding contract: a test-only `Decodable` mirroring v1's `HulderState`/`Layout` with exactly `version`, `layout.defaultSection`, `layout.apps` and `settings`, as v1 decodes them. A state holding app assignments and module assignments is encoded with the new encoder and decoded with that frozen contract, and every v1 field survives with its value.
  - `MenuBarItem.unit` for each case: a module with `systemItem`, an app item, a managed item, an unresolved owner.
- [ ] **Step 2: Run them; they fail.**
- [ ] **Step 3: Implement.** Encode `systemItems` as a dictionary keyed by module name. Decode it with `decodeIfPresent`.
- [ ] **Step 4: Run the full core suite; it passes.**
- [ ] **Step 5: Commit** "Store sections for Apple's own items".

### Task 2: Core labels for Apple's items

**Depends on:** Task 1

**Files:**
- Modify: `Packages/HulderCore/Sources/HulderCore/Models/LayoutPresentation.swift`
- Test: `Packages/HulderCore/Tests/HulderCoreTests/ItemKeyNameTests.swift` or `LayoutPresentationTests.swift`

- [ ] **Step 1: Write the failing tests:**
  - an item owned by `com.apple.systemuiserver` with key `status:com.apple.systemuiserver::Siri` that is NOT managed by macOS is labelled "Siri";
  - the TextInputMenuAgent item is labelled "Input Menu";
  - a module with `systemItem` WiFi is labelled "Wi-Fi";
  - the tooltip or VoiceOver label of each ends ", part of macOS";
  - an ordinary app item keeps "<app>: <description>";
  - `readOnlyReason` of a managed `module:FocusModes` item is "macOS hides Focus whenever Hulder hides anything";
  - `readOnlyReason` of another managed module without `systemItem` (`module:Sound`) is "macOS doesn't let Hulder hide this item";
  - `readOnlyReason` of a `com.apple.controlcenter` item and of an unresolved owner stays v1's.
- [ ] **Step 2: Run them; they fail** for the unmanaged Apple items.
- [ ] **Step 3: Implement.** `label` uses `isManagedByMacOS || isAppleItem` where it uses `isManagedByMacOS` today. `MenuBarModel.label(of:layout:)` appends ", part of macOS" for Apple items. `readOnlyReason` gives the two module reasons above (Focus by its module name, `FocusModes`).
- [ ] **Step 4: Run the core suite; it passes.**
- [ ] **Step 5: Commit** "Name Apple's items as macOS's".

### Task 3: Core concealment: hide modules, keep Apple's owners until assigned

**Depends on:** Task 1

**Files:**
- Modify: `Packages/HulderCore/Sources/HulderCore/Concealment/ConcealmentPlanner.swift`, and every user of `keepsAllSystemItems` (`rg keepsAllSystemItems`), including the probe in HulderPlatform27, kept compiling
- Test: `Packages/HulderCore/Tests/HulderCoreTests/ConcealmentPlannerTests.swift`

**Interfaces:**
- Produces:
  - `AllowList.hiddenSystemItems: Set<SystemItemID>`, replacing `keepsAllSystemItems`; empty means keep every system item;
  - `ConcealmentPlanner.plan(layout:state:running:own:)`, same signature.

- [ ] **Step 1: Write the failing tests:**
  - nothing assigned, default Visible → `.none`, as v1;
  - one app Hidden → the allowlist equals v1's, and `hiddenSystemItems` is empty;
  - default Hidden, nothing assigned, `com.apple.systemuiserver` and `com.apple.TextInputMenuAgent` running → both on the allowlist (v1 left them off);
  - `com.apple.MenuBarAgent` and `com.apple.controlcenter` always on the allowlist, even when assigned (they can't be);
  - SystemUIServer assigned Hidden, state hidden → off the allowlist;
  - WiFi assigned Hidden, every app Visible, state hidden → `.allow` with `hiddenSystemItems == [WiFi]`;
  - the same in state revealed → still `.allow` with `hiddenSystemItems` empty (the assertion stays);
  - WiFi assigned Always Hidden, state revealed → `[WiFi]`;
  - revealed-all → `.none`.
- [ ] **Step 2: Run them; they fail.**
- [ ] **Step 3: Implement.**
  - An Apple owner not in `layout.apps` counts as Visible.
  - An assertion is needed while any running app's effective section or any assigned module's section is not Visible.
  - A module goes in `hiddenSystemItems` when `state.conceals` its section.
- [ ] **Step 4: Run the core and platform suites; they pass** (the probe and platform still compile).
- [ ] **Step 5: Commit** "Plan hidden modules and keep Apple's owners until assigned".

### Task 4: Platform: the module table, numbers, keys and hidden modules

**Depends on:** Tasks 1, 3

**Files:**
- Create: `Packages/HulderPlatform27/Sources/HulderPlatform27/Concealment/SystemItemTable27.swift`
- Modify:
  - `Concealment/AllowListTranslation.swift`, `Concealment/AssertionBackend27.swift`;
  - `Scan/ItemKeyBuilder.swift`, `Scan/InventoryAssembly.swift`, `Scan/MenuBarScanner27.swift`;
  - `Platform27.swift`.
- Test: `AllowListTranslationTests.swift`, `ItemKeyBuilderTests.swift`, `InventoryAssemblyTests.swift`, `AssertionBackend27Tests.swift`

**Interfaces:**
- Produces:
  - `SystemItemTable27.entry(forIdentifier:) -> (id: SystemItemID, number: Int, orderName: String)?`;
  - `SystemItemTable27.number(for: SystemItemID) -> Int?`;
  - `AllowListTranslation.arguments(for:)` → `systemItems` = `0...127` minus the numbers of `hiddenSystemItems`;
  - `AssertionBackend27.concealedSystemItems() -> Set<SystemItemID>`, the union over confirmed assertions, an over-approximation like `concealedApps`;
  - `ItemKeyBuilder.systemKeys(identifiers:entries:) -> [(key: ItemKey, isCertain: Bool)]`: certain only for an identifier match to the module's own entry.

- [ ] **Step 1: Write the failing tests:**
  - **Translation:** empty set → `Array(0...127)`; `[WiFi]` → `0...127` without 6; `[Battery, BentoBox]` → without 0 and 8.
  - **Keys:** with entries lacking `module:WiFi`, the Wi-Fi identifier's key is uncertain, and never Battery's entry; the live set from fix 19 stays certain.
  - **Assembly:**
    - a MenuBarAgent group with the Wi-Fi identifier yields an item with `systemItem == WiFi`;
    - a group without an identifier yields `systemItem == nil`;
    - a group from `com.apple.systemuiserver` is not managed by macOS;
    - with `concealedSystemItems == [WiFi]` and no Wi-Fi group drawn, MenuBarAgent's items include a Wi-Fi item: key `module:WiFi` (or the entry's key), no bar position, certain only when the entry exists.
  - **Backend:** `concealedSystemItems` follows the confirmed assertions.
- [ ] **Step 2: Run them; they fail.**
- [ ] **Step 3: Implement.**
  - Remove `com.apple.systemuiserver` and `com.apple.TextInputMenuAgent` from `macOSManagedBundleIDs`.
  - Carry `concealedSystemItems` into the scan pass the way `concealed` is, appending hidden modules to MenuBarAgent's drawn items.
  - Wire `Platform27` to the backend.
- [ ] **Step 4: Run the platform suite; it passes.**
- [ ] **Step 5: Commit** "Hide Apple's modules by number and list them while hidden".

### Task 5: Core order, rows, sightings and Layout actions for units

**Depends on:** Tasks 1, 3, 4

**Files:**
- Modify:
  - `Packages/HulderCore/Sources/HulderCore/Order/OrderPlanner.swift` (`OrderContext.section(of:)`);
  - `Models/MenuBarModel.swift` (`rows`, `readOnlyItems`, `isAssignable`);
  - `Models/LayoutActions.swift` (`move`, `drop`, `tidy` and the helpers);
  - `Engine/SightingRecorder.swift`;
  - `Models/StateModel.swift`, if assigning needs a new mutation.
- Test: `OrderPlannerTests.swift`, `MenuBarModelTests.swift`, `LayoutActionsTests.swift`, `SightingRecorderTests.swift`

**Interfaces:**
- Produces:
  - `LayoutActions.move(_ unit: AssignableUnit, to: Section) async -> LayoutOutcome`, replacing `move(app:to:)`. Keep `move(app:to:)` as a one-line wrapper only if the app target still needs it; otherwise update the callers in Task 6.
  - `drop(_:to:before:)` works for any item whose `unit` is non-nil.

- [ ] **Step 1: Write the failing tests:**
  - **`OrderContext.section(of:)`:**
    - nil for an unassigned module and an unassigned Apple-owner item;
    - the assigned section once assigned;
    - unchanged for apps.
  - **`misplaced`:** an unassigned Wi-Fi left of the divider isn't misplaced; once assigned Visible, it is.
  - **`rows`:**
    - unassigned Wi-Fi and Siri appear in the Visible row;
    - Wi-Fi assigned Hidden appears in the Hidden row, also when it's a hidden module with no bar position;
    - Focus (managed, no `systemItem`) is only in `readOnlyItems`.
  - **`move(.systemItem(WiFi), to: .hidden)`** assigns it and places its key at the divider. With an uncertain key it assigns it and doesn't write the order (`.sectionChangedInPlace`).
  - **`drop` of an unassigned Wi-Fi within Visible** first records Visible, then moves it.
  - **Pinned `module:Clock` moved to Hidden** → section changes, order untouched, and the outcome says why it didn't move.
  - **Pinned `module:Clock` dragged within its row, or moved with Move Left/Right** → `.unavailable("macOS keeps this item at the right end of the bar.")`, nothing written. This replaces the planner's silent nil, which `finish` turns into `.unchanged`. The notice line shows the text.
  - **SightingRecorder** never records `com.apple.systemuiserver` or `com.apple.TextInputMenuAgent`.
- [ ] **Step 2: Run them; they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the core suite; it passes.**
- [ ] **Step 5: Commit** "Assign, order and tidy Apple's items like apps".

### Task 6: Layout window for units

**Depends on:** Tasks 2, 5

**Files:**
- Modify: `Hulder/Windows/LayoutView.swift`, `Hulder/Windows/LayoutRowView.swift`, and any app call site of `move(app:to:)`

- [ ] **Step 0 (core, test first):** `MenuBarItem.rowTitle: String?` in HulderCore (`LayoutPresentation.swift`) is the item's own name for Apple's items ("Wi-Fi", "Battery", "Clock", "Control Center", "Siri", "Input Menu") and nil for app items. The four modules share MenuBarAgent's icon, so the rows must name them. Test it in `LayoutPresentationTests`.
- [ ] **Step 1:** Route "Move to", drag and drop, Move Left/Right and ⌘←/→ through `item.unit`. In the rows, an entry with a `rowTitle` shows that title as visible text beside or instead of the owner's icon, so the modules can be told apart without hovering. A row entry whose item has a unit is draggable and movable; the read-only list stays as is.
- [ ] **Step 2:** Show the tooltip and VoiceOver label from `MenuBarModel.label(of:layout:)`, which ends ", part of macOS" for Apple's items.
- [ ] **Step 3:** Generate the project and build Debug and Release, with 0 warnings. Run both suites.
- [ ] **Step 4: Commit** "Move Apple's items in the Layout window".

### Task 7: Probe `hide-items`

**Depends on:** Task 4

**Files:**
- Modify: `Packages/HulderPlatform27/Sources/HulderPlatform27/Probe/PlatformProbe27.swift`, `Probe/ProbeHide.swift`; `AGENTS.md` (the probe list)
- Test: `ProbeTests.swift` (argument parsing)

- [ ] **Step 1: Write the failing test.** `hide-items WiFi Battery` parses to the hide-items command with those modules; no modules is a usage error.
- [ ] **Step 2: Implement `hide-items <module…>`.** Through the shipped backend, an `AllowList` of every running app plus Hulder, with `hiddenSystemItems` set to the named modules. Scan while hidden, pause, invalidate, pause, as `hide` does. Add it to the usage text and to AGENTS.md's probe list.
- [ ] **Step 3: Run the platform suite and the Debug build.**
- [ ] **Step 4: Commit** "Add a probe step that hides Apple's modules".

### Task 8: Live acceptance (controller, unattended, then Michael)

**Depends on:** Tasks 1–7

- [x] **Step 1 (controller, unattended):** install the Debug build in `/Applications`.
  - Launch Hulder and the probe by running the bundle's executable directly. The agent can't use `open`, which its sandbox blocks.
  - This step checks only what the hiding assertion does, read from the bar through the terminal's Accessibility grant. Accessibility attribution under a normal launch is Step 2's, with `open` *(the controller's ruling)*.
  - Run `hide-items WiFi` and `hide-items Battery Clock BentoBox` through the probe, launched directly, and check the bar through Accessibility: exactly those modules gone, and back after.
  - Then write a state file with WiFi assigned Hidden (Hulder quit first, state backed up), launch Hulder directly from the terminal, and check through Accessibility that Wi-Fi isn't drawn.
  - Restore the state file afterwards.
  - Record the results in the spec's "Measured" section.
- [x] **Step 2 (Michael, 2026-11-03):** run the spec's acceptance item 2 in the Layout window. All six checks passed; see the spec's "Live check with Michael".
- [x] **Step 3:** commit the measurements: "Record the live checks of Apple's items".
