import Foundation
import CoreGraphics
import Vision
import Vapor

// RequestResponse
// https://github.com/obsproject/obs-websocket/blob/master/docs/generated/protocol.md#requestresponse-opcode-7
// {
//   "op": 7,
//   "d": {
//     "requestType": "SetCurrentProgramScene",
//     "requestId": "f819dcf0-89cc-11eb-8f0e-382c4ac93b9c",
//     "requestStatus": {
//       "result": true,
//       "code": 100
//     }
//   }
// }


struct OBSWebSocketMessage: Decodable {
    let op: Int
    let d: DataType

    enum OpCode: Int {
        case RequestResponse = 7
    }

    enum DataType {
        case requestResponse(RequestResponseData)
        case unknown
    }

    enum CodingKeys: String, CodingKey {
        case op
        case d
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        op = try container.decode(Int.self, forKey: .op)
        switch op {
        case OpCode.RequestResponse.rawValue:
            d = .requestResponse(try container.decode(RequestResponseData.self, forKey: .d))
        default:
            d = .unknown
        }
    }
}

// OpCode 7
struct RequestResponseData: Codable {
    let requestType: String
    let requestId: String // Int?
    // let requestStatus: RequestStatus
    let responseData: Optional<Dictionary<String, String>>
}


func routes(_ app: Application) throws {
    app.webSocket { req, client in
        // maxFrameSize defaults to 1<<14, which seems to be too small for OBS WebSocket message,
        // especially for GetSourceScreenshot response.
        // > [obs-websocket] [WebSocketServer::onClose] WebSocket client `[::1]:51344` has disconnected with code `1006` and reason: Underlying Transport
        let config = WebSocketClient.Configuration.init(tlsConfiguration: nil, maxFrameSize: Int(UInt32.max))
        _ = WebSocket.connect(to: "ws://localhost:4455", configuration: config, on: req.eventLoop) { upstream in
            client.onText { ws, text in
                app.logger.debug("--> \(text)")
                upstream.send(text)
            }
            upstream.onText { ws, text in
                // app.logger.debug("<-- \(text)")
                client.send(text)

                // GenericMessageとしてデコード
                do {
                    let message = try JSONDecoder().decode(OBSWebSocketMessage.self, from: Data(text.utf8))
                    if case let .requestResponse(data) = message.d {
                        if data.requestType == "GetSourceScreenshot" {
                            if let imageData = data.responseData?["imageData"] as? String {
                                let base64Data = Data(base64Encoded: String(imageData.dropFirst("data:image/png;base64,".count)))
                                if let dataProvider = CGDataProvider(data: base64Data! as CFData) {
                                    if let cgImage = CGImage(pngDataProviderSource: dataProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                                        app.logger.debug("CGImage: \(cgImage)")

                                        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                                        let request = VNRecognizeTextRequest { (request, error) in
                                            let observations = request.results as? [VNRecognizedTextObservation] ?? []

                                            for observation in observations {
                                                if let topCandidate = observation.topCandidates(1).first {
                                                    app.logger.info("Recognized text: \(topCandidate.string)")
                                                    app.logger.info("  at \(observation.boundingBox)")
                                                }
                                            }
                                        }

                                        request.recognitionLevel = .accurate
                                        request.automaticallyDetectsLanguage = true

                                        do {
                                            try requestHandler.perform([request])
                                        } catch {
                                            app.logger.error("Failed to perform text recognition: \(error)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    app.logger.error("Error: \(error)")
                }
            }
            
            client.onClose.whenComplete { _ in
                app.logger.info("Client closed")
                _ = upstream.close()
            }
            upstream.onClose.whenComplete { result in
                app.logger.info("Upstream closed \(result)")
                _ = client.close()
            }
        }
    }
}
