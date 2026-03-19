import {LitElement, html, css} from 'lit';
import {customElement, property} from 'lit/decorators.js';

/**
 * <bit-field> — Displays a word value as a bit-field diagram.
 *
 * Usage:
 *   <bit-field label="HW1: F3E4" pattern="00000xxxddddddbb" value="0xf3e4"></bit-field>
 *   <bit-field label="PSW1" pattern="nnnnnnnnnnnnnnnnccwmriiiiiiiiiiiiii" value="0x005f0000" bits="32"></bit-field>
 *
 * The pattern is a string where each character names a field:
 *   - '0' or '1' = fixed opcode bits (grouped as 'op')
 *   - Any other letter = named field (consecutive same letters are one field)
 *
 * The diagram shows:
 *   - A label line
 *   - Hex value per field (yellow)
 *   - A box with field names (top row, blue) and individual bit values (bottom row)
 *   - Fields separated by solid borders, bits within a field by tick marks
 */
@customElement('bit-field')
export class BitField extends LitElement {

  @property({ type: Number }) value: number = 0;
  @property() pattern: string = '';
  @property() label: string = '';
  @property({ type: Number }) bits: number = 16;

  private _parseFields(): Array<{ name: string; bits: number[] }> {
    const fields: Array<{ name: string; bits: number[] }> = [];
    let current: { name: string; bits: number[] } | null = null;
    for (let i = 0; i < this.pattern.length; i++) {
      const ch = this.pattern[i];
      const fieldName = (ch === '0' || ch === '1') ? 'op' : ch;
      if (current && current.name === fieldName) {
        current.bits.push(i);
      } else {
        current = { name: fieldName, bits: [i] };
        fields.push(current);
      }
    }
    return fields;
  }

  private _fieldValue(field: { name: string; bits: number[] }): number {
    const bitWidth = this.bits || this.pattern.length;
    let val = 0;
    for (const bitIdx of field.bits) {
      const bitPos = (bitWidth - 1) - bitIdx;
      val = (val << 1) | ((this.value >>> bitPos) & 1);
    }
    return val;
  }

  render() {
    if (!this.pattern) return html``;
    const fields = this._parseFields();
    const bitWidth = this.bits || this.pattern.length;

    return html`
      ${this.label ? html`<div class="label">${this.label}</div>` : ''}
      <div class="hex-row">
        ${fields.map(f => {
          const hexStr = this._fieldValue(f).toString(16).toUpperCase();
          return html`<span class="hex-cell" style="flex: ${f.bits.length}">${hexStr}</span>`;
        })}
      </div>
      <div class="diagram">
        ${fields.map((f, fIdx) => html`
          <div class="field" style="flex: ${f.bits.length}; ${fIdx > 0 ? 'border-left: 1px solid var(--bf-border, #888);' : ''}">
            <div class="field-name">${f.name === 'op' ? '' : f.name}</div>
            <div class="bit-row">
              ${f.bits.map((bitIdx, bIdx) => {
                const bitPos = (bitWidth - 1) - bitIdx;
                const bitVal = (this.value >>> bitPos) & 1;
                return html`<span class="bit-cell" style="${bIdx > 0 ? 'border-left: 1px solid var(--bf-tick, #444);' : ''}">${bitVal}</span>`;
              })}
            </div>
          </div>
        `)}
      </div>
    `;
  }

  static styles = css`
    :host {
      display: block;
      margin-bottom: 6px;
      font-family: 'Consolas for Powerline', Consolas, monospace;
      font-size: 9px;
    }

    .label {
      font-size: 10px;
      color: var(--bf-label-color, #777);
      margin-bottom: 2px;
    }

    .hex-row {
      display: flex;
      color: var(--bf-hex-color, #ff0);
      height: 12px;
    }

    .hex-cell {
      text-align: center;
      min-width: 0;
    }

    .diagram {
      display: flex;
      border: 1px solid var(--bf-border, #888);
      height: 28px;
    }

    .field {
      display: flex;
      flex-direction: column;
      min-width: 0;
      position: relative;
    }

    .field-name {
      text-align: center;
      color: var(--bf-field-color, #aaf);
      height: 14px;
      line-height: 14px;
      overflow: hidden;
    }

    .bit-row {
      display: flex;
      height: 14px;
      line-height: 14px;
    }

    .bit-cell {
      flex: 1;
      text-align: center;
      color: var(--bf-bit-color, #ccc);
      min-width: 0;
    }
  `;
}

declare global {
  interface HTMLElementTagNameMap {
    'bit-field': BitField;
  }
}
