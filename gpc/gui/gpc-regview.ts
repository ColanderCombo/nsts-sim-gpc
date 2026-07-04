import {LitElement, html, css} from 'lit';
import {customElement, property} from 'lit/decorators.js';
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

  // When true, double-clicking any register / field opens an inline hex editor.
  @property({ type: Boolean }) declare editable: boolean;

  // Step number of last refresh — registers written after this are "changed"
  private _lastRefreshStep: number = 0;
  private _editingSpan: HTMLElement | null = null;

  constructor() {
    super();
    this.editable = false;
  }

  resetTracking(): void {
    this._lastRefreshStep = 0;
  }

  // Re-render this pane after an edit and ask the host to sync the other panes
  // (e.g. editing NIA should move the disassembly view).
  private _afterEdit(): void {
    this.refresh();
    this.dispatchEvent(new CustomEvent('register-edited', { bubbles: true, composed: true }));
  }

  // Make a value span double-click editable.  `initial` is the editable text
  // (raw, no grouping space); `write` applies the parsed integer to the CPU.
  private _enableEdit(span: HTMLElement, initial: string,
                      write: (v: number) => void, radix: number = 16): void {
    if (!this.editable) return;
    span.classList.add('editable');
    span.title = 'double-click to edit';
    span.addEventListener('dblclick', (e: Event) => {
      e.preventDefault();
      this._beginEdit(span, initial, (text) => {
        const v = parseInt(text.trim().replace(/^0x/i, ''), radix);
        if (!Number.isFinite(v)) return false;
        write(v >>> 0);
        this._afterEdit();   // re-render this pane + notify host to sync others
        return true;
      });
    });
  }

  private _beginEdit(span: HTMLElement, initial: string,
                     commit: (text: string) => boolean): void {
    if (this._editingSpan) return;
    this._editingSpan = span;
    const prev = span.textContent ?? '';
    const input = document.createElement('input');
    input.type = 'text';
    input.value = initial;
    input.className = 'reg-edit';
    input.spellcheck = false;
    input.style.width = `${Math.max(3, initial.length + 1)}ch`;
    span.textContent = '';
    span.appendChild(input);
    input.focus();
    input.select();

    let done = false;
    const finish = (apply: boolean): void => {
      if (done) return;
      done = true;
      this._editingSpan = null;
      if (!apply || !commit(input.value)) {
        // commit() may have rebuilt the DOM via refresh(); if not, restore text.
        if (span.isConnected) span.textContent = prev;
      }
    };
    input.addEventListener('keydown', (e: KeyboardEvent) => {
      e.stopPropagation();   // don't trigger global debugger keys (s/r/p/f)
      if (e.key === 'Enter') { e.preventDefault(); finish(true); }
      else if (e.key === 'Escape') { e.preventDefault(); finish(false); }
    });
    input.addEventListener('blur', () => finish(false));
  }

  refresh(): void {
    if (!this.cpu) return;
    // Don't blow away an in-progress inline edit (commit clears _editingSpan
    // before calling refresh(), so committed writes still re-render).
    if (this._editingSpan) return;
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
      this._enableEdit(r0Value, (r0Val >>> 0).toString(16).padStart(8, '0'),
        (v) => this.cpu.regFiles[0].r(i).set32(v));

      row.appendChild(r0Label);
      row.appendChild(r0Value);

      // Bank 1 (R8-R15, no label)
      const r1Val = this.cpu.regFiles[1].r(i).get32();
      const r1Changed = wasWritten(this.cpu.regFiles[1], i);

      const r1Value = document.createElement('span');
      r1Value.className = 'reg-value';
      r1Value.style.color = r1Changed ? CHANGED : regSet === 1 ? ACTIVE : DIM;
      r1Value.textContent = fmtHex32(r1Val);
      this._enableEdit(r1Value, (r1Val >>> 0).toString(16).padStart(8, '0'),
        (v) => this.cpu.regFiles[1].r(i).set32(v));

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
          this._enableEdit(dseSpan, dseVal.toString(16),
            ((b: number, base: number) => (v: number) => this.cpu.regFiles[b].setDSE(base, v))(bank, i));
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
      fpReg.editable = this.editable;
      fpReg.className = 'fp-reg';
      if (this.editable) {
        const fi = i;
        fpReg.addEventListener('register-edit', (e: any) => {
          this.cpu.regFiles[2].r(fi).set32(e.detail.value >>> 0);
          this._afterEdit();
        });
      }
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

    const addPswRow = (label: string, value: string, color: string, labelColor: string = '#77f',
                       edit?: { initial: string; write: (v: number) => void; radix?: number }) => {
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
      if (edit) this._enableEdit(val, edit.initial, edit.write, edit.radix ?? 16);
      row.appendChild(lbl);
      row.appendChild(val);
      pswEl.appendChild(row);
    };

    addPswRow('P1', fmtHex32(psw1Val), psw1Changed ? CHANGED : ACTIVE, '#77f',
      { initial: (psw1Val >>> 0).toString(16).padStart(8, '0'), write: (v) => this.cpu.psw.psw1.set32(v) });
    addPswRow('P2', fmtHex32(psw2Val), psw2Changed ? CHANGED : ACTIVE, '#77f',
      { initial: (psw2Val >>> 0).toString(16).padStart(8, '0'), write: (v) => this.cpu.psw.psw2.set32(v) });
    addPswRow('NIA', this.cpu.psw.getNIA().toString(16).padStart(5, '0'), ACTIVE, '#f80',
      { initial: this.cpu.psw.getNIA().toString(16), write: (v) => this.cpu.psw.setNIA(v) });
    addPswRow('CC', this.cpu.psw.getCC().toString(2).padStart(2, '0'), ACTIVE, '#77f',
      { initial: this.cpu.psw.getCC().toString(2), write: (v) => this.cpu.psw.setCC(v), radix: 2 });
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

    .editable {
      cursor: text;
    }

    .editable:hover {
      outline: 1px solid #fa0;
      outline-offset: -1px;
    }

    .reg-edit {
      font-family: inherit;
      font-size: inherit;
      line-height: inherit;
      background: #000;
      color: #ff0;
      border: 1px solid #fa0;
      padding: 0;
      margin: 0;
      outline: none;
      box-sizing: border-box;
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
