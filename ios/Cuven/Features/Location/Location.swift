import SwiftUI
import MapKit
import CoreLocation

/// A place picked to send.
struct PickedPlace {
    var latitude: Double
    var longitude: Double
    var name: String
    var address: String
}

// MARK: - Where you are

/// Your position, asked for while the picker is open ("when in use").
@MainActor
@Observable
final class Locator: NSObject, CLLocationManagerDelegate {
    var coordinate: CLLocationCoordinate2D?
    var denied = false
    @ObservationIgnored private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: denied = true
        default: manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let status = m.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.denied = false
                self.manager.requestLocation()
            case .denied, .restricted:
                self.denied = true
            default: break
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        Task { @MainActor in self.coordinate = c }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}

// MARK: - The picker

/// Send a place (Apple Maps): the map, with a pin in its middle you move the
/// map under; that spot or your current position; the places nearby; and
/// search. Everything comes from MapKit on the device: no key, no server.
struct LocationPicker: View {
    let onPick: (PickedPlace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var locator = Locator()
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var center: CLLocationCoordinate2D?
    @State private var centerName = ""
    @State private var centerAddress = ""
    @State private var nearby: [MKMapItem] = []
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var moving = false
    @FocusState private var searching: Bool

    private var listed: [MKMapItem] { query.isEmpty ? nearby : results }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Send location").font(.headlineC).foregroundStyle(Theme.label)
                HStack {
                    GlassIconButton(sym: .xmark, title: "Cancel") { dismiss() }
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ZStack {
                Map(position: $position) {
                    UserAnnotation()
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
                .onMapCameraChange(frequency: .continuous) { _ in
                    if !moving { withAnimation(Motion.quick) { moving = true } }
                }
                .onMapCameraChange(frequency: .onEnd) { ctx in
                    withAnimation(Motion.bouncy) { moving = false }
                    center = ctx.region.center
                    Task { await describeCenter(ctx.region.center) }
                    Task { await loadNearby(ctx.region.center) }
                }
                // The pin you place by moving the map; it lifts while the map moves.
                VStack(spacing: 0) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 36))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.red)
                        .shadow(color: .black.opacity(0.25), radius: moving ? 8 : 3, y: moving ? 8 : 2)
                    Rectangle().fill(Theme.red).frame(width: 2.5, height: 12)
                }
                .offset(y: moving ? -30 : -22)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 12)

            HStack(spacing: 8) {
                SymbolView(.search, size: 17).foregroundStyle(Theme.label3)
                TextField("Search places", text: $query)
                    .font(.bodyC)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .focused($searching)
                ClearButton(text: $query)
            }
            .padding(.leading, 14).padding(.trailing, 8)
            .frame(height: 44)
            .background(Theme.fill2, in: Capsule())
            .padding(.horizontal, 16)
            .padding(.top, 12)

            List {
                if query.isEmpty {
                    Button { sendCenter() } label: {
                        placeRow(icon: "mappin.and.ellipse", tint: Theme.red,
                                 title: centerName.isEmpty ? String(localized: "This location") : centerName,
                                 subtitle: centerAddress.isEmpty ? String(localized: "The pin on the map") : centerAddress)
                    }
                    .disabled(center == nil)
                    if let mine = locator.coordinate {
                        Button { Task { await sendCurrent(mine) } } label: {
                            placeRow(icon: "location.fill", tint: Theme.blue,
                                     title: String(localized: "Your current location"),
                                     subtitle: String(localized: "Accurate to about 10 m"))
                        }
                    }
                }
                ForEach(listed, id: \.self) { item in
                    Button { send(item) } label: {
                        placeRow(icon: icon(for: item), tint: Theme.label2,
                                 title: item.name ?? String(localized: "Location"),
                                 subtitle: item.placemark.title ?? "")
                    }
                }
                if locator.denied && query.isEmpty {
                    Text("Allow location in Settings to send where you are, or search for a place.")
                        .font(.footnoteC).foregroundStyle(Theme.label2)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Theme.bg)
        .task { locator.start() }
        .task(id: query) {
            guard !query.isEmpty else { results = []; return }
            try? await Task.sleep(for: .milliseconds(300))
            await search(query)
        }
    }

    private func placeRow(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(Theme.fill3, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.bodyC).foregroundStyle(Theme.label).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.footnoteC).foregroundStyle(Theme.label2).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func icon(for item: MKMapItem) -> String {
        switch item.pointOfInterestCategory {
        case .restaurant?: return "fork.knife"
        case .cafe?: return "cup.and.saucer.fill"
        case .park?: return "tree.fill"
        case .publicTransport?: return "tram.fill"
        case .hotel?: return "bed.double.fill"
        case .store?: return "bag.fill"
        default: return "mappin"
        }
    }

    // MARK: Finding

    private func describeCenter(_ c: CLLocationCoordinate2D) async {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude))
        guard let p = marks?.first else { return }
        centerName = p.name ?? p.thoroughfare ?? ""
        centerAddress = [p.subLocality, p.locality, p.administrativeArea].compactMap { $0 }.joined(separator: " ")
    }

    private func loadNearby(_ c: CLLocationCoordinate2D) async {
        let req = MKLocalPointsOfInterestRequest(center: c, radius: 600)
        let found = try? await MKLocalSearch(request: req).start()
        nearby = Array((found?.mapItems ?? []).prefix(20))
    }

    private func search(_ q: String) async {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        if let c = center ?? locator.coordinate {
            req.region = MKCoordinateRegion(center: c, latitudinalMeters: 20_000, longitudinalMeters: 20_000)
        }
        let found = try? await MKLocalSearch(request: req).start()
        results = Array((found?.mapItems ?? []).prefix(25))
    }

    // MARK: Sending

    private func send(_ item: MKMapItem) {
        let c = item.placemark.coordinate
        finish(PickedPlace(latitude: c.latitude, longitude: c.longitude, name: item.name ?? "", address: item.placemark.title ?? ""))
    }

    private func sendCenter() {
        guard let c = center else { return }
        finish(PickedPlace(latitude: c.latitude, longitude: c.longitude, name: centerName, address: centerAddress))
    }

    private func sendCurrent(_ c: CLLocationCoordinate2D) async {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude))
        let p = marks?.first
        let address = [p?.subLocality, p?.locality, p?.administrativeArea].compactMap { $0 }.joined(separator: " ")
        finish(PickedPlace(latitude: c.latitude, longitude: c.longitude, name: p?.name ?? String(localized: "My location"), address: address))
    }

    private func finish(_ place: PickedPlace) {
        onPick(place)
        dismiss()
    }
}

