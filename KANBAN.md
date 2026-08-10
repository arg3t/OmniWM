# OmniWM Feature Implementation Kanban

## Branch
`feat/stack-layout-and-monitor-profiles` on `arg3t/OmniWM`

## Delegate Model
`moonshotai/kimi-k3` via Neuralwatt

---

## Backlog

### Feature 1: Per-Monitor-Setup Config Fallbacks
- [ ] T1-1: Define `MonitorSetupProfile` struct + signature computation
- [ ] T1-2: Add `monitorSetupProfiles` config section to `CanonicalTOMLConfig`
- [ ] T1-3: Add TOML codec entries in `SettingsTOMLCodec.swift`
- [ ] T1-4: Add `SettingsStore` properties + `scheduleSave()` wiring
- [ ] T1-5: Implement `MonitorSetupProfileResolver` — reacts to DisplayConfigurationObserver
- [ ] T1-6: Add settings UI tab for managing profiles
- [ ] T1-7: Write tests for profile matching + fallback

### Feature 2: DWM-like Stacking Layout
- [ ] T2-1: Define `StackSettings` + `MonitorStackSettings` config types
- [ ] T2-2: Add `.stack` to `LayoutType`, `ActiveLayoutKind`, `LayoutCompatibility` enums
- [ ] T2-3: Implement `StackLayoutEngine` core (tree, addWindow, removeWindow, rekey, activate)
- [ ] T2-4: Implement frame computation (master ratio + stack split)
- [ ] T2-5: Implement `StackLayoutHandler` (translates engine frames → EffectPlan)
- [ ] T2-6: Wire `StackLayoutEngine` into `WorldStore` (3rd engine alongside niri/dwindle)
- [ ] T2-7: Add `.stack` branch to `LayoutRefreshController` plan-building
- [ ] T2-8: Add stack-specific `HotkeyCommand` cases + `ActionCatalog` entries
- [ ] T2-9: Add `LayoutTopology` stack representation
- [ ] T2-10: Add config entries to `CanonicalTOMLConfig` + `SettingsExport` + `SettingsTOMLCodec`
- [ ] T2-11: Add IPC models for stack layout commands
- [ ] T2-12: Write tests for stack engine operations

## In Progress
(none)

## Done
(none)

---

## Allocation
- **Stream A** (subagent 1): T1-* (Feature 1 — config profiles)
- **Stream B** (subagent 2): T2-1, T2-2, T2-3, T2-4, T2-9, T2-10 (Feature 2 — engine core + types + config)
- **Stream C** (subagent 3): T2-5, T2-6, T2-7, T2-8, T2-11, T2-12 (Feature 2 — integration + actions + IPC + tests)

## Dependencies
- Stream C depends on Stream B's types (T2-1, T2-2, T2-3) but can start on T2-8 (action catalog) and T2-11 (IPC models) independently
- Stream A is fully independent of both
