import AppKit

// One binary, two roles: `peek file.png` (CLI, exits right away) and the
// background app that draws the cards (`--app`, started by launchd).
let args = Array(CommandLine.arguments.dropFirst())
let launchedByLaunchServices = args.isEmpty && getppid() == 1
if args.first == "--ssh-askpass" {
    exit(SSHAskpass.run(args.dropFirst().joined(separator: " ")))
} else if args.first == "--app" || args.contains(where: { $0.hasPrefix("-psn_") }) || launchedByLaunchServices {
    App.run()
} else {
    exit(CLI.main(args))
}
