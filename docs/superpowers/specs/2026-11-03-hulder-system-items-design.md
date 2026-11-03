# Hulder: Apple's own menu bar items — design

**Date:** 2026-11-03
**Owner:** Michael Rigart
**Status:** In progress ([PR #3](https://github.com/michaelrigart/hulder/pull/3)). Signed off by the controller on 2026-11-03 under Michael's overnight delegation
("if you know a working solution for the system icons, do implement it"), after Codex's spec
review; for Michael to confirm.
**Builds on:** `docs/superpowers/specs/2026-10-31-hulder-design.md` (v1, implemented). This
design supersedes v1's "Apple's own items appear in Layout as 'managed by macOS' and can't be
assigned in v1". Everything else in v1 holds.

## Why

Michael's words: Apple's items should get "the same full functionality as we have for the
application icons", hiding and reordering alike. He named Wi-Fi, Battery, Input, Siri and
Control Center. v1 listed them read-only, because what macOS allows for them had not been
measured. It has now (below), and most of it works.

## Measured on macOS 27.2 (2026-11-03)

Measured with the Debug probe launched from `/Applications`, while Hulder itself was not running:
- the bar was read through Accessibility from MenuBarAgent's windows;
- the order was changed through the shipped order store and restored afterwards.

- **Apple's items and their owners.** MenuBarAgent draws the modules. Each hosts a menu extra
  whose identifier names it, keyed in the order file as below. SystemUIServer and
  TextInputMenuAgent draw status items.

  | Item | Identifier | Order file key | Owner |
  |---|---|---|---|
  | Battery | `com.apple.menuextra.battery` | `module:Battery` | MenuBarAgent |
  | Wi-Fi | `com.apple.menuextra.wifi` | `module:WiFi` | MenuBarAgent |
  | Focus | `com.apple.menuextra.focusmode` | `module:FocusModes` | MenuBarAgent |
  | Clock | `com.apple.menuextra.clock` | `module:Clock` | MenuBarAgent |
  | Control Center | `com.apple.menuextra.controlcenter` | `module:BentoBox-0` | MenuBarAgent |
  | Sound | `com.apple.menuextra.sound` | `module:Sound` | MenuBarAgent |
  | Siri | — | `status:com.apple.systemuiserver::Siri` | SystemUIServer |
  | Input menu | — | `status:com.apple.TextInputMenuAgent::Item-0` | TextInputMenuAgent |

- **Hiding modules.** The assertion's first argument lists the numbered system items to keep.
  On 27.0 and 27.2, keeping the ranges 0…127, 0…7, 0…5, 0…1 and 0…0 in turn showed that Battery,
  Clock, Wi-Fi and Control Center each have their own number. Sound's row comes from the later
  measurement noted below the table:

  | Number | Item |
  |---|---|
  | 0 | Battery |
  | 2 | Clock |
  | 5 | Sound |
  | 6 | Wi-Fi |
  | 8 | Control Center |

  Battery, Clock, Wi-Fi and Control Center map as measured on 27.0. Leaving a number out hides
  that item.
  Sound (5) was measured later on 2026-11-03 with wired EarPods connected, which draws it: the
  probe kept system items 0…N with Corsair hidden and read the bar. N = 0, 1, 3 and 4 drew no
  Sound; N = 5 drew battery, clock and sound; N = 7 added Wi-Fi; N = 8, 15, 31 and 63 drew all five.
- **Focus** is hidden whenever any assertion is live, whatever the numbers. That is v1's
  measured side effect. It can't be shown while anything is hidden.
- **Hiding Siri and the Input menu** works like hiding any app: leave its owner's bundle
  identifier off the allowlist. On 27.0 the Input menu never hid; on 27.2 it does.
- **Reordering** works through the order file exactly as for apps. Writing `module:WiFi`
  before Corsair, and Siri before the Input menu, moved both live.
- **Pinned items.** The order file marks Clock and Control Center (`module:BentoBox-0`, `module:Clock`) as
  pinned. macOS keeps them at the right end, so they can't be reordered.
- **Other modules** in the order file (Display, Now Playing, Screen Mirroring, Audio and
  Video) weren't drawn on Michael's bar. Their system item numbers are unknown, so Hulder
  doesn't hide them. Sound is measured (above) and hideable.

### Live check of this build (unattended, 2026-11-03)

Debug build of `feat/hulder-system-items` at `10cac8d`, installed in `/Applications` and launched
by running its executable directly. The bar was read through the terminal's Accessibility grant
(MenuBarAgent's own groups, by menu-extra identifier). Baseline: battery, clock, controlcenter,
focusmode and wifi drawn.

| Run | Drawn while hidden | After invalidate or quit |
|---|---|---|
| probe `hide-items WiFi` | battery, clock, controlcenter (Wi-Fi and Focus gone) | all five back |
| probe `hide-items Battery Clock BentoBox` | wifi only (Focus gone too) | all five back |
| Hulder with `systemItems: {WiFi: hidden}`, no app assigned, default Visible | battery, clock, controlcenter (Wi-Fi and Focus gone) | all five back once Hulder quit |

- The numbers 0, 2, 6 and 8 hide Battery, Clock, Wi-Fi and Control Center exactly as in the table
  above. Focus goes with any assertion, as before.
- The Wi-Fi hide came from the state file alone: the planner built `hiddenSystemItems == [WiFi]`
  and the backend sent 0…127 without 6.
- **Probe finding:** `hide-items` logged `reportedHidden=` empty and `stillDrawn=<modules>` even
  though the bar hid them. The main cause was the probe's sorting: it took the modules in a pass's
  drawn entries as drawn, but while MenuBarAgent draws anything the scan reports a hidden module
  among its drawn items, without a bar position. A second cause was the timing: the probe read the
  bar the instant the assertion was live, before macOS reflows it. The Accessibility reads above
  were taken after about a second. The fixed probe sorts modules by bar position (none means
  hidden) and reads the bar a second after the activation. Rerun live at `0b64678` with
  `hide-items WiFi`: `drawn=Battery,BentoBox,Clock reportedHidden=WiFi stillDrawn=`, and the bar
  lost Wi-Fi and Focus.
- **Not covered here:** Siri and the Input menu hiding, Layout's drag and drop, and a click that
  brings Wi-Fi back. Those are acceptance item 2, for Michael.

### Live check with Michael (2026-11-03)

Debug build of `feat/hulder-system-items` at `e5fc305` (the app code of `798f41d`), signed ad
hoc, installed in `/Applications` and launched with `open`. Accessibility and the menu bar folder
were granted in Settings. Michael ran acceptance item 2 in the Layout window, and every check
passed:

- Wi-Fi assigned to Hidden disappeared and came back on a click.
- Battery assigned to Always Hidden came back on ⌥-click.
- Siri assigned to Hidden hid. The assignment went to its owner, SystemUIServer (the log reads
  `Section: com.apple.systemuiserver is hidden`).
- Wi-Fi dragged in Layout moved on the bar.
- Clock dragged was refused, with its reason.
- Layout kept listing Wi-Fi while it was hidden.

Finding: in Layout, Apple's items showed their owners' generic app icon, because MenuBarAgent,
SystemUIServer and TextInputMenuAgent are background agents with no icon of their own. Fixed on
this branch: they now show a symbol (see "Layout window").

## Goals

- **Seven items get the app items' functionality**, as far as macOS 27.2 allows: Battery, Wi-Fi,
  Clock, Sound and Control Center (modules), and Siri and the Input menu (status items of Apple
  apps). They can be:
  - assigned to Visible, Hidden or Always Hidden;
  - hidden and shown with the reveal states, hotkeys and automatic rehiding;
  - reordered in Layout (drag, Move Left/Right, ⌘←/→, Move to);
  - covered by Tidy, the misplaced marker, and placement at the divider when their section
    changes, once assigned.
- **The unit of assignment:**
  - each module is assigned on its own;
  - Siri and the Input menu are assigned through their owning app
    (`com.apple.systemuiserver`, `com.apple.TextInputMenuAgent`), as any app is.
- Layout keeps listing a hidden Apple item, as it does a hidden app's items.
- The probe can measure system item numbers again on a new macOS.

## Non-goals

- Showing Focus, AirDrop, Now Playing, the capture indicator or pinned Control Center
  controls while anything is hidden. macOS hides them; ⌥-click still brings them back.
- Assigning or reordering Focus, or modules whose number isn't measured (Display, Now
  Playing, Screen Mirroring, Audio and Video, any other). They stay read-only in the "Can't be
  assigned" list when drawn, as in v1, each with its reason.
- Listing modules that are only in the order file and not drawn: the user may have switched
  them off.
- Moving the Clock or Control Center: macOS pins them.
- Writing Control Center's own preferences ("Show in Menu Bar").

## Anti-goals

- **Nothing changes for an Apple item until the user assigns it.** An Apple item counts as
  assigned only once the user assigns it or moves it in Layout. Until then Hulder never hides
  it, never moves it in the order, never marks it misplaced and never lets Tidy move it. A
  first sighting records nothing for it, and the default section for new apps doesn't apply
  to it.
- **Labels stay as v1 shows them:** "Wi-Fi", "Siri", "Input Menu", never a process name.
- **A user who never assigns an Apple item** gets v1's behaviour: the same assertion arguments,
  with every system item number kept. The one exception is a v1 defect this fixes: with a
  default section other than Visible, v1 left SystemUIServer and TextInputMenuAgent off the
  allowlist, hiding Siri and the Input menu on its own. Apple's owners now stay on the
  allowlist until the user assigns them *(the controller's call, 2026-11-03)*.

## How it works

### What can be assigned

- **Hideable modules.** The platform names them by a table with, for each module:
  - its menu extra identifier (`com.apple.menuextra.wifi`);
  - its system item number (6);
  - its module name in the order file (`WiFi`).

  On macOS 27 the table holds Battery (0), Clock (2), Sound (5), Wi-Fi (6) and Control Center
  (8, order name `BentoBox`). The core sees only the module names, never the numbers.
- **Identifying a drawn module.** A drawn module is identified by the identifier its menu extra
  carries, through that table, not by its order-file key.
  - So hiding modules works without access to the order file.
  - A module whose identifier couldn't be read is not assignable, because a guess by position
    could hide the wrong item *(the controller's call)*.
- **Siri and the Input menu** are assignable through their owners, as any app. All of an
  owner's items share its section.
- **Apple's owners** are SystemUIServer, TextInputMenuAgent, MenuBarAgent and Control Center.
  - Until the user assigns one, it stays on the allowlist.
  - MenuBarAgent and Control Center are never assignable, and stay on the allowlist whenever they are running (as in v1): modules
    hide by number, never by leaving MenuBarAgent off.
- **Read-only, as in v1:**
  - Focus: "macOS hides Focus whenever Hulder hides anything";
  - other modules: "macOS doesn't let Hulder hide this item";
  - items of `com.apple.controlcenter`;
  - items with an unresolved owner.

### The layout

- **Storage.** The stored layout gains a map from module name (`WiFi`, `BentoBox`) to a section.
  An entry exists only once the user has assigned that module. SystemUIServer and
  TextInputMenuAgent enter the existing app map only when the user assigns them.
- **Compatibility.** A state file without the map loads with it empty, and the version stays the
  same.
  - v1's decoder ignores keys it doesn't know, so a v1 build reading a newer file keeps working.
  - It drops the module assignments when it saves, which only a downgrade can cause. Accepted
    *(the controller's call)*.
- **Sections.**
  - An unassigned Apple item shows in the Visible row; its effective section is Visible.
  - For the order planner it has no section, so nothing marks it misplaced or moves it.

### Hiding

- **The allowlist** gains the set of module names to hide. It replaces "keep every system item",
  which becomes the empty set.
- **The planner:**
  - A module goes in the set when the reveal state conceals its assigned section, just as an
    app's section decides whether it is on the allowlist.
  - Apple's owners are allowlisted unless the user assigned them a concealing section.
  - **When an assertion is live:** as in v1, in both the hidden and the revealed states, while
    any running app or any assigned module has a section other than Visible. In revealed, a
    module assigned Hidden is kept, so the assertion stays and the bar doesn't reflow. Only
    Always Hidden modules are left out. A test pins the case where the only non-Visible
    assignment is a module.
  - Revealed-all still drops the assertion.
- **Platform 27.** The platform turns the set into the numbers to keep: 0…127 minus the numbers
  of the hidden modules. With nothing hidden, that is all of 0…127, exactly as v1 sends.
- **Make-before-break, failures and timeouts** are unchanged: a change of the hidden modules is
  a new allowlist like any other.

### The inventory

- **A drawn module** carries its module name from the table when its identifier matches; that
  makes it assignable. Its identity and its order key are separate:
  - **Identity** (what it is, for assigning and hiding) comes from the identifier through the
    table.
  - **Order key** (where it is, for reordering) is certain only when the order file holds that
    module's own entry, matched by name. A key filled in by position, or a missing entry,
    leaves it uncertain.
  - An item whose key is uncertain can be assigned and hidden but never moved in the order,
    exactly as for an app with an uncertain key. So moving Wi-Fi can never rewrite Battery's
    entry.
- **A hidden module** isn't drawn.
  - The scan reports each module the live assertion hides, from the backend's current set. The
    report carries its module name, its `module:` entry from the order file (or `module:<order
    name>` without order access) and no bar position, the way it reports a hidden app's items.
  - Layout therefore still lists it in its row, marked hidden.
- **Hidden apps.** Siri's and the Input menu's owners are hidden through the existing path for
  concealed apps.
- **Recording sightings.** `SightingRecorder` keeps skipping Apple's owners, so a first sighting
  never records them.

### Order

- **Sections for the planner.** `OrderContext.section(of:)` returns:
  - an assigned module's or Apple owner's section, as it does an app's;
  - nil for an unassigned Apple item.

  Placing at the divider, dropping, Tidy and the misplaced marker then work unchanged, and only
  for assigned items.
- **A Layout action on an unassigned Apple item** (a drag within Visible, Move Left/Right) first
  records the assignment to its current section, then moves it.
- **Pinned keys** (Clock, Control Center) never move. Assigning one to another section changes
  only its section, reported as for an app whose icons couldn't be repositioned. Layout shows it
  at the end of its row.

### Layout window

- **Rows.**
  - The seven assignable items appear in their section's row, in bar order, like app items, with
    their v1 labels.
  - Their tooltip names them as macOS's ("Wi-Fi, part of macOS").
  - Apple's items, in the rows and in the "Can't be assigned" list, show an SF Symbol for what
    they are (`wifi`, `battery.100percent`, `siri`, `keyboard`, …), and `menubar.rectangle` for
    any other, drawn at about an app icon's visual size (70% of the icon frame). Their owners are
    background agents whose app icon is generic. An Apple owner assigned and then without an item
    on the bar gets its symbol by owner: TextInputMenuAgent `keyboard`, SystemUIServer
    `menubar.rectangle` even when it was recorded under Siri's name, because its item need not be
    Siri. App items keep their app icon.
  - The "Can't be assigned" list keeps the read-only items above, each with its reason.
- **Moving.** Drag and drop, Move to, Move Left/Right and the keyboard work on them as on app
  items. A refused move (a pinned item's order) shows the reason in the existing notice line.

### Probe

`hide-items <module…>` hides the named modules (for example `WiFi Battery`) through the shipped
concealment backend, with every running app allowlisted. It reads the bar while the assertion
is live, and pauses as `hide` does. It re-measures the numbers on a new macOS. `hide`'s
`maxSystemItem` stays.

## Constraints

- v1's constraints hold. HulderCore imports only Foundation and Observation. The numbers, and
  everything else specific to macOS 27, live in HulderPlatform27.
- Tests follow v1's rules: each pins a behaviour and fails without its fix. The planner, the
  translation, the layout's storage and compatibility, the inventory's hidden modules, the
  order context and Layout's assignability each get tests.

## Delivery

- **Branch:** `feat/hulder-system-items`, from `feat/hulder-v1`, run in its own worktree. Its
  draft pull request is stacked on v1.
- **Changelog:** once the distribution branch has added `CHANGELOG.md`, this branch adds its
  entry when it is rebased.

## Acceptance

1. Both suites and both builds pass.
2. **Live, on Michael's Mac**, with a Debug build in `/Applications`:
   - Wi-Fi assigned to Hidden disappears, and comes back on a click;
   - Battery assigned to Always Hidden comes back on ⌥-click;
   - Siri assigned to Hidden hides;
   - Wi-Fi dragged in Layout moves on the bar;
   - Clock dragged is refused with its reason;
   - Layout keeps listing a hidden Wi-Fi.

   The controller checks what it can unattended:
   - the assertion's arguments and the bar, read through Accessibility;
   - Layout actions through Layout's accessibility actions.

   Michael confirms the rest.
3. With no Apple item assigned and the default section Visible, the assertion's arguments are
   byte-for-byte v1's: every app as before, and 0…127. With the default Hidden, Apple's owners
   stay on the allowlist.

## Left to the builder

- the name and shape of the core type for an assignable unit (app or module);
- the probe subcommand's exact output;
- the tooltip wording;
- the shape of the platform's module table and of the backend's report of hidden modules.
