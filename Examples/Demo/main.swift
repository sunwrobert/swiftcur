import DemoCLI
import Foundation

await makeDemoCLI(environment: ProcessInfo.processInfo.environment).serve()
