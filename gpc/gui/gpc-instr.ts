import {LitElement, html, css} from 'lit';
import {customElement} from 'lit/decorators.js';
import 'cde/bit-field';
import 'com/util';
import Instruction from 'gpc/cpu_instr';

/**
 * <gpc-instr> — Displays decoded instruction bit-field diagrams
 * for the instruction at the current NIA.
 *
 * Properties (set via JS):
 *   cpu — CPU instance (reads NIA, mainStorage, registers)
 *
 * Public methods:
 *   refresh() — re-decode instruction at NIA and re-render
 */
@customElement('gpc-instr')
export class GpcInstr extends LitElement {

  cpu: any = null;

  refresh(): void {
    const container = this.shadowRoot?.getElementById('content');
    if (!container || !this.cpu) return;
    container.innerHTML = '';

    const nia = this.cpu.psw.getNIA();
    const hw1 = this.cpu.mainStorage.get16(nia, false);
    const hw2 = this.cpu.mainStorage.get16(nia + 1, false);
    const [desc, v] = Instruction.decode(hw1, hw2);
    if (!desc) return;

    // Title: mnemonic + full name
    const titleDiv = document.createElement('div');
    titleDiv.className = 'title';
    const mnSpan = document.createElement('span');
    mnSpan.className = 'mnemonic';
    mnSpan.textContent = desc.nm;
    titleDiv.appendChild(mnSpan);
    if (desc.fullName) {
      const nameSpan = document.createElement('span');
      nameSpan.className = 'fullname';
      nameSpan.textContent = `  ${desc.fullName}`;
      titleDiv.appendChild(nameSpan);
    }
    container.appendChild(titleDiv);

    const addBF = (value: number, pattern: string, label: string, bits: number = 16) => {
      const el = document.createElement('bit-field') as any;
      el.setAttribute('label', label);
      el.setAttribute('pattern', pattern);
      el.setAttribute('value', String(value >>> 0));
      el.setAttribute('bits', String(bits));
      container.appendChild(el);
    };

    // HW1
    const hw1Pattern = desc.d.split('/')[0];
    addBF(hw1, hw1Pattern, `HW1: ${hw1.toString(16).toUpperCase().padStart(4, '0')}`);

    // HW2 if present
    const len = desc.len ?? desc.origLen ?? 1;
    if (len > 1) {
      let hw2Pattern: string | null = null;
      let hw2Note = '';
      if (desc.type === 'RI' || desc.type === 'SI') {
        hw2Pattern = 'IIIIIIIIIIIIIIII';
        hw2Note = ` (${desc.type})`;
      } else if (desc.type === 'RS') {
        if (v.a === 1) {
          hw2Pattern = 'xxxaiddddddddddd';
          hw2Note = ' (indexed, AM=1)';
        } else {
          hw2Pattern = 'dddddddddddddddd';
          hw2Note = ' (extended, AM=0)';
        }
      } else if (desc.type === 'SRS') {
        if (v.extended) {
          hw2Pattern = v.i != null ? 'xxxaiddddddddddd' : 'dddddddddddddddd';
          hw2Note = v.i != null ? ' (indexed)' : ' (extended)';
        }
      } else {
        hw2Pattern = 'dddddddddddddddd';
      }
      if (hw2Pattern) {
        addBF(hw2, hw2Pattern, `HW2: ${hw2.toString(16).toUpperCase().padStart(4, '0')}${hw2Note}`);
      }
    }

    // Register decode diagrams for dx/dy
    for (const regField of ['x', 'y']) {
      const regPattern = desc[`d${regField}`];
      if (!regPattern || v[regField] == null) continue;
      const regNum = v[regField];
      const regVal = this.cpu.r(regNum).get32();
      const bitWidth = regPattern.length;
      const hexChars = Math.ceil(bitWidth / 4);
      const regLabel = `R${regNum} (${regField}): ${(regVal >>> 0).toString(16).toUpperCase().padStart(hexChars, '0')}`;
      addBF(regVal, regPattern, regLabel, bitWidth);
    }
  }

  render() {
    return html`<div id="content"></div>`;
  }

  static styles = css`
    :host {
      display: block;
      font-family: 'Consolas for Powerline', Consolas, monospace;
    }

    .title {
      font-size: 11px;
      color: #0f0;
      margin-bottom: 4px;
    }

    .mnemonic {
      font-weight: bold;
    }

    .fullname {
      color: #888;
    }
  `;
}

declare global {
  interface HTMLElementTagNameMap {
    'gpc-instr': GpcInstr;
  }
}
