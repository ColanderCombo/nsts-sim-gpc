import {LitElement, html, css, render} from 'lit';
import {customElement} from 'lit/decorators.js';
import 'cde/toolbar';

interface LabelSym {
  name: string;
  address?: number;
  type?: string;        // "section" | "entry" | "local"
  kind?: string;        // "section" | "code" | "data" | "equ"
  scope?: string;       // "global" | "local"
  section?: string | null;
  module?: string;
}

const KIND_COLOR: Record<string, string> = {
  code: '#7ec7ff',     // code labels -- blue
  data: '#c8a0ff',     // data labels -- purple
  section: '#ffd479',  // sections    -- amber
  equ: '#9aa0a6',      // EQU / absolute -- grey
};

@customElement('gpc-labels')
export class GpcLabels extends LitElement {

  sym: any = null;

  private _filter = '';
  private _contentEl: HTMLDivElement | null = null;
  // Filter is hoisted into the dock tab strip (see getToolbar()).
  private _toolbarEl: HTMLElement | null = null;


  firstUpdated(): void {
    this._contentEl = this.shadowRoot!.getElementById('content') as HTMLDivElement;
    this.refresh();
  }

  private _onFilter(e: Event): void {
    this._filter = (e.target as HTMLInputElement).value.trim().toLowerCase();
    this.refresh();
  }


  refresh(): void {
    const container = this._contentEl;
    if (!container) return;
    container.innerHTML = '';

    const syms: LabelSym[] = this.sym?.symbols?.symbols || [];
    if (syms.length === 0) {
      this._placeholder(container, 'No labels');
      return;
    }

    // Address-ordered, name as tiebreak; only addressed labels are navigable.
    const rows = syms
      .filter(s => s.address != null)
      .filter(s => !this._filter || s.name.toLowerCase().includes(this._filter))
      .sort((a, b) => (a.address! - b.address!) || a.name.localeCompare(b.name));

    if (rows.length === 0) {
      this._placeholder(container, 'No match');
      return;
    }

    for (const s of rows) {
      container.appendChild(this._row(s));
    }
  }


  private _placeholder(container: HTMLElement, text: string): void {
    const div = document.createElement('div');
    div.style.cssText = 'color: #666; font-style: italic; padding: 4px;';
    div.textContent = text;
    container.appendChild(div);
  }

  private _row(s: LabelSym): HTMLDivElement {
    const row = document.createElement('div');
    row.className = 'row';

    const kind = s.kind || (s.type === 'section' ? 'section' : 'code');
    const color = KIND_COLOR[kind] || '#ddd';
    const addrHex = s.address!.toString(16).padStart(5, '0');

    const isTarget = s.scope === 'global' || s.type === 'section' || s.type === 'entry';
    const marker = isTarget ? '▸' : '·';  // ▸ target  ·  local

    const markerSpan = document.createElement('span');
    markerSpan.className = 'marker';
    markerSpan.textContent = marker;
    markerSpan.style.color = isTarget ? color : '#555';

    const addrSpan = document.createElement('span');
    addrSpan.className = 'addr';
    addrSpan.textContent = addrHex;

    const nameSpan = document.createElement('span');
    nameSpan.className = 'name';
    nameSpan.textContent = s.name;
    nameSpan.style.color = color;
    if (isTarget) nameSpan.style.fontWeight = 'bold';

    row.appendChild(markerSpan);
    row.appendChild(addrSpan);
    row.appendChild(nameSpan);

    const scope = s.scope || (isTarget ? 'global' : 'local');
    row.title = `${s.name}  @0x${addrHex}  ${kind}/${scope}` +
      (s.section ? `  in ${s.section}` : '') +
      (s.module ? `  (${s.module})` : '');

    row.onclick = () => {
      this.dispatchEvent(new CustomEvent('label-selected', {
        detail: { name: s.name, address: s.address },
        bubbles: true,
        composed: true,
      }));
    };

    return row;
  }

  // --- Template ---

  render() {
    return html`<div id="content"></div>`;
  }

  // Filter box hoisted into the dock tab strip.
  getToolbar(): HTMLElement {
    if (!this._toolbarEl) {
      this._toolbarEl = document.createElement('div');
      this._toolbarEl.style.display = 'contents';
    }
    render(html`
      <sim-toolbar>
        <input type="text" placeholder="filter…" spellcheck="false"
          style="background:#1e1e1e; border:1px solid #333; color:#ddd; font:10px 'Consolas for Powerline',Consolas,monospace; padding:1px 3px;"
          @input="${this._onFilter}" />
      </sim-toolbar>
    `, this._toolbarEl, { host: this });
    return this._toolbarEl;
  }

  // --- Styles ---

  static styles = css`
    :host {
      display: flex;
      flex-direction: column;
      overflow: hidden;
      padding-left: 4px;
      font-family: 'Consolas for Powerline', Consolas, monospace;
      min-height: 0;
      min-width: 0;
      flex: 1;
    }

    #content {
      flex: 1;
      overflow: auto;
    }

    .row {
      display: flex;
      align-items: baseline;
      gap: 4px;
      padding: 1px 2px;
      cursor: pointer;
      white-space: nowrap;
      font-size: 10px;
      line-height: 14px;
    }

    .row:hover {
      background: #2a2d2e;
    }

    .marker {
      flex: 0 0 auto;
      width: 8px;
      text-align: center;
    }

    .addr {
      flex: 0 0 auto;
      color: #888;
    }

    .name {
      flex: 1 1 auto;
      overflow: hidden;
      text-overflow: ellipsis;
    }
  `;
}

declare global {
  interface HTMLElementTagNameMap {
    'gpc-labels': GpcLabels;
  }
}
