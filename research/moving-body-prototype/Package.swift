// swift-tools-version: 6.0
import PackageDescription
let package=Package(name:"MovingBodyPrototype",platforms:[.macOS(.v13)],dependencies:[.package(path:"../..")],targets:[
    .target(name:"MovingBodyMath",dependencies:[.product(name:"HeadLinkCore",package:"HeadLink")]),
    .testTarget(name:"MovingBodyMathTests",dependencies:["MovingBodyMath"])
])
