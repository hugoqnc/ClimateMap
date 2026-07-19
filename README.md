# ClimateMap for iOS

Native SwiftUI app for the personal SwitchBot installation.

## Open and run

1. Copy `.env.example` to `.env` and add your SwitchBot `TOKEN` and `SECRET` values. Never commit that file.
2. Open `SmartHome.xcodeproj` in Xcode 26.4 or newer.
3. Select an iOS 26 simulator and run the shared `ClimateMap` scheme.

For a physical iPhone, select your personal Apple Development team under **Signing & Capabilities**, connect the phone, and run. The credentials are embedded into the app and widget at build time. Keep the `group.com.queinnec.SmartHome` App Group enabled for both targets so their state remains synchronized.

## Climate widget

The `ClimateWidget` target provides an interactive medium widget named **Climate Controls**. Add it from the iOS widget gallery after installing the app. It includes:

- the persisted target temperature with one-step minus and plus controls;
- the linked room temperature and the age of its reading;
- a state-aware Power control with explicit ON/OFF status;
- a Silence control with explicit ON/OFF status;
- dimmed, inert controls whenever power or Eco mode makes an action unavailable.

The widget requests a new timeline approximately every 15 minutes; WidgetKit decides the exact execution time. Its provider reuses readings under one minute old and otherwise asks SwitchBot for the thermometer associated with Climate. The app requests an immediate widget timeline reload after receiving newer readings or changing climate state, plus one coalesced final reload when it becomes inactive, so the Home Screen reflects the controller state without waiting for the scheduled refresh.

## Timed air direction

The Air direction card models the portable AC's physical flap and replaces the raw three-state infrared cycle. Auto is animated from a persisted phase clock. Selecting a fixed height synchronizes to a known Auto start when needed, accounts for the 13-second preparation, 7.5-second one-way travel, and calibrated infrared latency, shows an integrated loading state, and sends the fixing command when the flap reaches the requested position. A short iOS background task lets an in-progress sequence finish if the app becomes inactive.

Only Auto is retained by the appliance across a power cycle. ClimateMap therefore keeps Auto and starts a fresh phase clock when power returns; Fixed restarts as Closed. The last fixed percentage remains remembered only as the next selector target.

## Changing the floor plan

Edit only `SmartHome/Models/FloorPlanDefinition.swift`. Coordinates are normalized from the original 804 × 1482 reference drawing. The file contains:

- apartment outline;
- wall, door, and window segments;
- room labels;
- suggested first-run device positions.

Rendering and diffusion automatically consume that definition.

## State and synchronization

The app starts with Climate on, target 24°C, high fan, and all optional modes off. It persists every accepted command and every sensor placement in the shared App Group UserDefaults suite. Existing state from the earlier app-only store is migrated automatically. Since this is intended to be the only climate controller, the locally tracked infrared state should remain aligned with the appliance.

While the app is active, temperature readings refresh when their latest successful update is at least 60 seconds old. Failed automatic attempts are also rate-limited to one per minute. Readings older than two minutes are replaced by loading states until fresh data arrives; the Plan toolbar can always request a manual refresh.

The Plan heatmap is theme-adaptive. Sensor badges track drag gestures immediately while the more expensive wall-aware diffusion field remains stable, then recomputes off the main actor when the gesture ends.

Meter badges include a compact humidity reading. Status responses are validated before display: missing, zero, non-finite, or implausible climate values remain in a loading state, and the heatmap is withheld unless every discovered meter has a valid reading.

The simulator-only `--open-ac` launch argument opens the second tab directly for visual testing. Add `--open-vent` to scroll that tab to the Air direction card. Normal launches always open on the Plan tab.
