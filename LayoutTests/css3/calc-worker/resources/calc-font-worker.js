// Sets calc() fonts on a worker OffscreenCanvas, which resolves them through Style::resolveForUnresolvedFont
// on the worker thread, and compares measureText against the px font each should resolve to (default parent 10px).
onmessage = () => {
    const ctx = new OffscreenCanvas(100, 100).getContext("2d");
    const cases = [
        ["calc(50% + 2px) serif", "7px serif"],
        ["calc(100% + 4px) serif", "14px serif"],
        ["bold calc(200% - 5px) sans-serif", "bold 15px sans-serif"],
        ["calc(min(150%, 30px) + 1px) monospace", "16px monospace"],
    ];
    const results = [];
    for (let round = 0; round < 200; ++round) {
        for (const [calcFont, pxFont] of cases) {
            ctx.font = pxFont;
            const expected = ctx.measureText("Hello, calc()").width;
            ctx.font = calcFont;
            const actual = ctx.measureText("Hello, calc()").width;
            if (round === 0)
                results.push({ calcFont, pxFont, expected, actual, font: ctx.font });
        }
    }
    postMessage(results);
};