// MARK: - The map in a message

/// Small maps of shared places, drawn once on the device (MKMapSnapshotter)
/// with the pin in the middle, light or dark.
enum MapSnapshots {
    private static let cache = NSCache<NSString, UIImage>()

    @MainActor
    static func image(latitude: Double, longitude: Double, size: CGSize, dark: Bool) async -> UIImage? {
        let key = String(format: "%.5f,%.5f,%.0fx%.0f,%d", latitude, longitude, size.width, size.height, dark ? 1 : 0) as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 700, longitudinalMeters: 700)
        options.size = size
        options.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        let pin = UIImage(systemName: "mappin.circle.fill")?
            .applyingSymbolConfiguration(.init(pointSize: 30, weight: .regular))?
            .applyingSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            snapshot.image.draw(at: .zero)
            if let pin {
                let p = snapshot.point(for: coordinate)
                pin.draw(at: CGPoint(x: p.x - pin.size.width / 2, y: p.y - pin.size.height + 4))
            }
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// A shared place: a small map with the pin, its name and address under it;
/// tapped, the map opens bigger with directions.
struct LocationBubble: View {
    let message: Message
    let mine: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var snapshot: UIImage?
    @State private var open = false

    private var lat: Double { message.meta?.lat ?? 0 }
    private var lng: Double { message.meta?.lng ?? 0 }
    private var name: String {
        let n = message.meta?.name ?? ""
        return n.isEmpty ? String(localized: "Location") : n
    }
    private var address: String { message.meta?.address ?? "" }
    private let size = CGSize(width: 248, height: 140)

    var body: some View {
        Button { open = true } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Theme.fill3
                    if let snapshot {
                        Image(uiImage: snapshot).resizable().scaledToFill().transition(.opacity)
                    } else {
                        Image(systemName: "map").font(.system(size: 28)).foregroundStyle(Theme.label3)
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipped()
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.subheadBoldC).foregroundStyle(Theme.label).lineLimit(1)
                    if !address.isEmpty {
                        Text(address).font(.footnoteC).foregroundStyle(Theme.label2).lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(width: size.width, alignment: .leading)
                .background(Theme.surface)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.press(0.97))
        .accessibilityLabel(Text("\(String(localized: "Location")): \(name) \(address)"))
        .task(id: scheme) {
            let img = await MapSnapshots.image(latitude: lat, longitude: lng, size: size, dark: scheme == .dark)
            withAnimation(Motion.quick) { snapshot = img }
        }
        .sheet(isPresented: $open) {
            LocationSheet(latitude: lat, longitude: lng, name: name, address: address)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// The place, big: the map with its marker, and the way there in Maps.
struct LocationSheet: View {
    let latitude: Double
    let longitude: Double
    let name: String
    let address: String

    private var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    var body: some View {
        VStack(spacing: 0) {
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 900, longitudinalMeters: 900))) {
                Marker(name, coordinate: coordinate)
                UserAnnotation()
            }
            .mapControls { MapUserLocationButton(); MapCompass(); MapScaleView() }
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.title3C).foregroundStyle(Theme.label).lineLimit(2)
                if !address.isEmpty {
                    Text(address).font(.subheadC).foregroundStyle(Theme.label2).lineLimit(2)
                }
                HStack(spacing: 10) {
                    Button { openInMaps(directions: true) } label: {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(AppFont.make(16, .semibold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.glassProminent)
                    Button { openInMaps(directions: false) } label: {
                        Label("Open in Maps", systemImage: "map")
                            .font(AppFont.make(16, .semibold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.glass)
                }
                .padding(.top, 10)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
    }

    private func openInMaps(directions: Bool) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        item.openInMaps(launchOptions: directions ? [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault] : nil)
    }
}
