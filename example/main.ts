import OBSWebSocket from "obs-websocket-js";
import groupBy from "object.groupby";

interface __GetTextFromLastScreenshotResponse {
  text_results: {
    text: string;
    bounding_box: {
      x: number;
      y: number;
      width: number;
      height: number;
    };
  }[];
}

async function main() {
  const obs = new OBSWebSocket();
  await obs.connect("ws://localhost:4456", process.env.OBS_WEBSOCKET_PASSWORD);

  // 1秒ごとにスクリーンショットを撮って、OCRする
  while (true) {
    await obs.call("GetSourceScreenshot", {
      sourceName: "video",
      imageFormat: "png",
    });
    const response: __GetTextFromLastScreenshotResponse = await obs.call(
      "__GetTextFromLastScreenshot" as any
    );

    const texts = response.text_results
      .map(({ text, bounding_box: { x, y, width, height } }) => ({
        lineNumber: Math.floor((0.22 - y) / 0.06),
        left: x,
        right: x + width,
        height,
        text,
      }))
      .filter(
        ({ lineNumber, left, right, height }) =>
          lineNumber >= 0 && 0.14 <= left && right <= 0.8 && height >= 0.025
      )
      .sort((a, b) => a.lineNumber - b.lineNumber || a.left - b.left);

    const lines = groupBy(texts, ({ lineNumber }) => lineNumber);

    Object.keys(lines)
      .sort()
      .forEach((lineNumber) => {
        const line = lines[lineNumber];
        console.log(line.map(({ text }) => text).join(""));
      });
    console.log("-----");

    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
}

main();
