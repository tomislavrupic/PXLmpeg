import Foundation
let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
let object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
guard let dependencies=object["dependencies"] as? [Any],dependencies.isEmpty,
      let targets=object["targets"] as? [[String:Any]], !targets.contains(where:{$0["type"] as? String == "binary"}) else {
    fatalError("External package or binary dependency detected")
}
print("Manifest: zero external package dependencies and binary targets")
