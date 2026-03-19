import {LitElement, html, css} from 'lit';
import {customElement} from 'lit/decorators.js';
import 'gpc/gui/gpc-register';

/**
 * <gpc-regview> — Displays AP-101 register file, PSW, NIA, and CC.
 *
 * Properties (set via JS):
 *   cpu — CPU instance (reads regFiles, psw)
 *
 * Public methods:
 *   refresh() — re-read registers and re-render with change highlighting
 *   resetTracking() — clear change tracking (call on simulator reset)
 */
@customElement('gpc-regview')
export class GpcRegview extends LitElement {

  cpu: any = null;

  // Step number of last refresh — registers written after this are "changed"
  private _lastRefreshStep: number = 0;

  resetTracking(): void {
    this._lastRefreshStep = 0;
  }

  refresh(): void {
    if (!this.cpu) return;
    const regEl = this.shadowRoot?.getElementById('int-regs');
    const pswEl = this.shadowRoot?.getElementById('psw-regs');
    if (!regEl) return;

    regEl.innerHTML = '';

    const regSet = this.cpu.psw.getRegSet(); // 0 or 1
    const ACTIVE = '#ccc';
    const DIM = '#555';
    const CHANGED = '#f55';
    const prevStep = this._lastRefreshStep;
    this._lastRefreshStep = this.cpu.mainStorage.step;

    // Check if a register was written since the last refresh
    const wasWritten = (regFile: any, regNum: number): boolean =>
      regFile.getLastWritten(regNum) > prevStep;
    const dseWasWritten = (regFile: any, baseReg: number): boolean =>
      regFile.getDSELastWritten(baseReg) > prevStep;

    const fmtHex32 = (val: number): string => {
      const h = (val >>> 0).toString(16).padStart(8, '0');
      return `${h.substring(0, 4)} ${h.substring(4)}`;
    };

    for (let i = 0; i < 8; i++) {
      const row = document.createElement('div');
      row.className = 'row';

      // Bank 0 (R0-R7)
      const r0Val = this.cpu.regFiles[0].r(i).get32();
      const r0Changed = wasWritten(this.cpu.regFiles[0], i);

      const r0Label = document.createElement('span');
      r0Label.className = 'reg-label';
      r0Label.textContent = `R${i}`;

      const r0Value = document.createElement('span');
      r0Value.className = 'reg-value';
      r0Value.style.color = r0Changed ? CHANGED : regSet === 0 ? ACTIVE : DIM;
      r0Value.textContent = fmtHex32(r0Val);

      row.appendChild(r0Label);
      row.appendChild(r0Value);

      // Bank 1 (R8-R15, no label)
      const r1Val = this.cpu.regFiles[1].r(i).get32();
      const r1Changed = wasWritten(this.cpu.regFiles[1], i);

      const r1Value = document.createElement('span');
      r1Value.className = 'reg-value';
      r1Value.style.color = r1Changed ? CHANGED : regSet === 1 ? ACTIVE : DIM;
      r1Value.textContent = fmtHex32(r1Val);

      row.appendChild(r1Value);

      // DSE (rows 0-3 only)
      if (i < 4) {
        for (let bank = 0; bank < 2; bank++) {
          const dseVal = this.cpu.regFiles[bank].getDSE(i);
          const dseChanged = dseWasWritten(this.cpu.regFiles[bank], i);

          const dseSpan = document.createElement('span');
          dseSpan.className = 'dse-value';
          dseSpan.style.color = dseChanged ? CHANGED
            : ((bank === 0 && regSet === 0) || (bank === 1 && regSet === 1)) ? ACTIVE : DIM;
          dseSpan.textContent = dseVal.toString(16);
          row.appendChild(dseSpan);
        }
      } else {
        for (let bank = 0; bank < 2; bank++) {
          const spacer = document.createElement('span');
          spacer.className = 'dse-spacer';
          row.appendChild(spacer);
        }
      }

      // Float register (F0-F7) via <gpc-register type="float">
      const fpVal = this.cpu.regFiles[2].r(i).get32();
      const fpChanged = wasWritten(this.cpu.regFiles[2], i);

      const fpReg = document.createElement('gpc-register') as any;
      fpReg.name = `F${i}`;
      fpReg.value = fpVal;
      fpReg.type = 'float';
      fpReg.changed = fpChanged;
      fpReg.className = 'fp-reg';
      row.appendChild(fpReg);
      regEl.appendChild(row);
    }

    // PSW
    if (!pswEl) return;
    pswEl.innerHTML = '';

    const psw1Val = this.cpu.psw.psw1.get32();
    const psw1Changed = this.cpu.psw.lastWritten1 > prevStep;

    const psw2Val = this.cpu.psw.psw2.get32();
    const psw2Changed = this.cpu.psw.lastWritten2 > prevStep;

    const addPswRow = (label: string, value: string, color: string, labelColor: string = '#77f') => {
      const row = document.createElement('div');
      row.className = 'row';
      const lbl = document.createElement('span');
      lbl.className = 'reg-label';
      lbl.style.color = labelColor;
      lbl.textContent = label;
      const val = document.createElement('span');
      val.className = 'reg-value';
      val.style.color = color;
      val.textContent = value;
      row.appendChild(lbl);
      row.appendChild(val);
      pswEl.appendChild(row);
    };

    addPswRow('P1', fmtHex32(psw1Val), psw1Changed ? CHANGED : ACTIVE);
    addPswRow('P2', fmtHex32(psw2Val), psw2Changed ? CHANGED : ACTIVE);
    addPswRow('NIA', this.cpu.psw.getNIA().toString(16).padStart(5, '0'), ACTIVE, '#f80');
    addPswRow('CC', this.cpu.psw.getCC().toString(2).padStart(2, '0'), ACTIVE);
  }

  render() {
    return html`
      <div class="section-label">REGISTERS</div>
      <div id="int-regs"></div>
      <div class="section-label" style="margin-top: 4px;">PSW</div>
      <div id="psw-regs"></div>
    `;
  }

  static styles = css`
    :host {
      display: block;
      font-family: 'Consolas for Powerline', Consolas, monospace;
      font-size: 11px;
    }

    .section-label {
      color: #888;
      font-size: 10px;
      margin-bottom: 2px;
      border-bottom: 1px solid #333;
      padding-bottom: 2px;
    }

    .row {
      display: flex;
      gap: 4px;
      line-height: 16px;
    }

    .reg-label {
      color: #77f;
      width: 20px;
    }



    .reg-value {
      border: 1px solid #444;
    }

    .dse-value {
      border: 1px solid #444;
      min-width: 8px;
      text-align: center;
    }

    .dse-spacer {
      min-width: 8px;
      border: 1px solid transparent;
    }

    .fp-reg {
      margin-left: 8px;
    }
  `;
}

declare global {
  interface HTMLElementTagNameMap {
    'gpc-regview': GpcRegview;
  }
}
