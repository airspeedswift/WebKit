// Sets calc() fonts on a worker OffscreenCanvas, which resolves them through Style::resolveForUnresolvedFont
// on the worker thread, and compares measureText against the px font each should resolve to (default parent 10px).
onmessage = () => {
    const ctx = new OffscreenCanvas(100, 100).getContext("2d");
    const cases = [
        ["calc(50% + 2px) serif", "7px serif"],
        ["calc(100% + 4px) serif", "14px serif"],
        ["bold calc(200% - 5px) sans-serif", "bold 15px sans-serif"],
        ["calc(min(150%, 30px) + 1px) monospace", "16px monospace"],
        ["calc(max(50%, 12px) - 1px) serif", "11px serif"],
        ["clamp(8px, 150% + 1px, 13px) serif", "13px serif"],
        ["calc(10% * 3 + 3px) serif", "6px serif"],
        ["calc(200% - 25px) serif", "0px serif"],
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
