import {LitElement, html, css} from 'lit';
import {customElement} from 'lit/decorators.js';
import {readHalfwords, formatTypedValue} from 'gpc/gui/memformat';

/**
 * <gpc-watch> — Displays symbol values (watch panel).
 *
 * Properties (set via JS):
 *   cpu  — CPU instance (reads mainStorage)
 *   sym  — SymbolTable instance (symbols, symTypes, getSectionAt, getSymbolSize)
 *
 * Public methods:
 *   refresh() — re-read memory and re-render symbol values
 *
 * Events:
 *   watch-selected — detail: { name: string|null, addresses: Set<number>|null }
 *     Fired when user clicks a symbol row (toggles selection).
 */
@customElement('gpc-watch')
export class GpcWatch extends LitElement {

  cpu: any = null;
  sym: any = null;

  private _selected: string | null = null;

  refresh(): void {
    const container = this.shadowRoot?.getElementById('content');
    if (!container || !this.cpu || !this.sym?.symbols?.symbols) {
      if (container) container.innerHTML = '';
      return;
    }
    container.innerHTML = '';

    for (const sym of this.sym.symbols.symbols) {
      if (sym.type === 'section') continue;

      // Resolve type from symTypes
      let typeInfo: any = null;
      if (this.sym.symTypes) {
        const sect = this.sym.getSectionAt(sym.address);
        if (sect) {
          typeInfo = this.sym.symTypes[`${sect}.${sym.name}`];
        }
        if (!typeInfo) typeInfo = this.sym.symTypes[sym.name];
      }

      const displayType: string = typeInfo?.type || 'hw';
      const displaySize: number = typeInfo?.size || 1;

      // Determine how many halfwords to read
      let readCount = displaySize;
      if (displayType === 'fw' || displayType === 'int32' || displayType === 'float') readCount = 2;
      else if (displayType === 'dfloat') readCount = 4;

      const addr = sym.address;
      const hws = readHalfwords(this.cpu.mainStorage, addr, readCount);
      const valueStr = formatTypedValue(displayType, hws, displaySize);
      const symSize = this.sym.getSymbolSize(sym, displayType, displaySize);
      const isSelected = this._selected === sym.name;

      const row = document.createElement('div');
      row.className = 'row';
      if (isSelected) row.classList.add('selected');

      // Address
      const addrSpan = document.createElement('span');
      addrSpan.className = 'addr';
      addrSpan.textContent = addr.toString(16).padStart(5, '0');

      // Name
      const nameSpan = document.createElement('span');
      nameSpan.className = 'name';
      if (isSelected) nameSpan.classList.add('name-selected');
      nameSpan.textContent = sym.name;
      nameSpan.title = `${sym.name} @ 0x${addr.toString(16).padStart(5, '0')} (${symSize} hw)`;

      // Value — right-justified, monospace
      const valSpan = document.createElement('span');
      valSpan.className = 'value';
      valSpan.textContent = valueStr;
      valSpan.title = valueStr;

      // Click to select/deselect
      row.addEventListener('click', () => {
        if (this._selected === sym.name) {
          this._selected = null;
          this.dispatchEvent(new CustomEvent('watch-selected', {
            detail: { name: null, addresses: null },
            bubbles: true, composed: true,
          }));
        } else {
          this._selected = sym.name;
          const addrs = new Set<number>();
          for (let i = 0; i < symSize; i++) addrs.add(addr + i);
          this.dispatchEvent(new CustomEvent('watch-selected', {
            detail: { name: sym.name, addresses: addrs },
            bubbles: true, composed: true,
          }));
        }
        this.refresh();
      });

      row.appendChild(addrSpan);
      row.appendChild(nameSpan);
      row.appendChild(valSpan);
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
      font-size: 11px;
    }

    .row {
      display: flex;
      line-height: 14px;
      cursor: pointer;
      padding: 0 2px;
      white-space: nowrap;
    }

    .row:hover {
      background-color: #1a1a1a;
    }

    .row.selected {
      background-color: #2a2a00;
    }

    .addr {
      color: #666;
      margin-right: 4px;
      flex: 0 0 auto;
    }

    .name {
      color: #7af;
      margin-right: 4px;
      flex: 0 0 auto;
    }

    .name-selected {
      color: #ff0;
    }

    .value {
      color: #ccc;
      flex: 1;
      min-width: 0;
      text-align: right;
      overflow: hidden;
      text-overflow: ellipsis;
    }
  `;
}

declare global {
  interface HTMLElementTagNameMap {
    'gpc-watch': GpcWatch;
  }
}
