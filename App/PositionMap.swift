// The map under the Map tab: MapKit's own view, since SwiftUI's map draws neither a dot with a name
// nor a shape before iOS 17 and macOS 14. Each position is a marker at the centre of its cell, and a
// cell coarser than a street is drawn too: that is the honest "somewhere in here".

import MapKit
import SwiftUI
import TernKit

#if os(iOS)
import UIKit
private typealias PlatformColor = UIColor
#else
import AppKit
private typealias PlatformColor = NSColor
#endif

/// A position the node holds, as the map and its list show it.
struct MapPoint: Identifiable, Equatable {
    /// "c:" and the contact's address, or "g:", the group's id and the member's routing id.
    var id: String
    var name: String
    var position: Position
    var isGroup: Bool

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: Double(position.lat) / 1e7, longitude: Double(position.lon) / 1e7)
    }

    /// Half a cell's size, in degrees: the cell is `360 / 2^precision` each way.
    var halfCell: Double { 180 / pow(2, Double(position.precision)) }

    /// How precise, how old, and the altitude and accuracy if it came with them, as one line.
    var details: String {
        var parts = [PositionWords.within(position.precision), "\(Words.duration(position.age)) ago"]
        if position.altitude != Position.noAltitude { parts.append("\(position.altitude) m") }
        if position.accuracy != 0 { parts.append("± \(position.accuracy) m") }
        return parts.joined(separator: " · ")
    }
}

/// Where the map was asked to look: the point, and a count so that asking again looks again.
struct MapFocus: Equatable {
    var id: String
    var count: Int
}

struct PositionMap {
    var points: [MapPoint]
    /// The user lets the app have their location: MapKit shows it as its blue dot.
    var showsPhone: Bool
    var focus: MapFocus?

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        private var shown: [MapPoint] = []
        private var focused: MapFocus?
        /// What the camera was fitted to: nil before it was, false when there was nothing to fit
        /// but the world, so that the first position or phone location found is fitted to once more.
        private var fitted: Bool?
        /// The phone's location was in the last fit: until it is, its first fix is fitted to once.
        private var fittedPhone = false

        func make() -> MKMapView {
            let view = MKMapView()
            view.delegate = self
            return view
        }

        func update(_ view: MKMapView, with map: PositionMap) {
            if view.showsUserLocation != map.showsPhone { view.showsUserLocation = map.showsPhone }
            if map.points != shown {
                let selected = (view.selectedAnnotations.first as? PointAnnotation)?.id
                view.removeAnnotations(view.annotations.filter { $0 is PointAnnotation })
                view.removeOverlays(view.overlays)
                for p in map.points {
                    view.addAnnotation(PointAnnotation(p))
                    if p.position.precision < 20 { view.addOverlay(cell(p)) }
                }
                shown = map.points
                if let selected, let a = annotation(selected, in: view) { view.selectAnnotation(a, animated: false) }
            }
            if fitted != true {
                if view.bounds.isEmpty {
                    // Not yet laid out: a fit now would be to a map of no size.
                    DispatchQueue.main.async { [weak self, weak view] in
                        guard let self, let view, self.fitted != true else { return }
                        self.fit(view)
                    }
                } else {
                    fit(view)
                }
            }
            if let focus = map.focus, focus != focused {
                focused = focus
                look(at: focus.id, in: view)
            }
        }

        /// Every position and the phone's location in view; the phone's alone if there are none;
        /// else the whole world.
        private func fit(_ view: MKMapView) {
            var rect = MKMapRect.null
            for p in shown {
                rect = rect.union(region(p))
            }
            if let phone = view.userLocation.location, view.showsUserLocation {
                rect = rect.union(MKMapRect(origin: MKMapPoint(phone.coordinate), size: MKMapSize(width: 0, height: 0)))
                fittedPhone = true
            }
            guard !rect.isNull else {
                if fitted == nil { view.setVisibleMapRect(.world, animated: false) }
                fitted = false
                return
            }
            show(rect, in: view, animated: fitted != nil)
            fitted = true
        }

