import Flutter
import UIKit
import Mapbox
import MapboxAnnotationExtension

class MapboxMapController: NSObject, FlutterPlatformView, MGLMapViewDelegate, MapboxMapOptionsSink, MGLAnnotationControllerDelegate {
    
    private var registrar: FlutterPluginRegistrar
    private var channel: FlutterMethodChannel?
    
    private var mapView: MGLMapView
    private var isMapReady = false
    private var mapReadyResult: FlutterResult?
    
    private var initialTilt: CGFloat?
    private var cameraTargetBounds: MGLCoordinateBounds?
    private var trackCameraPosition = false
    private var myLocationEnabled = false
    
    private var symbolAnnotationController: MGLSymbolAnnotationController?
    private var circleAnnotationController: MGLCircleAnnotationController?
    private var lineAnnotationController: MGLLineAnnotationController?
    
    func view() -> UIView {
        return mapView
    }
    
    init(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?, registrar: FlutterPluginRegistrar) {
        if let args = args as? [String: Any] {
            if let token = args["accessToken"] as? NSString{
                MGLAccountManager.accessToken = token
            }
        }
        mapView = MGLMapView(frame: frame)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.registrar = registrar
        
        super.init()
        
        channel = FlutterMethodChannel(name: "plugins.flutter.io/mapbox_maps_\(viewId)", binaryMessenger: registrar.messenger())
        channel!.setMethodCallHandler(onMethodCall)
        
        mapView.delegate = self
        
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleMapTap(sender:)))
        for recognizer in mapView.gestureRecognizers! where recognizer is UITapGestureRecognizer {
            singleTap.require(toFail: recognizer)
        }
        mapView.addGestureRecognizer(singleTap)
        
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleMapLongPress(sender:)))
        for recognizer in mapView.gestureRecognizers! where recognizer is UILongPressGestureRecognizer {
            longPress.require(toFail: recognizer)
        }
        mapView.addGestureRecognizer(longPress)
        
        if let args = args as? [String: Any] {
            Convert.interpretMapboxMapOptions(options: args["options"], delegate: self)
            if let initialCameraPosition = args["initialCameraPosition"] as? [String: Any],
                let camera = MGLMapCamera.fromDict(initialCameraPosition, mapView: mapView),
                let zoom = initialCameraPosition["zoom"] as? Double {
                mapView.setCenter(camera.centerCoordinate, zoomLevel: zoom, direction: camera.heading, animated: false)
                initialTilt = camera.pitch
            }
        }
    }
    
    func onMethodCall(methodCall: FlutterMethodCall, result: @escaping FlutterResult) {
        switch(methodCall.method) {
        case "map#waitForMap":
            if isMapReady {
                result(nil)
            } else {
                mapReadyResult = result
            }
        case "map#update":
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            Convert.interpretMapboxMapOptions(options: arguments["options"], delegate: self)
            if let camera = getCamera() {
                result(camera.toDict(mapView: mapView))
            } else {
                result(nil)
            }
        case "map#invalidateAmbientCache":
            MGLOfflineStorage.shared.invalidateAmbientCache{
                (error) in
                if let error = error {
                    result(error)
                } else{
                    result(nil)
                }
            }
        case "map#updateMyLocationTrackingMode":
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            if let myLocationTrackingMode = arguments["mode"] as? UInt, let trackingMode = MGLUserTrackingMode(rawValue: myLocationTrackingMode) {
                setMyLocationTrackingMode(myLocationTrackingMode: trackingMode)
            }
            result(nil)
        case "map#matchMapLanguageWithDeviceDefault":
            if let style = mapView.style {
                style.localizeLabels(into: nil)
            }
            result(nil)
        case "map#updateContentInsets":
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            
            if let bounds = arguments["bounds"] as? [String: Any],
                let top = bounds["top"] as? CGFloat,
                let left = bounds["left"]  as? CGFloat,
                let bottom = bounds["bottom"] as? CGFloat,
                let right = bounds["right"] as? CGFloat,
                let animated = arguments["animated"] as? Bool {
                mapView.setContentInset(UIEdgeInsets(top: top, left: left, bottom: bottom, right: right), animated: animated) {
                    result(nil)
                }
            } else {
                result(nil)
            }
        case "map#setMapLanguage":
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            if let localIdentifier = arguments["language"] as? String, let style = mapView.style {
                let locale = Locale(identifier: localIdentifier)
                style.localizeLabels(into: locale)
            }
            result(nil)
        case "map#queryRenderedFeatures":
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            let layerIds = arguments["layerIds"] as? Set<String>
            var filterExpression: NSPredicate?
            if let filter = arguments["filter"] as? [Any] {
                filterExpression = NSPredicate(mglJSONObject: filter)
            }
            var reply = [String: NSObject]()
            var features:[MGLFeature] = []
            if let x = arguments["x"] as? Double, let y = arguments["y"] as? Double {
                features = mapView.visibleFeatures(at: CGPoint(x: x, y: y), styleLayerIdentifiers: layerIds, predicate: filterExpression)
            }
            if  let top = arguments["top"] as? Double,
                let bottom = arguments["bottom"] as? Double,
                let left = arguments["left"] as? Double,
                let right = arguments["right"] as? Double {
                features = mapView.visibleFeatures(in: CGRect(x: left, y: top, width: right, height: bottom), styleLayerIdentifiers: layerIds, predicate: filterExpression)
            }
            var featuresJson = [String]()
            for feature in features {
                let dictionary = feature.geoJSONDictionary()
                if  let theJSONData = try? JSONSerialization.data(withJSONObject: dictionary, options: []),
                    let theJSONText = String(data: theJSONData, encoding: .ascii) {
                    featuresJson.append(theJSONText)
                }
            }
            reply["features"] = featuresJson as NSObject
            result(reply)
        case "map#setTelemetryEnabled":
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            let telemetryEnabled = arguments["enabled"] as? Bool
            UserDefaults.standard.set(telemetryEnabled, forKey: "MGLMapboxMetricsEnabled")
            result(nil)
        case "map#getTelemetryEnabled":
            let telemetryEnabled = UserDefaults.standard.bool(forKey: "MGLMapboxMetricsEnabled")
            result(telemetryEnabled)
        case "map#getVisibleRegion":
            var reply = [String: NSObject]()
            let visibleRegion = mapView.visibleCoordinateBounds
            reply["sw"] = [visibleRegion.sw.latitude, visibleRegion.sw.longitude] as NSObject
            reply["ne"] = [visibleRegion.ne.latitude, visibleRegion.ne.longitude] as NSObject
            result(reply)
        case "camera#move":
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            guard let cameraUpdate = arguments["cameraUpdate"] as? [Any] else { return }
            if let camera = Convert.parseCameraUpdate(cameraUpdate: cameraUpdate, mapView: mapView) {
                mapView.setCamera(camera, animated: false)
            }
            result(nil)
        case "camera#animate":
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            guard let cameraUpdate = arguments["cameraUpdate"] as? [Any] else { return }
            if let camera = Convert.parseCameraUpdate(cameraUpdate: cameraUpdate, mapView: mapView) {
                if let duration = arguments["duration"] as? TimeInterval {
                    mapView.setCamera(camera, withDuration: TimeInterval(duration / 1000), 
                                      animationTimingFunction: CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut))
                    result(nil)
                }
                mapView.setCamera(camera, animated: true)
            }
            result(nil)
        case "symbols#addAll":
            guard let symbolAnnotationController = symbolAnnotationController else { return }
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            
            if let options = arguments["options"] as? [[String: Any]] {
                var symbols: [MGLSymbolStyleAnnotation] = [];
                for o in options {
                    if let symbol = getSymbolForOptions(options: o)  {
                        symbols.append(symbol)
                    }
                }
                if !symbols.isEmpty {
                    symbolAnnotationController.addStyleAnnotations(symbols)
                }
                
                result(symbols.map { $0.identifier })
            } else {
                result(nil)
            }
        case "symbol#update":
            guard let symbolAnnotationController = symbolAnnotationController else { return }
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            guard let symbolId = arguments["symbol"] as? String else { return }
            
            for symbol in symbolAnnotationController.styleAnnotations(){
                if symbol.identifier == symbolId {
                    Convert.interpretSymbolOptions(options: arguments["options"], delegate: symbol as! MGLSymbolStyleAnnotation)
                    // Load (updated) icon image from asset if an icon name is supplied.
                    if let options = arguments["options"] as? [String: Any],
                        let iconImage = options["iconImage"] as? String {
                        addIconImageToMap(iconImageName: iconImage)
                    }
                    symbolAnnotationController.updateStyleAnnotation(symbol)
                    break;
                }
            }
            result(nil)
        case "symbols#removeAll":
            guard let symbolAnnotationController = symbolAnnotationController else { return }
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            guard let symbolIds = arguments["symbols"] as? [String] else { return }
            var symbols: [MGLSymbolStyleAnnotation] = [];
            
            for symbol in symbolAnnotationController.styleAnnotations(){
                if symbolIds.contains(symbol.identifier) {
                    symbols.append(symbol as! MGLSymbolStyleAnnotation)
                }
            }
            symbolAnnotationController.removeStyleAnnotations(symbols)
            result(nil)
        case "symbol#getGeometry":
            guard let symbolAnnotationController = symbolAnnotationController else { return }
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            guard let symbolId = arguments["symbol"] as? String else { return }
            
            var reply: [String:Double]? = nil
            for symbol in symbolAnnotationController.styleAnnotations(){
                if symbol.identifier == symbolId {
                    if let geometry = symbol.geoJSONDictionary["geometry"] as? [String: Any],
                        let coordinates = geometry["coordinates"] as? [Double] {
                        reply = ["latitude": coordinates[1], "longitude": coordinates[0]]
                    }
                    break;
                }
            }
            result(reply)
        case "symbolManager#iconAllowOverlap":
            guard let symbolAnnotationController = symbolAnnotationController else { return }
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            guard let iconAllowOverlap = arguments["iconAllowOverlap"] as? Bool else { return }
            
            symbolAnnotationController.iconAllowsOverlap = iconAllowOverlap
            result(nil)
        case "symbolManager#iconIgnorePlacement":
            guard let symbolAnnotationController = symbolAnnotationController else { return }
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            guard let iconIgnorePlacement = arguments["iconIgnorePlacement"] as? Bool else { return }
            
            symbolAnnotationController.iconIgnoresPlacement = iconIgnorePlacement
            result(nil)
        case "symbolManager#textAllowOverlap":
            guard let symbolAnnotationController = symbolAnnotationController else { return }
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            guard let textAllowOverlap = arguments["textAllowOverlap"] as? Bool else { return }
            
            symbolAnnotationController.textAllowsOverlap = textAllowOverlap
            result(nil)
        case "symbolManager#textIgnorePlacement":
            result(FlutterMethodNotImplemented)
        case "circle#add":
            guard let circleAnnotationController = circleAnnotationController else { return }
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            // Parse geometry
            if let options = arguments["options"] as? [String: Any],
                let geometry = options["geometry"] as? [Double] {
                // Convert geometry to coordinate and create circle.
                let coordinate = CLLocationCoordinate2DMake(geometry[0], geometry[1])
                let circle = MGLCircleStyleAnnotation(center: coordinate)
                Convert.interpretCircleOptions(options: arguments["options"], delegate: circle)
                circleAnnotationController.addStyleAnnotation(circle)
                result(circle.identifier)
            } else {
                result(nil)
            }
        case "circle#update":
            guard let circleAnnotationController = circleAnnotationController else { return }
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            guard let circleId = arguments["circle"] as? String else { return }
            
            for circle in circleAnnotationController.styleAnnotations() {
                if circle.identifier == circleId {
                    Convert.interpretCircleOptions(options: arguments["options"], delegate: circle as! MGLCircleStyleAnnotation)
                    circleAnnotationController.updateStyleAnnotation(circle)
                    break;
                }
            }
            result(nil)
        case "circle#remove":
            guard let circleAnnotationController = circleAnnotationController else { return }
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            guard let circleId = arguments["circle"] as? String else { return }
            
            for circle in circleAnnotationController.styleAnnotations() {
                if circle.identifier == circleId {
                    circleAnnotationController.removeStyleAnnotation(circle)
                    break;
                }
            }
            result(nil)
        case "line#add":
            guard let lineAnnotationController = lineAnnotationController else { return }
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            // Parse geometry
            if let options = arguments["options"] as? [String: Any],
                let geometry = options["geometry"] as? [[Double]] {
                // Convert geometry to coordinate and create a line.
                var lineCoordinates: [CLLocationCoordinate2D] = []
                for coordinate in geometry {
                    lineCoordinates.append(CLLocationCoordinate2DMake(coordinate[0], coordinate[1]))
                }
                let line = MGLLineStyleAnnotation(coordinates: lineCoordinates, count: UInt(lineCoordinates.count))
                Convert.interpretLineOptions(options: arguments["options"], delegate: line)
                lineAnnotationController.addStyleAnnotation(line)
                result(line.identifier)
            } else {
                result(nil)
            }
        case "line#update":
            guard let lineAnnotationController = lineAnnotationController else { return }
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            guard let lineId = arguments["line"] as? String else { return }
            
            for line in lineAnnotationController.styleAnnotations() {
                if line.identifier == lineId {
                    Convert.interpretLineOptions(options: arguments["options"], delegate: line as! MGLLineStyleAnnotation)
                    lineAnnotationController.updateStyleAnnotation(line)
                    break;
                }
            }
            result(nil)
        case "line#remove":
            guard let lineAnnotationController = lineAnnotationController else { return }
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            guard let lineId = arguments["line"] as? String else { return }
            
            for line in lineAnnotationController.styleAnnotations() {
                if line.identifier == lineId {
                    lineAnnotationController.removeStyleAnnotation(line)
                    break;
                }
            }
            result(nil)
        case "line#getGeometry":
            guard let lineAnnotationController = lineAnnotationController else { return }
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            guard let lineId = arguments["line"] as? String else { return }
            
            var reply: [Any]? = nil
            for line in lineAnnotationController.styleAnnotations() {
                if line.identifier == lineId {
                    if let geometry = line.geoJSONDictionary["geometry"] as? [String: Any],
                        let coordinates = geometry["coordinates"] as? [[Double]] {
                        reply = coordinates.map { [ "latitude": $0[1], "longitude": $0[0] ] }
                    }
                    break;
                }
            }
            result(reply)
        case "style#addImage":
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            guard let name = arguments["name"] as? String else { return }
            //guard let length = arguments["length"] as? NSNumber else { return }
            guard let bytes = arguments["bytes"] as? FlutterStandardTypedData else { return }
            guard let sdf = arguments["sdf"] as? Bool else { return }
            guard let data = bytes.data as? Data else{ return }
            guard let image = UIImage(data: data) else { return }
            if (sdf) {
                self.mapView.style?.setImage(image.withRenderingMode(.alwaysTemplate), forName: name)
            } else {
                self.mapView.style?.setImage(image, forName: name)
            }
            result(nil)
            
        // CUSTOM PART BEGIN
        case "neoRanges#update":
            guard let arguments = methodCall.arguments as? [String: Any] else { return }
            
            guard let visionRangeOptions = arguments["vision_range_options"] as? [String: Any] else {return}
            guard let adRangeOptions = arguments["ad_range_options"] as? [String: Any] else {return}
            guard let actionRangeOptions = arguments["action_range_options"] as? [String: Any] else {return}
            
            guard let geometryInDouble : [Double] = arguments["geometry"] as? [Double] else {return}
            let geometry : CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: geometryInDouble[0], longitude: geometryInDouble[1])
            
            guard let circlePrecision : Int = arguments["circle_precision"] as? Int else {return}
            
            
            let style = mapView.style;
            
            
            guard let currentSource = style?.source(withIdentifier: "neo_ranges_sources") as? MGLShapeSource else {return}
            
            let visionFeature = NeoCircleBuilder.createNeoCircleFeature(options: visionRangeOptions,geometry: geometry, circlePrecision: circlePrecision )
            let adFeature =  NeoCircleBuilder.createNeoCircleFeature(options: adRangeOptions, geometry: geometry, circlePrecision: circlePrecision )
            let actionFeature =  NeoCircleBuilder.createNeoCircleFeature(options: actionRangeOptions,geometry: geometry, circlePrecision: circlePrecision)
            
            var features = [MGLPolygonFeature]()
            features.append(visionFeature)
            features.append(adFeature)
            features.append(actionFeature)
            
            currentSource.shape = MGLShapeCollectionFeature.init(shapes: features)
            
            result(nil)
        // CUSTOM PART END
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func getSymbolForOptions(options: [String: Any]) -> MGLSymbolStyleAnnotation? {
        // Parse geometry
        if let geometry = options["geometry"] as? [Double] {
            // Convert geometry to coordinate and create symbol.
            let coordinate = CLLocationCoordinate2DMake(geometry[0], geometry[1])
            let symbol = MGLSymbolStyleAnnotation(coordinate: coordinate)
            Convert.interpretSymbolOptions(options: options, delegate: symbol)
            // Load icon image from asset if an icon name is supplied.
            if let iconImage = options["iconImage"] as? String {
                addIconImageToMap(iconImageName: iconImage)
            }
            return symbol
        }
        return nil
    }
    
    private func addIconImageToMap(iconImageName: String) {
        // Check if the image has already been added to the map.
        if self.mapView.style?.image(forName: iconImageName) == nil {
            // Build up the full path of the asset.
            // First find the last '/' ans split the image name in the asset directory and the image file name.
            if let range = iconImageName.range(of: "/", options: [.backwards]) {
                let directory = String(iconImageName[..<range.lowerBound])
                let assetPath = registrar.lookupKey(forAsset: "\(directory)/")
                let fileName = String(iconImageName[range.upperBound...])
                // If we can load the image from file then add it to the map.
                if let imageFromAsset = UIImage.loadFromFile(imagePath: assetPath, imageName: fileName) {
                    self.mapView.style?.setImage(imageFromAsset, forName: iconImageName)
                }
            }
        }
    }
    
    private func updateMyLocationEnabled() {
        mapView.showsUserLocation = self.myLocationEnabled
    }
    
    private func getCamera() -> MGLMapCamera? {
        return trackCameraPosition ? mapView.camera : nil
        
    }
    
    /*
     *  UITapGestureRecognizer
     *  On tap invoke the map#onMapClick callback.
     */
    @objc @IBAction func handleMapTap(sender: UITapGestureRecognizer) {
        // Get the CGPoint where the user tapped.
        let point = sender.location(in: mapView)
        let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
        channel?.invokeMethod("map#onMapClick", arguments: [
            "x": point.x,
            "y": point.y,
            "lng": coordinate.longitude,
            "lat": coordinate.latitude,
        ])
    }
    
    /*
     *  UILongPressGestureRecognizer
     *  After a long press invoke the map#onMapLongClick callback.
     */
    @objc @IBAction func handleMapLongPress(sender: UILongPressGestureRecognizer) {
        //Fire when the long press starts
        if (sender.state == .began) {
            // Get the CGPoint where the user tapped.
            let point = sender.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            channel?.invokeMethod("map#onMapLongClick", arguments: [
                "x": point.x,
                "y": point.y,
                "lng": coordinate.longitude,
                "lat": coordinate.latitude,
            ])
        }
        
    }
    
    
    
    /*
     *  MGLAnnotationControllerDelegate
     */
    func annotationController(_ annotationController: MGLAnnotationController, didSelect styleAnnotation: MGLStyleAnnotation) {
        guard let channel = channel else {
            return
        }
        
        if let symbol = styleAnnotation as? MGLSymbolStyleAnnotation {
            channel.invokeMethod("symbol#onTap", arguments: ["symbol" : "\(symbol.identifier)"])
        } else if let circle = styleAnnotation as? MGLCircleStyleAnnotation {
            channel.invokeMethod("circle#onTap", arguments: ["circle" : "\(circle.identifier)"])
        } else if let line = styleAnnotation as? MGLLineStyleAnnotation {
            channel.invokeMethod("line#onTap", arguments: ["line" : "\(line.identifier)"])
        }
    }
    
    // This is required in order to hide the default Maps SDK pin
    func mapView(_ mapView: MGLMapView, viewFor annotation: MGLAnnotation) -> MGLAnnotationView? {
        if annotation is MGLUserLocation {
            return nil
        }
        return MGLAnnotationView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    }
    
    /*
     *  MGLMapViewDelegate
     */
    func mapView(_ mapView: MGLMapView, didFinishLoading style: MGLStyle) {
        isMapReady = true
        updateMyLocationEnabled()
        
        if let initialTilt = initialTilt {
            let camera = mapView.camera
            camera.pitch = initialTilt
            mapView.setCamera(camera, animated: false)
        }
        
        // CUSTOM PART BEGIN
        // Create and add to the map a Source for NeoRanges with empty Features
        let neoRangesSource = MGLShapeSource(identifier: "neo_ranges_sources", features: [MGLPolygonFeature]())
        style.addSource(neoRangesSource)
        
        // Create and add to the map the NeoRanges FillLayer and LineLayer with some properties
        let neoRangesFillLayer = MGLFillStyleLayer.init(identifier: "neo_ranges_fill_layer", source: neoRangesSource);
        let neoRangesLineLayer = MGLLineStyleLayer.init(identifier: "neo_ranges_line_layer", source: neoRangesSource);
        
        neoRangesFillLayer.sourceLayerIdentifier = "neo_ranges_sources"
        
         let lineWidthStops = [
            0: NSExpression(forConstantValue: 0),
            22: NSExpression(forKeyPath: "border-width"),
        ]
        
       neoRangesLineLayer.lineWidth = NSExpression(format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.3, %@)", lineWidthStops)
       neoRangesLineLayer.lineColor = NSExpression(forKeyPath: "border-color")
       neoRangesLineLayer.lineOpacity = NSExpression(forKeyPath: "border-opacity")
                
        
        neoRangesFillLayer.fillColor = NSExpression(forKeyPath: "fill-color")
        neoRangesFillLayer.fillOpacity =  NSExpression(forKeyPath: "fill-opacity")
        
        style.addLayer(neoRangesFillLayer)
        style.addLayer(neoRangesLineLayer)
        // CUSTOM PART END
        
        
        lineAnnotationController = MGLLineAnnotationController(mapView: self.mapView)
        lineAnnotationController!.annotationsInteractionEnabled = true
        lineAnnotationController?.delegate = self
        
        symbolAnnotationController = MGLSymbolAnnotationController(mapView: self.mapView)
        symbolAnnotationController!.annotationsInteractionEnabled = true
        symbolAnnotationController?.delegate = self
        
        circleAnnotationController = MGLCircleAnnotationController(mapView: self.mapView)
        circleAnnotationController!.annotationsInteractionEnabled = true
        circleAnnotationController?.delegate = self
        
        // CUSTOM PART BEGIN
        // It make symbols scale with zoom when no iconSize specified and add a CircleLayer for NeoRanges
        
        // Get symbol layer
        let symbolLayer = symbolAnnotationController!.layer;
        
        // Icon scale stops
        let iconScaleStops = [
            0:0,
            20:2
        ]
        
        // Icon scale stops
        let textSizeStops = [
            0:0,
            15.5:0,
            15.6:10,
            20:15
        ]
        
        // Update iconScale value with an expression
        symbolLayer.setValue(NSExpression(format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.4, %@)", iconScaleStops), forKey: "iconScale")
        symbolLayer.setValue(NSExpression(format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.4, %@)", textSizeStops), forKey: "textFontSize")
        symbolLayer.setValue(NSExpression(forConstantValue: ["Averta Semibold"]), forKey: "textFontNames")
        // CUSTOM PART END
        
        mapReadyResult?(nil)
        if let channel = channel {
            channel.invokeMethod("map#onStyleLoaded", arguments: nil)
        }
    }
    
    func mapView(_ mapView: MGLMapView, shouldChangeFrom oldCamera: MGLMapCamera, to newCamera: MGLMapCamera) -> Bool {
        guard let bbox = cameraTargetBounds else { return true }
        
        // Get the current camera to restore it after.
        let currentCamera = mapView.camera
        
        // From the new camera obtain the center to test if it’s inside the boundaries.
        let newCameraCenter = newCamera.centerCoordinate
        
        // Set the map’s visible bounds to newCamera.
        mapView.camera = newCamera
        let newVisibleCoordinates = mapView.visibleCoordinateBounds
        
        // Revert the camera.
        mapView.camera = currentCamera
        
        // Test if the newCameraCenter and newVisibleCoordinates are inside bbox.
        let inside = MGLCoordinateInCoordinateBounds(newCameraCenter, bbox)
        let intersects = MGLCoordinateInCoordinateBounds(newVisibleCoordinates.ne, bbox) && MGLCoordinateInCoordinateBounds(newVisibleCoordinates.sw, bbox)
        
        return inside && intersects
    }
    
    func mapView(_ mapView: MGLMapView, imageFor annotation: MGLAnnotation) -> MGLAnnotationImage? {
        // Only for Symbols images should loaded.
        guard let symbol = annotation as? Symbol,
            let iconImageFullPath = symbol.iconImage else {
                return nil
        }
        // Reuse existing annotations for better performance.
        var annotationImage = mapView.dequeueReusableAnnotationImage(withIdentifier: iconImageFullPath)
        if annotationImage == nil {
            // Initialize the annotation image (from predefined assets symbol folder).
            if let range = iconImageFullPath.range(of: "/", options: [.backwards]) {
                let directory = String(iconImageFullPath[..<range.lowerBound])
                let assetPath = registrar.lookupKey(forAsset: "\(directory)/")
                let iconImageName = String(iconImageFullPath[range.upperBound...])
                let image = UIImage.loadFromFile(imagePath: assetPath, imageName: iconImageName)
                if let image = image {
                    annotationImage = MGLAnnotationImage(image: image, reuseIdentifier: iconImageFullPath)
                }
            }
        }
        return annotationImage
    }
    
    // On tap invoke the symbol#onTap callback.
    func mapView(_ mapView: MGLMapView, didSelect annotation: MGLAnnotation) {
        
        if let symbol = annotation as? Symbol {
            channel?.invokeMethod("symbol#onTap", arguments: ["symbol" : "\(symbol.id)"])
        }
    }
    
    // Allow callout view to appear when an annotation is tapped.
    func mapView(_ mapView: MGLMapView, annotationCanShowCallout annotation: MGLAnnotation) -> Bool {
        return true
    }
    
    func mapView(_ mapView: MGLMapView, didChange mode: MGLUserTrackingMode, animated: Bool) {
        if let channel = channel {
            channel.invokeMethod("map#onCameraTrackingChanged", arguments: ["mode": mode.rawValue])
            if mode == .none {
                channel.invokeMethod("map#onCameraTrackingDismissed", arguments: [])
            }
        }
    }
    
    func mapViewDidBecomeIdle(_ mapView: MGLMapView) {
        if let channel = channel {
            channel.invokeMethod("map#onIdle", arguments: []);
        }
    }
    
    func mapView(_ mapView: MGLMapView, regionWillChangeAnimated animated: Bool) {
        if let channel = channel {
            channel.invokeMethod("camera#onMoveStarted", arguments: []);
        }
    }
    
    func mapViewRegionIsChanging(_ mapView: MGLMapView) {
        if !trackCameraPosition { return };
        if let channel = channel {
            channel.invokeMethod("camera#onMove", arguments: [
                "position": getCamera()?.toDict(mapView: mapView)
            ]);
        }
    }
    
    func mapView(_ mapView: MGLMapView, regionDidChangeAnimated animated: Bool) {
        if let channel = channel {
            channel.invokeMethod("camera#onIdle", arguments: []);
        }
    }
    
    /*
     *  MapboxMapOptionsSink
     */
    func setCameraTargetBounds(bounds: MGLCoordinateBounds?) {
        cameraTargetBounds = bounds
    }
    func setCompassEnabled(compassEnabled: Bool) {
        mapView.compassView.isHidden = compassEnabled
        mapView.compassView.isHidden = !compassEnabled
    }
    func setMinMaxZoomPreference(min: Double, max: Double) {
        mapView.minimumZoomLevel = min
        mapView.maximumZoomLevel = max
    }
    func setStyleString(styleString: String) {
        // Check if json, url or plain string:
        if styleString.isEmpty {
            NSLog("setStyleString - string empty")
        } else if (styleString.hasPrefix("{") || styleString.hasPrefix("[")) {
            // Currently the iOS Mapbox SDK does not have a builder for json.
            NSLog("setStyleString - JSON style currently not supported")
        } else if (
            !styleString.hasPrefix("http://") && 
                !styleString.hasPrefix("https://") &&
                !styleString.hasPrefix("mapbox://")) {
            // We are assuming that the style will be loaded from an asset here.
            let assetPath = registrar.lookupKey(forAsset: styleString)
            mapView.styleURL = URL(string: assetPath, relativeTo: Bundle.main.resourceURL)
        } else {
            mapView.styleURL = URL(string: styleString)
        }
    }
    func setRotateGesturesEnabled(rotateGesturesEnabled: Bool) {
        mapView.allowsRotating = rotateGesturesEnabled
    }
    func setScrollGesturesEnabled(scrollGesturesEnabled: Bool) {
        mapView.allowsScrolling = scrollGesturesEnabled
    }
    func setTiltGesturesEnabled(tiltGesturesEnabled: Bool) {
        mapView.allowsTilting = tiltGesturesEnabled
    }
    func setTrackCameraPosition(trackCameraPosition: Bool) {
        self.trackCameraPosition = trackCameraPosition
    }
    func setZoomGesturesEnabled(zoomGesturesEnabled: Bool) {
        mapView.allowsZooming = zoomGesturesEnabled
    }
    func setMyLocationEnabled(myLocationEnabled: Bool) {
        if (self.myLocationEnabled == myLocationEnabled) {
            return
        }
        self.myLocationEnabled = myLocationEnabled
        updateMyLocationEnabled()
    }
    func setMyLocationTrackingMode(myLocationTrackingMode: MGLUserTrackingMode) {
        mapView.userTrackingMode = myLocationTrackingMode
    }
    func setMyLocationRenderMode(myLocationRenderMode: MyLocationRenderMode) {
        switch myLocationRenderMode {
        case .Normal:
            mapView.showsUserHeadingIndicator = false
        case .Compass:
            mapView.showsUserHeadingIndicator = true
        case .Gps:
            NSLog("RenderMode.GPS currently not supported")
        }
    }
    func setLogoViewMargins(x: Double, y: Double) {
        mapView.logoViewMargins = CGPoint(x: x, y: y)
    }
    func setCompassViewPosition(position: MGLOrnamentPosition) {
        mapView.compassViewPosition = position
    }
    func setCompassViewMargins(x: Double, y: Double) {
        mapView.compassViewMargins = CGPoint(x: x, y: y)
    }
    func setAttributionButtonMargins(x: Double, y: Double) {
        mapView.attributionButtonMargins = CGPoint(x: x, y: y)
    }
}
