import MapLibre
import SwiftUI
import UIKit
import ChompKit

/// The game map. MapLibre with our own style; game state is pushed in as a
/// MapSnapshot and applied to GeoJSON sources without rebuilding the style.
struct GameMapView: UIViewRepresentable {
    enum CameraMode: Equatable {
        case free
        case follow
        case fit([Coordinate])
    }

    let area: Area
    let snapshot: MapSnapshot
    var camera: CameraMode = .free
    var focus: Coordinate?
    var interactive = true
    var showsUserLocation = true
    var onUserPan: (() -> Void)?
    /// Called when the camera settles: centre and zoom. The home map uses it to
    /// load streets wherever the player looks.
    var onRegionChange: ((Coordinate, Double) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: Coordinator.styleURL(look: snapshot.look, conquered: snapshot.conquered))
        map.delegate = context.coordinator
        map.logoView.isHidden = true
        map.attributionButtonPosition = .topLeft
        map.attributionButtonMargins = CGPoint(x: 12, y: 170)
        map.compassViewPosition = .topRight
        map.compassViewMargins = CGPoint(x: 16, y: 120)
        map.tintColor = UIColor(Color(hex: snapshot.playerColorHex))
        map.minimumZoomLevel = 9
        map.maximumZoomLevel = 19
        map.isPitchEnabled = false
        map.isRotateEnabled = interactive
        map.isScrollEnabled = interactive
        map.isZoomEnabled = interactive
        if !LocationPermission.isAuthorized { map.locationManager = PassiveLocationManager() }
        map.showsUserLocation = showsUserLocation && LocationPermission.isAuthorized
        let start = focus ?? (area.tiles.isEmpty ? LocationPermission.shared.lastKnown : nil) ?? area.center
        context.coordinator.lastFocus = focus
        context.coordinator.centredOnStreets = focus != nil || !area.tiles.isEmpty
        map.setCenter(CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude), zoomLevel: area.tiles.isEmpty && focus == nil ? 12 : 14.4, animated: false)
        map.isAccessibilityElement = false
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didPan(_:)))
        pan.delegate = context.coordinator
        map.addGestureRecognizer(pan)
        context.coordinator.map = map
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let c = context.coordinator
        c.parent = self
        let authorized = LocationPermission.isAuthorized
        if authorized, map.locationManager is PassiveLocationManager { map.locationManager = nil } // back to MapLibre's default
        map.showsUserLocation = showsUserLocation && snapshot.runner == nil && authorized
        map.tintColor = UIColor(Color(hex: snapshot.playerColorHex))
        if c.conquered != snapshot.conquered || c.look != snapshot.look {
            c.conquered = snapshot.conquered
            c.look = snapshot.look
            c.styleReady = false
            map.styleURL = Coordinator.styleURL(look: snapshot.look, conquered: snapshot.conquered)
            return
        }
        c.apply(snapshot)
        // The map can appear before any streets have loaded (it then starts on a
        // generic view). Once they arrive, go to them, unless the player has
        // already moved the map.
        if !c.centredOnStreets, !area.tiles.isEmpty {
            c.centredOnStreets = true
            if !c.userMoved, camera == .free, focus == nil {
                map.setCenter(CLLocationCoordinate2D(latitude: area.center.latitude, longitude: area.center.longitude), zoomLevel: 14.4, animated: false)
            }
        }
        if focus != c.lastFocus, let f = focus {
            c.lastFocus = f
            map.setCenter(CLLocationCoordinate2D(latitude: f.latitude, longitude: f.longitude), zoomLevel: max(map.zoomLevel, 15.5), animated: true)
        }
        switch camera {
        case .follow:
            if let r = snapshot.runner {
                map.setCenter(CLLocationCoordinate2D(latitude: r.latitude, longitude: r.longitude), zoomLevel: max(map.zoomLevel, 16), animated: true)
            }
        case .fit(let coords) where c.lastFit != coords && !coords.isEmpty:
            c.lastFit = coords
            let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
            let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: lats.min()!, longitude: lons.min()!),
                                             ne: CLLocationCoordinate2D(latitude: lats.max()!, longitude: lons.max()!))
            map.setVisibleCoordinateBounds(bounds, edgePadding: UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 40), animated: false, completionHandler: nil)
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: GameMapView
        weak var map: MLNMapView?
        var styleReady = false
        var conquered: Bool
        var look: PlayerProfile.MapLook
        var lastVersion = -1
        var lastFocus: Coordinate?
        var centredOnStreets = false
        var userMoved = false
        var lastFit: [Coordinate]?
        private var coinPoints: [[CLLocationCoordinate2D]] = []
        private var coinKeys: [[CoinID]] = []
        private weak var featuresArea: Area?
        private var registeredIcons = Set<String>()
        private var pulse: Timer?

        init(_ p: GameMapView) {
            parent = p
            conquered = p.snapshot.conquered
            look = p.snapshot.look
        }

        static func styleURL(look: PlayerProfile.MapLook, conquered: Bool) -> URL {
            let name = "chomp-style-\(look.rawValue)\(conquered ? "-conquered" : "")-v6.json"
            let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
            let json = MapStyle.json(palette: MapStyle.palette(look, conquered: conquered))
            try? json.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        @objc func didPan(_ g: UIPanGestureRecognizer) {
            if g.state == .began { userMoved = true; parent.onUserPan?() }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            NSLog("[ChompMap] style failed: \(error.localizedDescription)")
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            NSLog("[ChompMap] style loaded with \(style.layers.count) layers")
            styleReady = true
            registeredIcons.removeAll()
            featuresArea = nil
            lastVersion = -1
            apply(parent.snapshot)
            startPulse()
        }

        private func startPulse() {
            pulse?.invalidate()
            var t = 0.0
            pulse = Timer.scheduledTimer(withTimeInterval: 1 / 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let style = self.map?.style else { return }
                    t += 1 / 15
                    let s = (sin(t * 3) + 1) / 2
                    (style.layer(withIdentifier: "power-glow") as? MLNCircleStyleLayer)?.circleRadius = NSExpression(forConstantValue: 16 + 10 * s)
                    (style.layer(withIdentifier: "runner-glow") as? MLNCircleStyleLayer)?.circleRadius = NSExpression(forConstantValue: 14 + 8 * s)
                }
            }
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            let c = mapView.centerCoordinate
            parent.onRegionChange?(Coordinate(latitude: c.latitude, longitude: c.longitude), mapView.zoomLevel)
        }

        /// Street geometry only changes when tiles load; rebuild it then. Each street
        /// gets one coin per token, evenly spaced along it.
        private func rebuildFeaturesIfNeeded(metresPerToken: Double) -> Bool {
            guard featuresArea !== parent.area else { return false }
            let area = parent.area
            featuresArea = area
            coinPoints = area.segments.map { seg in
                let n = max(1, Int((seg.length / metresPerToken).rounded()))
                return (0..<n).map { i in
                    let c = area.projection.unproject(seg.polyline.point(at: seg.length * (Double(i) + 0.5) / Double(n)))
                    return CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
                }
            }
            coinKeys = area.segments.enumerated().map { i, seg in (0..<coinPoints[i].count).map { Coins.id(seg.id, $0) } }
            return true
        }

        private func coinIcon(_ hex: String, unclaimed: Bool = false, in style: MLNStyle) -> String {
            let name = "coin-\(hex)\(unclaimed ? "-open" : "")"
            if !registeredIcons.contains(name) {
                style.setImage(CoinIcon.render(colorHex: hex, unclaimed: unclaimed), forName: name)
                registeredIcons.insert(name)
            }
            return name
        }

        private static func heatHex(_ times: Int) -> String {
            switch times { case ..<2: "3B6BFF"; case 2: "8B5CFF"; case 3...4: "FF2BD6"; case 5...7: "FF8A3D"; default: "FFE14D" }
        }

        func apply(_ s: MapSnapshot) {
            guard styleReady, let style = map?.style else { return }
            let rebuilt = rebuildFeaturesIfNeeded(metresPerToken: s.metresPerToken)
            guard rebuilt || s.version != lastVersion || lastVersion == -1 else { return }
            lastVersion = s.version
            // One feature per run of same-looking coins on a street.
            let neutral = MapStyle.neutralCoin(s.look)
            var features: [MLNPointCollectionFeature] = []
            features.reserveCapacity(coinPoints.count)
            for (i, seg) in parent.area.segments.enumerated() where i < coinPoints.count {
                let streetLook = s.looks[seg.id]
                let heat = s.heat?[seg.id] ?? 0
                var runStart = 0
                var runKey: String?
                var runAttrs: [String: Any] = [:]
                func flush(_ end: Int) {
                    guard end > runStart else { return }
                    var pts = Array(coinPoints[i][runStart..<end])
                    let f = MLNPointCollectionFeature(coordinates: &pts, count: UInt(pts.count))!
                    f.attributes = runAttrs
                    features.append(f)
                }
                for c in 0..<coinPoints[i].count {
                    let look = s.coinLooks[coinKeys[i][c]] ?? streetLook
                    let state = look?.state ?? "neutral"
                    var hex: String
                    if heat > 0 { hex = Self.heatHex(heat) }
                    else if state == "neutral" { hex = s.bonus.contains(seg.id) ? MapStyle.bonusCoin : neutral }
                    else if state == "mine" { hex = MapStyle.mineCoin(s.look) }
                    else { hex = MapStyle.rivalCoin(look?.colorHex ?? "FF3355") }
                    let strength = ((look?.strength ?? 0) * 20).rounded() / 20
                    let key = "\(hex)|\(state)|\(strength)"
                    if key != runKey {
                        flush(c)
                        runStart = c
                        runKey = key
                        runAttrs = [
                            "icon": coinIcon(hex.uppercased(), unclaimed: state == "neutral" && heat == 0 && !s.bonus.contains(seg.id), in: style),
                            "state": state,
                            "strength": strength,
                            // Lower draws first when coins compete for space: yours win, then rivals', then unclaimed.
                            "rank": state == "mine" ? 0 : state == "rival" ? 1 : 2,
                        ]
                    }
                }
                flush(coinPoints[i].count)
            }
            set(style, "coins", MLNShapeCollectionFeature(shapes: features))

            // Flash the most recently collected coins (or whole streets, for old runs).
            var flash: [CLLocationCoordinate2D] = []
            for key in s.eaten.suffix(12) {
                guard let idx = parent.area.segmentIndex(Coins.segment(of: key)), idx < coinPoints.count else { continue }
                if let c = Coins.index(of: key) {
                    if c < coinPoints[idx].count { flash.append(coinPoints[idx][c]) }
                } else {
                    flash += coinPoints[idx]
                }
            }
            let eaten: [MLNPointCollectionFeature] = flash.isEmpty ? [] : [MLNPointCollectionFeature(coordinates: &flash, count: UInt(flash.count))!]
            set(style, "eaten", MLNShapeCollectionFeature(shapes: eaten))

            var trail = s.trail.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            set(style, "trail", trail.count > 1 ? MLNPolylineFeature(coordinates: &trail, count: UInt(trail.count)) : MLNShapeCollectionFeature(shapes: []))
            var route = s.route.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            set(style, "route", route.count > 1 ? MLNPolylineFeature(coordinates: &route, count: UInt(route.count)) : MLNShapeCollectionFeature(shapes: []))

            let pellets: [MLNPointFeature] = s.pellets.map { p in
                let f = MLNPointFeature()
                f.coordinate = CLLocationCoordinate2D(latitude: p.landmark.coordinate.latitude, longitude: p.landmark.coordinate.longitude)
                f.attributes = ["name": p.landmark.name]
                return f
            }
            set(style, "pellets-power", MLNShapeCollectionFeature(shapes: pellets))

            let ghosts: [MLNPointFeature] = s.ghosts.map { g in
                let icon = "ghost-\(g.colorHex)"
                if !registeredIcons.contains(icon) {
                    style.setImage(GhostIcon.render(colorHex: g.colorHex), forName: icon)
                    registeredIcons.insert(icon)
                }
                let f = MLNPointFeature()
                f.coordinate = CLLocationCoordinate2D(latitude: g.coordinate.latitude, longitude: g.coordinate.longitude)
                f.attributes = ["icon": icon, "color": "#" + g.colorHex, "label": g.isBot ? "\(g.name.uppercased()) · BOT" : g.name]
                return f
            }
            set(style, "ghosts", MLNShapeCollectionFeature(shapes: ghosts))

            if let r = s.runner {
                let f = MLNPointFeature()
                f.coordinate = CLLocationCoordinate2D(latitude: r.latitude, longitude: r.longitude)
                f.attributes = ["color": "#" + s.playerColorHex]
                set(style, "runner", f)
            } else {
                set(style, "runner", MLNShapeCollectionFeature(shapes: []))
            }
        }

        private func set(_ style: MLNStyle, _ id: String, _ shape: MLNShape) {
            (style.source(withIdentifier: id) as? MLNShapeSource)?.shape = shape
        }
    }
}

