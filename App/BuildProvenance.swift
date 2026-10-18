import Foundation

struct BuildProvenance:Codable {
    let commit:String
    let branch:String
    let run:String
    static var current:Self? {
        guard let url=Bundle.main.url(forResource:"BuildProvenance",withExtension:"json"),let data=try? Data(contentsOf:url) else { return nil }
        return try? JSONDecoder().decode(Self.self,from:data)
    }
}
