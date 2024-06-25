# OBS WebSocket OCR Proxy for macOS

A proxy for obs-websocket that adds Optical Character Recognition (OCR) capabilities.

Utilizes macOS’s [Vision framework](https://developer.apple.com/documentation/vision) to perform OCR on captured screenshots.

Currently, it introduces one special request type: `__GetTextFromLastScreenshot`. See below for details.

## Usage

    obs-websocket-ocr [--upstream-url URL] [--port PORT] [--hostname HOSTNAME]

- `--upstream-url URL`: The URL of the upstream obs-websocket server. Default: `ws://localhost:4455`.
- `--port PORT`: The port to bind to. Default: `4456`.
- `--hostname HOSTNAME`: The hostname to bind to. Default: `localhost`.

When started, the proxy will listen on `localhost:4456` and forward all messages to the upstream obs-websocket server.
You can connect to the proxy using the obs-websocket client as you would with a normal obs-websocket server.

## Request types

In addition to the [standard obs-websocket request types](https://github.com/obsproject/obs-websocket/blob/master/docs/generated/protocol.md#getversion), the proxy adds one special request type: `__GetTextFromLastScreenshot`.

### \_\_GetTextFromLastScreenshot

Does OCR on the last screenshot taken by OBS and returns the recognized text items and the bounding boxes of them.

#### Response fields:

| Name           | Type                | Description                |
| -------------- | ------------------- | -------------------------- |
| `text_results` | `Array<TextResult>` | The recognized text items. |

TextResult:

| Name           | Type                 | Description                   |
| -------------- | -------------------- | ----------------------------- |
| `text`         | `string`             | The recognized text.          |
| `bounding_box` | `Array<BoundingBox>` | The bounding box of the text. |

BoundingBox:

| Name     | Type     | Description                              |
| -------- | -------- | ---------------------------------------- |
| `x`      | `number` | The x-coordinate of the top-left corner. |
| `y`      | `number` | The y-coordinate of the top-left corner. |
| `width`  | `number` | The width of the bounding box.           |
| `height` | `number` | The height of the bounding box.          |

## Author

Hironao Otsubo (motemen)
