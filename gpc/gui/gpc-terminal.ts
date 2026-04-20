import {LitElement, html, css} from 'lit';
import {customElement, property, state} from 'lit/decorators.js';
import 'cde/toolbar';

@customElement('gpc-terminal')
export class GpcTerminal extends LitElement {

  @property({type: Boolean, attribute: 'break-on-input'}) breakOnInput: boolean = false;

  @state() private _copyFlash: boolean = false;

  private _outputEl: HTMLDivElement | null = null;
  private _inputEl: HTMLInputElement | null = null;
  private _copyFlashTimer: ReturnType<typeof setTimeout> | null = null;

  // --- Public API (called by host) ---

  appendText(text: string): void {
    if (!this._outputEl) return;
    this._outputEl.textContent += text;
    this._outputEl.scrollTop = this._outputEl.scrollHeight;
  }

  clear(): void {
    if (this._outputEl) this._outputEl.textContent = '';
  }

  activateInput(): void {
    if (!this._inputEl) return;
    this._inputEl.disabled = false;
    this._inputEl.placeholder = 'Type input and press Enter';
    this._inputEl.style.borderColor = '#0f0';
    this._inputEl.style.backgroundColor = '#001a00';
    this._inputEl.focus();
  }

  resetInput(): void {
    if (!this._inputEl) return;
    this._inputEl.value = '';
    this._inputEl.disabled = true;
    this._inputEl.placeholder = '(waiting for program input...)';
    this._inputEl.style.borderColor = '#444';
    this._inputEl.style.backgroundColor = '#111';
  }

  // --- Internal ---

  private _onKeyDown(e: KeyboardEvent): void {
    if (e.key !== 'Enter') return;
    const input = e.target as HTMLInputElement;
    const text = input.value;
    input.value = '';
    input.disabled = true;
    input.placeholder = '(waiting for program input...)';
    input.style.borderColor = '#444';
    input.style.backgroundColor = '#111';

    // Echo to output
    this.appendText(text + '\n');

    // Notify host
    this.dispatchEvent(new CustomEvent('terminal-input', {
      detail: { text },
      bubbles: true,
      composed: true,
    }));
  }

  private _onClear(): void {
    this.clear();
  }

  private async _onCopy(): Promise<void> {
    const text = this._outputEl?.textContent ?? '';
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand('copy'); } finally { document.body.removeChild(ta); }
    }
    this._copyFlash = true;
    if (this._copyFlashTimer) clearTimeout(this._copyFlashTimer);
    this._copyFlashTimer = setTimeout(() => { this._copyFlash = false; }, 900);
  }

  private _onBreakToggle(e: Event): void {
    this.breakOnInput = (e.target as HTMLInputElement).checked;
    this.dispatchEvent(new CustomEvent('break-on-input-changed', {
      detail: { value: this.breakOnInput },
      bubbles: true,
      composed: true,
    }));
  }

  firstUpdated(): void {
    this._outputEl = this.shadowRoot!.getElementById('output') as HTMLDivElement;
    this._inputEl = this.shadowRoot!.getElementById('input') as HTMLInputElement;
  }

  render() {
    return html`
      <sim-toolbar label="TERMINAL" label-color="#aa0">
        <button class="sm" @click="${this._onClear}" title="Clear terminal output">CLR</button>
        <label id="break-label" slot="status" title="When checked, stop after input instead of auto-resuming run">
          <input type="checkbox" .checked="${this.breakOnInput}" @change="${this._onBreakToggle}" />
          <span>BREAK on INPUT</span>
        </label>
        <button
          slot="status"
          class="sm icon ${this._copyFlash ? 'ok' : ''}"
          @click="${this._onCopy}"
          title="${this._copyFlash ? 'Copied!' : 'Copy terminal output to clipboard'}"
          aria-label="Copy terminal output">
          ${this._copyFlash
            ? html`<svg viewBox="0 0 24 24" width="12" height="12" fill="none"
                     stroke="currentColor" stroke-width="2.5"
                     stroke-linecap="round" stroke-linejoin="round"
                     aria-hidden="true">
                     <polyline points="20 6 9 17 4 12"></polyline>
                   </svg>`
            : html`<svg viewBox="0 0 24 24" width="12" height="12" fill="none"
                     stroke="currentColor" stroke-width="2"
                     stroke-linecap="round" stroke-linejoin="round"
                     aria-hidden="true">
                     <rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>
                     <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>
                   </svg>`}
        </button>
      </sim-toolbar>
      <div id="output"></div>
      <input id="input" type="text"
        placeholder="(waiting for program input...)"
        disabled
        @keydown="${this._onKeyDown}" />
    `;
  }

  static styles = css`
    :host {
      display: flex;
      flex-direction: column;
      overflow: hidden;
      padding: 4px 8px;
      background-color: #0a0a0a;
      font-family: 'Consolas for Powerline', Consolas, monospace;
    }

    #break-label {
      font-size: 9px;
      color: #888;
      cursor: pointer;
      user-select: none;
      display: flex;
      align-items: center;
      gap: 3px;
    }

    #break-label input {
      margin: 0;
      cursor: pointer;
    }

    button.icon {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      padding: 2px 4px;
      line-height: 0;
    }

    button.icon svg {
      display: block;
    }

    button.icon.ok {
      color: #0f0;
      border-color: #0a0;
    }

    #output {
      flex: 1;
      overflow: auto;
      font-size: 12px;
      line-height: 1.4;
      color: #0f0;
      background-color: #000;
      padding: 4px;
      white-space: pre-wrap;
      word-wrap: break-word;
      border: 1px solid #333;
    }

    #input {
      width: 100%;
      padding: 3px 4px;
      background-color: #111;
      color: #0f0;
      border: 1px solid #444;
      font-size: 12px;
      font-family: 'Consolas for Powerline', Consolas, monospace;
      margin-top: 2px;
      outline: none;
      box-sizing: border-box;
    }
  `;
}

declare global {
  interface HTMLElementTagNameMap {
    'gpc-terminal': GpcTerminal;
  }
}
