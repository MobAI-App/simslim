import Foundation
import SimSlimKit

// M0 scaffold: only --version works. Commands arrive with the later milestones.
let arguments = Array(CommandLine.arguments.dropFirst())

if arguments == ["--version"] || arguments == ["version"] {
  print("simslim \(simslimVersion)")
  exit(0)
}

FileHandle.standardError.write(Data("simslim: the Swift port is not feature-complete yet\n".utf8))
exit(2)
