// Runs one of the fake servers in AgnetaFakes until it is stopped, for tests outside Swift (Project Chat's
// smoke test). Development only.
//   agneta-fakes model <port> <log file>
//   agneta-fakes mcp <port> <bearer> <log file>
import AgnetaFakes
import Foundation

let arguments = CommandLine.arguments.dropFirst()
let usage = "usage: agneta-fakes model <port> <log file> | mcp <port> <bearer> <log file>"
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let server: FakeServer
switch (arguments.first, arguments.count) {
case ("model", 3):
    guard let port = Int(arguments[arguments.startIndex + 1]) else { fail(usage) }
    server = try await FakeServer.model(port: port, log: URL(filePath: arguments[arguments.startIndex + 2]))
case ("mcp", 4):
    guard let port = Int(arguments[arguments.startIndex + 1]) else { fail(usage) }
    server = try await FakeServer.mcp(port: port, bearer: arguments[arguments.startIndex + 2], log: URL(filePath: arguments[arguments.startIndex + 3]))
default:
    fail(usage)
}
print("listening on 127.0.0.1:\(arguments[arguments.startIndex + 1])")
fflush(stdout)
signal(SIGTERM, SIG_IGN)
let stop = DispatchSource.makeSignalSource(signal: SIGTERM)
stop.setEventHandler { server.stop(); exit(0) }
stop.resume()
while true { try await Task.sleep(for: .seconds(3600)) }
