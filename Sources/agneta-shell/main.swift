// GOOSE_SHELL for engines that Agneta runs: `agneta-shell -c <command>`.
// Forwards the command to Agneta's tool broker, which runs it under the
// session's strict sandbox, and relays output and exit status. No logic of
// its own, so it works inside the engine's sandbox with nothing but its socket.
import Darwin
import Foundation

func fail(_ message: String, _ status: Int32) -> Never {
    FileHandle.standardError.write(Data("agneta-shell: \(message)\n".utf8))
    exit(status)
}

let args = CommandLine.arguments
guard args.count >= 3, args[1] == "-c" else { fail("usage: agneta-shell -c <command>", 2) }
let env = ProcessInfo.processInfo.environment
guard let path = env["AGNETA_BROKER_SOCKET"], let token = env["AGNETA_BROKER_TOKEN"] else { fail("no broker configured", 126) }

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let bytes = Array(path.utf8)
withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
guard connected == 0 else { fail("can't reach Agneta (\(String(cString: strerror(errno))))", 126) }
var noSigPipe: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

let request = try JSONSerialization.data(withJSONObject: ["token": token, "cwd": FileManager.default.currentDirectoryPath, "command": args[2]]) + Data("\n".utf8)
_ = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

var buffer = Data()
var chunk = [UInt8](repeating: 0, count: 65536)
while true {
    let count = read(fd, &chunk, chunk.count)
    if count <= 0 { fail("Agneta closed the command", 125) }
    buffer.append(contentsOf: chunk[0..<count])
    while let newline = buffer.firstIndex(of: 0x0A) {
        let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex...newline)
        let payload = String(line.dropFirst(2))
        switch line.first {
        case "o": if let data = Data(base64Encoded: payload) { FileHandle.standardOutput.write(data) }
        case "e": if let data = Data(base64Encoded: payload) { FileHandle.standardError.write(data) }
        case "x": exit(Int32(payload) ?? 1)
        default: break
        }
    }
}
