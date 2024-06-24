import Foundation
import CoreGraphics
import Vision
import Vapor
import struct os.OSAllocatedUnfairLock

func decodeMessagePayload(expectedOpCode: Int, expectedRequestType: String, data: Data, logger: Logger) -> (Any, [String: Any])? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        logger.warning("Failed to parse JSON as dictionary: \(data)")
        return nil
    }

    guard let opCode = obj["op"] as? Int else {
        logger.warning("Failed to get opCode: \(obj)")
        return nil
    }

    if opCode != expectedOpCode {
        return nil
    }

    guard let payload = obj["d"] as? [String: Any] else {
        logger.warning("Failed to get payload: \(obj)")
        return nil
    }

    if payload["requestType"] as? String != expectedRequestType {
        return nil
    }

    guard let requestId = payload["requestId"] else {
        logger.warning("Failed to get requestId: \(payload)")
        return nil
    }

    return (requestId, payload)
}

func decodeGetSourceScreenshotResponseImageData(data: Data, logger: Logger) -> String? {
    guard let (_, payload) = decodeMessagePayload(expectedOpCode: 7, expectedRequestType: "GetSourceScreenshot", data: data, logger: logger) else {
        return nil
    }

    if let imageData = (payload["responseData"] as? [String: Any])?["imageData"] as? String {
        return imageData
    } else {
        logger.warning("Failed to get imageData: \(payload)")
        return .none
    }
}

// Overview:
// - Proxy WebSocket messages between client and upstream server
// - On GetSourceScreenshot response, save latest image data
// - On __GetTextFromLastScreenshot request, which is this proxy's custom request, recognize text from the latest image data
func runOBSWebSocketProxySession(client: WebSocket, upstreamURL: String, on eventLoopGroup: EventLoopGroup, logger: Logger) {
    // maxFrameSize defaults to 1<<14, which seems to be too small for OBS WebSocket message,
    // especially for GetSourceScreenshot response.
    // > [obs-websocket] [WebSocketServer::onClose] WebSocket client `[::1]:51344` has disconnected with code `1006` and reason: Underlying Transport Error
    let config = WebSocketClient.Configuration.init(tlsConfiguration: nil, maxFrameSize: Int(UInt32.max))
    _ = WebSocket.connect(to: upstreamURL, configuration: config, on: eventLoopGroup) { upstream in
        let latestImageData = OSAllocatedUnfairLock(initialState: Optional<String>.none)

        client.onText { ws, text in
            logger.debug("--> \(text)")

            if let (requestId, _) = decodeMessagePayload(expectedOpCode: 6, expectedRequestType: "__GetTextFromLastScreenshot", data: Data(text.utf8), logger: logger) {
                latestImageData.withLock { state in
                    var responseData = [:]
                    defer {
                        let responseJSON = [
                            "op": 7,
                            "d": [
                                "requestType": "__GetTextFromLastScreenshot",
                                "requestId": requestId,
                                "requestStatus": ["result": true, "code": 100],
                                "responseData": responseData as Any
                            ]
                        ] as [String: Any]
                        client.send(try! JSONSerialization.data(withJSONObject: responseJSON))
                    }

                    guard let imageData = state else {
                        logger.warning("No image data")
                        return
                    }

                    let base64Data = Data(base64Encoded: String(imageData.dropFirst("data:image/png;base64,".count)))
                    guard let dataProvider = CGDataProvider(data: base64Data! as CFData) else {
                        logger.warning("Failed to create CGDataProvider")
                        return
                    }

                    guard let cgImage = CGImage(pngDataProviderSource: dataProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                        logger.warning("Failed to create CGImage")
                        return
                    }

                    var textResults = []

                    let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    let request = VNRecognizeTextRequest { (request, error) in
                        let observations = request.results as? [VNRecognizedTextObservation] ?? []

                        for observation in observations {
                            if let topCandidate = observation.topCandidates(1).first {
                                logger.info("Recognized text: \(topCandidate.string)")
                                logger.info("  at \(observation.boundingBox)")
                                textResults.append([
                                    "text": topCandidate.string,
                                    "bounding_box": [
                                        "x": observation.boundingBox.origin.x,
                                        "y": observation.boundingBox.origin.y,
                                        "width": observation.boundingBox.width,
                                        "height": observation.boundingBox.height,
                                    ]
                                ])
                            }
                        }

                        responseData = ["text_results": textResults]
                    }

                    request.recognitionLevel = .accurate
                    request.automaticallyDetectsLanguage = true

                    do {
                        try requestHandler.perform([request])
                    } catch {
                        logger.error("Failed to perform text recognition: \(error)")
                    }
                }
            } else {
                upstream.send(text)
            }
        }

        upstream.onText { ws, text in
            // logger.debug("<-- \(text)")
            client.send(text)

            if let imageData = decodeGetSourceScreenshotResponseImageData(data: Data(text.utf8), logger: logger) {
                latestImageData.withLock { state in
                    state = imageData
                }
            }
        }
        
        client.onClose.whenComplete { result in
            switch result {
            case .success:
                logger.info("Client closed")
            case .failure(let error):
                logger.error("Client closed with error: \(error)")
            }
            _ = upstream.close()
        }
        upstream.onClose.whenComplete { result in
            switch result {
            case .success:
                logger.info("Upstream closed")
            case .failure(let error):
                logger.error("Upstream closed with error: \(error)")
            }
            _ = client.close()
        }
    }
}

func routes(_ app: Application) throws {
    app.webSocket { req, client in
        runOBSWebSocketProxySession(client: client, upstreamURL: "ws://localhost:4455", on: req.eventLoop, logger: app.logger)
    }
}
