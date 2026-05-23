import Foundation

@main
enum AppMain {
    static func main() async {
        let arguments = CommandLine.arguments
        if let harnessIndex = arguments.firstIndex(of: "--harness") {
            #if os(macOS)
            let harnessArguments = Array(arguments.dropFirst(harnessIndex + 1))
            let exitCode = await BitchatHarnessMain.run(arguments: harnessArguments)
            Foundation.exit(Int32(exitCode))
            #else
            print("{\"message\":\"BitChat harness mode is only available on macOS\",\"type\":\"error\"}")
            Foundation.exit(2)
            #endif
        }

        BitchatApp.main()
    }
}
