import {LitElement, html, css} from 'lit';
import {customElement} from 'lit/decorators.js';
import 'com/util';
import Instruction from 'gpc/cpu_instr';

/**
 * <gpc-breakpoints> — Displays the breakpoint list.
 *
 * Properties (set via JS):
 *   cpu         — CPU instance (reads mainStorage for instruction disassembly)
 *   breakpoints — Map<number, {enabled: boolean}>
 *
 * Public methods:
 *   refresh() — re-render the breakpoint list
 *
 * Events:
 *   breakpoint-toggle — detail: { addr }   (left click)
 *   breakpoint-menu   — detail: { addr, x, y } (right click)
 */
@customElement('gpc-breakpoints')
export class GpcBreakpoints extends LitElement {

  cpu: any = null;
  breakpoints: Map<number, { enabled: boolean }> | null = null;

  private _disasmFields(hw1: number, hw2: number): { mnemonic: string; args: string } {
    const [d, v] = Instruction.decode(hw1, hw2);
    if (!d) {
      return { mnemonic: 'DW', args: `X'${hw1.toString(16).padStart(4, '0')}'` };
    }
    const full = Instruction.toStr(hw1, hw2);
    return { mnemonic: full.substring(0, 5).trim(), args: full.substring(5) };
  }

  refresh(): void {
    const container = this.shadowRoot?.getElementById('content');
    if (!container) return;
    container.innerHTML = '';

    if (!this.breakpoints || this.breakpoints.size === 0) {
      const empty = document.createElement('div');
      empty.className = 'empty';
      empty.textContent = '(none)';
      container.appendChild(empty);
      return;
    }

    const sorted = Array.from(this.breakpoints.entries()).sort((a, b) => a[0] - b[0]);

    for (const [addr, bp] of sorted) {
      const row = document.createElement('div');
      row.className = 'row';
      if (!bp.enabled) row.classList.add('disabled');

      // Circle
      const circle = document.createElement('span');
      circle.className = 'circle';
      circle.style.color = bp.enabled ? '#e22' : '#666';
      circle.textContent = '\u25CF';
      row.appendChild(circle);

      // Address
      const addrSpan = document.createElement('span');
      addrSpan.className = 'addr';
      addrSpan.textContent = addr.toString(16).padStart(5, '0');
      row.appendChild(addrSpan);

      // Disassemble instruction
      if (this.cpu) {
        const hw1 = this.cpu.mainStorage.get16(addr, false);
        const hw2 = this.cpu.mainStorage.get16(addr + 1, false);
        const fields = this._disasmFields(hw1, hw2);

        const mnSpan = document.createElement('span');
        mnSpan.className = 'mnemonic';
        mnSpan.textContent = fields.mnemonic;
        row.appendChild(mnSpan);

        const argSpan = document.createElement('span');
        argSpan.className = 'args';
        argSpan.textContent = fields.args.trim();
        row.appendChild(argSpan);
      }

      // Left click: toggle
      row.addEventListener('click', () => {
        this.dispatchEvent(new CustomEvent('breakpoint-toggle', {
          detail: { addr }, bubbles: true, composed: true,
        }));
      });

      // Right click: context menu
      row.addEventListener('contextmenu', (e: MouseEvent) => {
        e.preventDefault();
        e.stopPropagation();
        this.dispatchEvent(new CustomEvent('breakpoint-menu', {
          detail: { addr, x: e.clientX, y: e.clientY },
          bubbles: true, composed: true,
        }));
      });

      container.appendChild(row);
    }
  }

  render() {
    return html`<div id="content"></div>`;
  }

  static styles = css`
    :host {
      display: block;
      overflow: auto;
      font-family: 'Consolas for Powerline', Consolas, monospace;
      font-size: 10px;
    }

    .empty {
      color: #555;
      font-style: italic;
      padding: 2px;
    }

    .row {
      display: flex;
      align-items: center;
      gap: 4px;
      line-height: 14px;
      padding: 1px 2px;
      cursor: pointer;
      white-space: nowrap;
    }

    .row:hover {
      background-color: #282828;
    }

    .row.disabled {
      opacity: 0.5;
    }

    .circle {
      font-size: 9px;
      width: 10px;
      text-align: center;
    }

    .addr {
      color: #888;
    }

    .mnemonic {
      color: #0d0;
    }

    .args {
      color: #aaa;
      overflow: hidden;
      text-overflow: ellipsis;
      flex: 1;
      min-width: 0;
    }
  `;
}

declare global {
  interface HTMLElementTagNameMap {
    'gpc-breakpoints': GpcBreakpoints;
  }
}