/// Stops MapLibre asking for location before the player chooses to run.
/// Chomp asks itself, with context, when the first run starts.
final class PassiveLocationManager: NSObject, MLNLocationManager {
    weak var delegate: MLNLocationManagerDelegate?
    var authorizationStatus: CLAuthorizationStatus { .notDetermined }
    var headingOrientation: CLDeviceOrientation = .portrait
    func requestAlwaysAuthorization() {}
    func requestWhenInUseAuthorization() {}
    func startUpdatingLocation() {}
    func stopUpdatingLocation() {}
    func startUpdatingHeading() {}
    func stopUpdatingHeading() {}
    func dismissHeadingCalibrationDisplay() {}
}

/// Rival marker: a rounded hexagon with a visor. Original design.
enum GhostIcon {
    @MainActor
    static func render(colorHex: String) -> UIImage {
        let size = CGSize(width: 34, height: 34)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = UIColor(Color(hex: colorHex))
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
            let path = UIBezierPath()
            let cx = rect.midX, cy = rect.midY, r = rect.width / 2
            for i in 0..<6 {
                let a = CGFloat(i) * .pi / 3 - .pi / 2
                let p = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
                i == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            path.close()
            path.lineJoinStyle = .round
            c.setFill()
            path.fill()
            UIColor.white.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 2
            path.stroke()
            let visor = UIBezierPath(roundedRect: CGRect(x: cx - 9, y: cy - 3.5, width: 18, height: 7), cornerRadius: 3.5)
            UIColor(white: 0.04, alpha: 1).setFill()
            visor.fill()
            let eye = UIBezierPath(roundedRect: CGRect(x: cx - 6, y: cy - 1.5, width: 12, height: 3), cornerRadius: 1.5)
            c.setFill()
            eye.fill()
            _ = ctx
        }
    }
}

