import Foundation
import Network

/// Lets Murmur's API calls skip a VPN when `bypassVPN` is on in config.json.
///
/// Some APIs (Groq) refuse connections from VPN addresses. With the bypass on, while a VPN is active,
/// Murmur sends its own requests straight out of the Wi-Fi/Ethernet interface. Everything else on the
/// Mac stays in the VPN. URLSession can't pin a request to an interface, so these requests go through
/// /usr/bin/curl with --interface. Secrets travel in environment variables and the body on stdin, never
/// in the command line.
enum DirectRoute {
    private static let monitor = NWPathMonitor()
    private static let physicalMonitor = NWPathMonitor(prohibitedInterfaceTypes: [.other])
    private static let lock = NSLock()
    private static var vpnActive = false
    private static var physicalInterface: String?

    /// Starts watching the network. Call once at launch.
    static func start() {
        monitor.pathUpdateHandler = { path in
            // VPN tunnels show up as interface type "other" (utun).
            lock.withLock { vpnActive = path.status == .satisfied && path.usesInterfaceType(.other) }
        }
        physicalMonitor.pathUpdateHandler = { path in
            let name = path.availableInterfaces.first { $0.type == .wifi || $0.type == .wiredEthernet }?.name
            lock.withLock { physicalInterface = name }
        }
        monitor.start(queue: .global(qos: .utility))
        physicalMonitor.start(queue: .global(qos: .utility))
    }

    /// The interface to bind to, if the request should bypass the VPN right now.
    static func bypassInterface(enabled: Bool) -> String? {
        guard enabled else { return nil }
        return lock.withLock { vpnActive ? physicalInterface : nil }
    }

    /// Performs `request` (with `body`) through curl bound to `interface`.
    static func send(_ request: URLRequest, body: Data, interface: String) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw MurmurError("Missing URL") }
        let marker = "\n__murmur_status__"
        var args = ["-sS", "--max-time", String(Int(request.timeoutInterval.rounded(.up))),
                    "--interface", interface, "-X", request.httpMethod ?? "POST",
                    "--data-binary", "@-",
                    "-w", marker + "%{http_code} %header{retry-after}|%header{x-ratelimit-reset-tokens}"]
        var env = ["PATH": "/usr/bin:/bin"]
        for (i, (name, value)) in (request.allHTTPHeaderFields ?? [:]).enumerated() {
            env["MURMUR_H\(i)"] = "\(name): \(value)"
            args += ["--variable", "%MURMUR_H\(i)", "--expand-header", "{{MURMUR_H\(i)}}"]
        }
        args.append(url.absoluteString)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = args
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let (output, errors): (Data, Data) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    stdin.fileHandleForWriting.write(body)
                    try? stdin.fileHandleForWriting.close()
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    // End of file on both pipes means curl is done. Don't use Process.waitUntilExit(): in an app,
                    // for a process started from a Swift concurrency thread, it can wait forever.
                    let out = stdout.fileHandleForReading.readDataToEndOfFile()
                    let err = stderr.fileHandleForReading.readDataToEndOfFile()
                    cont.resume(returning: (out, err))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        // curl prints the status trailer even when the request fails (as 000), so it tells us how it went.
        guard let range = output.range(of: Data(marker.utf8), options: .backwards) else {
            let message = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MurmurError("Direct connection failed: \(message.isEmpty ? "no response" : message)")
        }
        let body = output[..<range.lowerBound]
        let trailer = String(decoding: output[range.upperBound...], as: UTF8.self)
        let parts = trailer.split(separator: " ", maxSplits: 1).map(String.init)
        let status = Int(parts.first ?? "") ?? 0
        guard status > 0 else {
            let message = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MurmurError("Direct connection failed: \(message.isEmpty ? "no response" : message)")
        }
        var headers: [String: String] = [:]
        let limits = (parts.count > 1 ? parts[1] : "").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if let retry = limits.first, !retry.isEmpty { headers["retry-after"] = retry }
        if limits.count > 1, !limits[1].isEmpty { headers["x-ratelimit-reset-tokens"] = limits[1] }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            throw MurmurError("Direct connection: bad status")
        }
        return (Data(body), response)
    }
}
