import Vapor
import Logging
import NIOCore
import NIOPosix

struct UpstreamURLKey: StorageKey {
    typealias Value = String
}

extension Application {
    var upstreamURL: String {
        get {
            return self.storage[UpstreamURLKey.self]  ?? "ws://localhost:4455"
        }
        set {
            self.storage[UpstreamURLKey.self] = newValue
        }
    }
}

struct CustomServeCommand: AsyncCommand {
    var help: String {
        return "Starts obs-websocket-ocr proxy server."
    }

    let serveCommand: ServeCommand

    init(_ serveCommand: ServeCommand) {
        self.serveCommand = serveCommand
    }

    struct Signature: CommandSignature {
        @Option(name: "hostname", short: "H", help: "Set the hostname the server will run on.")
        var hostname: String?
        
        @Option(name: "port", short: "p", help: "Set the port the server will run on.")
        var port: Int?

        @Option(name: "upstream-url", short: "u", help: "The URL of the upstream server.")
        var upstreamURL: String?
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        if let upstreamURL = signature.upstreamURL {
            context.application.upstreamURL = upstreamURL
        }
        context.application.logger.info("Upstream URL: \(context.application.upstreamURL)")

        let arguments = [
            context.input.executable,
            "--hostname", signature.hostname ?? "localhost",
            "--port", String(signature.port ?? 4456)
        ]
        var serveCommandContext = CommandContext(console: context.console, input: CommandInput(arguments: arguments))
        serveCommandContext.application = context.application
        try await serveCommand.run(using: &serveCommandContext)
    }
}

@main
enum Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        
        let app = try await Application.make(env)
        let customServeCommand = CustomServeCommand(await app.servers.asyncCommand)

        // This attempts to install NIO as the Swift Concurrency global executor.
        // You should not call any async functions before this point.
        let executorTakeoverSuccess = NIOSingletons.unsafeTryInstallSingletonPosixEventLoopGroupAsConcurrencyGlobalExecutor()
        app.logger.debug("Running with \(executorTakeoverSuccess ? "SwiftNIO" : "standard") Swift Concurrency default executor")
        
        do {
            try await configure(app)
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }

        do {
            var context = CommandContext(console: app.console, input: app.environment.commandInput)
            context.application = app
            try await app.asyncBoot()
            try await app.console.run(customServeCommand, with: context)
            try await app.running?.onStop.get()
        } catch {
            app.logger.report(error: error)
            throw error
        }

        try await app.asyncShutdown()
    }
}
