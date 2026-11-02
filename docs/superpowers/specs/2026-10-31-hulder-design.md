# Hulder: design

**Date:** 2026-10-31
**Owner:** Michael Rigart
**Status:** In progress (branch `feat/hulder-v1`; no merge request yet, because the repository has no remote). Signed off by Michael on 2026-10-31, after Codex's spec review.
**Name:** Hulder, after the hidden folk of Scandinavian folklore.
**Revised:** 2026-10-31, during the plan review. A reorder of items macOS isn't drawing
(hidden items) is reported as saved, not applied (Michael's decision). Diagnostics record
failures as fixed categories.
**Revised:** 2026-11-01, after the feasibility check. "Measured on macOS 27.2" records the
results. Order writes accept a microsecond window for a concurrent ⌘-drag, and moves are
confirmed through the saved order (Michael's decisions). Items without a bundle identifier
stay visible.
**Revised:** 2026-11-02, after the pre-merge review stopped converging. While an app whose
menus Hulder can't watch has an item on the bar, menu tracking is partial (Michael's decision).
First sightings, what the inventory remembers and menu-tracking coverage are restated for the
structural fix in the plan's Task 16a.

## Why

Michael uses Ice (`jordanbaird/Ice`) to hide menu bar items. Ice is unmaintained. Its last
stable release was in October 2024 and its last code change in June 2025. It has about 400
open issues and is broken on macOS 26 and 27. Its two live forks don't fit what Michael
wants:

- **Thaw** (`thaw-app/Thaw`) is active and well tested, but large: about 126k lines of
  non-test Swift. Its macOS 27 hiding and ordering live in a closed, prebuilt binary
  (PlatformRuntimeKit).
- **holzBar** (`holzcloud/holzBar`) has readable macOS 27 code. But it grew to about 69k
  lines in its first month, its core is untested, it coordinates through fixed delays, and
  it carries many speculative features.

Hulder is Michael's own menu bar manager. It is the third app in his Mac suite, after
Muninn and Linger. It does a few things reliably, and its codebase stays high quality when
macOS changes again.

## What macOS 27 allows

These facts come from Thaw's and holzBar's documentation and source, read on 2026-10-31.
They are used as facts only (see Clean room). holzBar measured them on macOS 27.0. **None is
verified on macOS 27.2**, which is what the owner's Mac runs. The plan's first task checks
the ones Hulder depends on; the next section records what it measured.

- **Items have no windows.** MenuBarAgent draws the whole bar. The window list no longer
  contains items, and Ice's trick of widening a status item to 10,000 pt to push items off
  screen no longer works: the system drops status items that don't fit.
- **Listing items.** Every process's menu bar items can be read through the public
  Accessibility attribute `kAXExtrasMenuBarAttribute`: frame, identifier, description and
  title. This needs the Accessibility permission. It is slow. holzBar measured 12.7 s for a
  first full scan, and Thaw times out with about 240 running apps. Thaw lists processes with
  `proc_listallpids`, because NSWorkspace's application list can be stale.
- **Hiding** goes through the private framework
  `/System/Library/PrivateFrameworks/MenuBarClientCore.framework`:
  - `MBAssessmentModeConfiguration` is created with
    `initWithAllowedSystemItems:allowedBundleIdentifiers:`. The first argument is an
    `NSArray` of `NSNumber`, the second an `NSArray` of `NSString`.
  - `MBAssessmentModeAssertion` is created with `init`. It is turned on with
    `activateWithConfiguration:completionHandler:`; the handler receives an error or nil, on
    any queue. It is turned off with `invalidate`.
  - **While an assertion is live,** the bar drops every application whose bundle identifier
    is not in the list. Hiding is therefore per application: all of one app's items hide
    together.
  - **Numbered system items.** On 27.0 only 0 (battery), 2 (clock), 6 (Wi-Fi) and
    8 (Control Center) drew anything. MenuBarAgent accepted every number from 0 to 127.
  - **Only a signed application bundle can hold an assertion.** From a command-line tool
    the call succeeds and hides nothing. Whether an ad-hoc signature counts is unknown.
  - **Make before break.** Activating a new assertion before invalidating the old one avoids
    a moment where everything shows.
  - MenuBarAgent animates the change itself, in about 250 ms.
- **Side effects while any assertion is live:**
  - Control Center's capture indicator (the camera, microphone and screen-sharing button)
    is not drawn. The small privacy dot beside the clock stays.
  - Focus, AirDrop, Now Playing, Fast User Switching and Live Activities are hidden. Items
    pinned from Control Center leave the bar.
  - Time Machine and the Input menu never hide. Game Mode cannot be hidden.
  - The clock and Control Center stay at the right end of the bar.
- **Order.**
  - **Where it's kept.** macOS keeps the bar's order in a protected file under
    `~/Library/Group Containers/com.apple.MenuBar`.
  - **Writing it.** Thaw writes positions into that file to reorder items. The pointer
    doesn't move and nothing flickers. For access, the user picks that file once in an open
    panel, with Full Disk Access as Thaw's fallback.
  - **Unknowns.** Whether MenuBarAgent applies a write immediately, and the file's format,
    are not documented. They are not visible in Thaw's source either, because its writes go
    through closed code.
  - **Other ways to reorder.** Users can still reorder items themselves by ⌘-dragging them.
    Whether a synthetic ⌘-drag works on 27 is unknown.
  - **Limits.**
    - The clock and Control Center can't move.
    - Items whose text changes (a temperature, a transfer rate) are placed from macOS's
      memory, so they land next to the intended spot rather than exactly on it.
- **Overflow.** On a crowded display with a notch, macOS 27 folds items that don't fit
  behind its own « button. There is no API for it.
- **Displays.** One set of items is shown on every display.
- **App location.** macOS only attributes a status item to its app when the app is in
  `/Applications`. Apps launched from elsewhere can fail to draw while hiding is on.

## Measured on macOS 27.2

Measured on 2026-10-31 and 2026-11-01 with the Debug probe, in an ad-hoc-signed build run
from `/Applications`. Where this section and the one above differ, this one holds.

- **Hiding (check 1) works with an ad-hoc signature.**
  - Activation completes in 0–19 ms, and invalidation takes effect at once. Nothing
    flickers, and switching make-before-break shows no flash.
  - Two live assertions intersect: an item shows only if every live assertion allows it.
  - Items whose owner has no bundle identifier stay visible while an assertion is live.
    They can't be hidden at all.
  - **Side effects.** The capture indicator and Focus are hidden. The battery and the
    privacy dot beside the clock stay. Allowing system items beyond 0–127 changes nothing.
- **Release (check 2).** After `abort()` or `kill -9`, MenuBarAgent drops the assertion
  within 1 ms.
- **Listing (check 3).**
  - **Speed.** A full `kAXExtrasMenuBarAttribute` pass over about 800 processes takes
    40–260 ms. Most processes return `kAXErrorCannotComplete` at once, because they have no
    Accessibility server. That means "no items", not a timeout.
  - **It depends on macOS's overflow.** While the overflow indicator is
    `menu-bar-overflow-indicator-expanded`, every app returns an empty list. Otherwise only
    items drawn on the bar are listed, and hidden items stay listed with a stale frame. Some
    apps' items never appear in it.
  - **MenuBarAgent's own windows are reliable.**
    - **What they hold.** MenuBarAgent's `AXDialog` windows hold one `AXGroup` per drawn
      status item, carrying the item's frame, plus the overflow indicator. They include the
      items the listing misses and Apple's own.
    - **Owners.** The group's child is a remote element whose process identifier gives the
      owning app.
    - **Overflow.** Items in macOS's overflow are stacked left of the indicator.
    - **No names.** Groups carry no identifier or description.
  - **No item notifications.** Accessibility notifications registered on an app's items are
    unsupported (`kAXErrorNotificationUnsupported`).
- **Menus (check 4): tracking is full.**
  - **What to observe.** On each app element: `kAXMenuOpenedNotification`,
    `kAXMenuClosedNotification`, `kAXWindowCreatedNotification` and
    `kAXUIElementDestroyedNotification`. Observe every running app whose activation policy
    isn't prohibited.
  - **What that catches:**
    - classic menus;
    - popovers;
    - window-style SwiftUI extras;
    - Control Center (`com.apple.controlcenter`);
    - the clock (`com.apple.notificationcenterui`).
  - **Events are hints.** Some popovers create a short-lived second window right after
    closing. So an event only means "re-read that app's windows". A menu counts as open
    while the app shows a menu, or a window anchored at the bar.
  - **Apple's owners.** LaunchServices runs SystemUIServer, Control Center, MenuBarAgent,
    Notification Center and TextInputMenuAgent as UI elements, so none of them has a
    prohibited activation policy (read with `lsappinfo` on 2026-11-02). The owner without a
    bundle identifier from check 1 runs background-only, which is the prohibited policy.
    Whether its menus produce these notifications isn't measured yet; Hulder observes it
    too, because it draws an item (see "Menu tracking").
- **The permission's name.** System Settings lists the Accessibility permission as "Device
  Control and Data Access", under Privacy & Security. Hulder's copy uses that name.
- **Launches.**
  - `NSWorkspace.didLaunchApplicationNotification` is not delivered for agent
    (`LSUIElement`) apps. Watch `NSWorkspace.runningApplications` instead.
  - **The launch gap.** An item created while its app was off the allowlist is drawn about
    20 ms after a new allowlist includes the app. The gap is therefore Hulder's own launch
    handling plus 20 ms.
- **The order file (check 6).**
  - **Location.** It is the preferences domain `com.apple.MenuBar` in the group container
    `~/Library/Group Containers/com.apple.MenuBar`, file
    `Library/Preferences/com.apple.MenuBar.plist`.
  - **Format.**
    - **One key,** `TrailingItemPreferredPositions`: a dictionary from item key to a
      number of points from the bar's trailing edge.
    - **Values.** The clock is 0, larger numbers sit further left, and halves occur.
    - **Leftovers.** Entries of apps that aren't running stay in the file.
  - **Item keys.**
    - `module:<Name>` for Control Center modules, such as `Clock`, `Battery`, `WiFi` and
      `FocusModes`;
    - `status:<bundle identifier or executable name>::<autosave name or Item-N>` for status
      items.
  - **Access.** Reading the container directly is denied, without a prompt. Choosing its
    folder in an open panel grants access without Full Disk Access. A security-scoped
    bookmark keeps that access across relaunches and ad-hoc rebuilds.
  - **Writing.**
    - **How.** Through the private container-aware preferences functions:
      - `_CFPreferencesCopyAppValueWithContainer`;
      - `_CFPreferencesSetAppValueWithContainer`;
      - `_CFPreferencesAppSynchronizeWithContainer`.

      They are looked up at run time.
    - **Speed.** A write takes under 1 ms. The file and a preferences read agree right
      after.
  - **Applied live.** MenuBarAgent moves the item at once, without flicker or a restart. No
    Accessibility event marks the move.
  - **The user's drags** reach the file at drag end, as one change. MenuBarAgent sometimes
    re-derives every drawn item's value from the current layout, and sometimes changes only
    the swapped items. A value is a preference, not a slot.
  - **Change signal.** A file-system watch on the container's `Library/Preferences` fires
    once per write, because the file is replaced. A preferences read at that moment is
    current.
  - **Concurrent drags.** The whole order is one preferences value, so a write means read,
    modify and set. There is no per-entry write and no compare-and-swap.
    - **Measured.** In 20 seconds, 364 writes during a native ⌘-drag lost nothing. The
      window between the read and the set is microseconds.
    - **Accepted.** Michael accepted that window (see Decisions).
  - **Unexplained.** Once, two entries went back overnight to their values from before a
    drag, with no Hulder write and no restart. Hulder treats the file as the truth and shows
    what it holds.
  - **Logout.** Whether a written order survives logging out isn't measured yet. It is
    checked at acceptance.

## Success

- Replaces Ice on Michael's Mac and runs from login for weeks without attention.
- Hidden apps stay hidden across restarts, logins, sleep and display changes. The layout is
  never lost.
- Quitting or crashing leaves the menu bar fully visible.
- Showing and hiding feel immediate: the only delay is macOS's own animation.
- A reorder made in Layout lands on the bar without the pointer moving and without
  flicker. Shown items appear next to Hulder's icon, unless the user has dragged them
  elsewhere.
- No measurable CPU use while idle.
- When macOS 28 changes the menu bar, the fix lives in the platform layer only. The core and
  the user interface don't change.

## Goals (v1)

1. **Three sections, assigned per app:** Visible, Hidden and Always Hidden.
2. **Show and hide.**
   - A click on Hulder's icon shows the Hidden apps; ⌥-click also shows Always Hidden.
   - Two global hotkeys do the same.
   - Hulder hides them again automatically.
3. **Reorder items.** Hulder's icon is the divider, as in Ice:
   - Hidden and Always Hidden items sit to its left, so shown items appear right next to it.
   - Visible items sit to its right.
4. **A Layout window** for assigning apps to sections and putting items in order.
5. **New apps** go to a default section, and to the matching side of the divider.
6. **Housekeeping.** Launch at login, no Dock icon, everything remembered.

## Non-goals (v1)

Each of these can come later, if it fits the architecture below.

- **A separate bar or panel for hidden items** (Ice Bar, Thaw Bar, holzBar's Shelf), and
  clicking items on the user's behalf.
- **Item images.** No Screen Recording permission. Layout shows each item as its app's icon
  with the item's Accessibility description.
- **Hiding Apple's own items:** the clock, battery, Wi-Fi, Control Center and Control
  Center modules.
- **Other features:**
  - search, profiles, triggers and rules;
  - groups, spacers, item spacing;
  - tint and appearance, widgets, notch features;
  - a URL scheme, CLI, AppleScript or Shortcuts;
  - stand-in items;
  - hiding through System Settings' per-app switches.
- **Distribution:** automatic updates, localisation (English only), and the Mac App Store.
  The App Store is impossible: Hulder uses a private framework and cannot be sandboxed.
- **macOS 26 and earlier.**

## Anti-goals

Hulder has failed, even if it works, if it:

- leaves anything hidden after it quits or crashes;
- loses or changes the user's section choices on its own, for example after an update, a
  slow scan or an app that isn't running;
- treats a scan that timed out as "this app has no items";
- hides items while a menu or popover opened from the menu bar is showing;
- shows hidden items for its own purposes, so icons never flicker;
- fights macOS with retry or repair loops: when a change fails, it says so and waits for
  the next user action or layout change;
- posts synthetic mouse or keyboard events, or moves the pointer. Reordering goes through
  macOS's order file only;
- writes any system file other than macOS's menu bar order file. That file is written only
  under the rules in "Order" below, and Control Center's preferences are never touched;
- moves an item back after the user, or macOS, moved it;
- blocks the main thread on an Accessibility or private call, or hangs when one doesn't
  answer;
- crashes or degrades silently when macOS removes a private symbol: it must say what isn't
  supported;
- asks for any permission other than Accessibility and access to the order file (picked by
  the user; never Full Disk Access);
- makes any network connection, or collects telemetry;
- shows a Dock icon, or opens windows nobody asked for.

## Constraints

- **Platform.** macOS 27 and later; deployment target 27.0.
- **Stack.**
  - Swift 6 with strict concurrency checking. SwiftUI for windows. AppKit `NSStatusItem` for
    Hulder's own icon, because it needs click, ⌥-click and right-click handling. Swift
    Testing.
  - Not sandboxed (Accessibility access to other apps and a private framework rule it out).
    Hardened Runtime on.
- **Install location.** Hulder runs from `/Applications` (see App location above).
- **Identity.** Bundle identifier `com.michaelrigart.hulder`.
- **Signing.** Ad-hoc, like Linger, unless the feasibility check shows the assertion needs a
  real signing identity. The Accessibility grant is tied to the signature, so every ad-hoc
  rebuild needs it granted again.
- **Toolchain.** The same as Linger:
  - Xcode through `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` per command.
  - XcodeGen, pinned in the repository's `mise.toml`; the generated project is not tracked.
  - Builds and tests run outside any agent sandbox.
- **Repository and license.**
  - Lives at `~/Code/hulder`, under the MIT license.
  - Becomes a public GitHub repository under `michaelrigart` when Michael says so.
  - Public docs stay free of details about Michael's machine.

## Architecture

Michael asked for a stable core that a macOS 28 change can't reach, and for a codebase that
stays high quality. Hulder has three parts.

1. **HulderCore**, a Swift package. It uses Foundation only: no AppKit, SwiftUI,
   ApplicationServices or `#available` checks. It holds:
   - **The model:**
     - an app's identity (its bundle identifier) and the three sections;
     - the layout, meaning each known app's section, the default section for new apps, and
       each known app's display name and when it was last seen;
     - a versioned storage format.
   - **The reveal state machine:**
     - States: hidden, revealed, revealed-all.
     - Inputs: icon clicks, hotkeys, the rehide timer, menus opening and closing, screen
       lock and quit.
     - The clock is injected.
   - **The concealment planner.** From the layout, the reveal state and the running apps, it
     works out what should be concealed. The answer is either nothing, or an allowlist of
     apps plus a policy to keep every system item. The core never sees MenuBarAgent's item
     numbers; the platform layer translates the policy into them.
   - **The order planner.** It turns a Layout edit, or a first sighting, into the smallest
     set of moves. It takes the bar's current order and returns which items move and where.
     It never plans a move nobody asked for.
   - **The platform interface** (described below). It is declared here and implemented
     elsewhere.
2. **The platform layer** for macOS 27.
   - **What it implements:**
     - the Accessibility scan;
     - observing app launches and quits;
     - detecting open menus;
     - managing the assertion;
     - reading and writing the order file.
   - **Where version specifics go:** every private symbol and every `#available` check
     lives here.
   - **macOS 28:** it gets its own implementation or changes confined to this layer. One
     factory picks the implementation at launch.
3. **The app target.**
   - **What it holds:**
     - the composition root, which builds the components and passes each its
       dependencies;
     - the status item, the Layout window and Settings;
     - hotkeys, launch at login, the permission prompt and logging.
   - **What it doesn't hold:** business rules.

### The platform interface

Names are left to the builder. The contract is:

- **Capabilities.** What this macOS supports (per-app hiding, reordering, full or partial
  menu tracking), and a reason for anything unavailable.
- **Item records.** Each item has:
  - an opaque key that stays the same across launches;
  - its owner: either a bundle identifier with a display name, or an unresolved owner
    (a process with no bundle identifier) with its process name;
  - its Accessibility description and title.

  Inventory and Order use the same keys.
- **Order.**
  - **Read** the bar's current order: item keys in left-to-right order, plus which items
    macOS pins.
  - **Change it:** move items to positions. This is idempotent, and it confirms once
    macOS's saved order matches (see "Confirming").
  - **Drawn items.** Say which items MenuBarAgent draws right now, read once on request.
  - **One write at a time.** Writes go through one owner, one at a time.
  - **Concurrent updates.**
    - **The rule.** A write must not overwrite a change MenuBarAgent makes at the same
      moment, such as a native drag recorded between Hulder's read and its write.
    - **On macOS 27.** The order is one preferences value, so no mechanism rules this out
      completely. A write therefore re-reads the order through the preferences system
      immediately before writing, and changes only the moved items' entries. That leaves a
      window of microseconds, which Michael accepted (see Decisions).
    - **Not enough.** Replacing the file atomically, even after re-reading it, still loses
      updates: atomicity only prevents partial files.
  - **Change events.** Report order changes made by anyone, including the user's own
    ⌘-drags.
- **Running apps.** A stream of the running applications' bundle identifiers, from launch
  and quit events. This is what the planner allowlists from. It does not wait for the
  scan.
- **Inventory.** A stream of scan passes. A pass holds what one look at the bar found, and
  nothing remembered:
  - the items drawn, per owner;
  - the running apps the live concealment hides that aren't drawn, each with the items the
    order file lists for it;
  - whether the bar and the order file could be read.

  The core builds the inventory from the passes.
  - **What it remembers:** the items each owner was last seen drawing, for the whole run, also
    after the app quits. An app it can't see now, because it is hidden or the bar can't be
    read, keeps those items, marked stale. Order entries add items only for a hidden app
    Hulder hasn't seen drawn.
  - **Nothing is dropped** by a pass that couldn't read the bar.
  - **What it's for:** Layout and first sightings only. It never decides what gets hidden.
- **Apply a concealment.** Idempotent and make-before-break. It returns once MenuBarAgent
  confirms, and throws after a timeout. One owner manages assertions, and requests run one
  at a time. Each request has a generation number, and only the newest generation's
  assertion may stay live.
  - **Timeout.** When an activation times out, the pending assertion is invalidated at
    once.
  - **Late completion.** A completion that arrives after its timeout, or after a newer
    request superseded it, invalidates its own assertion and changes nothing else.
  - **Make-before-break only between confirmed assertions.** A newer assertion is
    activated before the older confirmed one is invalidated. A failed activation leaves
    the older one in place.
- **Menu tracking.** Events for when a menu or popover opened from the menu bar appears and
  disappears, and a capability that says whether tracking is full or partial.
  - **Covered:** every process that draws an item on the bar, by process, and the system apps
    whose menus open from Apple's items (Control Center and Notification Center). A process
    stays covered until a scan no longer finds its item.
  - **Full** while Hulder watches every covered process.
  - **Watched:** Hulder observes every covered process, whatever its activation policy and
    whether macOS lists it as a running app. A process counts as watched once its observer
    has registered for all four notifications.
  - **Partial** while a covered process isn't watched: its observer failed or missed a
    notification (see Decisions).
- **Release everything.** Used at quit.

A fake implementation of the interface drives the core's tests.

### The quality bar

- Version checks and private API live only in the platform layer.
- No central object that every component reaches into. Each component has one
  responsibility and receives its dependencies explicitly.
- Coordination is event-driven. A timeout is an upper bound on a wait, never a way to let
  things settle. The only timer users see is the rehide delay, which lives in the core and
  runs on the injected clock.
- Every blocking Accessibility or private call runs off the main actor and off Swift's
  cooperative thread pool, with a timeout.
- Every private symbol is looked up at run time (`dlopen`, `NSClassFromString`,
  `instancesRespond(to:)`). If one is missing, the capability is switched off and Settings
  says so. Hulder never crashes over it.
- `@unchecked Sendable` and `nonisolated(unsafe)` are allowed only with a stated reason.
- Every state transition and planner rule has a test with exact expected values.

## How it works

### Sections and the allowlist

- **Visible** apps always show. **Hidden** apps show while revealed. **Always Hidden** apps
  show only while revealed-all.
- **The allowlist is built from running apps, not from the scan.** In the hidden and revealed
  states, it holds:
  - every running app that the current state doesn't hide. That includes apps not yet in
    the layout when the default section is Visible;
  - every app in the layout that is assigned Visible, running or not, so it shows the moment
    it launches;
  - Hulder's own bundle identifier;
  - the policy "keep every system item", so Hulder never hides one. On macOS 27 the
    platform layer turns this into the numbers 0 to 127, the whole range MenuBarAgent
    accepts, which also covers system items a later build adds.

  An app whose items appear late, or that the scan hasn't reached yet, therefore isn't
  hidden by mistake. If hidden apps drop out of the scan, nothing changes either.
- **When an assertion is live:**
  - **Hidden and revealed states:** whenever at least one running app is assigned Hidden or
    Always Hidden. If none is, no assertion is held.
  - **Revealed:** keeps an assertion even when no Always Hidden app is running, so the bar
    doesn't reflow on every reveal.
  - **Revealed-all:** drops the assertion entirely, so everything shows, Apple's items
    included.
- **The cost.** In everyday use some Hidden app is almost always running, so macOS's side
  effects are present most of the time: the capture-indicator button, Focus, AirDrop, Now
  Playing and pinned Control Center controls are off the bar. ⌥-click (revealed-all)
  brings them back. This follows from choosing the assertion (see Decisions).
- **Items with an unresolved owner** (a process with no bundle identifier) can't be
  allowlisted. On macOS 27.2 they stay visible whenever an assertion is live, so Hulder can't
  hide them. Layout lists them read-only, with that reason. Menu tracking covers their
  process like any other owner's.
- **Apple's own items** appear in Layout as "managed by macOS" and can't be assigned in v1.
  The builder measures which owners count as Apple's: Control Center, SystemUIServer and the
  numbered system items at least.
- **One section per app.** An app with several items has them all in one section.
- **Re-applying.** The allowlist is recomputed and applied again after:
  - a layout change;
  - a change of reveal state;
  - an app launching or quitting.
  
  An unchanged allowlist is not applied again.

### Showing and hiding

- **Clicks on Hulder's icon.**
  - A click switches between hidden and revealed.
  - ⌥-click goes to revealed-all.
  - Right-click opens a menu with Layout…, Settings… and Quit.
- **Hotkeys.** One toggles, one reveals all. They are unset by default.
- **Hiding again automatically.**
  - Hulder hides again after a delay, 10 s by default, with a "never" choice. The delay
    counts from the moment items were shown, or from when the last menu bar menu closed.
  - It never hides while a menu or popover opened from the menu bar is showing; it waits
    until that closes.
  - **If menu tracking is partial,** automatic rehiding is not available. Hulder hides on a
    click, a hotkey, lock or sleep only, and Settings explains why. A rehide that was
    counting down is cancelled.
    - **When.** Tracking is partial while an app whose menus Hulder can't watch has an item
      on the bar (see "Menu tracking"). Once no such item is drawn, automatic rehiding is
      available again.
  - A click on Hulder's icon hides at once.
  - Locking the screen or sleeping hides as well.

### Order

- **The divider.** Left to right, the bar holds:
  1. the Always Hidden items;
  2. the Hidden items;
  3. Hulder's icon;
  4. the Visible items;
  5. the items macOS pins (the clock and Control Center).

  Shown items therefore appear right next to Hulder's icon.
- **Hulder writes the order only when:**
  - **The user edits Layout.** Only the items the user moved are written.
  - **A section changes.** The app's items move to the boundary of their new section, next
    to the divider, keeping their relative order. The exception is when the user dropped
    them at a particular spot in Layout.
  - **An app is seen for the first time.** Hulder places its items once, on the side of
    the divider that matches its section.

  It never writes at launch, on a timer, or to repair an order.
- **The user's own drags are respected.** When the user ⌘-drags an item, or macOS moves
  one, Hulder reads the new order and shows it.
  - Hulder doesn't move the item back, and a native drag never changes an app's section.
  - Layout marks items that are now on the wrong side of the divider. A **Tidy** action
    moves just those, and only when the user asks.
- **Writing safely:**
  - **Before each write,** Hulder copies the file into its own Application Support folder,
    keeping the last 10 copies. Settings can restore the copy from before Hulder's last
    change.
  - **Coordinated with macOS.** Writes go through the preferences system and re-read the
    order immediately before writing (see "Concurrent updates"). They change only the
    positions of the items being moved and keep everything else in the file as it is.
  - **Stale plans.** If the order changed since the moves were planned, Hulder plans once
    more from the new order. If it changed again, Hulder gives up and says so.
  - **Unknown format.** Hulder recognises the file's format as measured in the feasibility
    check. If the format is anything else, reordering is switched off with the reason
    shown, and Hulder never writes.
  - **Confirming.** After a write, Hulder waits, with a timeout, for macOS's saved order to
    match. If the timeout passes, Hulder says so and does not retry.
    - **Why the saved order.** macOS 27.2 applies a saved order to drawn items at once, and
      nothing on the bar signals a move. Watching the bar would mean polling.
    - **"Applied"** is used when at least one moved item is drawn.
    - **Items macOS isn't drawing,** such as hidden items, have their reorder reported as
      saved. Layout says: "Saved. macOS applies it when these icons are shown."
    - Hulder never reveals hidden items to check.
- **Access to the file.** The first time the user reorders, Hulder asks for the file through
  an open panel pointed at it, and keeps that access across launches. Without it,
  reordering is unavailable and Layout still assigns sections. Hulder never asks for Full
  Disk Access.

### New apps

- **First sighting.** An app seen with items for the first time goes to the default
  section, which is Visible by default. Hulder records its section and places its items on
  the matching side of the divider. Changing the default later doesn't move apps it
  already knows.
  - **Only from a scan that can place it.** Hulder records a first sighting from a scan that
    read the order file, once it can write the order, so the items carry the keys macOS
    uses. Until then the app stays new: it follows the default section, and the next such
    scan records and places it.
  - **Without reordering** (no access to the order file, or a format Hulder doesn't know),
    the app is recorded and not placed. Granting access later doesn't move it.
- **Apps not running** stay in the layout with the date they were last seen. Layout can
  forget them.
- **The short gap.** An app launched for the first time is not on the allowlist yet, so
  macOS hides it until Hulder handles the launch event. That gap should be short; the
  feasibility check measures it. It also checks that an item created while its app was off
  the allowlist appears once the app is added.

### Layout window

- **What it shows.** Three rows, one per section, laid out like the bar.
  - Each row holds its section's items in bar order.
  - Each item shows its app's icon. The item's Accessibility description and the app's name
    appear on hover and to VoiceOver.
  - Apps that aren't running appear dimmed, at the end of their row.
- **Moving items.**
  - Drag an item within a row to reorder it, or to another row to change its app's section.
  - Moving one item to another section moves all of that app's items.
  - A "Move to" context menu and the keyboard do the same.
  - Changes apply immediately.
- **What can't be assigned.** Apple's items and items with an unresolved owner are listed
  read-only, each with a one-line reason.
- **macOS 27's limits.** A short section lists what macOS 27 doesn't allow (from the
  section above), so users don't report those limits as Hulder bugs.

### Settings

- **General:**
  - launch at login, on by default;
  - the default section for new apps;
  - the rehide delay;
  - the two hotkeys.
- **Permissions:** the state of the Accessibility permission and of access to the order
  file, each with a button to grant it.
- **Order:** restore the menu bar order from before Hulder's last change.
- **About:**
  - the version;
  - capability states, including "not supported on this macOS" with its reason;
  - Copy Diagnostics: the macOS version, capabilities, counts and recent failures, but no
    file paths and no app names.
    - **Failures** are recorded as a fixed set of categories with fixed wording.
    - **Capability reasons** are fixed text written by Hulder.
    - **System error descriptions** go only to the log, never into the report.

### Permissions and first launch

- **Accessibility is required.** Without it, Hulder can't tell which apps own items. It
  then holds no assertion and shows a short onboarding window that explains the permission.
- **Launching for testing.** Start the app with `open` or Finder. Launched from a terminal,
  macOS attributes the Accessibility permission to the terminal (learned on Linger).

### Startup, quit and crash

- **At launch,** Hulder applies the stored layout to the running apps as soon as the
  platform layer is ready, before the first full scan finishes. Hulder's own start-up then
  adds no flash of hidden apps.
  - **What it can't prevent:** a Hidden app that starts before Hulder (another login item,
    or an app macOS reopens) can show briefly until Hulder applies the layout.
  - **How it launches at login:** as an ordinary login item through `SMAppService`.
- **At quit,** it invalidates the live assertion and any pending one before exiting.
- **After a crash,** Hulder relies on MenuBarAgent dropping the assertion when the
  process dies. The feasibility check proves this. If it doesn't hold, stop and bring it
  to Michael.

### Failures

- **The assertion is rejected or times out** (3 s). The icon's menu shows that hiding
  failed, and Hulder logs it. It does not retry on its own; the next user action or layout
  change tries again.
- **MenuBarClientCore or one of its classes is missing.** The capability is switched off,
  and Settings says "not supported on this macOS" with the reason. Hulder holds nothing.
- **The bar can't be read.** Hulder keeps the items it last saw and marks them stale.
- **An order write fails or isn't confirmed.** Layout says so. Hulder does not retry on its
  own.

### Logging

Hulder uses Unified Logging with subsystem `com.michaelrigart.hulder`. State changes and
failures are logged at notice level so they persist. Read them with `/usr/bin/log`, because
zsh has a `log` builtin.

## Verification

- **Core unit tests** (Swift Testing) pin exact expected values:
  - **The planner:**
    - the exact allowlist for each reveal state with a fixed layout and fixed running apps;
    - no assertion in the hidden or revealed state when no running app is Hidden or Always
      Hidden;
    - the revealed state keeps its assertion when no Always Hidden app is running;
    - no assertion in the revealed-all state;
    - Hulder's own identifier and the "keep every system item" policy are always in the
      allowlist;
    - known Visible apps that aren't running are allowed;
    - unknown running apps follow the default section;
    - an inventory change alone never changes the allowlist.
  - **The state machine:**
    - toggling and revealing all;
    - rehiding after the delay on the injected clock;
    - waiting while a menu is open, with the delay restarting when it closes;
    - no automatic rehiding when menu tracking is partial;
    - hiding on lock.
  - **The order planner:**
    - the exact moves for a reorder within a section;
    - the exact moves for a section change, with the app's items placed at the divider
      boundary and their relative order kept;
    - the exact moves for an explicit drop position;
    - placement on first sighting for each section;
    - Tidy moves only the misplaced items;
    - pinned items are never moved;
    - a native reorder produces no moves and no section change.
  - **The layout:**
    - an app is never dropped on a timeout or a quit;
    - storage round-trips;
    - a file from an unknown future version is refused and never overwritten.
  - **The inventory:**
    - a hidden app keeps the items it last drew, marked stale, also after it quits and comes
      back hidden, and its order entries add none;
    - a pass that couldn't read the bar drops nothing.
  - **First sightings:**
    - recorded and placed only from a scan that read the order file, once the order can be
      written, in one change;
    - recorded and never placed while reordering is unavailable;
    - capability changes before that never lose an app.
  - **Against the fake platform:**
    - the new assertion is activated before the old one is invalidated;
    - a failed activation keeps the old one;
    - an activation that times out is invalidated. If it completes late, after the user
      has moved to revealed-all, it is invalidated and nothing ends up hidden;
    - a pending activation superseded by a newer request is invalidated when it
      completes;
    - an unchanged allowlist is not applied again;
    - order writes run one at a time, and each is preceded by a backup;
    - an order that changed since planning is planned once more, then given up on;
    - an unrecognised format disables reordering and is never written.
- **A platform probe** for Debug builds only, started with a launch argument as in Linger. It
  runs from `/Applications` on a real Mac and logs:
  - the scan time and each app's result;
  - the effect of an allowlist that leaves out a chosen app, checked through
    Accessibility;
  - the release;
  - that "keep every system item" keeps the clock, battery, Wi-Fi and Control Center on
    the bar;
  - the order file's format, and the effect of moving one chosen item, checked through
    MenuBarAgent's item groups.
  
  It is run again on every new macOS release.
- **Manual acceptance on Michael's Mac:**
  - assign apps to all three sections;
  - reorder items in Layout, and see shown items appear next to Hulder's icon;
  - a ⌘-drag on the bar shows up in Layout and is not undone;
  - restoring the order from Settings works;
  - show and hide by click, ⌥-click and hotkey;
  - automatic rehiding waits while a hidden app's menu is open;
  - the layout survives a restart and a reboot;
  - quitting and `kill -9` both leave every item visible;
  - Hulder's start-up adds no flash of hidden apps at login;
  - idle CPU stays at 0%.

## Delivery

- **v1 deliverable:** Hulder.app, built locally, installed in `/Applications`, launching at
  login and replacing Ice.
- **The plan's first task is a feasibility check on macOS 27.2,** using a signed app bundle
  run from `/Applications`, before any user-interface work:
  1. An assertion hides an app that isn't on the allowlist, keeps the ones that are, and
     invalidating it restores everything. Switching between two assertions
     make-before-break shows no flash. Record whether an ad-hoc signature is enough.
  2. Quitting, and killing the process with `kill -9`, both restore every item. Record how
     quickly.
  3. The Accessibility scan:
     - the full-scan time on Michael's Mac;
     - whether apps that are hidden still appear in it;
     - whether each item's owning bundle identifier can be resolved.
  4. A way to detect that a menu or popover opened from another app's menu bar item is
     showing.
  5. The side effects on 27.2: the capture indicator, the privacy dot, and Focus, AirDrop and
     Now Playing. Also how long a newly launched app stays hidden before Hulder allowlists
     it, and whether an item created while its app was off the allowlist appears once the
     app is added.
  6. The order file:
     - its location and format on 27.2;
     - a write mechanism that cannot lose a concurrent MenuBarAgent update. One example is
       key-level updates through the preferences system, if the file is a preferences
       domain. Test it with a native ⌘-drag made while Hulder writes;
     - whether access picked by the user in an open panel works, and survives a relaunch,
       without Full Disk Access;
     - whether MenuBarAgent applies a write immediately, without a restart and without
       flicker;
     - whether the user's own ⌘-drags show up in the file, and how quickly;
     - whether a written order survives logging out and back in.
- **Michael at the Mac.** The check needs him there for about half an hour. He watches for
  flashes and side effects, and grants Accessibility again after each ad-hoc rebuild.
- **Signing.** The Mac had no code-signing identity on 2026-10-31. If an ad-hoc build holds
  an assertion that hides nothing, that can't be told apart from the API not working on
  27.2. Stop and ask Michael to set up an identity (a free Personal Team in Xcode), then
  repeat check 1.
- **Stop and bring it to Michael** if:
  - check 1 or 2 fails;
  - check 1 needs a signing identity other than ad-hoc;
  - the privacy dot beside the clock disappears while an assertion is live;
  - check 6 shows that the order file can't be written safely and applied live. Examples:
    there is no write mechanism that is safe against concurrent updates, a write only takes
    effect after MenuBarAgent restarts, or access needs Full Disk Access.
    The alternatives (synthetic ⌘-drags, or Full Disk Access) are design changes.

  Each of these changes what gets built.

## Clean room

Thaw and holzBar are GPL-3.0; Hulder is MIT.

- **No GPL code.** Implementers neither read nor copy their source.
- **Facts are free to use.** This spec carries the facts Hulder needs (the framework path,
  class and selector names, and measured behaviour), and facts aren't copyrightable. The
  sources are credited in "What macOS 27 allows".
- **Further facts** come from Apple's SDK, from inspecting the framework at run time on the
  Mac, and from Hulder's own probe.

## Left to the builder

- Code structure inside the three parts, and all names.
- The storage format, as long as it is versioned and readable.
- The hotkey mechanism.
- The menu-detection mechanism, subject to the feasibility check.
- How the order file is read and written, within the rules in "Order" and as measured by
  the feasibility check.
- Accessibility timeout values.
- The icon artwork, and the Layout window's visual design within the behaviour described
  above.

## Decisions

**Michael decided (2026-10-31):**

- Build his own app rather than adopt or fork Thaw or holzBar.
- MIT license.
- macOS 27 and later only.
- A stable core, with macOS-version specifics isolated so that macOS 28 touches one layer.
  Few features, done properly. A codebase that is and stays high quality.
- No throwaway spike before this spec. Feasibility is the plan's first task.
- The name is Hulder.
- Reordering is in v1.
- Where there's a choice, pick the best solution, judged first by code quality, then by UI
  and UX.
- A reorder of items macOS isn't drawing is reported as saved, not applied. Hulder doesn't
  reveal them to confirm it (option A, chosen during the plan review).

**Michael decided (2026-11-01, after the feasibility check):**

- **Order writes accept a microsecond window.** On macOS 27 the order is one preferences
  value, so no write can rule out overwriting a ⌘-drag recorded between Hulder's read and
  its write. Hulder re-reads immediately before each write, and writes once per user action
  or first sighting, never on a timer. The alternative was no reordering in v1.
- **Moves are confirmed through the saved order,** not by watching the bar. Watching the
  bar would need polling, and it still couldn't see items Accessibility doesn't list.

**Michael decided (2026-11-02, after the pre-merge review stopped converging):**

- **Partial tracking while an unwatched app is on the bar.** While an app whose menus Hulder
  can't watch has an item drawn on the bar, menu tracking counts as partial, so automatic
  rehiding is unavailable and Settings says why. Once no such item is drawn, it is available
  again. This extends "if menu tracking is only partial, automatic rehiding is not
  available". The alternative was to keep automatic rehiding on and risk hiding while that
  app's menu is open.
- **One structural fix** replaces three rounds of patches: first sightings wait for a scan
  that can place them, the core remembers what each app last drew, and menu tracking covers
  every process that draws an item (the plan's Task 16a).

**My calls** (Michael to confirm when reading):

- **Hiding through the assertion,** rather than through System Settings' per-app switches.
  - The assertion dies with the process, so a crash can't leave anything hidden.
  - It needs no writes to Control Center's preferences.
  - It covers apps that have no System Settings entry.
  - The cost is macOS's side effects while anything is hidden. ⌥-click (revealed-all) brings
    Apple's items back.
- **Reordering only through macOS's order file,** never with synthetic ⌘-drags. It moves no
  pointer and causes no flicker.
- **Hulder's icon as the divider,** with Tidy and restoring the order as user actions only.
- Bundle identifier `com.michaelrigart.hulder` and repository `~/Code/hulder`.
- The v1 scope as listed in Goals and Non-goals: no hidden-items bar, no item images, no
  hiding of Apple's items.
- The allowlist is built from running apps and known Visible apps, never from the scan.
- The revealed state keeps its assertion, so the bar is steady; revealed-all drops it.
- New apps default to Visible.
- A rehide delay of 10 s by default; hiding again on lock and sleep. If menu tracking is
  only partial, automatic rehiding is not available at all, rather than offered with a
  risk.
- "No flash at login" covers Hulder's own delay. Apps that start before Hulder can show
  briefly. Launch at login goes through `SMAppService`.
- Hotkeys unset by default.
- Linger's toolchain (XcodeGen in `mise.toml`) and ad-hoc signing.
- Not sandboxed, and therefore never on the App Store.
- English only.
