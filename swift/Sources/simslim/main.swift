import Foundation
import SimSlimCLI

// Output goes through unbuffered writes so progress and results interleave
// correctly when stdout and stderr are the same pipe.
func write(_ handle: FileHandle) -> CLI.Sink {
  { text in handle.write(Data(text.utf8)) }
}

let cli = CLI(stdout: write(.standardOutput), stderr: write(.standardError))
exit(cli.run(Array(CommandLine.arguments.dropFirst())))
