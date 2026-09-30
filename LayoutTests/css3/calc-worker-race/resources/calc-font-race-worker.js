// Sets calc() fonts that mix a length and a percentage on a worker OffscreenCanvas as fast as it can. Before the
// fix each one built a Style::PrimitiveData on this thread, inserting into (and then removing from) the process-wide,
// unlocked ValueHandleMap that the main thread's style resolution uses at the same time.
onmessage = e => {
    const ctx = new OffscreenCanvas(10, 10).getContext("2d");
    const deadline = Date.now() + e.data.ms;
    let n = 0;
    while (Date.now() < deadline) {
        for (let i = 0; i < 64; ++i) {
            ctx.font = `calc(${50 + (n & 63)}% + ${1 + (i & 7)}px) serif`;
            ++n;
        }
    }
    postMessage(n);
};
