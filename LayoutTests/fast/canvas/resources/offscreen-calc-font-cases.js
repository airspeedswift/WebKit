// calc() fonts that mix a percentage with a length, and the px font each should resolve to (default parent size 10px).
const calcFontCases = [
    ["calc(50% + 2px) serif", "7px serif"],
    ["calc(100% + 4px) serif", "14px serif"],
    ["bold calc(200% - 5px) sans-serif", "bold 15px sans-serif"],
    ["calc(min(150%, 30px) + 1px) monospace", "16px monospace"],
    ["calc(max(50%, 12px) - 1px) serif", "11px serif"],
    ["clamp(8px, 150% + 1px, 13px) serif", "13px serif"],
    ["calc(10% * 3 + 3px) serif", "6px serif"],
    ["calc(200% - 25px) serif", "0px serif"],
];

function measureCalcFontCases(ctx)
{
    return calcFontCases.map(([calcFont, pxFont]) => {
        ctx.font = pxFont;
        const expected = ctx.measureText("Hello, calc()").width;
        ctx.font = calcFont;
        const actual = ctx.measureText("Hello, calc()").width;
        return { calcFont, pxFont, expected, actual, font: ctx.font };
    });
}
