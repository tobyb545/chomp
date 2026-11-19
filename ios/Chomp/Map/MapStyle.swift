import Foundation

/// Chomp's own map style: a base map from OpenFreeMap vector tiles (OpenMapTiles
/// schema, free, no key) with our game layers on top. Built in code so the
/// brightness setting (Light / Dusk / Dark) and the "conquered" variant can change it.
enum MapStyle {
    struct Palette {
        var background: String
        var land: String
        var water: String
        var green: String
        var building: String
        var road: String
        var label: String
        var segmentBase: String
        /// The dots (tokens) on streets you don't own.
        var pellet = pelletColour
        /// Your run trail and the flash when a street is eaten.
        var trail = "#FFFFFF"
        /// A dark edge under owned streets so pale player colours show on a light map.
        var casingOpacity = 0.0
    }

    static let arcade = Palette(background: "#07070E", land: "#0B0B16", water: "#0A1838", green: "#0A1A14",
                                building: "#11111F", road: "#191930", label: "#6F6F96", segmentBase: "#2A2A4A")
    /// Unlocked by owning a whole map square: warmer, gold-trimmed.
    static let conquered = Palette(background: "#0E0904", land: "#140E06", water: "#0B1A2E", green: "#141A08",
                                   building: "#1C140A", road: "#2A1F10", label: "#A08A5C", segmentBase: "#4A3A1C")
    /// Default: a lighter slate night, roads and parks easy to read.
    static let dusk = Palette(background: "#262B40", land: "#2C3249", water: "#2B4A7A", green: "#2C4A3D",
                              building: "#383F5C", road: "#4D5679", label: "#BAC1DE", segmentBase: "#5C6690")
    static let duskConquered = Palette(background: "#362C20", land: "#3E3326", water: "#2D4A6E", green: "#3B482A",
                                       building: "#4A3E2D", road: "#6A5838", label: "#E2CA92", segmentBase: "#7C6842")
    /// Daytime: pale ground, white roads, amber tokens.
    static let light = Palette(background: "#ECEEF3", land: "#E4E7EE", water: "#A8C7EB", green: "#D0E5CB",
                               building: "#D8DBE4", road: "#FFFFFF", label: "#545A70", segmentBase: "#BFC5D4",
                               pellet: "#E08600", trail: "#262B40", casingOpacity: 0.55)
    static let lightConquered = Palette(background: "#F3ECDC", land: "#EEE5D0", water: "#B2CCE6", green: "#D9E4C3",
                                        building: "#E2D7C0", road: "#FFFDF6", label: "#76603C", segmentBase: "#D4C399",
                                        pellet: "#C86A00", trail: "#3A2E20", casingOpacity: 0.55)

    static func palette(_ look: PlayerProfile.MapLook, conquered c: Bool) -> Palette {
        switch look {
        case .dark: c ? conquered : arcade
        case .dusk: c ? duskConquered : dusk
        case .light: c ? lightConquered : light
        }
    }

    static let pelletColour = "#FFF1C1"
    static let routeColour = "#38E8FF"
    static let powerColour = "#FF2BD6"

    /// Coin artwork is drawn at `CoinIcon.points`; this scales it with zoom.
    /// Slightly bigger than the old dots, and roughly one coin per 10 m when zoomed in.
    static var coinSize: [Any] { ["interpolate", ["exponential", 1.5], ["zoom"], 13, 0.2, 15, 0.34, 16, 0.46, 17, 0.62, 18, 0.9, 19, 1.15] }
    static func coinRadius(_ scale: Double) -> [Any] {
        ["interpolate", ["exponential", 1.5], ["zoom"], 13, 2.2 * scale, 15, 3.7 * scale, 16, 5 * scale, 17, 6.8 * scale, 18, 9.9 * scale]
    }
    /// Unowned coins: gold.
    static func neutralCoin(_ look: PlayerProfile.MapLook) -> String { look == .light ? "F0A400" : "FFC83D" }
    static let bonusCoin = "FF2BD6"

