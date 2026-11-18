# E2E Test Infra: Cuven Native iOS & iPhone Duo (`iOS 27.2 SDK`)

## Test Philosophy
- **Opaque-box, requirement-driven**: Derived strictly from `ORIGINAL_REQUEST.md`, Apple HIG (*Designing for iPhone Duo*, *Liquid Glass*, *Motion*), and user-facing Cuven Web specifications — zero dependency on internal implementation details.
- **Methodology**: Category-Partition + Boundary Value Analysis (BVA) + Pairwise Combinatorial Testing + Real-World End-User Workload Testing across both **iPhone** and **iPhone Duo** Simulators + binary `.ipa` Mach-O **`sdk 27.2`** verification.

## Feature Inventory & Coverage Matrix
| # | Feature | Source (Requirement) | Tier 1 | Tier 2 | Tier 3 | Tier 4 |
|---|---------|---------------------|:------:|:------:|:------:|:------:|
| F1 | Apple HIG & iOS 27.2 SDK Binary/Bundle Compliance (`sdk 27.2`, `UIRequiresFullScreen=false`, Clarinetta `.ttf`, `Assets.car`) | `ORIGINAL_REQUEST` Follow-up `2026-11-18T04:56:54Z` | 5 | 5 | ✓ | ✓ |
| F2 | Auth, Segmented Invite Code Track, Demo Entry & Sidebar Scopes | `ORIGINAL_REQUEST` + Web Auth/Sidebar | 5 | 5 | ✓ | ✓ |
| F3 | iPhone & iPhone Duo Spatial Strip (`466×678` Closed, `Half` Book/Laptop, `951×669` Open `342\|609` & `525\|426` Zero-Reflow, `56pt` Dock vs `52pt` `DuoRail` + `Pages`) | `ORIGINAL_REQUEST` + *Designing for iPhone Duo* | 6 | 6 | ✓ | ✓ |
| F4 | Chat List, `24h` Notes, For You Insights, Pinned Grid, Swipe Actions & Search | `ORIGINAL_REQUEST` + Web ChatList | 5 | 5 | ✓ | ✓ |
| F5 | Conversation Thread, `#18181B` Ink Curved-Tail Bubbles, Tapbacks, Edit/Unsend, Honk Typing, Composer Glow & AI Explain | `ORIGINAL_REQUEST` + Web Thread/AI | 6 | 6 | ✓ | ✓ |
| F6 | Moments Feed, Profile Media Grid & Full-Page Editor (6 Tones, Crop, `+ALT`, `@Tag`, Schedule, Undo/Redo) | `ORIGINAL_REQUEST` + Web Moments | 5 | 5 | ✓ | ✓ |
| F7 | Artifact Room Info, Drawing Board (`5` Tools + `3` Papers), Telegram Stickers & Memories Flashback/Lightbox | `ORIGINAL_REQUEST` + Web Artifact/Memories | 5 | 5 | ✓ | ✓ |
| F8 | Audio/Video Calling, Dark Glass Controls, Duo Laptop Split, PiP & Settings/Avatar Crop/AI Routine | `ORIGINAL_REQUEST` + Web Calls/Settings | 5 | 5 | ✓ | ✓ |

## Test Architecture
- **UI & Simulator Runner**: `xcodebuild test-without-building` on GitHub Actions `runs-on: xcode-27` (`/Applications/Xcode_27.2.app`, `iphonesimulator27.2` SDK) executing `CuvenUITests` against BOTH:
  1. Official **`iPhone Duo` Simulator** (`com.apple.CoreSimulator.SimDeviceType.iPhone-Duo` on `SimRuntime.iOS-27-2` / `<= 27.2`)
  2. Standard **`iPhone` Simulator** (`iPhone 18 Pro` / `iPhone 17` on `SimRuntime.iOS-27-2` / `<= 27.2`)
- **Artifact & HIG Compliance Runner**: `ios/scripts/run-e2e-suite.sh` (invoking CI verification + local Linux `llvm-objdump --macho --private-headers` verifying `ARM64`, `MH_MAGIC_64`, `LC_BUILD_VERSION` **`sdk 27.2`**, `SwiftUI`/`UIKit` linkage, zero `WebKit` linkage, `Info.plist`, `Assets.car`, `_CodeSignature/CodeResources`, and non-empty Simulator screenshot PNGs).
- **Directory Layout**:
  - `ios/CuvenUITests/UITestHelpers.swift`
  - `ios/CuvenUITests/CuvenTier1FeatureUITests.swift`
  - `ios/CuvenUITests/CuvenTier2BoundaryUITests.swift`
  - `ios/CuvenUITests/CuvenTier3CrossFeatureDuoUITests.swift`
  - `ios/CuvenUITests/CuvenTier4RealWorldScenariosUITests.swift`
  - `ios/scripts/run-e2e-suite.sh`

## Real-World Application Scenarios (Tier 4)
| # | Scenario | Features Exercised | Complexity |
|---|----------|--------------------|------------|
| S1 | Cold-boot on `iPhone` compact → browse Notes & Insights → open DM → send message + tapback + edit → swipe back with pinned `Back` pill | F2, F3, F4, F5 | High |
| S2 | `iPhone Duo` `closed` → open Conversation → unfold to `duoOpen` (`342\|609`) preserving draft → open Drawing Board (`525\|426` zero thread reflow) → sketch & send | F3, F5, F7 | High |
| S3 | Switch via `DuoRail` `Pages` capsule to `Moments` → compose multi-filter post with `+ALT` & `@tag` → publish → verify in feed & Profile waterfall | F3, F6 | High |
| S4 | Initiate Video Call on `iPhone Duo` → transition to `duoHalfLaptop` tabletop split → minimize to corner-snapping PiP while browsing `Memories` flashback | F3, F7, F8 | High |
| S5 | Customize Avatar crop (`512×512` + dominant tint) & switch Liquid Glass (`Tinted`) + Composer Glow (`Aurora`) + Dark Mode → verify across `ChatList` & `Thread` + `.ipa` `sdk 27.2` binary audit | F1, F4, F5, F8 | High |

## Coverage Thresholds
- **Tier 1**: >= 42 isolated happy-path feature tests (>=5 per feature across 8 feature groups)
- **Tier 2**: >= 40 boundary & negative corner-case tests (empty drafts, 60-char Note limit, 15m/5x edit limit, narrow/wide viewport transitions, Reduce Transparency fallback, invalid auth input)
- **Tier 3**: >= 12 pairwise cross-feature interaction tests (unfolding mid-draft, unfolding mid-drawing, call PiP + chat navigation, dark mode + Liquid Glass + backdrop combinations)
- **Tier 4**: >= 5 full end-to-end multi-screen user workflows across `iPhone` & `iPhone Duo` + genuine `Cuven.ipa` (`sdk 27.2`) binary audit
- **Total Minimum**: >= 99 automated verification checks
