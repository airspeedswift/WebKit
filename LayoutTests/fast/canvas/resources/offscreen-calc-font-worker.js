importScripts("offscreen-calc-font-cases.js");

onmessage = () => {
    postMessage(measureCalcFontCases(new OffscreenCanvas(100, 100).getContext("2d")));
};
