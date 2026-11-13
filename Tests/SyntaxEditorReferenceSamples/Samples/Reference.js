const state = {
    enabled: true,
    count: 2,
};

export async function renderLabel(item = state) {
    const suffix = item.enabled ? "ready" : "waiting";
    await Promise.resolve();
    return `Item ${item.count}: ${suffix}`;
}

class ReferenceController extends HTMLElement {
    connectedCallback() {
        this.dataset.state = state.enabled ? "ready" : "idle";
    }
}

customElements.define("reference-controller", ReferenceController);
console.log(await renderLabel(state));