        /// Centres on a position, with its cell in view, and opens its callout.
        private func look(at id: String, in view: MKMapView) {
            guard let p = shown.first(where: { $0.id == id }) else { return }
            show(region(p), in: view, animated: true)
            if let a = annotation(id, in: view) { view.selectAnnotation(a, animated: true) }
        }

        private func show(_ rect: MKMapRect, in view: MKMapView, animated: Bool) {
            // A point, or a street, is a few hundred metres across: not as close as MapKit goes.
            let least = 400 * MKMapPointsPerMeterAtLatitude(rect.origin.coordinate.latitude)
            let grown = rect.insetBy(dx: -max(0, least - rect.width) / 2, dy: -max(0, least - rect.height) / 2)
            #if os(iOS)
            let padding = UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40)
            #else
            let padding = NSEdgeInsets(top: 40, left: 40, bottom: 40, right: 40)
            #endif
            view.setVisibleMapRect(grown, edgePadding: padding, animated: animated)
        }

        /// The cell a position is somewhere in, as a map rectangle.
        private func region(_ p: MapPoint) -> MKMapRect {
            let corners = cellCorners(p)
            let a = MKMapPoint(corners[0])
            let b = MKMapPoint(corners[2])
            return MKMapRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        }

        private func cellCorners(_ p: MapPoint) -> [CLLocationCoordinate2D] {
            let c = p.coordinate
            let h = p.halfCell
            let south = max(c.latitude - h, -90)
            let north = min(c.latitude + h, 90)
            return [
                CLLocationCoordinate2D(latitude: south, longitude: c.longitude - h),
                CLLocationCoordinate2D(latitude: south, longitude: c.longitude + h),
                CLLocationCoordinate2D(latitude: north, longitude: c.longitude + h),
                CLLocationCoordinate2D(latitude: north, longitude: c.longitude - h),
            ]
        }

        private func cell(_ p: MapPoint) -> MKPolygon {
            let corners = cellCorners(p)
            let polygon = MKPolygon(coordinates: corners, count: corners.count)
            polygon.title = p.isGroup ? "group" : "contact"
            return polygon
        }

        private func annotation(_ id: String, in view: MKMapView) -> PointAnnotation? {
            view.annotations.lazy.compactMap { $0 as? PointAnnotation }.first { $0.id == id }
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let point = annotation as? PointAnnotation else { return nil }
            let reuse = "point"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuse) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: point, reuseIdentifier: reuse)
            view.annotation = point
            view.canShowCallout = true
            view.markerTintColor = point.isGroup ? PlatformColor.systemPurple : PlatformColor.systemOrange
            view.glyphImage = nil
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polygon = overlay as? MKPolygon else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolygonRenderer(polygon: polygon)
            let color = polygon.title == "group" ? PlatformColor.systemPurple : PlatformColor.systemOrange
            renderer.fillColor = color.withAlphaComponent(0.15)
            renderer.strokeColor = color.withAlphaComponent(0.6)
            renderer.lineWidth = 1
            return renderer
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            // Nothing to look at before: the phone is something. And positions fitted to before the
            // phone's first fix came are fitted to again with it, once.
            if fitted == false || (fitted == true && !fittedPhone && userLocation.location != nil) { fit(mapView) }
        }
    }
}

/// A position on the map: its name over the marker, and how precise and how old in the callout.
final class PointAnnotation: NSObject, MKAnnotation {
    let id: String
    let isGroup: Bool
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?

    init(_ p: MapPoint) {
        id = p.id
        isGroup = p.isGroup
        coordinate = p.coordinate
        title = p.name
        subtitle = p.details
    }
}

#if os(iOS)
extension PositionMap: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView { context.coordinator.make() }

    func updateUIView(_ view: MKMapView, context: Context) { context.coordinator.update(view, with: self) }
}
#else
extension PositionMap: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView { context.coordinator.make() }

    func updateNSView(_ view: MKMapView, context: Context) { context.coordinator.update(view, with: self) }
}
#endif
