import {LitElement, html, css} from 'lit';
import {property, customElement} from 'lit/decorators.js';
import {FloatIBM} from 'gpc/floatIBM';

/**
 * <gpc-register> — Displays a single register value.
 *
 * Properties:
 *   name     — label (e.g. "R0", "F3", "P1")
 *   value    — 32-bit register value
 *   bits     — bit width (default 32)
 *   type     — "int" (default) or "float" (enables click-to-cycle display modes)
 *   changed  — if true, value is shown in red (recently written)
 *   dim      — if true, value is shown dimmed (inactive bank)
 *
 * For type="float", clicking cycles: hex → float → hex
 */
@customElement('gpc-register')
export class GpcRegister extends LitElement {

  @property({ type: String }) name: string = '';
  @property({ type: Number }) value: number = 0;
  @property({ type: Number }) bits: number = 32;
  @property({ type: String }) type: string = 'int';
  @property({ type: Boolean }) changed: boolean = false;
  @property({ type: Boolean }) dim: boolean = false;

  private _displayMode: number = 0; // 0=hex, 1=float

  private _fmtHex(): string {
    const h = (this.value >>> 0).toString(16).padStart(Math.ceil(this.bits / 4), '0');
    if (this.bits <= 16) return h;
    return `${h.substring(0, h.length - 4)} ${h.substring(h.length - 4)}`;
  }

  private _fmtFloat(): string {
    const f = FloatIBM.From32(this.value);
    return f.toFloat().toPrecision(7);
  }

  private _getDisplay(): { text: string; title: string } {
    if (this.type === 'float' && this._displayMode === 1) {
      return { text: this._fmtFloat(), title: `${this._fmtHex()} (click for hex)` };
    }
    const title = this.type === 'float' ? 'click for float' : '';
    return { text: this._fmtHex(), title };
  }

  private _onClick(): void {
    if (this.type !== 'float') return;
    this._displayMode = (this._displayMode + 1) % 2;
    this.requestUpdate();
  }

  private _getColor(): string {
    if (this.changed) return 'var(--reg-changed, #f55)';
    if (this.dim) return 'var(--reg-dim, #555)';
    return 'var(--reg-active, #ccc)';
  }

  render() {
    const { text, title } = this._getDisplay();
    const isClickable = this.type === 'float';
    return html`
      ${this.name ? html`<span class="label">${this.name}</span>` : ''}
      <span class="value ${isClickable ? 'clickable' : ''}"
        style="color: ${this._getColor()}; ${this.type === 'float' && this._displayMode === 1 ? 'min-width: 95px; display: inline-block;' : ''}"
        title="${title}"
        @click="${this._onClick}">${text}</span>
    `;
  }

  static styles = css`
    :host {
      display: inline-flex;
      align-items: center;
      font-family: 'Consolas for Powerline', Consolas, monospace;
      font-size: 11px;
      line-height: 16px;
    }

    .label {
      color: var(--reg-label, #77f);
      width: 20px;
    }

    .value {
      border: 1px solid #444;
    }

    .clickable {
      cursor: pointer;
    }
  `;
}

declare global {
  interface HTMLElementTagNameMap {
    'gpc-register': GpcRegister;
  }
}