    static func json(palette p: Palette) -> String {
        let empty: [String: Any] = ["type": "FeatureCollection", "features": [Any]()]
        func geo() -> [String: Any] { ["type": "geojson", "data": empty] }
        let zoomWidth: (Double, Double) -> [Any] = { a, b in ["interpolate", ["exponential", 1.6], ["zoom"], 13, a, 18, b] }

        let layers: [[String: Any]] = [
            ["id": "background", "type": "background", "paint": ["background-color": p.background]],
            ["id": "landuse", "type": "fill", "source": "ofm", "source-layer": "landuse",
             "paint": ["fill-color": p.land]],
            ["id": "green", "type": "fill", "source": "ofm", "source-layer": "landcover",
             "filter": ["in", ["get", "class"], ["literal", ["grass", "wood", "farmland", "wetland"]]],
             "paint": ["fill-color": p.green, "fill-opacity": 0.9]],
            ["id": "water", "type": "fill", "source": "ofm", "source-layer": "water", "paint": ["fill-color": p.water]],
            ["id": "waterway", "type": "line", "source": "ofm", "source-layer": "waterway",
             "paint": ["line-color": p.water, "line-width": zoomWidth(1, 4)]],
            ["id": "building", "type": "fill", "source": "ofm", "source-layer": "building", "minzoom": 14,
             "paint": ["fill-color": p.building, "fill-outline-color": p.road]],
            ["id": "rail", "type": "line", "source": "ofm", "source-layer": "transportation",
             "filter": ["==", ["get", "class"], "rail"],
             "paint": ["line-color": p.segmentBase, "line-width": zoomWidth(1, 3), "line-dasharray": [3, 2]]],
            ["id": "roads", "type": "line", "source": "ofm", "source-layer": "transportation",
             "filter": ["!=", ["get", "class"], "rail"],
             "layout": ["line-cap": "round", "line-join": "round"],
             "paint": ["line-color": p.road, "line-width": zoomWidth(1, 6)]],

            // Game layers
            // A planned loop: cyan dashes under the coins.
            ["id": "route-casing", "type": "line", "source": "route",
             "layout": ["line-cap": "round", "line-join": "round"],
             "paint": ["line-color": "#0B0B16", "line-width": zoomWidth(5, 14), "line-opacity": 0.35 + p.casingOpacity * 0.6]],
            ["id": "route", "type": "line", "source": "route",
             "layout": ["line-cap": "round", "line-join": "round"],
             "paint": ["line-color": routeColour, "line-width": zoomWidth(3, 9), "line-dasharray": [1.4, 1.1], "line-opacity": 0.95]],
            // Just-eaten coins flash.
            ["id": "eaten-flash", "type": "circle", "source": "eaten",
             "paint": ["circle-color": p.trail, "circle-radius": coinRadius(1.9), "circle-blur": 0.8, "circle-opacity": 0.7]],
            // Tokens: one coin per token along every street, tinted by owner. When
            // zoomed out, overlapping coins are dropped so they never merge into a line.
            ["id": "coins", "type": "symbol", "source": "coins", "minzoom": 13,
             "layout": ["icon-image": ["get", "icon"], "icon-size": coinSize,
                        "icon-allow-overlap": false, "icon-ignore-placement": true, "icon-padding": 0,
                        "symbol-sort-key": ["get", "rank"]],
             "paint": ["icon-opacity": ["case", ["==", ["get", "state"], "neutral"], 1,
                                        ["+", 0.4, ["*", 0.6, ["get", "strength"]]]]]],
            ["id": "trail", "type": "line", "source": "trail",
             "layout": ["line-cap": "round", "line-join": "round"],
             "paint": ["line-color": p.trail, "line-width": zoomWidth(1.5, 4), "line-opacity": 0.55]],
            ["id": "power-glow", "type": "circle", "source": "pellets-power",
             "paint": ["circle-color": powerColour, "circle-radius": 22, "circle-blur": 1, "circle-opacity": 0.6]],
            ["id": "power", "type": "circle", "source": "pellets-power",
             "paint": ["circle-color": "#FFFFFF", "circle-radius": 9, "circle-stroke-color": powerColour, "circle-stroke-width": 4]],
            ["id": "ghost-halo", "type": "circle", "source": "ghosts",
             "paint": ["circle-color": ["to-color", ["get", "color"]], "circle-radius": 26, "circle-blur": 0.8, "circle-opacity": 0.35]],
            ["id": "ghost", "type": "symbol", "source": "ghosts",
             "layout": ["icon-image": ["get", "icon"], "icon-allow-overlap": true, "text-field": ["get", "label"],
                        "text-font": ["Noto Sans Bold"], "text-size": 11, "text-offset": [0, 2.0], "text-anchor": "top",
                        "text-allow-overlap": false],
             "paint": ["text-color": ["to-color", ["get", "color"]], "text-halo-color": p.background, "text-halo-width": 1.5]],
            ["id": "runner-glow", "type": "circle", "source": "runner",
             "paint": ["circle-color": ["to-color", ["get", "color"]], "circle-radius": 20, "circle-blur": 1, "circle-opacity": 0.7]],
            ["id": "runner", "type": "circle", "source": "runner",
             "paint": ["circle-color": ["to-color", ["get", "color"]], "circle-radius": 8, "circle-stroke-color": "#FFFFFF", "circle-stroke-width": 3]],
            ["id": "street-labels", "type": "symbol", "source": "ofm", "source-layer": "transportation_name", "minzoom": 15,
             "layout": ["symbol-placement": "line", "text-field": ["coalesce", ["get", "name:en"], ["get", "name"]],
                        "text-font": ["Noto Sans Regular"], "text-size": 11],
             "paint": ["text-color": p.label, "text-halo-color": p.background, "text-halo-width": 1.5]],
            ["id": "place-labels", "type": "symbol", "source": "ofm", "source-layer": "place", "maxzoom": 15,
             "filter": ["in", ["get", "class"], ["literal", ["town", "village", "suburb", "hamlet"]]],
             "layout": ["text-field": ["get", "name"], "text-font": ["Noto Sans Bold"], "text-size": 13,
                        "text-transform": "uppercase", "text-letter-spacing": 0.15],
             "paint": ["text-color": p.label, "text-halo-color": p.background, "text-halo-width": 2]],
        ]

        let style: [String: Any] = [
            "version": 8,
            "name": "Chomp Arcade",
            "glyphs": "https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf",
            "sources": [
                "ofm": ["type": "vector", "url": "https://tiles.openfreemap.org/planet",
                        "attribution": "<a href=\"https://openfreemap.org\">OpenFreeMap</a> © <a href=\"https://www.openmaptiles.org/\">OpenMapTiles</a> Data from <a href=\"https://www.openstreetmap.org/copyright\">OpenStreetMap</a>"],
                "coins": geo(), "eaten": geo(), "trail": geo(), "route": geo(),
                "pellets-power": geo(), "ghosts": geo(), "runner": geo(),
            ],
            "layers": layers,
        ]
        let data = try! JSONSerialization.data(withJSONObject: style, options: [])
        return String(decoding: data, as: UTF8.self)
    }
}
