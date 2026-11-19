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
        let map = MLNMapView(frame: .zero, styleURL: Coordinator.styleURL(conquered: snapshot.conquered))
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
        if c.conquered != snapshot.conquered {
            c.conquered = snapshot.conquered
            c.styleReady = false
            map.styleURL = Coordinator.styleURL(conquered: snapshot.conquered)
            return
        }
        c.apply(snapshot)
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
        var lastVersion = -1
        var lastFocus: Coordinate?
        var lastFit: [Coordinate]?
        private var segmentFeatures: [MLNPolylineFeature] = []
        private weak var featuresArea: Area?
        private var registeredIcons = Set<String>()
        private var pulse: Timer?

        init(_ p: GameMapView) {
            parent = p
            conquered = p.snapshot.conquered
        }

        static func styleURL(conquered: Bool) -> URL {
            let name = conquered ? "chomp-style-conquered-v1.json" : "chomp-style-arcade-v1.json"
            let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
            let json = MapStyle.json(palette: conquered ? MapStyle.conquered : MapStyle.arcade)
            try? json.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        @objc func didPan(_ g: UIPanGestureRecognizer) {
            if g.state == .began { parent.onUserPan?() }
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
                    (style.layer(withIdentifier: "bonus-glow") as? MLNLineStyleLayer)?.lineOpacity = NSExpression(forConstantValue: 0.25 + 0.45 * s)
                    (style.layer(withIdentifier: "runner-glow") as? MLNCircleStyleLayer)?.circleRadius = NSExpression(forConstantValue: 14 + 8 * s)
                }
            }
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            let c = mapView.centerCoordinate
            parent.onRegionChange?(Coordinate(latitude: c.latitude, longitude: c.longitude), mapView.zoomLevel)
        }

        /// Street geometry only changes when tiles load; rebuild it then.
        private func rebuildFeaturesIfNeeded() -> Bool {
            guard featuresArea !== parent.area else { return false }
            featuresArea = parent.area
            segmentFeatures = parent.area.segments.map { seg in
                var coords = seg.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                let f = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
                f.identifier = seg.id as NSString
                return f
            }
            return true
        }

        func apply(_ s: MapSnapshot) {
            guard styleReady, let style = map?.style else { return }
            let rebuilt = rebuildFeaturesIfNeeded()
            guard rebuilt || s.version != lastVersion || lastVersion == -1 else { return }
            lastVersion = s.version
            for (i, seg) in parent.area.segments.enumerated() where i < segmentFeatures.count {
                let look = s.looks[seg.id]
                segmentFeatures[i].attributes = [
                    "state": look?.state ?? "off",
                    "color": "#" + (look?.colorHex ?? "FFF1C1"),
                    "strength": look?.strength ?? 0,
                    "bonus": s.bonus.contains(seg.id) ? 1 : 0,
                    "heat": s.heat?[seg.id] ?? 0,
                ]
            }
            set(style, "segments", MLNShapeCollectionFeature(shapes: segmentFeatures))

            let blocks: [MLNPolygonFeature] = s.blocks.compactMap { b in
                guard let block = parent.area.blockByID[b.id] else { return nil }
                var coords = block.ring.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                let f = MLNPolygonFeature(coordinates: &coords, count: UInt(coords.count))
                f.attributes = ["color": "#" + b.colorHex]
                return f
            }
            set(style, "blocks", MLNShapeCollectionFeature(shapes: blocks))

            let eaten: [MLNPolylineFeature] = s.eaten.suffix(3).compactMap { id in
                guard let seg = parent.area.segment(id) else { return nil }
                var coords = seg.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                return MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
            }
            set(style, "eaten", MLNShapeCollectionFeature(shapes: eaten))

            var trail = s.trail.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            set(style, "trail", trail.count > 1 ? MLNPolylineFeature(coordinates: &trail, count: UInt(trail.count)) : MLNShapeCollectionFeature(shapes: []))

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