/// A token: a chunky coin with a rim, an inner ring and a glint. Original art,
/// drawn in code so it can take any player's colour.
enum CoinIcon {
    static let points: CGFloat = 26

    /// Unclaimed coins are small, quiet silver; claimed coins are full-size and
    /// struck in the owner's colour, so territory stands out from the open map.
    @MainActor
    static func render(colorHex: String, unclaimed: Bool = false) -> UIImage {
        let key = "\(colorHex)|\(unclaimed)"
        if let hit = cache[key] { return hit }
        let size = CGSize(width: points, height: points)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 3
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            draw(in: ctx.cgContext, size: size, base: UIColor(Color(hex: colorHex)), unclaimed: unclaimed)
        }
        cache[key] = img
        return img
    }

    @MainActor private static var cache: [String: UIImage] = [:]

    @MainActor
    static func render(color: Color, unclaimed: Bool = false) -> UIImage {
        let c = color.resolve(in: EnvironmentValues())
        let hex = String(format: "%02X%02X%02X", Int((c.red * 255).rounded()), Int((c.green * 255).rounded()), Int((c.blue * 255).rounded()))
        return render(colorHex: hex, unclaimed: unclaimed)
    }

    private static func shade(_ c: UIColor, brightness k: CGFloat, saturation s: CGFloat = 1, alpha: CGFloat = 1) -> UIColor {
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        return UIColor(hue: h, saturation: min(1, sat * s), brightness: min(1, max(0, b * k)), alpha: alpha)
    }

    private static func draw(in g: CGContext, size: CGSize, base: UIColor, unclaimed: Bool) {
        let space = CGColorSpaceCreateDeviceRGB()
        let d: CGFloat = unclaimed ? 14 : 21
        let outer = CGRect(x: (size.width - d) / 2, y: (size.height - d) / 2 - 0.5, width: d, height: d)

        // Contact shadow, so coins sit on light and dark maps alike.
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: unclaimed ? 0.8 : 1.4), blur: unclaimed ? 1.5 : 2.5,
                    color: UIColor.black.withAlphaComponent(unclaimed ? 0.35 : 0.5).cgColor)
        g.setFillColor(shade(base, brightness: 0.5, saturation: 1.1).cgColor)
        g.fillEllipse(in: outer)
        g.restoreGState()

        // Bevelled rim: lit from the top left.
        g.saveGState()
        g.addEllipse(in: outer)
        g.clip()
        let rim = CGGradient(colorsSpace: space, colors: [
            shade(base, brightness: 1.15, saturation: 0.7).cgColor,
            shade(base, brightness: 0.78, saturation: 1.05).cgColor,
            shade(base, brightness: 0.48, saturation: 1.15).cgColor,
        ] as CFArray, locations: [0, 0.5, 1])!
        g.drawLinearGradient(rim, start: CGPoint(x: outer.minX, y: outer.minY), end: CGPoint(x: outer.maxX, y: outer.maxY), options: [])
        g.restoreGState()

        // Face: domed radial shading.
        let face = outer.insetBy(dx: unclaimed ? 1.6 : 2.2, dy: unclaimed ? 1.6 : 2.2)
        g.saveGState()
        g.addEllipse(in: face)
        g.clip()
        let dome = CGGradient(colorsSpace: space, colors: [
            shade(base, brightness: 1.25, saturation: 0.55).cgColor,
            base.cgColor,
            shade(base, brightness: 0.8, saturation: 1.1).cgColor,
        ] as CFArray, locations: [0, 0.55, 1])!
        let hi = CGPoint(x: face.minX + face.width * 0.34, y: face.minY + face.height * 0.3)
        g.drawRadialGradient(dome, startCenter: hi, startRadius: 0, endCenter: CGPoint(x: face.midX, y: face.midY),
                             endRadius: face.width * 0.62, options: [.drawsAfterEndLocation])
        g.restoreGState()

        if unclaimed {
            // A single soft glint: present, but quiet.
            g.setFillColor(UIColor.white.withAlphaComponent(0.85).cgColor)
            g.fillEllipse(in: CGRect(x: face.minX + face.width * 0.24, y: face.minY + face.height * 0.18,
                                     width: face.width * 0.3, height: face.height * 0.2))
            return
        }

        // Struck edge just inside the rim.
        g.setStrokeColor(shade(base, brightness: 0.62, saturation: 1.1, alpha: 0.7).cgColor)
        g.setLineWidth(0.8)
        g.strokeEllipse(in: face.insetBy(dx: 1.4, dy: 1.4))

        // Emblem: an embossed four-point star (shadow, then highlight, then face).
        func star(_ c: CGPoint, _ r: CGFloat) -> CGPath {
            let p = CGMutablePath()
            let inner = r * 0.36
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4 - .pi / 2
                let rr = i % 2 == 0 ? r : inner
                let pt = CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            p.closeSubpath()
            return p
        }
        let c = CGPoint(x: face.midX, y: face.midY)
        let r = face.width * 0.3
        g.addPath(star(CGPoint(x: c.x + 0.5, y: c.y + 0.6), r))
        g.setFillColor(shade(base, brightness: 0.55, saturation: 1.15, alpha: 0.85).cgColor)
        g.fillPath()
        g.addPath(star(CGPoint(x: c.x - 0.4, y: c.y - 0.45), r))
        g.setFillColor(UIColor.white.withAlphaComponent(0.7).cgColor)
        g.fillPath()
        g.addPath(star(c, r))
        g.setFillColor(shade(base, brightness: 1.08, saturation: 0.85).cgColor)
        g.fillPath()

        // Gloss crescent across the top.
        g.saveGState()
        g.addEllipse(in: face)
        g.clip()
        let gloss = CGGradient(colorsSpace: space, colors: [UIColor.white.withAlphaComponent(0.55).cgColor,
                                                            UIColor.white.withAlphaComponent(0).cgColor] as CFArray,
                               locations: [0, 1])!
        g.addEllipse(in: CGRect(x: face.minX + face.width * 0.12, y: face.minY - face.height * 0.05,
                                width: face.width * 0.76, height: face.height * 0.42))
        g.clip()
        g.drawLinearGradient(gloss, start: CGPoint(x: face.midX, y: face.minY), end: CGPoint(x: face.midX, y: face.minY + face.height * 0.4), options: [])
        g.restoreGState()
    }
}
