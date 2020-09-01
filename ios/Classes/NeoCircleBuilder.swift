import Mapbox
import MapboxAnnotationExtension


class NeoCircleBuilder {
    
    static func createNeoCircleFeature (options: [String: Any], radius: Double) -> MGLPointFeature {
        
         let newFeature = MGLPointFeature()
        
        let geometry = options["geometry"] as! [Double]
        let lat = geometry[0]
        let lon = geometry[1]
        let circleColor = options["circleColor"] as! String
    
        newFeature.coordinate = CLLocationCoordinate2DMake(lat, lon)
        
        newFeature.attributes = [
            "radius": radius * 18,
            "circle-color": circleColor
        ]
        
   
                
        return newFeature
    }
    
}
