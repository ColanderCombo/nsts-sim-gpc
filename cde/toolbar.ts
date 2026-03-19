import {LitElement, html, css} from 'lit';
import {customElement, property} from 'lit/decorators.js';

/**
 * <sim-toolbar> — A reusable horizontal toolbar / header bar.
 *
 * Usage:
 *   <sim-toolbar label="DISASSEMBLY">
 *     <button slot="controls">⬆</button>
 *     <input slot="controls" type="text" />
 *     <span slot="status">NIA: 005f</span>
 *   </sim-toolbar>
 *
 * Slots:
 *   (default)  — main content (buttons, inputs, etc.)
 *   "status"   — right-aligned status items
 *
 * Properties:
 *   label      — optional label text shown at the start
 *   label-color — label text color (default: #888)
 */
@customElement('sim-toolbar')
export class SimToolbar extends LitElement {

  @property() label: string = '';
  @property({ attribute: 'label-color' }) labelColor: string = '#888';

  render() {
    return html`
      <div id="bar">
        ${this.label ? html`<span class="label" style="color: ${this.labelColor}">${this.label}</span>` : ''}
        <slot></slot>
        <div id="status"><slot name="status"></slot></div>
      </div>
    `;
  }

  static styles = css`
    :host {
      display: block;
      flex: 0 0 auto;
    }

    #bar {
      display: flex;
      align-items: center;
      gap: 4px;
      padding: 2px 0;
      font-family: 'Consolas for Powerline', Consolas, monospace;
      font-size: 11px;
      color: #ccc;
    }

    .label {
      font-size: 10px;
      padding-bottom: 2px;
      border-bottom: 1px solid #333;
      white-space: nowrap;
    }

    #status {
      margin-left: auto;
      display: flex;
      gap: 8px;
      align-items: center;
      white-space: nowrap;
    }

    /* Style slotted buttons and inputs to match CDE theme */
    ::slotted(button) {
      padding: 2px 6px;
      background-color: #444;
      color: #eee;
      border: 1px solid #666;
      cursor: pointer;
      font-family: 'Consolas for Powerline', Consolas, monospace;
      font-size: 11px;
    }

    ::slotted(button:hover) {
      background-color: #555;
    }

    ::slotted(button.sm) {
      padding: 2px 6px;
      background-color: #333;
      color: #aaa;
      border: 1px solid #555;
      font-size: 10px;
    }

    ::slotted(button.sm:hover) {
      background-color: #444;
    }

    ::slotted(input[type="text"]) {
      width: 58px;
      padding: 2px 4px;
      background-color: #222;
      color: #ff0;
      border: 1px solid #555;
      font-size: 11px;
      font-family: 'Consolas for Powerline', Consolas, monospace;
    }

    ::slotted(.toolbar-label) {
      color: #666;
      font-size: 10px;
    }
  `;
}

declare global {
  interface HTMLElementTagNameMap {
    'sim-toolbar': CdeToolbar;
  }
}
