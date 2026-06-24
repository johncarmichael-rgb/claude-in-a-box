---
name: ux-architecture
description: Decide how an application is structured and navigated, the navigation chrome (top nav, side nav, tab bar, command palette), the information architecture pattern, and the screen-level layout. Use whenever building or restructuring a dashboard, admin panel, internal tool, SaaS app, or any multi-screen product, and whenever the user mentions navigation, sidebar, menu structure, sitemap, app layout, information architecture, IA, or "how should I organize these screens", even if they don't say "architecture". This skill decides structure and inherits the app's existing colours and type; it does not invent a visual identity (that is the frontend-design skill's job).
---

# UX Architecture

This skill decides how a product is organized and moved through: what the navigation looks like, how screens relate to each other, and how a single screen is laid out. It is about structure, not aesthetics. Visual identity (palette, typefaces, signature moments) is the `frontend-design` skill's job. The two are complementary: pick the structure here, render it in the existing visual language.

The output of using this skill well is a defensible answer to four questions: which navigation chrome, which information architecture pattern, which organizational scheme, and which screen-level layout, each chosen for *this* product rather than copied from the last dashboard you saw.

This is a decision-forcing skill, not a catalogue to browse. Do not build until you have committed to a pattern, justified it against the inventory, and named the alternative you rejected. The default failure mode is reaching for the most familiar layout on autopilot; the steps below exist to interrupt that. Do this reasoning before writing any markup, and record the outcome (see "Commit the decision" near the end).

**Two entry points.** Match the work in front of you:
- *Architecting a product or a section*: run all steps top-down (Gate 0, inventory, chrome, IA pattern, scheme, then per-screen layout).
- *Building a single page or screen*: you still confirm Gate 0 and a one-line inventory of that screen's job and primary user, then go straight to Step 5 to pick the screen-level layout, and choose chrome only if this screen introduces navigation the app does not already have. Do not impose a whole new app structure to ship one page.

## Gate 0: inherit the visual system, or stop and define one

Before deciding any structure, find the app's existing visual language and commit to using it unchanged:

- Look for design tokens or CSS custom properties, a Tailwind/theme config, a component library in use (shadcn/ui, MUI, Chakra, Radix, Ant, Carbon, etc.), existing screens, brand colours, and the chosen typefaces.
- If they exist, inherit them exactly. Navigation and layout you produce must use the same colour tokens, type scale, spacing, and radius as the rest of the app. New chrome that introduces its own palette or fonts reads as bolted on, and it is the fastest way to make a product feel incoherent.

If no visual system exists, do not invent one silently and do not refuse outright. Pause and put it back to the user: structure built on an undefined surface will have to be redone the moment colours and type are chosen, so it is cheaper to settle the basics first. Offer to scaffold a minimal token set for confirmation (a background/surface/border/foreground colour set, one accent, a body face, a display or UI face, and a spacing/radius scale), or point them to the `frontend-design` skill. Only proceed once there is something to inherit.

This gate is not bureaucracy; it is the difference between a navigation system that belongs to the product and one that fights it.

## Step 1: inventory before you structure

You cannot choose a structure without knowing what you are structuring. Establish, briefly:

- The product's single job, and who uses it (one concrete primary user, named).
- The top-level destinations: the distinct places a user needs to reach. Count them. This number drives almost every navigation decision below.
- Depth: how many levels live under each destination.
- Switching frequency: do users live inside one area, or hop between areas constantly?
- The primary device: desktop-first app, mobile-first, or genuinely both.

If the brief does not pin these down, pin them yourself and state your assumption. Structure chosen against an unknown content set is a guess dressed up as a decision.

## Step 2: choose the navigation chrome

Navigation chrome is the persistent frame a user steers from. Pick by destination count, switching frequency, and device. These are heuristics with real tradeoffs, not laws.

**Top navigation (horizontal bar).** Best for shallow products with few top-level destinations (roughly up to 5 to 7), marketing-adjacent surfaces, and apps where brand prominence matters more than dense in-app movement. It is space-cheap vertically and reads as familiar. It stops scaling the moment destinations outgrow the horizontal room, at which point you are hiding things behind "More" and losing the discoverability you came for.

**Side navigation (vertical rail).** The default for dashboards, admin panels, and internal tools. It scales to many destinations, supports grouping and section labels, tolerates deeper hierarchy, and can collapse to icons to reclaim width. The cost is horizontal space and a slightly heavier first impression. Choose it when users live in the app and switch contexts often, or when destinations exceed what a top bar carries comfortably.

**Top bar plus side nav (the app shell).** The standard for complex products. The top bar holds global, cross-cutting concerns (workspace or account switcher, global search, notifications, profile); the side nav holds primary in-app navigation. Reach for this when you have both a global layer and a deep in-app layer; do not reach for it on a product simple enough to need only one.

**Bottom tab bar.** Mobile primary navigation for 3 to 5 equal, frequently used destinations. Thumb-reachable and always visible. Past 5 destinations it breaks down; do not overflow it.

**Drawer / hamburger.** Navigation hidden behind a toggle. Legitimate on mobile and in genuinely space-starved layouts, but it trades discoverability for space: anything behind a hamburger is used less. Avoid it on desktop when a persistent rail would fit.

**Command palette / search-first.** A keyboard-driven launcher (often Cmd/Ctrl-K) for power-user products whose surface is too broad to navigate by clicking, or as an accelerator layered on top of conventional chrome. It is an addition for fluent users, not a replacement for visible navigation that newcomers can see.

When two patterns both fit, prefer the one that keeps the most navigation *visible* for the product's least experienced user.

## Step 3: choose the information architecture pattern

The IA pattern describes how screens relate, the shape of movement through the product.

**Hierarchical (tree).** Broad categories branching into specifics. The default for most apps, and what a side nav naturally expresses. Choose it unless you have a specific reason not to.

**Sequential (linear).** A fixed, ordered path where each step gates the next: onboarding, setup wizards, checkout, multi-step forms. Use it precisely where order is mandatory, and nowhere else; forcing linearity onto free exploration frustrates users.

**Hub and spoke.** A central hub links out to independent sections, and users return to the hub to switch. Natural for mobile home screens and for products whose sections genuinely do not relate to one another. The cost is the forced trip back to the hub, so avoid it when users need to move *between* spokes directly.

**Matrix / faceted.** Multiple coexisting ways to slice the same content (filter, sort, facet, tag). The right pattern for large datasets, catalogues, tables, and search-heavy screens where no single hierarchy serves everyone. It gives freedom at the price of a more complex interface, so it earns its place only when the data volume demands it.

**Nested doll (progressive drill-down).** Each screen reveals the next level deeper, with a clear way back up. Common on mobile and inside a single section of a larger app. It keeps focus but can bury things; pair it with breadcrumbs or a clear back path so users always know where they are.

Most real products combine these: a hierarchical spine, a sequential onboarding flow, and a faceted data table inside one section. Name the dominant pattern, then note the local exceptions.

## Step 4: choose the organizational scheme

The scheme decides how top-level items are *grouped and labelled*. The wrong scheme makes a structurally sound app feel illogical.

- **Task-oriented**: grouped by what the user is trying to do ("Create campaign", "Review approvals"). Strong when the product is a set of jobs to be done.
- **Audience-based**: segmented by who the user is ("For clinicians", "For admins", "For developers"). Use when distinct user types need genuinely different surfaces; avoid when it just mirrors an internal org chart.
- **Topic / subject**: grouped by domain area. Familiar and durable when the subject has natural, stable categories.
- **Exact schemes** (alphabetical, chronological, geographic): for reference content and lists where the user already knows the item's name, date, or place.

Pick the scheme that matches how the user already thinks about the work, not how the system is built internally. Label things by what people control and recognize ("Notifications", not "Webhook config").

## Step 5: lay out the screen

**The app shell.** Top bar (global), side nav (primary), main content, and an optional right rail or inspector for contextual detail. Keep the shell stable across screens; only the main content should change as users navigate. A persistent shell is what makes an app feel like one place.

**The dashboard home (bento / card layout).** A home screen of distinct blocks, each surfacing a small, glanceable slice of one area, with a path to the full view. A dashboard summarizes and routes; it does not try to *be* every screen. Show the few things a user checks first, and link out to the rest. Resist cramming; a dashboard that shows everything shows nothing.

**Common content-area patterns.** Pick by the screen's single job, decided in this order:
- The job is *act on one of many similar things* (triage, review, edit records in place) → **list-detail (master-detail)**: a list on one side, the selected item's detail on the other. The workhorse for inboxes, records, and any "browse then inspect" flow.
- The job is *compare, sort, or scan many rows of structured data* → **table with filters**: dense, scannable rows over a faceted filter set.
- The job is *choose from visual or loosely structured items* → **card grid**: items that each need a thumbnail or summary.
- The job is *understand or operate on one entity in depth* → **detail view**: a single record in full, with its actions grouped and obvious.
- The job is *capture or change data* → **form**: one clear job per screen, fields in the order the user thinks, the primary action named for what it does ("Publish", not "Submit").
- The job is *check status across several areas at a glance, then leave* → **dashboard / bento home** (above), not a do-everything screen.

If a screen seems to want two of these at once, it is usually two screens, or a primary pattern with the second behind a drill-in. Resolve that before building rather than blending them.

## Commit the decision

Before writing any markup, state the decision in a short record, so the reasoning is explicit and the user can challenge it. Keep it to the lines that apply (a single page needs only the last two or three):

```
Chrome:   <pattern> — because <fact from inventory: destination count / switching / device>
IA:       <pattern> — dominant, with <local exceptions>
Scheme:   <task | audience | topic | exact> — because <how the user thinks about the work>
Layout:   <per screen> — because <each screen's job>
Rejected: <the next-best option> — because <the inventory fact that ruled it out>
```

Two rules make this real rather than decorative: every "because" cites a fact from the inventory, not a preference or a habit; and you must name a rejected alternative. If you cannot say what you rejected and why, you have not made a decision, you have defaulted, so go back to the step that was skipped. When the inventory genuinely underdetermines the choice (for example, destination count sits right on a threshold), say so and pick the option that keeps navigation more visible for the least experienced user.

## Quality floor

Hold these without announcing them:

- Responsive down to mobile; the desktop side nav has a defined collapsed or drawer behaviour on small screens.
- The current location is always visible: active state on the nav item, breadcrumbs for anything more than two levels deep, and a page title that matches the nav label.
- Keyboard navigable with visible focus states; reduced-motion respected.
- An action keeps its name through the whole flow: the button that says "Publish" produces a "Published" confirmation.
- Empty and error states give direction in the interface's voice, not an apology or a shrug.

## Worked example

*Brief: an internal tool for care coordinators to manage clients, visits, and incidents; coordinators switch between these constantly all day; desktop-first.*

- Gate 0: the company already has tokens and a UI font; inherit both, add no new colours.
- Inventory: 3 to 4 top-level destinations (Clients, Schedule, Incidents, Reports), moderate depth, very high switching, desktop.
- Chrome: side nav, because switching is constant and a top bar would force re-finding items all day; a thin top bar carries global search and the user menu. Add a command palette as an accelerator, since coordinators are daily power users.
- IA: hierarchical spine, with a sequential flow for "log an incident" and a faceted table inside Clients.
- Scheme: task-oriented, matching how coordinators describe their day.
- Layout: list-detail for Clients and Incidents; a calendar/table for Schedule; a bento home only if a genuine at-a-glance need exists, otherwise land users directly on Schedule.

Note how each choice cites the inventory, not a habit.

## Relationship to other skills

Use `frontend-design` to establish or sharpen the visual identity. Use this skill to decide structure. When both apply, settle the visual system first (Gate 0), then architect on top of it.