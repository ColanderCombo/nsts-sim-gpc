import {LitElement, html, css} from 'lit';
import {property, state, customElement} from 'lit/decorators.js';
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

  @property({ type: String })  declare name: string;
  @property({ type: Number })  declare value: number;
  @property({ type: Number })  declare bits: number;
  @property({ type: String })  declare type: string;
  @property({ type: Boolean }) declare changed: boolean;
  @property({ type: Boolean }) declare dim: boolean;
  // When true, double-clicking the value opens an inline hex editor; committing
  // with Enter updates `value` and fires a `register-edit` {value} event.
  @property({ type: Boolean }) declare editable: boolean;
  @state()                     declare private _displayMode: number; // 0=hex, 1=float
  @state()                     declare private _editing: boolean;

  constructor() {
    super();
    this.name = '';
    this.value = 0;
    this.bits = 32;
    this.type = 'int';
    this.changed = false;
    this.dim = false;
    this.editable = false;
    this._displayMode = 0;
    this._editing = false;
  }

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
    if (this._editing) return;
    if (this.type !== 'float') return;
    this._displayMode = (this._displayMode + 1) % 2;
  }

  // --- inline editing ---

  private _editInitial(): string {
    return (this.value >>> 0).toString(16).padStart(Math.ceil(this.bits / 4), '0');
  }

  private _onValueDblClick(e: Event): void {
    if (!this.editable) return;
    e.preventDefault();
    e.stopPropagation();
    this._editing = true;
  }

  private _onEditKey(e: KeyboardEvent): void {
    // Keep keystrokes from reaching the global debugger shortcuts (s/r/p/f…).
    e.stopPropagation();
    if (e.key === 'Enter') {
      const v = parseInt((e.target as HTMLInputElement).value.replace(/[^0-9a-fA-F]/g, ''), 16);
      if (Number.isFinite(v)) {
        this.value = v >>> 0;
        this.dispatchEvent(new CustomEvent('register-edit', {
          detail: { value: this.value }, bubbles: true, composed: true,
        }));
      }
      this._editing = false;
    } else if (e.key === 'Escape') {
      this._editing = false;
    }
  }

  updated(): void {
    if (this._editing) {
      const inp = this.shadowRoot?.querySelector('input') as HTMLInputElement | null;
      if (inp && this.shadowRoot!.activeElement !== inp) { inp.focus(); inp.select(); }
    }
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
      ${this._editing
        ? html`<input class="edit" type="text" .value="${this._editInitial()}"
            spellcheck="false"
            @keydown="${this._onEditKey}"
            @blur="${() => { this._editing = false; }}" />`
        : html`<span class="value ${isClickable ? 'clickable' : ''} ${this.editable ? 'editable' : ''}"
            style="color: ${this._getColor()}; ${this.type === 'float' && this._displayMode === 1 ? 'min-width: 95px; display: inline-block;' : ''}"
            title="${this.editable ? 'double-click to edit' : title}"
            @click="${this._onClick}"
            @dblclick="${this._onValueDblClick}">${text}</span>`}
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

    .editable {
      cursor: text;
    }

    .editable:hover {
      outline: 1px solid #fa0;
      outline-offset: -1px;
    }

    .edit {
      font-family: inherit;
      font-size: inherit;
      line-height: inherit;
      width: 72px;
      background: #000;
      color: #ff0;
      border: 1px solid #fa0;
      padding: 0 1px;
      margin: 0;
      outline: none;
      box-sizing: border-box;
    }
  `;
}

declare global {
  interface HTMLElementTagNameMap {
    'gpc-register': GpcRegister;
  }
}
