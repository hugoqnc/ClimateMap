# ClimateMap iOS implementation plan

## Product shape

The app is a personal, native SwiftUI companion for the existing SwitchBot setup. It has two tabs:

1. **Plan** — the default tab, with live Meter readings, wall-aware temperature diffusion, and editable sensor placement.
2. **Climate** — the complete climate control surface, with a semicircular temperature dial, linked room reading, power and mode toggles, and fan/oscillation selectors.

## Architecture

- `Models/FloorPlanDefinition.swift` is the single editable description of the apartment: outline, walls, doors, windows, labels, and suggested initial positions.
- `Models/HomeModel.swift` owns live device data and coordinates API, persistence, and UI state.
- `Models/PersistedState.swift` stores AC state, linked Meter, normalized device positions, and the widget sensor cache in an App Group UserDefaults suite.
- `Networking/SwitchBotClient.swift` signs API v1.1 requests with CryptoKit and sends the configured custom infrared commands.
- `Rendering/TemperatureDiffusion.swift` computes a weighted geodesic field where open space, doors, and walls have increasing thermal resistance.
- `Views/FloorPlan` and `Views/AC` contain the two independent product surfaces.
- `ClimateWidget` contains the medium WidgetKit surface, its timeline provider, and App Intent controls.

## Persistence choice

UserDefaults is preferable to SwiftData here because the persisted model is one small, single-user configuration document with no querying, relationships, or unbounded history. The Codable envelope remains easy to version or migrate later.

## Credential strategy

`Config/Shared.xcconfig` includes the workspace-root `.env`. Xcode substitutes `TOKEN` and `SECRET` into the built app's Info.plist. This deliberately bundles credentials because the app is personal and installed only on the owner's devices.

## Delivery checklist

- [x] Dedicated and replaceable floor-plan definition
- [x] Two native Liquid Glass tabs
- [x] SwitchBot API v1.1 HMAC authentication
- [x] Live discovery for Meter Plus and the infrared climate remote
- [x] Optional Apple Home switch override for app and widget power control
- [x] UserDefaults position and AC-state persistence
- [x] Plan edit mode with draggable SF Symbol markers
- [x] Wall- and door-aware temperature diffusion
- [x] AC cooling source in the heat model
- [x] Animated airflow driven by power, fan, and oscillation
- [x] Native AC controls with a 24°C / on / high-fan default
- [x] Interactive medium Climate widget with linked room temperature
- [x] Shared App Group state and rate-conscious WidgetKit timeline refresh
- [x] Real-time side-profile vent control with calibrated 6-second closure and release-to-set positioning
- [x] iOS 26.4 simulator build, install, launch, and live API verification
